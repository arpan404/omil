import AppKit
import AVFoundation
import Combine
import OmilCore
import ServiceManagement

// MARK: - DictationController (Mac)
//
// Owns the full Mac workflow: destination capture -> recording -> local
// inference -> cleanup -> guarded insertion (AX direct, clipboard fallback)
// with receipts, scoped undo, and inspectable history.

@MainActor
final class DictationController: ObservableObject {
    enum Phase: String {
        case idle, preparing, recording, processing, ready, failed
    }

    @Published var phase: Phase = .idle
    @Published var draftText = ""
    @Published var lastRaw = ""
    @Published var lastCleaned = ""
    @Published var lastDiff = ""
    @Published var statusMessage = "Idle"
    @Published var backendDescription = "Probing…"
    @Published var assetState = "Unknown"
    @Published var cleanupMode: CleanupMode = .clean {
        didSet { UserDefaults.standard.set(cleanupMode.rawValue, forKey: "omil.mode") }
    }
    @Published var backendPreference: BackendChoice = .omilServer {
        didSet {
            if let data = try? JSONEncoder().encode(backendPreference) {
                UserDefaults.standard.set(data, forKey: "omil.backend")
            }
            Task { await refreshBackendStatus() }
        }
    }
    @Published var history: [HistoryEntry] = []
    @Published var lastReceipt: InsertionReceipt?
    @Published var lastDeliveryMethod = ""
    @Published var micPermission: MicPermission = .unknown
    @Published var historyEnabled = true
    @Published var serverConfig = ServerConfig()
    @Published var serverCleanupEnabled = true
    @Published var serverNote = ""
    @Published var serverHealth = "Unknown"
    @Published var whisperFile = "ggml-large-v3-turbo.bin"
    @Published var llmFile = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    @Published var promptText = ""
    @Published var promptCustom = false
    @Published var serverOpNote = ""
    @Published var pillEnabled = true {
        didSet { UserDefaults.standard.set(pillEnabled, forKey: "omil.pillEnabled") }
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

    private var session: DictationSession?
    private var capture = AudioCapture()
    private var backend: (any TranscriptionBackend)?
    private var probe = SpeechSupportProbe()
    private var selector = BackendSelector()
    private var status = AppleSpeechStatus(speechTranscriberAvailable: false, dictationAvailable: false, sfOnDeviceAvailable: false, installedLocales: [], detail: "probing")
    private var ax = AXInserter()
    private var clipboard = ClipboardInserter()
    private var precondition: SelectionPrecondition?
    private var sessionSeq = 0
    private var eventTask: Task<Void, Never>?
    private var dictionary = PersonalDictionary()

    init() {
        if let raw = UserDefaults.standard.string(forKey: "omil.mode"), let m = CleanupMode(rawValue: raw) {
            cleanupMode = m
        }
        if let data = UserDefaults.standard.data(forKey: "omil.backend"),
           let pref = try? JSONDecoder().decode(BackendChoice.self, from: data) {
            backendPreference = pref
        }
        dictionary = LocalHistory.loadDictionary()
        history = LocalHistory.loadHistory()
        historyEnabled = UserDefaults.standard.object(forKey: "omil.historyEnabled") as? Bool ?? true
        if !historyEnabled { history = [] }
        if let data = UserDefaults.standard.data(forKey: "omil.serverConfig"),
           let cfg = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            serverConfig = cfg
        }
        whisperFile = UserDefaults.standard.string(forKey: "omil.whisperFile") ?? whisperFile
        llmFile = UserDefaults.standard.string(forKey: "omil.llmFile") ?? llmFile
        pillEnabled = UserDefaults.standard.object(forKey: "omil.pillEnabled") as? Bool ?? true
        serverCleanupEnabled = UserDefaults.standard.object(forKey: "omil.serverCleanup") as? Bool ?? true
    }

    /// Post-launch startup (called from AppDelegate): hotkeys + backend probe.
    /// Kept out of init so launch stays fast and diagnosable.
    /// The inference server runs separately (see docs/BUILD.md); this app is
    /// a pure client over its LAN API.
    func startup() {
        NSLog("Omil: startup")
        HotkeyManager.shared.onPushStart = { [weak self] in self?.start() }
        HotkeyManager.shared.onPushStop = { [weak self] in self?.stop() }
        HotkeyManager.shared.onToggle = { [weak self] in self?.toggle() }
        HotkeyManager.shared.start()
        Task { await refreshBackendStatus() }
        NSLog("Omil: startup done")
    }

    var axTrusted: Bool { ax.isTrusted }
    var canUndo: Bool { lastReceipt?.undoSupported == true }

    func requestAXTrust() {
        ax.requestTrust()
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
        Task {
            let granted = await AudioCapture.requestPermission()
            await MainActor.run {
                self.micPermission = granted ? .granted : .denied
            }
        }
    }

    // MARK: Status

