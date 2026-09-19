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
    @Published var keyboardHint = ""

    let store: ResultStore
    private var session: DictationSession?
    private var backend: (any TranscriptionBackend)?
    private var capture = AudioCapture()
    private var probe = SpeechSupportProbe()
    private var selector = BackendSelector()
    private var status = AppleSpeechStatus(speechTranscriberAvailable: false, dictationAvailable: false, sfOnDeviceAvailable: false, installedLocales: [], detail: "probing")
    private var shared: SharedSession?
    private var eventTask: Task<Void, Never>?
    private var dictionary = PersonalDictionary()

    init() {
        self.store = ResultStore(appGroupId: Self.appGroupId)
        if let raw = UserDefaults.standard.string(forKey: "omil.mode"), let m = CleanupMode(rawValue: raw) {
            cleanupMode = m
        }
        dictionary = Self.loadDictionary()
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        status = await probe.probe()
        let resolved = selector.resolve(status: status, preference: .automatic)
        backendDescription = selector.describe(status: status, resolved: resolved)
        switch resolved {
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
        switch selector.resolve(status: status, preference: .automatic) {
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
        do {
            let captureBackend = backend
            try capture.start(targetSampleRate: 16_000, targetChannels: 1) { chunk in
                Task { await captureBackend.appendAudio(chunk.pcm16, timestamp: chunk.timestamp) }
            }
        } catch {
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        Task {
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
        if let s = shared {
            store.publishResult(
                s.sessionId, cleaned: committed.cleaned.text,
                raw: committed.rawSnapshot.rawText, sequence: 1)
        }
        await MainActor.run {
            self.lastCleaned = committed.cleaned.text
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
