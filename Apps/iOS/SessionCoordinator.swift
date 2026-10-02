import Foundation
import Combine
import AVFAudio
import OmilCore

// MARK: - SessionCoordinator (iOS)
// The app captures audio and streams it to the selected speech engine (by
// default the Omil server on the user's Mac), then publishes completed results
// to the shared ResultStore for the keyboard.
//
// The keyboard can't record, so it opens the app with omil://dictate. That
// starts a mic session: the audio engine keeps running in the background
// (UIBackgroundModes audio) for a few minutes, and the keyboard starts and
// stops dictations through the KeyboardLink while the user stays in their app.

@MainActor
final class SessionCoordinator: ObservableObject {
    enum Phase: String {
        case idle, preparing, recording, processing, ready, failed
    }

    static let appGroupId = "group.sh.arpan.omil.shared"

    /// Who started the current dictation.
    enum Origin { case app, keyboard }

    @Published var phase: Phase = .idle {
        didSet { if phase != oldValue { publishLink() } }
    }
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
    /// When the keyboard's mic session ends; nil when it's off.
    @Published private(set) var micSessionEnds: Date?
    /// Shown after the keyboard opens the app, telling the user to go back.
    @Published var showsReturnHint = false
    /// Set when the keyboard asks to pair, so the app opens the pairing screen.
    @Published var pairingRequested = false
    @Published var micSessionMinutes: Int {
        didSet { UserDefaults.standard.set(micSessionMinutes, forKey: Self.micSessionKey) }
    }
    @Published var returnAfterInsert: Bool {
        didSet {
            UserDefaults.standard.set(returnAfterInsert, forKey: Self.returnAfterInsertKey)
            shareKeyboardSetup()
        }
    }
    @Published private(set) var origin: Origin = .app
    private var activeCleanupPrompt: String?

    static let micSessionChoices = [1, 5, 15, 60]
    private static let micSessionKey = "omil.keyboard.micMinutes"
    private static let returnAfterInsertKey = "omil.keyboard.returnAfterInsert"

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
    private let router = CaptureRouter()
    /// The audio engine is running (always while a mic session is on).
    private var captureRunning = false
    private var recordingStarted: Date?
    private let link = LinkChannel(appGroupId: SessionCoordinator.appGroupId)
    private var commandObserver: DarwinObserver?
    private var lastCommandId: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var lastLinkWrite = Date.distantPast
    private var interruptionObserver: NSObjectProtocol?

    init() {
        self.store = ResultStore(appGroupId: Self.appGroupId)
        let minutes = UserDefaults.standard.integer(forKey: Self.micSessionKey)
        micSessionMinutes = Self.micSessionChoices.contains(minutes) ? minutes : 5
        returnAfterInsert = UserDefaults.standard.object(forKey: Self.returnAfterInsertKey) as? Bool ?? true
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
        router.setLevelHandler { [weak self] level in
            Task { @MainActor in self?.levelChanged(level) }
        }
        commandObserver = DarwinObserver(KeyboardLink.commandPosted) { [weak self] in
            Task { @MainActor in self?.handleKeyboardCommand() }
        }
        // A fresh launch has no mic session, whatever an earlier run left behind.
        publishLink()
        shareKeyboardSetup()
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
        shareKeyboardSetup()
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

    func start(origin: Origin = .app) {
        guard phase == .idle || phase == .ready || phase == .failed else { return }
        guard let backend = makeBackend() else {
            phase = .failed
            statusMessage = "No on-device speech backend available."
            return
        }
        let session = DictationSession(mode: cleanupMode, dictionary: dictionary)
        self.session = session
        self.origin = origin
        self.shared = store.createSession(mode: cleanupMode, autoInsert: origin == .keyboard)
        if let s = shared { store.updateState(s.sessionId, state: .recording) }
        draftText = ""
        phase = .preparing
        statusMessage = "Preparing…"
        Task {
            let granted = await AudioCapture.requestPermission()
            guard granted else {
                self.phase = .failed
                self.statusMessage = "Microphone permission denied."
                return
            }
            if !self.captureRunning { self.configureAudioSession() }
            do {
                try await session.start(backend: backend)
            } catch {
                self.releaseCapture()
                self.phase = .failed
                self.statusMessage = "Could not start: \(error)"
                return
            }
            self.recordingStarted = .now
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
            if micSessionEnds != nil {
                // A mic session runs for minutes in the background, so let
                // the user's music and videos keep playing.
                try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
            } else {
                try s.setCategory(.record, mode: .measurement, options: [.duckOthers])
            }
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
        capture.markSegmentStart()
        router.attach(forwarder)
        guard !captureRunning else { return }
        do {
            try capture.start(targetSampleRate: 16_000, targetChannels: 1) { [router] chunk in
                router.handle(chunk)
            }
            captureRunning = true
        } catch {
            router.detach()
            forwarder.cancel()
            audioForwarder = nil
            phase = .failed
            statusMessage = "Microphone unavailable: \(error)"
            Task { await session?.cancel() }
        }
    }

    private func levelChanged(_ level: Double) {
        guard phase == .recording else { return }
        audioLevel = level
        // The keyboard draws its waveform from the shared state.
        if micSessionEnds != nil, Date().timeIntervalSince(lastLinkWrite) > 0.08 {
            publishLink(notify: false)
        }
    }

    /// Stops sending audio to the finished dictation. A mic session keeps the
    /// engine running for the next one; otherwise the microphone turns off.
    private func releaseCapture() {
        router.detach()
        recordingStarted = nil
        guard micSessionEnds == nil else { return }
        stopEngine()
    }

    private func stopEngine() {
        guard captureRunning else { return }
        capture.stop()
        captureRunning = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
        audioLevel = 0
        releaseCapture()
        let forwarder = audioForwarder
        audioForwarder = nil
        statusMessage = "Finalizing…"
        phase = .processing
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
        releaseCapture()
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
        if micSessionEnds != nil { extendMicSession() }
        self.statusMessage = origin == .keyboard
            ? "Done — your text goes in where you were typing."
            : "Done — insert it with the Omil keyboard, or copy below."
        self.phase = .ready
        self.refreshKeyboardHint()
    }

    func setMode(_ m: CleanupMode) {
        cleanupMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "omil.mode")
    }

    // MARK: Keyboard mic session

    /// Handles omil:// links from the keyboard.
    func handle(url: URL) {
        guard url.scheme == KeyboardLink.dictateURL.scheme else { return }
        switch url.host {
        case KeyboardLink.dictateURL.host: dictateForKeyboard()
        case KeyboardLink.pairURL.host: pairingRequested = true
        default: break
        }
    }

    /// The keyboard opened the app to dictate: turn the mic session on and
    /// start listening right away, so the user can go back and keep talking.
    func dictateForKeyboard() {
        guard !needsMacSetup else {
            pairingRequested = true
            return
        }
        beginMicSession()
        showsReturnHint = true
        switch phase {
        case .idle, .ready, .failed: start(origin: .keyboard)
        case .preparing, .recording, .processing: break
        }
    }

    func beginMicSession() {
        let wasOff = micSessionEnds == nil
        extendMicSession()
        guard wasOff else { return }
        observeInterruptions()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.heartbeat()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func endMicSession() {
        guard micSessionEnds != nil else { return }
        micSessionEnds = nil
        showsReturnHint = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        switch phase {
        case .preparing, .recording: cancel()
        default: stopEngine()
        }
        publishLink()
    }

    private func extendMicSession() {
        micSessionEnds = Date().addingTimeInterval(TimeInterval(micSessionMinutes * 60))
    }

    private func heartbeat() {
        guard let ends = micSessionEnds else { return }
        let busy = phase == .preparing || phase == .recording || phase == .processing
        if !busy, ends <= .now {
            endMicSession()
            return
        }
        publishLink(notify: false)
    }

    /// A call or Siri takes the microphone and stops the engine; keep what
    /// was said so far and end the session (the keyboard reopens the app).
    private func observeInterruptions() {
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.phase == .recording { self.stop() }
                self.captureRunning = false
                self.capture.cancel()
                self.endMicSession()
            }
        }
        #endif
    }