    func refreshBackendStatus() async {
        status = await probe.probe()
        let resolved = selector.resolve(status: status, preference: backendPreference)
        backendDescription = selector.describe(status: status, resolved: resolved)
        switch resolved {
        case .omilServer:
            assetState = "Checking server…"
            Task { await self.refreshServerHealth() }
        case .appleSpeech: assetState = (await appleAssetState() ?? "Ready")
        case .legacySFSpeech: assetState = "Ready (no download)"
        case .unavailable(let r): assetState = r
        }
    }

    // MARK: Server core

    func saveServerConfig() {
        if let data = try? JSONEncoder().encode(serverConfig) {
            UserDefaults.standard.set(data, forKey: "omil.serverConfig")
        }
        UserDefaults.standard.set(serverCleanupEnabled, forKey: "omil.serverCleanup")
        Task { await refreshServerHealth() }
    }

    private func serverRequest(path: String, method: String = "GET", jsonBody: [String: Any]? = nil) -> URLRequest? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = serverConfig.host.isEmpty ? nil : serverConfig.host
        comps.port = serverConfig.port
        guard let base = comps.url else { return nil }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(serverConfig.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        return req
    }

    struct ServerModelInfo: Codable, Identifiable {
        var id: String
        var kind: String
        var description: String
        var filename: String
        var approxBytes: Int?
        var downloaded: Bool
        var selected: Bool
    }

    @Published var serverModels: [ServerModelInfo] = []

