import AppKit
import Combine
import CryptoKit
import Foundation
import OmilCore

// MARK: - ServerAssets
//
// App-owned prerequisites: the Mac app downloads everything the inference
// core needs with ONE button — whisper.cpp + llama.cpp sidecar binaries
// (Homebrew bottles fetched directly over HTTPS, no brew required) and both
// weight files. Every artifact is SHA-256 verified before use.
//
// Layout under ~/Library/Application Support/Omil/server/:
//   bin/whisper/{bin/whisper-cli, lib/*.dylib}
//   bin/llama/{bin/llama-server, lib/*.dylib}
//   models/{ggml-large-v3-turbo.bin, Qwen3-4B-Instruct-2507-Q4_K_M.gguf, manifest.local.json}
//   omil-server.log

@MainActor
final class ServerAssets: ObservableObject {
    struct Pin {
        var id: String
        var displayName: String
        var version: String
        var url: URL
        /// Pinned SHA-256. nil = trust-on-first-use (verified + pinned after download).
        var sha256: String?
        var approxBytes: Int64
        var kind: Kind
        enum Kind { case bottleWhisper, bottleLlama, weights }
    }

    struct CatalogOption {
        var id: String
        var displayName: String
        var approxMB: Int
    }

    static let whisperOptions: [CatalogOption] = [
        CatalogOption(id: "ggml-tiny.bin", displayName: "Whisper tiny — fastest", approxMB: 77),
        CatalogOption(id: "ggml-base.bin", displayName: "Whisper base — fast", approxMB: 148),
        CatalogOption(id: "ggml-small.bin", displayName: "Whisper small — balanced", approxMB: 488),
        CatalogOption(id: "ggml-medium.bin", displayName: "Whisper medium — accurate", approxMB: 1570),
        CatalogOption(id: "ggml-large-v3-turbo.bin", displayName: "Whisper large-v3-turbo — recommended", approxMB: 1624),
        CatalogOption(id: "ggml-large-v3.bin", displayName: "Whisper large-v3 — most accurate", approxMB: 3110),
    ]

