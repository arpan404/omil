import Foundation
import Combine
import AVFAudio
import OmilCore

// MARK: - SessionCoordinator (iOS)
// The app captures audio and streams it to the selected speech engine (by
// default the Omil server on the user's Mac), then publishes completed results
// to the shared ResultStore for the keyboard.

@MainActor
final class SessionCoordinator: ObservableObject {
    enum Phase: String {
        case idle, preparing, recording, processing, ready, failed
    }

    static let appGroupId = "group.sh.arpan.omil.shared"

    @Published var phase: Phase = .idle
    @Published var draftText = ""
    @Published var lastRaw = ""
    @Published var lastCleaned = ""
    /// Live microphone level (0...1) while recording, for UI feedback only.
    @Published var audioLevel: Double = 0
    @Published var statusMessage = "Idle"
    @Published var backendDescription = "Probing…"
    @Published var assetState = "Unknown"
    @Published var cleanupMode: CleanupMode = .clean
    @Published var speechSensitivity: SpeechSensitivity = .balanced {
        didSet { UserDefaults.standard.set(speechSensitivity.rawValue, forKey: "omil.speechSensitivity") }
    }
    @Published var keyboardResultPending = false
    @Published var backendPreference: BackendChoice = .omilServer
    @Published var serverConfig = ServerConfig(host: "", port: 3217)
    @Published var serverCleanupEnabled = true
    @Published var serverHealth = "Unknown"
    @Published var pairingMessage = ""
    @Published var pairingInProgress = false
    @Published var cleanupPromptText = ""
    @Published private(set) var cleanupPromptCustom = false
    private var activeCleanupPrompt: String?