    /// Persist model selection and tell the running server to switch.
    /// Missing weights download server-side on first use.
    func selectModels() {
        UserDefaults.standard.set(whisperFile, forKey: "omil.whisperFile")
        UserDefaults.standard.set(llmFile, forKey: "omil.llmFile")
        serverOpNote = "Switching models…"
        Task {
            guard let whisperId = ServerCatalog.whisperIdForFile[whisperFile],
                  let llmId = ServerCatalog.llmIdForFile[llmFile],
                  let req = serverRequest(path: "/v1/models/select", method: "POST",
                                           jsonBody: ["whisper": whisperId, "llm": llmId]) else {
                await MainActor.run { self.serverOpNote = "Server not configured" }
                return
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    await MainActor.run { self.serverOpNote = "Server rejected selection" }
                    return
                }
                let note = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["note"] as? String ?? "switched"
                await MainActor.run {
                    self.serverOpNote = "Models switched (\(note)). Missing weights download on first use."
                    Task {
                        await self.fetchServerModels()
                        await self.refreshServerHealth()
                    }
                }
            } catch {
                await MainActor.run { self.serverOpNote = "Selection failed: server unreachable?" }
            }
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
                return ServerModelInfo(id: id, kind: kind, description: description,
                                       filename: filename, approxBytes: d["approxBytes"] as? Int,
                                       downloaded: downloaded, selected: selected)
            }
            await MainActor.run { self.serverModels = models }
        } catch { /* server not up yet */ }
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
                        self.serverOpNote = "Custom prompt saved — used from the next cleanup"
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
        let probe = ServerTranscriptionBackend(config: serverConfig)
        let health = await probe.serverHealth()
        await MainActor.run {
            self.serverHealth = health
            if self.backendPreference == .omilServer {
                self.assetState = health
            }
        }
    }

    /// Qwen cleanup post-pass over the finalized raw transcript. The local
    /// deterministic engine always runs first (journal + fallback); the server
    /// result replaces the delivered text only on success. On server failure
    /// the LOCAL cleaned text is kept — never raw speech.
    func serverClean(rawText: String, localFallback: String) async -> (text: String, note: String) {
        guard serverCleanupEnabled, cleanupMode == .clean else {
            return (localFallback, "local rules (server cleanup off or verbatim mode)")
        }
        let client = ServerCleanupClient(config: serverConfig, dictionary: dictionary)
        do {
            let r = try await client.clean(text: rawText, mode: cleanupMode)
            let note = "Qwen cleanup via server: \(r.acceptedEdits.count) edits, \(r.abstentions.count) abstentions (\(r.rulesVersion))"
            return (r.text.isEmpty ? localFallback : r.text, note)
        } catch {
            return (localFallback, "Server cleanup unavailable (\(error)); used local rules")
        }
    }

    private func appleAssetState() async -> String? {
        if #available(macOS 26, *) {
            let b = AppleSpeechBackend()
            switch await b.currentAssetState() {
            case .ready: return "Ready"
            case .downloading: return "Downloading system assets…"
            case .notInstalled: return "System assets not installed"
            case .unavailable(let r): return r
            }
        }
        return nil
    }

    /// Explicit system-asset download (also runs automatically at session start).
    func downloadAssets() {
        assetState = "Downloading system assets…"
        Task {
            if #available(macOS 26, *) {
                let b = AppleSpeechBackend()
                do {
                    try await b.prepare()
                    await MainActor.run { self.assetState = "Ready" }
                } catch {
                    await MainActor.run { self.assetState = "Download failed: \(error)" }
                }
            } else {
                await MainActor.run { self.assetState = "Ready (no download)" }
            }
            await self.refreshBackendStatus()
        }
    }

    func makeBackend() -> (any TranscriptionBackend)? {
        let resolved = selector.resolve(status: status, preference: backendPreference)
        switch resolved {
        case .omilServer:
            return ServerTranscriptionBackend(config: serverConfig)
        case .appleSpeech:
            if #available(macOS 26, *) { return AppleSpeechBackend() }
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

    func toggle() {
        NSLog("Omil: toggle pressed, phase=%@", phase.rawValue)
        switch phase {
        case .idle, .ready, .failed: start()
        case .recording: stop()
        case .preparing, .processing: break
        }
    }

    func start() {
        NSLog("Omil: start pressed, phase=%@", phase.rawValue)
        guard phase == .idle || phase == .ready || phase == .failed else { return }
        refreshMicPermission()
        guard micPermission != .denied else {
            phase = .failed
            statusMessage = "Microphone access denied. Grant it in Settings → Permissions, then try again."
            return
        }
        if micPermission == .unknown {
            // First run: prompt, then auto-start on grant.
            phase = .preparing
            statusMessage = "Requesting microphone access…"
            Task {
                let granted = await AudioCapture.requestPermission()
                await MainActor.run {
                    self.micPermission = granted ? .granted : .denied
                    if granted {
                        self.phase = .idle
                        self.start()
                    } else {
                        self.phase = .failed
                        self.statusMessage = "Microphone access denied. Grant it in Settings → Permissions."
                    }
                }
            }
            return
        }
        guard let backend = makeBackend() else {
            phase = .failed
            statusMessage = "No on-device speech backend. See Settings → General → Download system assets."
            return
        }
        // Capture the intended destination + selection first.
        let axOk = ax.captureTarget()
        precondition = ax.capturePrecondition()
        sessionSeq += 1
        let session = DictationSession(mode: cleanupMode, dictionary: dictionary)
        self.session = session
        self.backend = backend
        phase = .preparing
        statusMessage = axOk ? "Preparing…" : "Preparing… (no text field — result will be kept for copy)"
        draftText = ""
        Task {
            do {
                try await session.start(backend: backend)
            } catch {
                await MainActor.run {
                    self.phase = .failed
                    self.statusMessage = "Could not start: \(error)"
                }
                return
            }
            await MainActor.run { self.phase = .recording; self.statusMessage = "Recording — release to finalize" }
            self.streamEvents(session: session)
            self.startCapture(backend: backend)
        }
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
                        self.lastDiff = DiffUtil.diff(raw: self.lastRaw, cleaned: view.text)
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
        // Negotiate capture format from the backend where possible.
        var rate: Double? = 16_000
        var channels: Int? = 1
        if #available(macOS 26, *), let apple = backend as? AppleSpeechBackend {
            Task {
                if let fmt = await apple.audioFormat() {
                    rate = fmt.sampleRate
                    channels = Int(fmt.channelCount)
                }
            }
        }
        do {
            let captureBackend = backend
            try capture.start(targetSampleRate: rate, targetChannels: channels) { chunk in
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
        Task {
            if let result = await session.stop() {
                await deliver(result: result)
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
        Task {
            await session?.cancel()
            await MainActor.run {
                self.phase = .idle
                self.draftText = ""
                self.statusMessage = "Cancelled — nothing inserted"
            }
        }
    }

    // MARK: Delivery

    private func deliver(result: SessionResult) async {
        guard let committed = await session?.commitForDelivery() else {
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
                self.statusMessage = "Empty result — nothing inserted"
            }
            return
        } else {
            let cleaned = await serverClean(rawText: committed.rawSnapshot.rawText,
                                            localFallback: committed.cleaned.text)
            text = cleaned.text
            note = cleaned.note
        }
        serverNote = note
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
                ? "Pasted via clipboard…"
                : "Copied — press ⌘V to paste (result kept below)",
            receipt: receipt, result: committed)
    }

    private func finishDelivery(text: String, method: String, receipt: InsertionReceipt, result: SessionResult) {
        lastReceipt = receipt
        lastDeliveryMethod = method
        lastCleaned = text
        phase = .ready
        statusMessage = method
        guard historyEnabled else { return }
        let entry = HistoryEntry(raw: result.rawSnapshot.rawText, cleaned: text, backend: result.backend.displayName, duration: result.duration)
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
            statusMessage = "Destination still unverifiable — result kept. Copy it manually."
        }
    }

    func undoLast() {
        guard let receipt = lastReceipt else { return }
        if ax.undo(receipt: receipt) {
            statusMessage = "Undone (only Omil's insertion was reversed)"
        } else {
            statusMessage = "Undo refused — the field changed after insertion"
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
            statusMessage = "Copied — press ⌘V to paste (needs Accessibility for auto-paste)"
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
        - backend pref: \(backendPreference.rawValue) — \(backendDescription)
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

    var dictionaryEntries: [String: String] { dictionary.entries }
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
}
