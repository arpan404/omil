import Foundation
import Combine
import AVFAudio
import OmilCore

// MARK: - SessionCoordinator (iOS)
// The containing app owns audio capture + local inference and publishes
// completed results to the shared ResultStore for the keyboard.

@MainActor
final class SessionCoordinator: ObservableObject {
    enum Phase: String {
        case idle, preparing, recording, processing, ready, failed
    }

    static let appGroupId = "group.com.omil.shared"

    @Published var phase: Phase = .idle
    @Published var draftText = ""
    @Published var lastRaw = ""
    @Published var lastCleaned = ""
    @Published var lastDiff = ""
    @Published var statusMessage = "Idle"
    @Published var backendDescription = "Probing…"
    @Published var assetState = "Unknown"
    @Published var cleanupMode: CleanupMode = .clean
    @Published var speechSensitivity: SpeechSensitivity = .balanced {
        didSet { UserDefaults.standard.set(speechSensitivity.rawValue, forKey: "omil.speechSensitivity") }
    }
    @Published var keyboardHint = ""
    // Server core (user's Mac). Thin client: capture + display + handoff.
    // Full mobile pass comes after Mac validation.
    @Published var backendPreference: BackendChoice = .omilServer
    @Published var serverConfig = ServerConfig(host: "", port: 3217)
    @Published var serverCleanupEnabled = true
    @Published var serverHealth = "Unknown"
    @Published var serverNote = ""
    @Published var cleanupPromptText = ""
    @Published private(set) var cleanupPromptCustom = false
    private var activeCleanupPrompt: String?

    let store: ResultStore
    private var session: DictationSession?
    private var backend: (any TranscriptionBackend)?
    private var capture = AudioCapture()
    private var audioForwarder: AudioChunkForwarder?
    private var probe = SpeechSupportProbe()
    private var selector = BackendSelector()
    private var status = AppleSpeechStatus(speechTranscriberAvailable: false, dictationAvailable: false, sfOnDeviceAvailable: false, installedLocales: [], detail: "probing")
    private var shared: SharedSession?
    private var eventTask: Task<Void, Never>?
    private var dictionary = PersonalDictionary()

