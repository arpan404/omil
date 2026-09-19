import AppKit
import Combine
import Foundation

// MARK: - ServerLifecycle
//
// The Mac app OWNS the inference server: it launches the embedded
// omil-server binary at startup, keeps it alive (bounded restarts), and stops
// it on quit. No manual `bun` invocation, no brew dependency at runtime.
//
// Server binary resolution order:
//   1. OMIL_SERVER_BIN env override (dev)
//   2. Embedded app resource (Release/dev bundle via scripts/build-server.sh)
// Sidecars + models come from ServerAssets (same Application Support dir).

@MainActor
final class ServerLifecycle: ObservableObject {
    enum Status: Equatable {
        case stopped
        case missingEngine(reason: String)
        case missingPrereqs
        case starting
        case ready(models: String)
        case degraded(reason: String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .missingEngine(let r): return "Engine missing: \(r)"
            case .missingPrereqs: return "Prerequisites missing"
            case .starting: return "Starting…"
            case .ready(let m): return "Ready (\(m))"
            case .degraded(let r): return "Degraded: \(r)"
            }
        }
    }

    static let port = 3217
    static let host = "127.0.0.1"

    @Published var status: Status = .stopped
    @Published var token: String = ""
    @Published var logPath: String = ServerAssets.logURL.path

    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var restarts = 0
    private var stopRequested = false
    private var onToken: ((String) -> Void)?

    var serverDir: URL { ServerAssets.serverDir }

    func engineURL() -> URL? {
        if let override_ = ProcessInfo.processInfo.environment["OMIL_SERVER_BIN"],
           FileManager.default.isExecutableFile(atPath: override_) {
            return URL(fileURLWithPath: override_)
        }
        if let bundled = Bundle.main.url(forResource: "omil-server", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    // MARK: Start / stop

    func start(onToken: ((String) -> Void)? = nil) {
        self.onToken = onToken
        stopRequested = false
        guard process == nil else { return }
        guard let engine = engineURL() else {
            status = .missingEngine(reason: "run scripts/build-server.sh, then rebuild the app")
            return
        }
        guard ServerAssets().allReadyForLaunch() else {
            status = .missingPrereqs
            return
        }
        launch(engine: engine)
    }

    private func launch(engine: URL) {
        status = .starting
        do {
            try FileManager.default.createDirectory(at: ServerAssets.serverDir, withIntermediateDirectories: true)
        } catch {
            status = .degraded(reason: "cannot create server dir: \(error)")
            return
        }
        // Rotate an oversized log.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: ServerAssets.logURL.path),
           (attrs[.size] as? Int64 ?? 0) > 10 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: ServerAssets.logURL)
        }
        let p = Process()
        p.executableURL = engine
        p.arguments = []
        p.currentDirectoryURL = ServerAssets.serverDir
        var env = ServerAssets.sidecarEnvironment()
        env["OMIL_HOST"] = Self.host
        env["OMIL_PORT"] = String(Self.port)
        env["OMIL_DATA"] = ServerAssets.serverDir.path
        env["OMIL_WHISPER_BIN"] = ServerAssets.binDir.appendingPathComponent("whisper/bin/whisper-cli").path
        env["OMIL_LLAMA_BIN"] = ServerAssets.binDir.appendingPathComponent("llama/bin/llama-server").path
        env["OMIL_LLAMA_PORT"] = "3218"
        p.environment = env
        if !FileManager.default.fileExists(atPath: ServerAssets.logURL.path) {
            FileManager.default.createFile(atPath: ServerAssets.logURL.path, contents: nil)
        }
        p.standardOutput = try? FileHandle(forWritingTo: ServerAssets.logURL)
        p.standardError = p.standardOutput
        // Append instead of truncating.
        (p.standardOutput as? FileHandle)?.seekToEndOfFile()
        do {
            try p.run()
        } catch {
            status = .degraded(reason: "launch failed: \(error)")
            return
        }
        process = p
        restarts = 0
        monitorTask?.cancel()
        monitorTask = Task { await self.monitorLoop() }
    }

    func stop() {
        stopRequested = true
        monitorTask?.cancel()
        monitorTask = nil
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if p.isRunning { p.interrupt() }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        status = .stopped
    }

    func restart() {
        stop()
        // Small delay so the port is released.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.stopRequested = false
            self?.start(onToken: self?.onToken)
        }
    }

    // MARK: Monitor

    private func monitorLoop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            // Process died unexpectedly?
            if let p = process, !p.isRunning, !stopRequested {
                consecutiveFailures += 1
                if consecutiveFailures > 5 || restarts >= 5 {
                    await MainActor.run {
                        self.status = .degraded(reason: "server exited repeatedly; see log")
                        self.process = nil
                    }
                    break
                }
                restarts += 1
                await MainActor.run { self.status = .starting }
                try? await Task.sleep(nanoseconds: UInt64(restarts) * 2_000_000_000)
                if let engine = engineURL() {
                    // Relaunch on the monitor task's behalf.
                    await MainActor.run { self.launch(engine: engine) }
                    consecutiveFailures = 0
                }
                continue
            }
            // Health probe (no auth, never downloads).
            let health = await probeHealth()
            await MainActor.run {
                switch health {
                case .ready(let models):
                    self.status = .ready(models: models)
                    self.readToken()
                case .starting:
                    if case .starting = self.status {} else { self.status = .starting }
                case .failed(let reason):
                    if !self.stopRequested {
                        self.status = .degraded(reason: reason)
                    }
                }
            }
        }
    }

    private enum Health { case ready(models: String); case starting; case failed(reason: String) }

    private func probeHealth() async -> Health {
        guard let url = URL(string: "http://\(Self.host):\(Self.port)/v1/health") else {
            return .failed(reason: "bad server URL")
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .starting }
            struct H: Codable {
                var whisperModelReady: Bool?
                var llmModelReady: Bool?
                var llamaLive: Bool?
            }
            let h = (try? JSONDecoder().decode(H.self, from: data)) ?? H(whisperModelReady: nil, llmModelReady: nil, llamaLive: nil)
            var models: [String] = []
            if h.whisperModelReady == true { models.append("whisper") }
            if h.llmModelReady == true { models.append("qwen") }
            if models.count == 2 { return .ready(models: models.joined(separator: " + ")) }
            return .starting
        } catch {
            return .failed(reason: "unreachable")
        }
    }

    private func readToken() {
        let url = ServerAssets.serverDir.appendingPathComponent("omil-token")
        guard token.isEmpty,
              let data = try? Data(contentsOf: url),
              let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              t.count >= 16 else { return }
        token = t
        onToken?(t)
    }
}

// MARK: - ServerAssets launch gate

extension ServerAssets {
    /// All four pins installed (fast path, no hashing).
    func allReadyForLaunch() -> Bool {
        refreshState()
        return allReady
    }
}
