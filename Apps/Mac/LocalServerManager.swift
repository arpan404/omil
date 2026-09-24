import Foundation
import OmilCore
import Security

struct LANConnectionCredentials: Equatable {
    let host: String
    let port: Int
    let token: String

    var endpoint: String { "http://\(host):\(port)" }
    var copyText: String {
        "Omil server\nHost: \(host)\nPort: \(port)\nToken: \(token)"
    }
}

struct LocalServerPorts: Equatable {
    let api: Int
    let llama: Int
}

enum LocalPortPicker {
    private static let defaultAPI = 3217
    private static let fallbackStart = 24_000
    private static let fallbackPairCount = 1_024

    static func choose(identity: String, isFree: (Int) -> Bool) -> LocalServerPorts? {
        if isFree(defaultAPI), isFree(defaultAPI + 1) {
            return LocalServerPorts(api: defaultAPI, llama: defaultAPI + 1)
        }

        let first = Int(stableHash(identity) % UInt64(fallbackPairCount))
        for offset in 0..<fallbackPairCount {
            let index = (first + offset) % fallbackPairCount
            let api = fallbackStart + index * 2
            if isFree(api), isFree(api + 1) {
                return LocalServerPorts(api: api, llama: api + 1)
            }
        }
        return nil
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }
}

/// Owns the bundled Effect/Bun server for the normal Mac experience.
/// A custom server is an explicit override managed by DictationController.
@MainActor
final class LocalServerManager: ObservableObject {
    enum ToolInstallState: Equatable {
        case idle
        case installing([String])
        case ready
        case failed(message: String, homebrewMissing: Bool)
    }

    static let manualInstallCommand = "brew install whisper.cpp llama.cpp"
    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var sharedCredentials: LANConnectionCredentials?
    @Published private(set) var toolInstallState: ToolInstallState = .idle

    private var process: Process?
    private var logHandle: FileHandle?
    private var activeConfig: ServerConfig?
    private var activeLANAccess = false
    private var toolInstallTask: Task<Void, Never>?

    var isRunning: Bool { process?.isRunning == true }

    /// Homebrew is only invoked when a required executable is absent.
    func ensureInferenceTools() async {
        if let toolInstallTask {
            await toolInstallTask.value
            return
        }
        let task = Task { await installMissingTools() }
        toolInstallTask = task
        await task.value
        toolInstallTask = nil
    }

    private func installMissingTools() async {
        let tools = [("whisper-cli", "whisper.cpp"), ("llama-server", "llama.cpp")]
        let missing = tools.filter { executablePath(named: $0.0) == nil }.map(\.1)
        guard !missing.isEmpty else {
            toolInstallState = .ready
            return
        }
        guard let brew = executablePath(named: "brew") else {
            toolInstallState = .failed(
                message: "Homebrew is required to install \(missing.joined(separator: " and ")).",
                homebrewMissing: true
            )
            return
        }
        toolInstallState = .installing(missing)
        do {
            let root = try serverDirectory(fileManager: .default)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let logURL = root.appendingPathComponent("homebrew-install.log")
            let path = mergedPath(ProcessInfo.processInfo.environment["PATH"])
            let status = try await Task.detached(priority: .utility) {
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                let log = try FileHandle(forWritingTo: logURL)
                defer { try? log.close() }
                try log.seekToEnd()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brew)
                process.arguments = ["install"] + missing
                process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
                process.standardOutput = log
                process.standardError = log
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            let stillMissing = tools.filter { executablePath(named: $0.0) == nil }.map(\.1)
            if status == 0 && stillMissing.isEmpty {
                toolInstallState = .ready
            } else {
                toolInstallState = .failed(
                    message: "Homebrew could not install the required tools. See \(logURL.path) for details.",
                    homebrewMissing: false
                )
            }
        } catch {
            toolInstallState = .failed(
                message: "Homebrew could not start: \(error.localizedDescription)",
                homebrewMissing: false
            )
        }
    }