    let store: ResultStore
    private var session: DictationSession?
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
        serverHealth = "Checking connection…"
        pairingMessage = "Checking connection…"
        if let data = try? JSONEncoder().encode(serverConfig) {
            UserDefaults.standard.set(data, forKey: "omil.serverConfig")
        }
        if let data = try? JSONEncoder().encode(backendPreference) {
            UserDefaults.standard.set(data, forKey: "omil.backend")
        }
        UserDefaults.standard.set(serverCleanupEnabled, forKey: "omil.serverCleanup")
        Task {
            await refreshServerHealth()
            pairingMessage = serverHealth.contains(" · ")
                ? "Connected to your Mac."
                : serverHealth
            await loadCleanupPrompt()
        }
    }

    func pair(with scannedText: String) async {
        guard !pairingInProgress else { return }
        guard let url = URL(string: scannedText),
              let candidate = ServerConfig(pairingURL: url),
              let endpoint = candidate.endpoint(path: "/v1/prompt") else {
            pairingMessage = "This is not an Omil pairing code."
            return
        }
        pairingInProgress = true
        pairingMessage = "Connecting to your Mac…"
        defer { pairingInProgress = false }
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 8
            request.setValue("Bearer \(candidate.token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                pairingMessage = "The Mac did not respond."
                return
            }
            guard response.statusCode == 200 else {
                pairingMessage = response.statusCode == 401
                    ? "The server token was rejected. Generate a new QR code on your Mac."
                    : "The Mac returned an error (\(response.statusCode))."
                return
            }
            serverConfig = candidate
            backendPreference = .omilServer
            saveServerConfig()
            pairingMessage = "Connected to your Mac."
        } catch {
            pairingMessage = "Could not reach your Mac. Keep both devices on the same network and enable sharing in Omil."
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
        serverHealth = await probeBackend.serverHealth()
    }

    /// Returns the server's cleanup of `rawText`, or `rawText` unchanged when
    /// server cleanup is off or fails (the caller then keeps the local result).
    func serverClean(rawText: String, requestId: String) async -> String {
        guard serverCleanupEnabled, cleanupMode == .clean else { return rawText }
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
            return r.text
        } catch {
            return rawText
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
        keyboardResultPending = store.pendingResult() != nil
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
        self.shared = store.createSession(mode: cleanupMode)
        if let s = shared { store.updateState(s.sessionId, state: .recording) }
        phase = .preparing
        statusMessage = "Preparing…"
        draftText = ""
        Task {
            let granted = await AudioCapture.requestPermission()
            guard granted else {
                self.phase = .failed
                self.statusMessage = "Microphone permission denied."
                return
            }
            self.configureAudioSession()
            do {
                try await session.start(backend: backend)
            } catch {
                self.phase = .failed
                self.statusMessage = "Could not start: \(error)"
                return
            }
            self.phase = .recording
            self.statusMessage = "Recording — tap Stop to finalize"
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
                    self.draftText = text
                case .finalized(let snap):
                    self.lastRaw = snap.rawText
                case .cleaned(let view):
                    self.lastCleaned = view.text
                case .failed(let err):
                    self.phase = .failed
                    self.statusMessage = "Recognition failed: \(err)"
                }
            }
        }
    }

    private func startCapture(backend: any TranscriptionBackend) {
        let forwarder = AudioChunkForwarder { chunk in
            await backend.appendAudio(chunk.pcm16, timestamp: chunk.timestamp)
        }
        audioForwarder = forwarder
        #if DEBUG
        if let path = DebugLaunch.dictateFile {
            feedDebugAudio(path: path, to: forwarder)
            return
        }
        #endif
        do {
            try capture.start(targetSampleRate: 16_000, targetChannels: 1) { [weak self] chunk in
                forwarder.append(chunk)
                let level = AudioLevelMeter.normalizedRMS(pcm16: chunk.pcm16)
                Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.audioLevel = level
                }
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

    #if DEBUG
    /// Plays a 16 kHz mono WAV through the recording pipeline in place of the
    /// microphone, then stops as if the user tapped Stop.
    private func feedDebugAudio(path: String, to forwarder: AudioChunkForwarder) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 44 else {
            phase = .failed
            statusMessage = "Debug audio not found: \(path)"
            return
        }
        let pcm = data.dropFirst(44)
        Task {
            let chunkBytes = 3_200 // 100 ms
            var offset = pcm.startIndex
            while offset < pcm.endIndex {
                let end = min(offset + chunkBytes, pcm.endIndex)
                let chunk = Data(pcm[offset..<end])
                let timestamp = Double(offset - pcm.startIndex) / 32_000
                forwarder.append(CapturedChunk(pcm16: chunk, sampleRate: 16_000, timestamp: timestamp))
                audioLevel = AudioLevelMeter.normalizedRMS(pcm16: chunk)
                offset = end
                try? await Task.sleep(for: .milliseconds(100))
            }
            stop()
        }
    }
    #endif

    func stop() {
        guard phase == .recording, let session = session else { return }
        phase = .processing
        statusMessage = "Finalizing…"
        audioLevel = 0
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
                self.phase = .idle
                self.statusMessage = "Cancelled"
            }
        }
    }

    func cancel() {
        capture.cancel()
        audioForwarder?.cancel()
        audioForwarder = nil
        audioLevel = 0
        if let s = shared { store.cancelSession(s.sessionId) }
        Task {
            await session?.cancel()
            self.phase = .idle
            self.draftText = ""
            self.statusMessage = "Cancelled — nothing published"
        }
    }

    private func publish(result: SessionResult) async {
        guard let committed = await session?.commitForDelivery() else {
            self.phase = .idle
            self.statusMessage = "Nothing to publish"
            return
        }
        let cleaned = await self.serverClean(
            rawText: committed.rawSnapshot.rawText,
            requestId: committed.sessionId.rawValue
        )
        let finalText = cleaned.isEmpty ? committed.cleaned.text : cleaned
        if let s = shared {
            store.publishResult(
                s.sessionId, cleaned: finalText,
                raw: committed.rawSnapshot.rawText, sequence: 1)
        }
        self.lastCleaned = finalText
        DictationHistory.shared.add(raw: committed.rawSnapshot.rawText, cleaned: finalText)
        self.phase = .ready
        self.statusMessage = "Done — switch to the Omil keyboard and tap Insert, or copy below."
        self.refreshKeyboardHint()
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
        objectWillChange.send()
        dictionary.confirm(spoken: spoken, written: written)
        if let data = try? JSONEncoder().encode(dictionary) {
            UserDefaults.standard.set(data, forKey: "omil.dict")
        }
    }

    func removeDictionary(spoken: String) {
        objectWillChange.send()
        dictionary.remove(spoken: spoken)
        if let data = try? JSONEncoder().encode(dictionary) {
            UserDefaults.standard.set(data, forKey: "omil.dict")
        }
    }

    var dictionaryEntries: [String: String] { dictionary.entries }
}
