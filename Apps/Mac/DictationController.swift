import AppKit
import AVFoundation
import Combine
import OmilCore
import ServiceManagement

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - DictationController (Mac)
//
// Owns the full Mac workflow: destination capture -> recording -> server
// inference and cleanup -> guarded insertion (AX direct, clipboard fallback)
// with receipts, scoped undo, and inspectable history.

@MainActor
final class DictationController: ObservableObject {
    enum Phase: String {
        case idle, preparing, recording, processing, ready, failed
    }

    enum ProcessingStage: Int, CaseIterable {
        case transcribing
        case cleaning
        case inserting

        var title: String {
            switch self {
            case .transcribing: return "Transcribing"
            case .cleaning: return "Cleaning up"
            case .inserting: return "Inserting"
            }
        }

        var icon: String {
            switch self {
            case .transcribing: return "waveform"
            case .cleaning: return "wand.and.stars"
            case .inserting: return "text.cursor"
            }
        }
    }

    enum RecordingSource { case app, shortcut, menuBar }
    @Published private(set) var recordingSource: RecordingSource = .app
    @Published var phase: Phase = .idle
    @Published var draftText = ""
    @Published var lastRaw = ""
    @Published var lastCleaned = ""
    @Published var lastDiff = ""
    @Published var statusMessage = "Idle"
    @Published private(set) var processingStage: ProcessingStage = .transcribing
    @Published var backendDescription = "Checking"
    @Published var assetState = "Unknown"
    @Published var cleanupMode: CleanupMode = .clean {
        didSet { UserDefaults.standard.set(cleanupMode.rawValue, forKey: "omil.mode") }
    }
    @Published var history: [HistoryEntry] = []
    @Published private(set) var recoveryRecordings: [RecoveryRecording] = []
    @Published private(set) var audioRetentionDays = 7
    @Published var lastReceipt: InsertionReceipt?
    @Published var lastDeliveryMethod = ""
    @Published var micPermission: MicPermission = .unknown
    @Published var historyEnabled = true
    @Published var serverConfig = ServerConfig()
    @Published var externalServerConfig = ServerConfig(host: "", port: 3217)
    @Published private(set) var usesCustomServer = false
    @Published private(set) var lanSharingEnabled = false
    @Published private(set) var lanCredentials: LANConnectionCredentials?
    @Published var serverNote = ""
    var speechSetupSummary: String {
        if serverIsReady {
            return usesCustomServer ? "Connected to your transcription server." : "Speech models are ready on this Mac."
        }
        return serverHealth
    }
    @Published var serverHealth = "Unknown"
    @Published var whisperFile = "ggml-large-v3-turbo.bin"
    @Published var llmFile = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    @Published private(set) var pendingWhisperFile: String?
    @Published private(set) var pendingLLMFile: String?
    @Published var promptText = ""
    @Published var promptCustom = false
    @Published var serverOpNote = ""
    @Published private(set) var modelsPreparing = false
    @Published private(set) var downloadingModelIDs: Set<String> = []
    @Published private(set) var audioLevels = Array(repeating: 0.0, count: 36)
    @Published private(set) var audioLevel = 0.0
    @Published var pillEnabled = true {
        didSet { UserDefaults.standard.set(pillEnabled, forKey: "omil.pillEnabled") }
    }
    @Published var appearance: AppearancePreference = .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "omil.appearance")
            AppAppearance.shared.apply(appearance)
        }
    }
    @Published private(set) var snippets: [Snippet] = []
    @Published var personalStyle: WritingStyle = .casual {
        didSet { UserDefaults.standard.set(personalStyle.rawValue, forKey: "omil.style.personal") }
    }
    @Published var workStyle: WritingStyle = .automatic {
        didSet { UserDefaults.standard.set(workStyle.rawValue, forKey: "omil.style.work") }
    }
    @Published var emailStyle: WritingStyle = .formal {
        didSet { UserDefaults.standard.set(emailStyle.rawValue, forKey: "omil.style.email") }
    }
    @Published var otherStyle: WritingStyle = .automatic {
        didSet { UserDefaults.standard.set(otherStyle.rawValue, forKey: "omil.style.other") }
    }

    enum MicPermission: String {
        case unknown, granted, denied
    }

    struct HistoryEntry: Identifiable, Codable {
        var id: UUID = UUID()
        var date: Date = Date()
        var raw: String
        var cleaned: String
        var backend: String
        var duration: Double = 0

        var wordCount: Int {
            cleaned.split(whereSeparator: { $0.isWhitespace }).count
        }
    }

    struct Snippet: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var trigger: String
        var expansion: String
    }

    enum AppCategory: String, CaseIterable, Identifiable {
        case personal = "Personal messages"
        case work = "Work messages"
        case email = "Email"
        case other = "Other apps"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .personal: return "message.fill"
            case .work: return "briefcase.fill"
            case .email: return "envelope.fill"
            case .other: return "square.grid.2x2.fill"
            }
        }
    }

    private var session: DictationSession?
    private var capture = AudioCapture()
    private var backend: (any TranscriptionBackend)?
    private var ax = AXInserter()
    private var clipboard = ClipboardInserter()
    private var precondition: SelectionPrecondition?
    private var sessionSeq = 0
    private var eventTask: Task<Void, Never>?
    private var dictionary = PersonalDictionary()
    private var lastMeterTimestamp: Double = -.infinity
    private let localServer: LocalServerManager
    private let recoveryStore = RecoveryAudioStore()
    private let recoveryBuffer = RecoveryAudioBuffer()
    private var startAttempt = UUID()
    private var recoveryIDsBySession: [SessionID: UUID] = [:]
    let recoveryPlayback = RecoveryPlayback()
    private var cancellables = Set<AnyCancellable>()

    init(localServer: LocalServerManager) {
        self.localServer = localServer
        if let raw = UserDefaults.standard.string(forKey: "omil.mode"), let m = CleanupMode(rawValue: raw) {
            cleanupMode = m
        }
        dictionary = LocalHistory.loadDictionary()
        snippets = LocalHistory.loadSnippets()
        history = LocalHistory.loadHistory()
        historyEnabled = UserDefaults.standard.object(forKey: "omil.historyEnabled") as? Bool ?? true
        if !historyEnabled { history = [] }
        audioRetentionDays = UserDefaults.standard.object(forKey: "omil.audioRetentionDays") as? Int ?? 7
        recoveryRecordings = recoveryStore.load(retentionDays: audioRetentionDays)
        if let data = UserDefaults.standard.data(forKey: "omil.serverConfig"),
           let cfg = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            externalServerConfig = cfg
        }
        usesCustomServer = UserDefaults.standard.bool(forKey: "omil.usesCustomServer")
        lanSharingEnabled = UserDefaults.standard.bool(forKey: "omil.lanSharingEnabled")
        if usesCustomServer { serverConfig = externalServerConfig }
        whisperFile = UserDefaults.standard.string(forKey: "omil.whisperFile") ?? whisperFile
        llmFile = UserDefaults.standard.string(forKey: "omil.llmFile") ?? llmFile
        pillEnabled = UserDefaults.standard.object(forKey: "omil.pillEnabled") as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: "omil.appearance"),
           let savedAppearance = AppearancePreference(rawValue: raw) {
            appearance = savedAppearance
        }
        personalStyle = Self.savedStyle(forKey: "omil.style.personal", fallback: .casual)
        workStyle = Self.savedStyle(forKey: "omil.style.work", fallback: .automatic)
        emailStyle = Self.savedStyle(forKey: "omil.style.email", fallback: .formal)
        otherStyle = Self.savedStyle(forKey: "omil.style.other", fallback: .automatic)
        UserDefaults.standard.removeObject(forKey: "omil.backend")
        UserDefaults.standard.removeObject(forKey: "omil.serverCleanup")
        localServer.$state.sink { [weak self] state in
            guard let self, !self.usesCustomServer,
                  case .failed(let message) = state else { return }
            self.serverHealth = message
            self.assetState = message
        }.store(in: &cancellables)
        localServer.$sharedCredentials.sink { [weak self] credentials in
            self?.lanCredentials = credentials
        }.store(in: &cancellables)
    }

    /// Post-launch startup: hotkeys plus either the app-owned local server or
    /// the user's explicit custom-server override.
    func startup() {
        AppAppearance.shared.apply(appearance)
        NSLog("Omil: startup")
        refreshMicPermission()
        HotkeyManager.shared.onPushStart = { [weak self] in self?.start(source: .shortcut) }
        HotkeyManager.shared.onPushStop = { [weak self] in self?.stop() }
        HotkeyManager.shared.onToggle = { [weak self] in self?.toggle(source: .shortcut) }
        HotkeyManager.shared.canCancel = { [weak self] in self?.phase == .recording || self?.phase == .preparing }
        HotkeyManager.shared.onCancel = { [weak self] in self?.cancel() }
        HotkeyManager.shared.start()
        Task {
            if usesCustomServer {
                await refreshBackendStatus()
            } else {
                await activateManagedServer()
            }
        }
        NSLog("Omil: startup done")
    }

    var axTrusted: Bool { ax.isTrusted }
    var canUndo: Bool { lastReceipt?.undoSupported == true }
    var serverIsReady: Bool {
        let value = serverHealth.lowercased()
        return serverConfig.isConfigured
            && value.contains("binaries ok")
            && modelIsDownloaded(file: whisperFile) == true
            && modelIsDownloaded(file: llmFile) == true
            && !value.contains("unreachable")
            && !value.contains("failed")
    }

    var displayedWhisperFile: String { pendingWhisperFile ?? whisperFile }
    var displayedLLMFile: String { pendingLLMFile ?? llmFile }

    func requestAXTrust() {
        ax.requestTrust()
        objectWillChange.send()
    }

    func refreshAXTrust() {
        objectWillChange.send()
    }

    // MARK: Permissions

    func refreshMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micPermission = .granted
        case .denied, .restricted: micPermission = .denied
        case .notDetermined: micPermission = .unknown
        @unknown default: micPermission = .unknown
        }
    }

    func requestMic() {
        if micPermission == .denied {
            openMicrophoneSettings()
            return
        }
        Task {
            let granted = await AudioCapture.requestPermission()
            await MainActor.run {
                self.micPermission = granted ? .granted : .denied
            }
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Status

    func refreshBackendStatus() async {
        backendDescription = "Omil server · Whisper + Qwen"
        assetState = "Checking server"
        await refreshServerHealth()
    }

    // MARK: Server core

    func saveServerConfig() {
        guard phase != .recording, phase != .preparing, phase != .processing else {
            serverOpNote = "Finish the current dictation before changing servers."
            return
        }
        guard externalServerConfig.isConfigured else {
            serverOpNote = "Enter the other server's host and token first."
            return
        }
        usesCustomServer = true
        UserDefaults.standard.set(true, forKey: "omil.usesCustomServer")
        localServer.stop()
        serverConfig = externalServerConfig
        serverModels = []
        if let data = try? JSONEncoder().encode(externalServerConfig) {
            UserDefaults.standard.set(data, forKey: "omil.serverConfig")
        }
        Task { await refreshServerHealth() }
    }

    func useManagedServer() {
        guard phase != .recording, phase != .preparing, phase != .processing else {
            serverOpNote = "Finish the current dictation before changing servers."
            return
        }
        guard usesCustomServer || !localServer.isRunning else { return }
        usesCustomServer = false
        UserDefaults.standard.set(false, forKey: "omil.usesCustomServer")
        Task { await activateManagedServer() }
    }

    func restartManagedServer() {
        guard !usesCustomServer else { return }
        guard phase != .recording, phase != .preparing, phase != .processing else {
            serverOpNote = "Finish the current dictation before restarting the engine."
            return
        }
        Task { await activateManagedServer(restart: true) }
    }

    func setLANSharing(_ enabled: Bool) {
        guard !usesCustomServer else {
            serverOpNote = "Switch back to this Mac before changing network access."
            return
        }
        guard phase != .recording, phase != .preparing, phase != .processing else {
            serverOpNote = "Finish the current dictation before changing network access."
            return
        }
        lanSharingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "omil.lanSharingEnabled")
        serverOpNote = enabled ? "Opening the engine to your local network." : "Blocking local network connections."
        Task { await activateManagedServer(restart: true) }
    }

    func regenerateLANToken() {
        guard !usesCustomServer else { return }
        guard phase != .recording, phase != .preparing, phase != .processing else {
            serverOpNote = "Finish the current dictation before replacing the connection token."
            return
        }
        serverHealth = "Replacing connection token"
        serverOpNote = "Replacing the token and restarting the local engine."
        Task {
            do {
                serverConfig = try await localServer.regenerateToken(
                    allowLANAccess: lanSharingEnabled
                )
                await refreshCurrentServerHealth()
                await fetchServerModels()
                serverOpNote = "New connection token ready. Other devices must use it."
            } catch {
                serverHealth = "Local engine failed: \(error.localizedDescription)"
                serverOpNote = "Could not replace the connection token."
            }
        }
    }

    func copyLANCredentials() {
        guard let credentials = lanCredentials else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(credentials.copyText, forType: .string)
        serverOpNote = "Connection details copied."
    }

    private func activateManagedServer(restart: Bool = false) async {
        serverHealth = restart ? "Restarting local engine" : "Starting local engine"
        assetState = serverHealth
        serverOpNote = ""
        serverModels = []
        do {
            let config = try await (restart
                ? localServer.restart(allowLANAccess: lanSharingEnabled)
                : localServer.start(allowLANAccess: lanSharingEnabled))
            serverConfig = config
            await refreshCurrentServerHealth()
            await fetchServerModels()
            if serverHealth.lowercased().contains("sidecars missing") {
                serverOpNote = "Whisper and llama sidecars are missing from this build."
            } else if !serverIsReady {
                await prepareSelectedModels()
            }
        } catch {
            serverHealth = "Local engine failed: \(error.localizedDescription)"
            assetState = serverHealth
        }
    }

    private func serverRequest(
        path: String,
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        timeout: TimeInterval = 60
    ) -> URLRequest? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = serverConfig.host.isEmpty ? nil : serverConfig.host
        comps.port = serverConfig.port
        guard let base = comps.url else { return nil }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(serverConfig.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        return req
    }

    struct ServerModelInfo: Codable, Identifiable, Equatable {
        var id: String
        var kind: String
        var description: String
        var filename: String
        var approxBytes: Int?
        var downloaded: Bool
        var selected: Bool
        var fileState: String?
        var receivedBytes: Int?
        var totalBytes: Int?
        var fileError: String?
        var memoryState: String?
        var activeUses: Int?
    }

    @Published var serverModels: [ServerModelInfo] = []

    /// Model choice belongs to this client. Missing weights download first;
    /// the current model remains usable until verification succeeds.
    func chooseWhisperModel(file: String) {
        chooseModel(file: file, kind: "whisper")
    }

    func chooseLLMModel(file: String) {
        chooseModel(file: file, kind: "llm")
    }

    private func chooseModel(file: String, kind: String) {
        let known = kind == "whisper"
            ? ServerCatalog.whisperIdForFile[file] != nil
            : ServerCatalog.llmIdForFile[file] != nil
        guard known else { return }
        if modelIsDownloaded(file: file) == true {
            activateModel(file: file, kind: kind)
            serverOpNote = kind == "whisper"
                ? "Transcription model switched for this Mac."
                : "Cleanup model switched for this Mac."
            return
        }
        if kind == "whisper" { pendingWhisperFile = file } else { pendingLLMFile = file }
        serverOpNote = "Downloading before switching. The current model remains available."
        downloadModel(file: file)
    }

    private func activateModel(file: String, kind: String) {
        if kind == "whisper" {
            whisperFile = file
            pendingWhisperFile = nil
            UserDefaults.standard.set(file, forKey: "omil.whisperFile")
        } else {
            llmFile = file
            pendingLLMFile = nil
            UserDefaults.standard.set(file, forKey: "omil.llmFile")
        }
    }

    func fetchServerModels() async {
        guard let req = serverRequest(path: "/v1/models") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["models"] as? [[String: Any]] else { return }
            let models = arr.compactMap { d -> ServerModelInfo? in
                guard let id = d["id"] as? String,
                      let kind = d["kind"] as? String,
                      let description = d["description"] as? String,
                      let filename = d["filename"] as? String,
                      let downloaded = d["downloaded"] as? Bool,
                      let selected = d["selected"] as? Bool else { return nil }
                return ServerModelInfo(
                    id: id, kind: kind, description: description,
                    filename: filename, approxBytes: d["approxBytes"] as? Int,
                    downloaded: downloaded, selected: selected,
                    fileState: d["fileState"] as? String,
                    receivedBytes: d["receivedBytes"] as? Int,
                    totalBytes: d["totalBytes"] as? Int,
                    fileError: d["fileError"] as? String,
                    memoryState: d["memoryState"] as? String,
                    activeUses: d["activeUses"] as? Int
                )
            }
            await MainActor.run {
                if self.serverModels != models { self.serverModels = models }
            }
        } catch { /* server not up yet */ }
    }

    func modelIsDownloaded(file: String) -> Bool? {
        serverModels.first(where: { $0.filename == file })?.downloaded
    }

    func modelIsDownloading(file: String) -> Bool {
        guard let id = serverModels.first(where: { $0.filename == file })?.id else { return false }
        return downloadingModelIDs.contains(id)
    }

    func modelInfo(file: String) -> ServerModelInfo? {
        serverModels.first(where: { $0.filename == file })
    }

    var selectedLLMMemoryState: String {
        modelInfo(file: llmFile)?.memoryState ?? "unloaded"
    }

    func unloadModels() {
        guard let request = serverRequest(path: "/v1/models/unload", method: "POST") else {
            serverOpNote = "Server not configured"
            return
        }
        serverOpNote = selectedLLMMemoryState == "inUse"
            ? "Cleanup will release memory when it finishes."
            : "Releasing cleanup model memory."
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    serverOpNote = "Could not release model memory."
                    return
                }
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let released = payload?["unloaded"] as? Bool ?? false
                await fetchServerModels()
                serverOpNote = released
                    ? "Cleanup model memory released."
                    : "Cleanup will release memory when the current request finishes."
            } catch {
                serverOpNote = "Could not release model memory: \(error.localizedDescription)"
            }
        }
    }

    func downloadModel(file: String) {
        guard !modelsPreparing, downloadingModelIDs.isEmpty,
              let model = serverModels.first(where: { $0.filename == file }) else {
            serverOpNote = "Model availability is still loading."
            return
        }
        guard !model.downloaded, !downloadingModelIDs.contains(model.id) else { return }
        guard let request = serverRequest(
            path: "/v1/models/prepare",
            method: "POST",
            jsonBody: ["model": model.id],
            timeout: 7_200
        ) else {
            serverOpNote = "Server not configured"
            return
        }

        downloadingModelIDs.insert(model.id)
        serverOpNote = model.kind == "whisper"
            ? "Downloading transcription model."
            : "Downloading cleanup model."
        Task { await downloadModel(model, with: request) }
    }

    func deleteModel(file: String) {
        guard downloadingModelIDs.isEmpty,
              let model = serverModels.first(where: { $0.filename == file }),
              model.downloaded,
              let request = serverRequest(
                path: "/v1/models/delete",
                method: "POST",
                jsonBody: ["model": model.id]
              ) else { return }
        if file == whisperFile || file == llmFile {
            guard let fallback = serverModels.first(where: {
                $0.kind == model.kind && $0.downloaded && $0.filename != file
            }) else {
                serverOpNote = "Download another \(model.kind == "whisper" ? "transcription" : "cleanup") model before deleting the active one."
                return
            }
            activateModel(file: fallback.filename, kind: model.kind)
        }
        serverOpNote = "Deleting \(model.filename)."
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    serverOpNote = "Could not delete model: \(detail ?? "server error")"
                    return
                }
                await fetchServerModels()
                await refreshCurrentServerHealth()
                serverOpNote = "Model deleted from this Mac."
            } catch {
                serverOpNote = "Could not delete model: \(error.localizedDescription)"
            }
        }
    }

    private func downloadModel(_ model: ServerModelInfo, with request: URLRequest) async {
        let targetConfig = serverConfig
        defer { downloadingModelIDs.remove(model.id) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard serverConfig == targetConfig else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                serverOpNote = "Download failed: \(detail ?? "server error")"
                await fetchServerModels()
                await refreshCurrentServerHealth()
                return
            }
            await fetchServerModels()
            await refreshCurrentServerHealth()
            activateModel(file: model.filename, kind: model.kind)
            serverOpNote = model.kind == "whisper"
                ? "Transcription model downloaded and selected for this Mac."
                : "Cleanup model downloaded and selected for this Mac."
        } catch {
            guard serverConfig == targetConfig else { return }
            serverOpNote = "Download failed: \(error.localizedDescription)"
            await fetchServerModels()
            await refreshCurrentServerHealth()
        }
    }

    func setPillEnabled(_ on: Bool) {
        pillEnabled = on
        UserDefaults.standard.set(on, forKey: "omil.pillEnabled")
    }

    // MARK: Prompt override

    func loadPrompt() {
        guard let req = serverRequest(path: "/v1/prompt") else { return }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                await MainActor.run {
                    self.promptText = (json["text"] as? String) ?? ""
                    self.promptCustom = (json["isCustom"] as? Bool) ?? false
                }
            } catch { /* server not up yet */ }
        }
    }

    func savePrompt() {
        guard promptText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50,
              let req = serverRequest(path: "/v1/prompt", method: "POST", jsonBody: ["text": promptText]) else {
            serverOpNote = "Prompt too short (min 50 chars)"
            return
        }
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                await MainActor.run {
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        self.promptCustom = true
                        self.serverOpNote = "Custom prompt saved. It applies to the next cleanup."
                    } else {
                        self.serverOpNote = "Prompt rejected by server"
                    }
                }
            } catch {
                await MainActor.run { self.serverOpNote = "Prompt save failed: server unreachable?" }
            }
        }
    }

    func resetPrompt() {
        guard let req = serverRequest(path: "/v1/prompt", method: "DELETE") else { return }
        Task {
            _ = try? await URLSession.shared.data(for: req)
            await MainActor.run {
                self.promptCustom = false
                self.loadPrompt()
                self.serverOpNote = "Prompt reset to default"
            }
        }
    }

    func refreshServerHealth() async {
        if !usesCustomServer, !localServer.isRunning {
            await activateManagedServer()
            return
        }
        await refreshCurrentServerHealth()
        await fetchServerModels()
    }

    private func refreshCurrentServerHealth() async {
        let probe = ServerTranscriptionBackend(config: serverConfig)
        let health = await probe.serverHealth()
        NSLog("Omil: server health %@ at %@:%d", health, serverConfig.host, serverConfig.port)
        serverHealth = health
        assetState = health
        guard let request = serverRequest(path: "/v1/models") else { return }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                serverHealth = "Server rejected the token"
                assetState = serverHealth
            }
        } catch {
            serverHealth = "Server became unreachable"
            assetState = serverHealth
        }
    }

    func prepareSelectedModels() async {
        guard !modelsPreparing else { return }
        let modelIDs = [
            ServerCatalog.whisperIdForFile[whisperFile],
            ServerCatalog.llmIdForFile[llmFile],
        ].compactMap { $0 }
        guard modelIDs.count == 2 else { return }
        let targetConfig = serverConfig
        modelsPreparing = true
        defer { modelsPreparing = false }
        serverHealth = "Downloading selected models"
        assetState = serverHealth
        serverOpNote = "Preparing Whisper and Qwen. You can keep using the rest of the app."
        do {
            for modelID in modelIDs {
                guard let request = serverRequest(
                    path: "/v1/models/prepare",
                    method: "POST",
                    jsonBody: ["model": modelID],
                    timeout: 7_200
                ) else { return }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard serverConfig == targetConfig else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let detail = String(data: data, encoding: .utf8) ?? "unknown server error"
                    serverOpNote = "Model preparation failed: \(detail)"
                    await refreshCurrentServerHealth()
                    return
                }
            }
            serverOpNote = "Models are ready."
            await fetchServerModels()
            await refreshCurrentServerHealth()
        } catch {
            guard serverConfig == targetConfig else { return }
            serverOpNote = "Model preparation failed: \(error.localizedDescription)"
            await refreshCurrentServerHealth()
        }
    }

    /// Qwen cleanup runs in the Effect/Bun service. A server failure retains
    /// the transcript in Omil instead of silently switching to Swift cleanup.
    func serverClean(rawText: String, requestId: String) async throws -> (text: String, note: String) {
        let client = ServerCleanupClient(
            config: serverConfig,
            dictionary: dictionary,
            snippets: Dictionary(uniqueKeysWithValues: snippets.map { ($0.trigger, $0.expansion) }),
            style: styleForCapturedTarget(),
            modelId: ServerCatalog.llmIdForFile[llmFile]
        )
        let result = try await client.clean(
            text: rawText,
            mode: cleanupMode,
            requestId: requestId
        )
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServerCleanupError.failed(reason: "server returned an empty cleanup result")
        }
        let snippetNote = result.appliedSnippetTriggers?.isEmpty == false ? " · snippet expanded" : ""
        let note = "Qwen cleanup via server: \(result.acceptedEdits.count) edits, \(result.abstentions.count) abstentions · \((result.writingStyle ?? .automatic).displayName)\(snippetNote) (\(result.rulesVersion))"
        return (result.text, note)
    }

    func makeBackend() -> (any TranscriptionBackend)? {
        ServerTranscriptionBackend(
            config: serverConfig,
            modelId: ServerCatalog.whisperIdForFile[whisperFile]
        )
    }

    // MARK: Recording

    func toggle(source: RecordingSource = .app) {
        NSLog("Omil: toggle pressed, phase=%@", phase.rawValue)
        switch phase {
        case .idle, .ready, .failed: start(source: source)
        case .recording: stop()
        case .preparing, .processing: break
        }
    }

    func start(source: RecordingSource = .app) {
        NSLog("Omil: start pressed, phase=%@", phase.rawValue)
        guard phase == .idle || phase == .ready || phase == .failed else { return }
        startAttempt = UUID()
        let attempt = startAttempt
        recordingSource = source
        recoveryPlayback.stop()
        refreshMicPermission()
        guard micPermission != .denied else {
            phase = .failed
            statusMessage = "Microphone access denied. Grant it in Settings → Permissions, then try again."
            return
        }
        if micPermission == .unknown {
            // First run: prompt, then auto-start on grant.
            phase = .preparing
            statusMessage = "Requesting microphone access"
            Task {
                let granted = await AudioCapture.requestPermission()
                await MainActor.run {
                    self.micPermission = granted ? .granted : .denied
                    guard self.startAttempt == attempt, self.phase == .preparing else { return }
                    if granted {
                        self.phase = .idle
                        self.start(source: source)
                    } else {
                        self.phase = .failed
                        self.statusMessage = "Microphone access denied. Grant it in Settings → Permissions."
                    }
                }
            }
            return
        }
        guard serverIsReady else {
            phase = .failed
            statusMessage = usesCustomServer
                ? "The custom server is not ready. Open Engine and check its connection."
                : "The local engine is still preparing. Open Engine to see its status."
            return
        }
        guard let backend = makeBackend() else {
            phase = .failed
            statusMessage = "The Omil engine is unavailable. Open Engine to check its status."
            return
        }
        // Capture the intended destination + selection first.
        let axOk = ax.captureTarget()
        precondition = ax.capturePrecondition()
        sessionSeq += 1
        let session = DictationSession(
            mode: cleanupMode,
            dictionary: dictionary,
            performsCleanup: false
        )
        self.session = session
        self.backend = backend
        recoveryBuffer.reset()
        phase = .preparing
        statusMessage = axOk ? "Preparing" : "Preparing. No text field was found, so Omil will keep the result."
        draftText = ""
        resetAudioMeter()
        let sessionID = session.sessionId
        Task {
            do {
                try await session.start(backend: backend)
            } catch {
                let stoppedPhase = await session.currentPhase
                await MainActor.run {
                    guard self.session?.sessionId == sessionID else { return }
                    if stoppedPhase == .cancelled {
                        self.phase = .idle
                        self.statusMessage = "Cancelled"
                    } else {
                        self.phase = .failed
                        self.statusMessage = "Could not start: \(error)"
                    }
                }
                return
            }
            let shouldStartCapture = await MainActor.run {
                guard self.session?.sessionId == sessionID, self.phase == .preparing else { return false }
                self.phase = .recording
                self.statusMessage = "Recording. Stop when you are finished."
                self.streamEvents(session: session)
                self.startCapture(backend: backend, session: session)
                return true
            }
            if !shouldStartCapture {
                await session.cancel()
            }
        }
    }

    private func streamEvents(session: DictationSession) {
        let sessionID = session.sessionId
        eventTask?.cancel()
        eventTask = Task {
            for await event in await session.events() {
                switch event {
                case .draftAvailable(let text):
                    await MainActor.run {
                        guard self.session?.sessionId == sessionID else { return }
                        self.draftText = text
                    }
                case .finalized(let snap):
                    await MainActor.run {
                        guard self.session?.sessionId == sessionID else { return }
                        self.lastRaw = snap.rawText
                    }
                case .cleaned(let view):
                    await MainActor.run {
                        guard self.session?.sessionId == sessionID else { return }
                        self.lastCleaned = view.text
                        self.lastDiff = DiffUtil.diff(raw: self.lastRaw, cleaned: view.text)
                    }
                case .failed(let err):
                    await MainActor.run {
                        guard self.session?.sessionId == sessionID else { return }
                        self.phase = .failed
                        self.statusMessage = "Could not transcribe this recording: \(err)"
                    }
                }
            }
        }
    }

    private func startCapture(backend: any TranscriptionBackend, session: DictationSession) {
        let sessionID = session.sessionId
        let recoveryBuffer = self.recoveryBuffer
        do {
            let captureBackend = backend
            try capture.start(targetSampleRate: 16_000, targetChannels: 1) { chunk in
                recoveryBuffer.append(chunk.pcm16)
                let level = AudioLevelMeter.normalizedRMS(pcm16: chunk.pcm16)
                Task { @MainActor [weak self] in
                    self?.pushAudioLevel(level, timestamp: chunk.timestamp)
                }
                Task { await captureBackend.appendAudio(chunk.pcm16, timestamp: chunk.timestamp) }
            }
        } catch {
            Task { @MainActor in
                guard self.session?.sessionId == sessionID else { return }
                self.phase = .failed
                self.statusMessage = "Microphone unavailable: \(error)"
                self.session = nil
            }
            Task { await session.cancel() }
        }
    }

    func stop() {
        if phase == .preparing {
            cancel()
            return
        }
        guard phase == .recording, let activeSession = session else { return }
        let sessionID = activeSession.sessionId
        processingStage = .transcribing
        phase = .processing
        statusMessage = "Transcribing your recording"
        capture.stop()
        saveRecoveryAudio(for: sessionID)
        Task {
            if let result = await activeSession.stop() {
                guard self.session?.sessionId == sessionID else { return }
                await deliver(result: result, session: activeSession)
            } else {
                let stoppedPhase = await activeSession.currentPhase
                await MainActor.run {
                    guard self.session?.sessionId == sessionID else { return }
                    if stoppedPhase == .failed {
                        self.phase = .failed
                        if !self.statusMessage.hasPrefix("Could not transcribe") {
                            self.statusMessage = "Could not transcribe this recording. Check Engine and try again."
                        }
                        self.updateRecovery(
                            for: sessionID,
                            state: .failed,
                            failureReason: self.statusMessage
                        )
                    } else {
                        self.phase = .idle
                        self.statusMessage = "Cancelled"
                    }
                }
            }
        }
    }

    func cancel() {
        guard phase == .recording || phase == .preparing else { return }
        let activeSession = session
        startAttempt = UUID()
        session = nil
        backend = nil
        eventTask?.cancel()
        eventTask = nil
        capture.cancel()
        recoveryBuffer.reset()
        phase = .idle
        draftText = ""
        resetAudioMeter()
        statusMessage = "Cancelled"
        Task {
            await activeSession?.cancel()
        }
    }

    private func pushAudioLevel(_ level: Double, timestamp: Double) {
        guard phase == .recording, timestamp - lastMeterTimestamp >= 1.0 / 30.0 else { return }
        lastMeterTimestamp = timestamp
        let smoothed = min(1, max(0, audioLevel * 0.48 + level * 0.52))
        audioLevel = smoothed
        audioLevels.append(smoothed)
        if audioLevels.count > 36 {
            audioLevels.removeFirst(audioLevels.count - 36)
        }
    }

    private func resetAudioMeter() {
        audioLevel = 0
        audioLevels = Array(repeating: 0, count: 36)
        lastMeterTimestamp = -.infinity
    }

    // MARK: Delivery

    private func deliver(result: SessionResult, session activeSession: DictationSession) async {
        guard self.session?.sessionId == activeSession.sessionId,
              let committed = await activeSession.commitForDelivery() else {
            await MainActor.run {
                self.phase = .idle
                self.statusMessage = "Nothing to deliver (duplicate or cancelled)"
            }
            return
        }
        let text: String
        let note: String
        if committed.cleaned.text.isEmpty && committed.rawSnapshot.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A10: never insert an empty result (would wipe the selection).
            await MainActor.run {
                self.phase = .ready
                self.lastCleaned = ""
                self.statusMessage = "No speech was detected"
                self.updateRecovery(for: committed.sessionId, state: .ready, transcript: "")
            }
            return
        } else {
            processingStage = .cleaning
            statusMessage = "Cleaning up your text"
            do {
                let cleaned = try await serverClean(
                    rawText: committed.rawSnapshot.rawText,
                    requestId: committed.sessionId.rawValue
                )
                text = cleaned.text
                note = cleaned.note
            } catch {
                await MainActor.run {
                    self.phase = .failed
                    self.lastRaw = committed.rawSnapshot.rawText
                    self.lastCleaned = committed.rawSnapshot.rawText
                    self.lastDiff = ""
                    self.serverNote = "Server cleanup failed: \(error)"
                    self.statusMessage = "Cleanup failed. The raw transcript is saved in History."
                    self.recordHistory(
                        raw: committed.rawSnapshot.rawText,
                        cleaned: committed.rawSnapshot.rawText,
                        backend: committed.backend.displayName,
                        duration: committed.duration
                    )
                    self.updateRecovery(
                        for: committed.sessionId,
                        state: .ready,
                        transcript: committed.rawSnapshot.rawText,
                        failureReason: "Cleanup failed; raw transcript preserved."
                    )
                }
                return
            }
        }
        serverNote = note
        processingStage = .inserting
        statusMessage = "Inserting your text"
        let pre = self.precondition ?? SelectionPrecondition()
        // 1. Try direct AX insertion with revalidation.
        if axTrusted, case .ok = ax.revalidate(precondition: pre) {
            do {
                let receipt = try ax.insert(text: text, precondition: pre, sessionId: committed.sessionId, sequence: committed.commitSequence)
                finishDelivery(text: text, method: "Inserted into focused field", receipt: receipt, result: committed)
                return
            } catch {
                // Fall through to clipboard recovery.
            }
        }
        // 2. Explicit clipboard recovery. Auto-paste needs Accessibility trust
        // (CGEvent); without it we copy and guide a manual paste instead.
        let prepared = clipboard.prepare(text: text)
        if axTrusted {
            clipboard.paste()
            // Restore prior contents after the host consumed the paste — only
            // while Omil still owns the clipboard write. Never blocks delivery.
            let inserter = clipboard
            DispatchQueue.global().async {
                let restored = inserter.restoreIfOwned(prepared: prepared)
                Task { @MainActor in
                    self.statusMessage = restored
                        ? "Pasted via clipboard (prior clipboard restored)"
                        : "Pasted via clipboard"
                }
            }
        }
        let receipt = InsertionReceipt(
            sessionId: committed.sessionId,
            destination: DestinationIdentity(appBundleId: "clipboard", fieldIdentifier: "pasteboard"),
            precondition: pre, insertedText: text, commitSequence: committed.commitSequence,
            undoSupported: false)
        finishDelivery(
            text: text,
            method: axTrusted
                ? "Pasted via clipboard"
                : "Copied. Press ⌘V to paste.",
            receipt: receipt, result: committed)
    }

    private func finishDelivery(text: String, method: String, receipt: InsertionReceipt, result: SessionResult) {
        lastReceipt = receipt
        lastDeliveryMethod = method
        lastCleaned = text
        phase = .ready
        statusMessage = method
        recordHistory(
            raw: result.rawSnapshot.rawText,
            cleaned: text,
            backend: result.backend.displayName,
            duration: result.duration
        )
        updateRecovery(for: result.sessionId, state: .ready, transcript: text)
    }

    private func recordHistory(raw: String, cleaned: String, backend: String, duration: Double) {
        guard historyEnabled else { return }
        let entry = HistoryEntry(raw: raw, cleaned: cleaned, backend: backend, duration: duration)
        history.insert(entry, at: 0)
        history = Array(history.prefix(200))
        LocalHistory.saveHistory(history)
    }

    // MARK: History controls

    func setHistoryEnabled(_ on: Bool) {
        historyEnabled = on
        UserDefaults.standard.set(on, forKey: "omil.historyEnabled")
        if !on {
            history = []
            LocalHistory.saveHistory([])
        }
    }

    func clearHistory() {
        history = []
        LocalHistory.saveHistory([])
        statusMessage = "History cleared from this Mac"
    }

    func insertRetainedResult() {
        // Explicit insertion of the retained result after a destination change.
        guard phase == .ready, !lastCleaned.isEmpty else { return }
        _ = ax.captureTarget()
        precondition = ax.capturePrecondition()
        guard let sessionId = lastReceipt?.sessionId else { return }
        sessionSeq += 1
        if axTrusted, case .ok = ax.revalidate(precondition: precondition ?? SelectionPrecondition()) {
            do {
                let receipt = try ax.insert(text: lastCleaned, precondition: precondition ?? SelectionPrecondition(), sessionId: sessionId, sequence: sessionSeq)
                lastReceipt = receipt
                lastDeliveryMethod = "Inserted into focused field"
                statusMessage = lastDeliveryMethod
            } catch {
                statusMessage = "Insertion failed: \(error)"
            }
        } else {
            statusMessage = "The destination changed. Copy the saved result manually."
        }
    }

    func undoLast() {
        guard let receipt = lastReceipt else { return }
        if ax.undo(receipt: receipt) {
            statusMessage = "Undone (only Omil's insertion was reversed)"
        } else {
            statusMessage = "Undo stopped because the field changed after insertion."
        }
    }

    func copyLast() {
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(lastCleaned, forType: .string)
        statusMessage = "Copied to clipboard"
    }

    /// Paste last result at the cursor (menu action). Auto-paste needs
    /// Accessibility trust for the key simulation; without it we copy and
    /// say so honestly instead of claiming a paste happened.
    func pasteLast() {
        guard !lastCleaned.isEmpty else {
            statusMessage = "Nothing to paste yet"
            return
        }
        let prepared = clipboard.prepare(text: lastCleaned)
        guard axTrusted else {
            statusMessage = "Copied. Press ⌘V to paste."
            return
        }
        clipboard.paste()
        let inserter = clipboard
        DispatchQueue.global().async {
            let restored = inserter.restoreIfOwned(prepared: prepared)
            Task { @MainActor in
                self.statusMessage = restored ? "Pasted last result" : "Pasted last result (clipboard kept)"
            }
        }
    }

    func deleteHistoryEntry(_ entry: HistoryEntry) {
        history.removeAll(where: { $0.id == entry.id })
        LocalHistory.saveHistory(history)
    }

    // MARK: Recovery recordings

    func setAudioRetentionDays(_ days: Int) {
        let allowed = [0, 1, 3, 7, 14, 30]
        let value = allowed.contains(days) ? days : 7
        audioRetentionDays = value
        UserDefaults.standard.set(value, forKey: "omil.audioRetentionDays")
        recoveryPlayback.stop()
        recoveryRecordings = recoveryStore.load(retentionDays: value)
        statusMessage = value == 0
            ? "Saved recovery audio removed"
            : "Recovery audio will be kept for \(value) day\(value == 1 ? "" : "s")"
    }

    func retryRecovery(_ recording: RecoveryRecording) {
        guard phase != .recording && phase != .preparing && phase != .processing else {
            statusMessage = "Finish the current dictation before retrying a recording."
            return
        }
        guard serverIsReady else {
            phase = .failed
            statusMessage = "The engine is not ready. Open Engine and try again."
            return
        }
        recoveryPlayback.stop()
        let url = recoveryStore.audioURL(for: recording)
        let requestID = "recovery-\(recording.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        let transcriber = ServerTranscriptionBackend(
            config: serverConfig,
            modelId: ServerCatalog.whisperIdForFile[whisperFile]
        )
        recordingSource = .app
        phase = .processing
        processingStage = .transcribing
        statusMessage = "Transcribing saved recording"

        Task {
            do {
                let transcript = try await transcriber.transcribeFile(url: url, requestId: requestID)
                guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BackendError.recognitionFailed(underlying: "no speech was detected")
                }
                processingStage = .cleaning
                statusMessage = "Cleaning up recovered text"
                let cleaned = try await serverClean(rawText: transcript.text, requestId: requestID)
                lastRaw = transcript.text
                lastCleaned = cleaned.text
                lastDiff = DiffUtil.diff(raw: transcript.text, cleaned: cleaned.text)
                serverNote = cleaned.note
                recordHistory(
                    raw: transcript.text,
                    cleaned: cleaned.text,
                    backend: "Whisper recovery",
                    duration: recording.duration
                )
                updateRecovery(recording.id, state: .ready, transcript: cleaned.text)
                phase = .ready
                statusMessage = "Recovered transcript ready"
            } catch {
                updateRecovery(recording.id, state: .failed, failureReason: "\(error)")
                phase = .failed
                statusMessage = "Could not transcribe saved recording: \(error)"
            }
        }
    }

    func playRecovery(_ recording: RecoveryRecording) {
        guard phase != .recording && phase != .preparing && phase != .processing else { return }
        recoveryPlayback.toggle(id: recording.id, url: recoveryStore.audioURL(for: recording))
    }

    func seekRecovery(_ recording: RecoveryRecording, to time: TimeInterval) {
        guard phase != .recording && phase != .preparing && phase != .processing else { return }
        recoveryPlayback.prepare(id: recording.id, url: recoveryStore.audioURL(for: recording))
        recoveryPlayback.seek(to: time)
    }

    func deleteRecovery(_ recording: RecoveryRecording) {
        if recoveryPlayback.recordingID == recording.id { recoveryPlayback.stop() }
        do {
            try recoveryStore.delete(recording)
            recoveryRecordings.removeAll { $0.id == recording.id }
            recoveryIDsBySession = recoveryIDsBySession.filter { $0.value != recording.id }
            statusMessage = "Saved recording deleted"
        } catch {
            statusMessage = "Could not delete saved recording: \(error.localizedDescription)"
        }
    }

    private func saveRecoveryAudio(for sessionID: SessionID) {
        let pcm = recoveryBuffer.take()
        guard audioRetentionDays > 0, !pcm.isEmpty else { return }
        do {
            let recording = try recoveryStore.save(pcm16: pcm)
            recoveryIDsBySession[sessionID] = recording.id
            recoveryRecordings.insert(recording, at: 0)
        } catch {
            serverNote = "Could not save recovery audio: \(error.localizedDescription)"
        }
    }

    private func updateRecovery(
        for sessionID: SessionID,
        state: RecoveryRecordingState,
        transcript: String? = nil,
        failureReason: String? = nil
    ) {
        guard let id = recoveryIDsBySession[sessionID] else { return }
        updateRecovery(id, state: state, transcript: transcript, failureReason: failureReason)
    }

    private func updateRecovery(
        _ id: UUID,
        state: RecoveryRecordingState,
        transcript: String? = nil,
        failureReason: String? = nil
    ) {
        guard let index = recoveryRecordings.firstIndex(where: { $0.id == id }) else { return }
        recoveryRecordings[index].state = state
        recoveryRecordings[index].transcript = transcript
        recoveryRecordings[index].failureReason = failureReason
        do {
            try recoveryStore.update(recoveryRecordings[index])
        } catch {
            serverNote = "Could not update saved recording: \(error.localizedDescription)"
        }
    }

    // MARK: Onboarding + stats (Hub Home)

    @Published var onboarded = UserDefaults.standard.bool(forKey: "omil.onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "omil.onboarded") }
    }

    var totalWords: Int { history.reduce(0) { $0 + $1.wordCount } }
    var totalDictations: Int { history.count }

    /// Consecutive days (including today or yesterday) with dictations.
    var dayStreak: Int {
        let days = Set(history.map { Calendar.current.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        var streak = 0
        var day = Calendar.current.startOfDay(for: Date())
        if !days.contains(day) {
            // Allow the streak to survive until end of "yesterday grace": only
            // count back from yesterday if today is empty.
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
            if !days.contains(day) { return 0 }
        }
        while days.contains(day) {
            streak += 1
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    var historyByDay: [(day: Date, entries: [HistoryEntry])] {
        let grouped = Dictionary(grouping: history) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted(by: { $0.date > $1.date })) }
    }

    func dayLabel(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: day)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                statusMessage = "Launch at login failed: \(error)"
            }
            objectWillChange.send()
        }
    }

    // MARK: Diagnostics (no transcript content — safe to paste)

    func diagnostics() -> String {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let windows = NSApp.windows.map { "\($0.title.isEmpty ? "(untitled)" : $0.title):visible=\($0.isVisible)" }.joined(separator: ", ")
        return """
        Omil diagnostics (no transcript content):
        - app: \(appVersion) (\(build)) on \(os)
        - phase: \(phase.rawValue) — \(statusMessage)
        - mic: \(micPermission.rawValue)
        - backend: Effect/Bun server — \(backendDescription)
        - assets: \(assetState)
        - server: \(serverHealth) at \(serverConfig.host):\(serverConfig.port) (token set: \(serverConfig.token.isEmpty ? "no" : "yes"))
        - whisper: \(whisperFile) — llm: \(llmFile)
        - windows: [\(windows)]
        - pill: \(PillManager.shared.debugInfo())
        - last delivery: \(lastDeliveryMethod)
        """
    }

    // MARK: Dictionary

    func confirmDictionary(spoken: String, written: String) {
        dictionary.confirm(spoken: spoken, written: written)
        LocalHistory.saveDictionary(dictionary)
    }

    func deleteDictionaryEntry(spoken: String) {
        dictionary.remove(spoken: spoken)
        LocalHistory.saveDictionary(dictionary)
    }

    var dictionaryEntries: [String: String] { dictionary.entries }

    // MARK: Snippets + styles

    @discardableResult
    func addSnippet(trigger: String, expansion: String) -> String? {
        let cleanTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTrigger.isEmpty, !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Add both a spoken trigger and its expansion."
        }
        guard cleanTrigger.count <= 60 else { return "Triggers can be at most 60 characters." }
        guard expansion.count <= 4_000 else { return "Expansions can be at most 4,000 characters." }
        guard !snippets.contains(where: { $0.trigger.compare(cleanTrigger, options: .caseInsensitive) == .orderedSame }) else {
            return "That snippet trigger already exists."
        }
        guard !dictionary.entries.keys.contains(where: { $0.compare(cleanTrigger, options: .caseInsensitive) == .orderedSame }) else {
            return "That trigger is already used in Dictionary."
        }
        snippets.append(Snippet(trigger: cleanTrigger, expansion: expansion))
        snippets.sort { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
        LocalHistory.saveSnippets(snippets)
        return nil
    }

    func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        LocalHistory.saveSnippets(snippets)
    }

    func style(for category: AppCategory) -> WritingStyle {
        switch category {
        case .personal: return personalStyle
        case .work: return workStyle
        case .email: return emailStyle
        case .other: return otherStyle
        }
    }

    func setStyle(_ style: WritingStyle, for category: AppCategory) {
        switch category {
        case .personal: personalStyle = style
        case .work: workStyle = style
        case .email: emailStyle = style
        case .other: otherStyle = style
        }
    }

    private func styleForCapturedTarget() -> WritingStyle {
        style(for: Self.category(for: ax.capturedBundleId))
    }

    private static func category(for bundleId: String?) -> AppCategory {
        let id = bundleId?.lowercased() ?? ""
        if ["message", "whatsapp", "signal", "telegram", "discord"].contains(where: id.contains) { return .personal }
        if ["mail", "outlook", "superhuman", "spark"].contains(where: id.contains) { return .email }
        if ["slack", "teams", "zoom", "notion", "linear"].contains(where: id.contains) { return .work }
        return .other
    }

    private static func savedStyle(forKey key: String, fallback: WritingStyle) -> WritingStyle {
        UserDefaults.standard.string(forKey: key).flatMap(WritingStyle.init(rawValue:)) ?? fallback
    }
}