    func start(allowLANAccess: Bool = false) async throws -> ServerConfig {
        if let activeConfig, isRunning, activeLANAccess == allowLANAccess { return activeConfig }

        stop()
        state = .starting

        let fileManager = FileManager.default
        let root = try serverDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let token = try loadOrCreateToken(in: root, fileManager: fileManager)
        guard let ports = LocalPortPicker.choose(
            identity: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            isFree: { [self] in !hasListener(on: $0) }
        ) else {
            let message = "Could not find a free local server port."
            state = .failed(message)
            throw LocalServerError.startupFailed(message)
        }
        let executable = try bundledServerURL(fileManager: fileManager)
        let logURL = root.appendingPathComponent("omil-server.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }

        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        let child = Process()
        child.executableURL = executable
        child.currentDirectoryURL = root
        child.standardOutput = log
        child.standardError = log

        var environment = ProcessInfo.processInfo.environment
        environment["OMIL_HOST"] = allowLANAccess ? "0.0.0.0" : "127.0.0.1"
        environment["OMIL_PORT"] = String(ports.api)
        environment["OMIL_LLAMA_PORT"] = String(ports.llama)
        environment["OMIL_DATA"] = root.path
        environment["OMIL_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["PATH"] = mergedPath(environment["PATH"])
        environment["OMIL_WHISPER_BIN"] = executablePath(named: "whisper-cli") ?? "whisper-cli"
        environment["OMIL_LLAMA_BIN"] = executablePath(named: "llama-server") ?? "llama-server"
        child.environment = environment

        do {
            try child.run()
        } catch {
            try? log.close()
            state = .failed("Could not launch the bundled server: \(error.localizedDescription)")
            throw error
        }

        process = child
        logHandle = log
        let launchedPID = child.processIdentifier
        child.terminationHandler = { [weak self] exited in
            let status = exited.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.process?.processIdentifier == launchedPID else { return }
                self.process = nil
                self.activeConfig = nil
                self.activeLANAccess = false
                self.sharedCredentials = nil
                try? self.logHandle?.close()
                self.logHandle = nil
                self.state = .failed("The local server exited with status \(status).")
            }
        }
        let config = ServerConfig(host: "127.0.0.1", port: ports.api, token: token)
        activeConfig = config
        activeLANAccess = allowLANAccess

        for _ in 0..<60 {
            if !child.isRunning {
                let message = "The bundled server exited during startup."
                state = .failed(message)
                throw LocalServerError.startupFailed(message)
            }
            if await responds(at: config), child.isRunning {
                state = .running(port: ports.api)
                sharedCredentials = allowLANAccess
                    ? LANConnectionCredentials(
                        host: preferredLANHost(),
                        port: ports.api,
                        token: token
                    )
                    : nil
                return config
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        stop()
        let message = "The bundled server did not become ready."
        state = .failed(message)
        throw LocalServerError.startupFailed(message)
    }

    func restart(allowLANAccess: Bool = false) async throws -> ServerConfig {
        await stopAndWait()
        return try await start(allowLANAccess: allowLANAccess)
    }

    func regenerateToken(allowLANAccess: Bool) async throws -> ServerConfig {
        await stopAndWait()
        let fileManager = FileManager.default
        let root = try serverDirectory(fileManager: fileManager)
        let tokenURL = root.appendingPathComponent("omil-token")
        if fileManager.fileExists(atPath: tokenURL.path) {
            try fileManager.removeItem(at: tokenURL)
        }
        return try await start(allowLANAccess: allowLANAccess)
    }

    private func stopAndWait() async {
        guard let running = process, running.isRunning else {
            stop()
            return
        }
        running.terminate()
        for _ in 0..<40 where running.isRunning {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if running.isRunning {
            running.interrupt()
        }
        stop()
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        activeConfig = nil
        try? logHandle?.close()
        logHandle = nil
        activeLANAccess = false
        sharedCredentials = nil
        state = .stopped
    }

    private func responds(at config: ServerConfig) async -> Bool {
        guard let base = config.baseURL else { return false }
        var request = URLRequest(url: base.appendingPathComponent("/v1/health"))
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func serverDirectory(fileManager: FileManager) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["OMIL_MANAGED_DATA"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("Omil/Server", isDirectory: true)
    }

    private func bundledServerURL(fileManager: FileManager) throws -> URL {
        guard let url = Bundle.main.url(forResource: "omil-server", withExtension: nil),
              fileManager.isExecutableFile(atPath: url.path) else {
            throw LocalServerError.missingBundle
        }
        return url
    }

    private func loadOrCreateToken(in directory: URL, fileManager: FileManager) throws -> String {
        let url = directory.appendingPathComponent("omil-token")
        if let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 16 {
            return value
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let value: String
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            value = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        } else {
            value = (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "")
        }
        try value.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }

    private func hasListener(on port: Int) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        check.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        check.standardOutput = Pipe()
        check.standardError = Pipe()
        do {
            try check.run()
            check.waitUntilExit()
            return check.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func mergedPath(_ current: String?) -> String {
        let required = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (current ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (required + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private func executablePath(named name: String) -> String? {
        let candidates = mergedPath(ProcessInfo.processInfo.environment["PATH"])
            .split(separator: ":")
            .map { "\($0)/\(name)" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func preferredLANHost() -> String {
        if let address = Host.current().addresses.first(where: { candidate in
            let parts = candidate.split(separator: ".")
            return parts.count == 4
                && candidate != "127.0.0.1"
                && !candidate.hasPrefix("169.254.")
        }) {
            return address
        }
        return ProcessInfo.processInfo.hostName
    }
}

enum LocalServerError: LocalizedError {
    case missingBundle
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundle:
            return "The Effect/Bun server is missing from this app build."
        case .startupFailed(let message):
            return message
        }
    }
}