    static let llmOptions: [CatalogOption] = [
        CatalogOption(id: "Qwen3-0.6B-Q4_K_M.gguf", displayName: "Qwen3 0.6B — tiny, fast", approxMB: 397),
        CatalogOption(id: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", displayName: "Qwen3 4B — recommended", approxMB: 2497),
        CatalogOption(id: "Qwen3-8B-Q4_K_M.gguf", displayName: "Qwen3 8B — best quality, 8GB+ headroom", approxMB: 5028),
    ]

    static let pins: [Pin] = [
        Pin(
            id: "whisper-bin", displayName: "Whisper speech engine (whisper.cpp)",
            version: "1.9.4",
            url: URL(string: "https://ghcr.io/v2/homebrew/core/whisper.cpp/blobs/sha256:7f4638ec796dadd46cf4436afe439f1c9f8056e61f8624379a800417e905d321")!,
            sha256: "7f4638ec796dadd46cf4436afe439f1c9f8056e61f8624379a800417e905d321",
            approxBytes: 90_000_000, kind: .bottleWhisper),
        Pin(
            id: "llama-bin", displayName: "Qwen inference engine (llama.cpp)",
            version: "0.4.1",
            url: URL(string: "https://ghcr.io/v2/homebrew/core/llama.cpp/blobs/sha256:109e5646fb5b08a22695c388d548aaefef101a3cd36ce31947dd2a1c2e538af5")!,
            sha256: "109e5646fb5b08a22695c388d548aaefef101a3cd36ce31947dd2a1c2e538af5",
            approxBytes: 80_000_000, kind: .bottleLlama),
        Pin(
            id: "ggml-tiny.bin", displayName: "Whisper tiny weights",
            version: "whisper.cpp main",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            sha256: nil,
            approxBytes: 77_000_000, kind: .weights),
        Pin(
            id: "ggml-base.bin", displayName: "Whisper base weights",
            version: "whisper.cpp main",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            sha256: nil,
            approxBytes: 148_000_000, kind: .weights),
        Pin(
            id: "ggml-small.bin", displayName: "Whisper small weights",
            version: "whisper.cpp main",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            sha256: nil,
            approxBytes: 488_000_000, kind: .weights),
        Pin(
            id: "ggml-medium.bin", displayName: "Whisper medium weights",
            version: "whisper.cpp main",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            sha256: nil,
            approxBytes: 1_570_000_000, kind: .weights),
        Pin(
            id: "ggml-large-v3-turbo.bin", displayName: "Whisper large-v3-turbo weights",
            version: "whisper.cpp main",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            approxBytes: 1_624_555_275, kind: .weights),
        Pin(
            id: "ggml-large-v3.bin", displayName: "Whisper large-v3 weights",
            version: "whisper.cpp main",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
            sha256: nil,
            approxBytes: 3_110_000_000, kind: .weights),
        Pin(
            id: "Qwen3-0.6B-Q4_K_M.gguf", displayName: "Qwen3 0.6B weights",
            version: "unsloth quant, Apache-2.0 weights",
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf")!,
            sha256: nil,
            approxBytes: 396_705_472, kind: .weights),
        Pin(
            id: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", displayName: "Qwen3 4B weights",
            version: "2507 Q4_K_M (unsloth quant, Apache-2.0 weights)",
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
            approxBytes: 2_497_281_120, kind: .weights),
        Pin(
            id: "Qwen3-8B-Q4_K_M.gguf", displayName: "Qwen3 8B weights",
            version: "unsloth quant, Apache-2.0 weights",
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf")!,
            sha256: nil,
            approxBytes: 5_027_784_512, kind: .weights),
    ]

    static func pin(id: String) -> Pin? { pins.first(where: { $0.id == id }) }

    // Selection (persisted): server model IDs, not filenames.
    // Canonical file<->id tables live in OmilCore.ServerCatalog.
    static var whisperIdForFile: [String: String] { ServerCatalog.whisperIdForFile }
    static var llmIdForFile: [String: String] { ServerCatalog.llmIdForFile }

    enum AssetState: Equatable {
        case missing
        case downloading(progress: Double)
        case verifying
        case extracting
        case ready
        case failed(reason: String)

        var isReady: Bool { self == .ready }
        var label: String {
            switch self {
            case .missing: return "Not installed"
            case .downloading(let p): return "Downloading \(Int(p * 100))%"
            case .verifying: return "Verifying…"
            case .extracting: return "Installing…"
            case .ready: return "Ready"
            case .failed(let r): return "Failed: \(r)"
            }
        }
    }

    @Published var states: [String: AssetState] = [:]
    @Published var isInstalling = false

    static var serverDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omil/server", isDirectory: true)
    }
    static var modelsDir: URL { serverDir.appendingPathComponent("models", isDirectory: true) }
    static var binDir: URL { serverDir.appendingPathComponent("bin", isDirectory: true) }
    static var logURL: URL { serverDir.appendingPathComponent("omil-server.log") }

    var allReady: Bool {
        requiredPins.allSatisfy { states[$0.id]?.isReady == true }
    }