// MARK: - Diff helper

enum DiffUtil {
    /// Simple word-level diff for the Raw/Cleaned/Diff inspector.
    /// Capped so pathological inputs cannot hang the UI.
    static func diff(raw: String, cleaned: String) -> String {
        if raw == cleaned { return "(no changes)" }
        var a = raw.split(separator: " ").map(String.init)
        var b = cleaned.split(separator: " ").map(String.init)
        if a.count > 2000 || b.count > 2000 {
            a = Array(a.prefix(2000)); b = Array(b.prefix(2000))
        }
        // LCS-based minimal diff.
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { out.append(a[i]); i += 1; j += 1 }
            else if j < m, (i >= n || dp[i][j + 1] >= dp[i + 1][j]) { out.append("[+\(b[j])]"); j += 1 }
            else if i < n { out.append("[-\(a[i])]"); i += 1 }
        }
        return out.joined(separator: " ")
    }
}

// MARK: - Local history persistence

enum LocalHistory {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omil", isDirectory: true)
    }

    static func loadHistory() -> [DictationController.HistoryEntry] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("history.json")) else { return [] }
        return (try? JSONDecoder().decode([DictationController.HistoryEntry].self, from: data)) ?? []
    }

    static func saveHistory(_ h: [DictationController.HistoryEntry]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(h) {
            try? data.write(to: dir.appendingPathComponent("history.json"))
        }
    }

    static func loadDictionary() -> PersonalDictionary {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("dictionary.json")) else { return PersonalDictionary() }
        return (try? JSONDecoder().decode(PersonalDictionary.self, from: data)) ?? PersonalDictionary()
    }

    static func saveDictionary(_ d: PersonalDictionary) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(d) {
            try? data.write(to: dir.appendingPathComponent("dictionary.json"))
        }
    }

    static func loadSnippets() -> [DictationController.Snippet] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("snippets.json")) else { return [] }
        return (try? JSONDecoder().decode([DictationController.Snippet].self, from: data)) ?? []
    }

    static func saveSnippets(_ snippets: [DictationController.Snippet]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: dir.appendingPathComponent("snippets.json"), options: .atomic)
        }
    }
}