    private func handleKeyboardCommand() {
        guard let command = link?.command(after: lastCommandId) else { return }
        lastCommandId = command.id
        switch command.kind {
        case .start:
            // The engine can't start in the background; without a running
            // session the keyboard opens the app instead.
            guard micSessionEnds != nil, captureRunning else {
                publishLink()
                return
            }
            extendMicSession()
            start(origin: .keyboard)
        case .stop: stop()
        case .cancel: cancel()
        case .end: endMicSession()
        }
    }

    private var linkState: LinkState {
        guard micSessionEnds != nil else {
            return LinkState(phase: .off, sessionId: shared?.sessionId.rawValue)
        }
        let linkPhase: LinkState.Phase
        switch phase {
        case .idle, .ready: linkPhase = .ready
        case .preparing: linkPhase = .starting
        case .recording: linkPhase = .recording
        case .processing: linkPhase = .processing
        case .failed: linkPhase = .failed
        }
        return LinkState(
            phase: linkPhase,
            sessionEnds: micSessionEnds,
            recordingStarted: recordingStarted,
            level: phase == .recording ? audioLevel : 0,
            draft: String(draftText.suffix(160)),
            message: phase == .failed ? keyboardFailureMessage : nil,
            sessionId: shared?.sessionId.rawValue
        )
    }

    private var keyboardFailureMessage: String {
        if statusMessage.contains("permission") { return "Allow the microphone for Omil in Settings." }
        if backendPreference == .omilServer { return "Couldn't reach your Mac. Make sure Omil is open on it." }
        return "Dictation didn't start. Try again."
    }

    private func publishLink(notify: Bool = true) {
        guard let link else { return }
        lastLinkWrite = .now
        link.write(linkState, notify: notify)
    }

    private func shareKeyboardSetup() {
        let paired = backendPreference != .omilServer || serverConfig.isConfigured
        link?.write(LinkSetup(paired: paired, macName: Self.macName(for: serverConfig.host),
                              returnAfterInsert: returnAfterInsert))
    }

    /// "Studio-Mac.local" → "Studio Mac"; addresses stay as they are.
    static func macName(for host: String) -> String? {
        guard !host.isEmpty else { return nil }
        guard host.hasSuffix(".local") else { return host }
        return String(host.dropLast(6)).replacingOccurrences(of: "-", with: " ")
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

/// Sends microphone audio to the dictation in progress, if any. The engine
/// keeps running between dictations in a mic session; audio arriving with no
/// dictation attached is dropped on the spot, never stored.
final class CaptureRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var forwarder: AudioChunkForwarder?
    private var onLevel: (@Sendable (Double) -> Void)?

    func setLevelHandler(_ handler: @escaping @Sendable (Double) -> Void) {
        lock.lock(); onLevel = handler; lock.unlock()
    }

    func attach(_ forwarder: AudioChunkForwarder) {
        lock.lock(); self.forwarder = forwarder; lock.unlock()
    }

    func detach() {
        lock.lock(); forwarder = nil; lock.unlock()
    }

    func handle(_ chunk: CapturedChunk) {
        lock.lock()
        let forwarder = forwarder
        let onLevel = onLevel
        lock.unlock()
        guard let forwarder else { return }
        forwarder.append(chunk)
        onLevel?(AudioLevelMeter.normalizedRMS(pcm16: chunk.pcm16))
    }
}