    /// Bottles + currently selected models (drives the one-button install).
    var requiredPins: [Pin] {
        let whisper = UserDefaults.standard.string(forKey: "omil.whisperFile") ?? "ggml-large-v3-turbo.bin"
        let llm = UserDefaults.standard.string(forKey: "omil.llmFile") ?? "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        return Self.pins.filter {
            $0.kind != .weights || $0.id == whisper || $0.id == llm
        }
    }

    init() {
        refreshState()
    }

    // MARK: State

    func refreshState() {
        for pin in Self.pins {
            if case .downloading = states[pin.id] { continue }
            states[pin.id] = isInstalled(pin) ? .ready : .missing
        }
    }

    private func isInstalled(_ pin: Pin) -> Bool {
        switch pin.kind {
        case .bottleWhisper:
            return FileManager.default.isExecutableFile(atPath: Self.binDir.appendingPathComponent("whisper/bin/whisper-cli").path)
        case .bottleLlama:
            return FileManager.default.isExecutableFile(atPath: Self.binDir.appendingPathComponent("llama/bin/llama-server").path)
        case .weights:
            let url = Self.modelsDir.appendingPathComponent(pin.id)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return false }
            // Size check only for the fast path; full SHA runs at install + server boot.
            return abs(size - pin.approxBytes) < pin.approxBytes / 20
        }
    }

    // MARK: Install (one button)

    /// Downloads + verifies + installs every missing prerequisite, in order.
    /// Installs both sidecars + the SELECTED whisper/llm models.
    func installPrerequisites(onDone: (() -> Void)? = nil) {
        guard !isInstalling else { return }
        isInstalling = true
        Task {
            for pin in self.requiredPins where states[pin.id]?.isReady != true {
                do {
                    try await self.install(pin)
                    self.states[pin.id] = .ready
                } catch {
                    self.states[pin.id] = .failed(reason: "\(error)")
                    break
                }
            }
            self.isInstalling = false
            self.refreshState()
            onDone?()
        }
    }

    /// Download a single catalog model (used when switching models).
    func installModel(id: String, onDone: ((Bool) -> Void)? = nil) {
        guard let pin = Self.pin(id: id), !isInstalling else { onDone?(false); return }
        isInstalling = true
        Task {
            do {
                try await self.install(pin)
                self.states[pin.id] = .ready
                self.isInstalling = false
                onDone?(true)
            } catch {
                self.states[pin.id] = .failed(reason: "\(error)")
                self.isInstalling = false
                onDone?(false)
            }
            self.refreshState()
        }
    }

    private func install(_ pin: Pin) async throws {
        states[pin.id] = .downloading(progress: 0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omil-\(pin.id).dl")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        switch pin.kind {
        case .bottleWhisper, .bottleLlama:
            try await downloadBottle(pin, to: tmp)
            states[pin.id] = .extracting
            try installBottle(pin, from: tmp)
            try smokeCheck(pin)
        case .weights:
            try await downloadWeights(pin, to: tmp)
            states[pin.id] = .verifying
            let sha: String
            if let expected = pin.sha256 {
                try verifySHA(path: tmp.path, expected: expected)
                sha = expected
            } else {
                // Trust-on-first-use: pin the downloaded bytes.
                sha = try computeSHA(path: tmp.path)
            }
            try FileManager.default.createDirectory(at: Self.modelsDir, withIntermediateDirectories: true)
            let dest = Self.modelsDir.appendingPathComponent(pin.id)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            try writeManifest(pin: pin, sha256: sha)
        }
    }

    // MARK: Downloads

    private func authedRequest(url: URL, scope: String?) async throws -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 3600
        if let scope {
            // Anonymous ghcr pull token (no account needed).
            var tokReq = URLRequest(url: URL(string: "https://ghcr.io/token?service=ghcr.io&scope=\(scope)")!)
            tokReq.timeoutInterval = 60
            let (tdata, _) = try await URLSession.shared.data(for: tokReq)
            if let json = try? JSONSerialization.jsonObject(with: tdata) as? [String: Any],
               let token = json["token"] as? String {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        return req
    }

    private func ghcrScope(for pin: Pin) -> String? {
        switch pin.kind {
        case .bottleWhisper: return "repository:homebrew/core/whisper.cpp:pull"
        case .bottleLlama: return "repository:homebrew/core/llama.cpp:pull"
        case .weights: return nil
        }
    }

    private func streamToFile(request: URLRequest, dest: URL, pin: Pin) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let total = (response as? HTTPURLResponse)?.expectedContentLength ?? pin.approxBytes
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            guard let retry = try? FileHandle(forWritingTo: dest) else {
                throw InstallError.io("cannot create \(dest.lastPathComponent)")
            }
            try await pump(bytes: bytes, handle: retry, total: total, pin: pin)
            try? retry.close()
            return
        }
        defer { try? handle.close() }
        try await pump(bytes: bytes, handle: handle, total: total, pin: pin)
    }

    private func pump(bytes: URLSession.AsyncBytes, handle: FileHandle, total: Int64, pin: Pin) async throws {
        // AsyncBytes yields UInt8; buffer into 1 MB writes with progress.
        var buffer = Data()
        buffer.reserveCapacity(1024 * 1024)
        var received: Int64 = 0
        var lastReport = 0.0
        func flush() throws {
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 1024 * 1024 {
                try flush()
                let p = total > 0 ? Double(received) / Double(total) : 0
                let now = Date().timeIntervalSinceReferenceDate
                if now - lastReport > 0.25 || p >= 1 {
                    lastReport = now
                    let progress = min(1, p)
                    await MainActor.run { self.states[pin.id] = .downloading(progress: progress) }
                }
            }
        }
        try flush()
        await MainActor.run { self.states[pin.id] = .downloading(progress: 1) }
    }

    private func downloadBottle(_ pin: Pin, to tmp: URL) async throws {
        let req = try await authedRequest(url: pin.url, scope: ghcrScope(for: pin))
        try await streamToFile(request: req, dest: tmp, pin: pin)
        await MainActor.run { self.states[pin.id] = .verifying }
        guard let expected = pin.sha256 else {
            throw InstallError.io("bottle \(pin.id) has no pinned checksum")
        }
        try verifySHA(path: tmp.path, expected: expected)
    }

    private func downloadWeights(_ pin: Pin, to tmp: URL) async throws {
        var req = URLRequest(url: pin.url)
        req.timeoutInterval = 3600
        try await streamToFile(request: req, dest: tmp, pin: pin)
    }

    // MARK: Verify + install

    private func verifySHA(path: String, expected: String) throws {
        let actual = try computeSHA(path: path)
        guard actual.lowercased() == expected.lowercased() else {
            throw InstallError.integrity("checksum mismatch for \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    private func computeSHA(path: String) throws -> String {
        guard let handle = try? FileHandle(forReadingAtPath: path) else {
            throw InstallError.io("cannot read for verification")
        }
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func installBottle(_ pin: Pin, from tmp: URL) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("omil-bottle-\(pin.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Bottle: gzip tar rooted at <formula>/<version>/{bin,lib,...}.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tmp.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw InstallError.io("tar extraction failed") }
        let sub = pin.kind == .bottleWhisper ? "whisper" : "llama"
        let destRoot = Self.binDir.appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.removeItem(at: destRoot)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        // Find the extracted formula root (whisper.cpp/<ver> or llama.cpp/<ver>).
        let roots = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        guard let formulaRoot = roots.first(where: { $0.hasDirectoryPath }) else {
            throw InstallError.io("unexpected bottle layout")
        }
        for entry in ["bin", "lib"] {
            let src = formulaRoot.appendingPathComponent(entry, isDirectory: true)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.copyItem(at: src, to: destRoot.appendingPathComponent(entry, isDirectory: true))
        }
        // Strip quarantine (URLSession quarantines downloads), make executable,
        // ad-hoc sign (best effort; dev builds run unsigned regardless).
        stripQuarantine(at: destRoot)
        makeExecutableBins(at: destRoot.appendingPathComponent("bin", isDirectory: true))
        adHocSign(at: destRoot)
    }

    private func stripQuarantine(at url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-r", "-d", "com.apple.quarantine", url.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    private func makeExecutableBins(at binDir: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: binDir.path)) ?? [] {
            let p = binDir.appendingPathComponent(name).path
            var attrs = (try? FileManager.default.attributesOfItem(atPath: p)) ?? [:]
            let perms = (attrs[.posixPermissions] as? Int ?? 0o644) | 0o111
            attrs[.posixPermissions] = perms
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: p)
        }
    }

    private func adHocSign(at root: URL) {
        for sub in ["bin", "lib"] {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let p = URL(fileURLWithPath: dir.appendingPathComponent(name).path)
                let cs = Process()
                cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                cs.arguments = ["--force", "--sign", "-", p.path]
                try? cs.run()
                cs.waitUntilExit()
            }
        }
    }

    private func smokeCheck(_ pin: Pin) throws {
        let sub = pin.kind == .bottleWhisper ? "whisper" : "llama"
        let exe = sub == "whisper" ? "whisper-cli" : "llama-server"
        let p = Process()
        p.executableURL = Self.binDir.appendingPathComponent("\(sub)/bin/\(exe)")
        p.arguments = ["--version"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.environment = Self.sidecarEnvironment()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw InstallError.io("\(exe) failed its smoke check")
        }
    }

    /// Environment for spawning sidecars: dylib fallback so the extracted
    /// bottles resolve their libraries without /opt/homebrew.
    static func sidecarEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let libs = [
            binDir.appendingPathComponent("whisper/lib").path,
            binDir.appendingPathComponent("llama/lib").path,
        ]
        let existing = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        env["DYLD_FALLBACK_LIBRARY_PATH"] = (libs + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    private func writeManifest(pin: Pin, sha256: String? = nil) throws {
        let url = Self.modelsDir.appendingPathComponent("manifest.local.json")
        var manifest: [String: [String: Any]] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            manifest = json
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.modelsDir.appendingPathComponent(pin.id).path)[.size] as? Int64) ?? pin.approxBytes
        manifest[pin.id] = ["sha256": sha256 ?? pin.sha256 ?? "", "bytes": size, "url": pin.url.absoluteString]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    enum InstallError: Error, LocalizedError {
        case io(String)
        case integrity(String)
        var errorDescription: String? {
            switch self {
            case .io(let m): return m
            case .integrity(let m): return m
            }
        }
    }
}