    init() {
        self.store = ResultStore(appGroupId: Self.appGroupId)
        activeCleanupPrompt = UserDefaults.standard.string(forKey: "omil.cleanupSystemPrompt")
        if let activeCleanupPrompt {
            cleanupPromptText = activeCleanupPrompt
            cleanupPromptCustom = true
        }
        if let raw = UserDefaults.standard.string(forKey: "omil.mode"), let m = CleanupMode(rawValue: raw) {
            cleanupMode = m
        }
        if let raw = UserDefaults.standard.string(forKey: "omil.speechSensitivity"),
           let saved = SpeechSensitivity(rawValue: raw) {
            speechSensitivity = saved
        }
        dictionary = Self.loadDictionary()
        if let data = UserDefaults.standard.data(forKey: "omil.serverConfig"),
           let cfg = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            serverConfig = cfg
        }
        if let data = UserDefaults.standard.data(forKey: "omil.backend"),
           let pref = try? JSONDecoder().decode(BackendChoice.self, from: data) {
            backendPreference = pref
        }
        serverCleanupEnabled = UserDefaults.standard.object(forKey: "omil.serverCleanup") as? Bool ?? true
        Task { await refreshStatus() }
    }

    func saveServerConfig() {
        if let data = try? JSONEncoder().encode(serverConfig) {
            UserDefaults.standard.set(data, forKey: "omil.serverConfig")
        }
        if let data = try? JSONEncoder().encode(backendPreference) {
            UserDefaults.standard.set(data, forKey: "omil.backend")
        }
        UserDefaults.standard.set(serverCleanupEnabled, forKey: "omil.serverCleanup")
        Task {
            await refreshServerHealth()
            await loadCleanupPrompt()
        }
    }

    func loadCleanupPrompt() async {
        guard !cleanupPromptCustom, let url = serverConfig.endpoint(path: "/v1/prompt") else { return }
        let textBeforeRequest = cleanupPromptText
        var request = URLRequest(url: url)
        request.setValue("Bearer \(serverConfig.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !cleanupPromptCustom,
              cleanupPromptText == textBeforeRequest else { return }
        cleanupPromptText = text
    }

    func saveCleanupPrompt() {
        guard cleanupPromptText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50,
              cleanupPromptText.count <= 50_000 else { return }
        activeCleanupPrompt = cleanupPromptText
        UserDefaults.standard.set(cleanupPromptText, forKey: "omil.cleanupSystemPrompt")
        cleanupPromptCustom = true
    }

    func resetCleanupPrompt() {
        activeCleanupPrompt = nil
        UserDefaults.standard.removeObject(forKey: "omil.cleanupSystemPrompt")
        cleanupPromptCustom = false
        cleanupPromptText = ""
        Task { await loadCleanupPrompt() }
    }

    func refreshServerHealth() async {
        let probeBackend = ServerTranscriptionBackend(
            config: serverConfig,
            modelId: ServerCatalog.whisperIdForFile[ServerCatalog.defaultWhisperFile]
        )
        let health = await probeBackend.serverHealth()
        await MainActor.run { self.serverHealth = health }
    }

    func serverClean(rawText: String, requestId: String) async -> (text: String, note: String) {
        guard serverCleanupEnabled, cleanupMode == .clean else {
            return (rawText, "local rules")
        }
        let client = ServerCleanupClient(
            config: serverConfig,
            dictionary: dictionary,
            modelId: ServerCatalog.llmIdForFile[ServerCatalog.defaultLlmFile],
            systemPrompt: activeCleanupPrompt
        )
        do {
            let r = try await client.clean(
                text: rawText,
                mode: cleanupMode,
                requestId: requestId
            )
            return (r.text, "Qwen cleanup via server (\(r.acceptedEdits.count) edits)")
        } catch {
            return (rawText, "Server cleanup unavailable (\(error)); used local rules")
        }
    }

    func refreshStatus() async {
        status = await probe.probe()
        let resolved = selector.resolve(status: status, preference: backendPreference)
        backendDescription = selector.describe(status: status, resolved: resolved)
        switch resolved {
        case .omilServer:
            assetState = "Checking server…"
            await refreshServerHealth()
            assetState = serverHealth
        case .appleSpeech: assetState = "Ready (system-managed assets)"
        case .legacySFSpeech: assetState = "Ready (no download)"
        case .unavailable(let r): assetState = r
        }
        refreshKeyboardHint()
    }

    func refreshKeyboardHint() {
        if let pending = store.pendingResult() {
            keyboardHint = "Keyboard has a result ready (\(pending.cleanedText?.prefix(40) ?? "")…)"
        } else {
            keyboardHint = "No pending keyboard result."
        }
    }

    private func makeBackend() -> (any TranscriptionBackend)? {
        switch selector.resolve(status: status, preference: backendPreference) {
        case .omilServer:
            return ServerTranscriptionBackend(
                config: serverConfig,
                modelId: ServerCatalog.whisperIdForFile[ServerCatalog.defaultWhisperFile],
                sensitivity: speechSensitivity
            )
        case .appleSpeech:
            if #available(iOS 26, *) { return AppleSpeechBackend() }
            return nil
        case .legacySFSpeech:
            #if canImport(Speech)
            return LegacySpeechBackend()
            #else
            return nil
            #endif
        case .unavailable:
            return nil
        }
    }

    // MARK: Recording

    func start() {
        guard phase == .idle || phase == .ready || phase == .failed else { return }
        guard let backend = makeBackend() else {
            phase = .failed
            statusMessage = "No on-device speech backend available."
            return
        }
        let session = DictationSession(mode: cleanupMode, dictionary: dictionary)
        self.session = session
        self.backend = backend
        self.shared = store.createSession(mode: cleanupMode)
        if let s = shared { store.updateState(s.sessionId, state: .recording) }
        phase = .preparing
        statusMessage = "Preparing…"
        draftText = ""
        Task {
            let granted = await AudioCapture.requestPermission()
            guard granted else {
                await MainActor.run {
                    self.phase = .failed
                    self.statusMessage = "Microphone permission denied."
                }
                return
            }
            self.configureAudioSession()
            do {
                try await session.start(backend: backend)
            } catch {
                await MainActor.run {
                    self.phase = .failed
                    self.statusMessage = "Could not start: \(error)"
                }
                return
            }
            await MainActor.run {
                self.phase = .recording
                self.statusMessage = "Recording — tap Stop to finalize"
            }
            self.streamEvents(session: session)
            self.startCapture(backend: backend)
        }
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try s.setActive(true)
        } catch {
            statusMessage = "Audio session: \(error)"
        }
        #endif
    }

    private func streamEvents(session: DictationSession) {
        eventTask?.cancel()
        eventTask = Task {
            for await event in await session.events() {
                switch event {
                case .draftAvailable(let text):
                    await MainActor.run { self.draftText = text }
                case .finalized(let snap):
                    await MainActor.run { self.lastRaw = snap.rawText }
                case .cleaned(let view):
                    await MainActor.run {
                        self.lastCleaned = view.text
                        self.lastDiff = DiffWords.diff(raw: self.lastRaw, cleaned: view.text)
                    }
                case .failed(let err):
                    await MainActor.run {
                        self.phase = .failed
                        self.statusMessage = "Recognition failed: \(err)"
                    }
                }
            }
        }
    }

    private func startCapture(backend: any TranscriptionBackend) {
        let forwarder = AudioChunkForwarder { chunk in
            await backend.appendAudio(chunk.pcm16, timestamp: chunk.timestamp)
        }
        audioForwarder = forwarder
        do {
            try capture.start(targetSampleRate: 16_000, targetChannels: 1) { chunk in
                forwarder.append(chunk)
            }
        } catch {
            forwarder.cancel()
            audioForwarder = nil
            Task { @MainActor in
                self.phase = .failed
                self.statusMessage = "Microphone unavailable: \(error)"
            }
            Task { await session?.cancel() }
        }
    }

    func stop() {
        guard phase == .recording, let session = session else { return }
        phase = .processing
        statusMessage = "Finalizing…"
        capture.stop()
        let forwarder = audioForwarder
        audioForwarder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        Task {
            await forwarder?.finish()
            if let result = await session.stop() {
                await self.publish(result: result)
            } else {
                await MainActor.run {
                    self.phase = .idle
                    self.statusMessage = "Cancelled"
                }
            }
        }
    }

    func cancel() {
        capture.cancel()
        audioForwarder?.cancel()
        audioForwarder = nil
        if let s = shared { store.cancelSession(s.sessionId) }
        Task {
            await session?.cancel()
            await MainActor.run {
                self.phase = .idle
                self.draftText = ""
                self.statusMessage = "Cancelled — nothing published"
            }
        }
    }

    private func publish(result: SessionResult) async {
        guard let committed = await session?.commitForDelivery() else {
            await MainActor.run {
                self.phase = .idle
                self.statusMessage = "Nothing to publish"
            }
            return
        }
        let cleaned = await self.serverClean(
            rawText: committed.rawSnapshot.rawText,
            requestId: committed.sessionId.rawValue
        )
        let finalText = cleaned.text.isEmpty ? committed.cleaned.text : cleaned.text
        await MainActor.run { self.serverNote = cleaned.note }
        if let s = shared {
            store.publishResult(
                s.sessionId, cleaned: finalText,
                raw: committed.rawSnapshot.rawText, sequence: 1)
        }
        await MainActor.run {
            self.lastCleaned = finalText
            self.phase = .ready
            self.statusMessage = "Done — switch to the Omil keyboard and tap Insert, or copy below."
            self.refreshKeyboardHint()
        }
    }

    func setMode(_ m: CleanupMode) {
        cleanupMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "omil.mode")
    }

    // MARK: Dictionary

    static func loadDictionary() -> PersonalDictionary {
        guard let data = UserDefaults.standard.data(forKey: "omil.dict") else { return PersonalDictionary() }
        return (try? JSONDecoder().decode(PersonalDictionary.self, from: data)) ?? PersonalDictionary()
    }

    func confirmDictionary(spoken: String, written: String) {
        dictionary.confirm(spoken: spoken, written: written)
        if let data = try? JSONEncoder().encode(dictionary) {
            UserDefaults.standard.set(data, forKey: "omil.dict")
        }
    }

    var dictionaryEntries: [String: String] { dictionary.entries }
}

enum DiffWords {
    static func diff(raw: String, cleaned: String) -> String {
        if raw == cleaned { return "(no changes)" }
        return "RAW: \(raw)\nCLEANED: \(cleaned)"
    }
}