private final class RecoveryAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let result = data
        data = Data()
        return result
    }

    func reset() {
        lock.lock()
        data = Data()
        lock.unlock()
    }
}


/// One player shared by History cards so recordings never overlap.
@MainActor
final class RecoveryPlayback: ObservableObject {
    @Published private(set) var recordingID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published var rate: Float = 1 {
        didSet { player?.rate = rate }
    }
    @Published var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    func toggle(id: UUID, url: URL) {
        if recordingID == id, let player {
            if isPlaying {
                player.pause()
                position = player.currentTime
                isPlaying = false
                progressTask?.cancel()
                return
            }
            if position >= duration { player.currentTime = 0 }
        } else {
            prepare(id: id, url: url)
        }
        guard let player, player.play() else {
            errorMessage = "Couldn't start playback. Check your Mac's sound output and try again."
            return
        }
        errorMessage = nil
        isPlaying = true
        position = player.currentTime
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, let player = self.player else { return }
                guard player.isPlaying else {
                    self.position = self.duration
                    self.isPlaying = false
                    return
                }
                self.position = player.currentTime
            }
        }
    }

    func prepare(id: UUID, url: URL) {
        guard recordingID != id || player == nil else { return }
        stop()
        recordingID = id
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.enableRate = true
            audio.rate = rate
            audio.volume = volume
            audio.prepareToPlay()
            player = audio
            duration = audio.duration
        } catch {
            errorMessage = "This recording couldn't be opened. The audio file may be missing or damaged."
        }
    }

    func seek(to time: TimeInterval) {
        guard let player, time.isFinite else { return }
        let target = min(max(0, time), duration)
        player.currentTime = target
        position = target
        if target >= duration {
            player.pause()
            isPlaying = false
            progressTask?.cancel()
        }
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        recordingID = nil
        isPlaying = false
        position = 0
        duration = 0
        errorMessage = nil
    }
}
