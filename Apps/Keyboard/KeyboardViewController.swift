import UIKit
import SwiftUI
import OmilCore

// MARK: - Omil keyboard
//
// A dictation key for any app. Extensions have no microphone, so the Omil app
// records: the first tap opens it (omil://dictate) and it starts a mic session
// that keeps running in the background. While that session is live the
// keyboard starts and stops dictations through the KeyboardLink without
// leaving the current app, and inserts the result as soon as it's ready.
// Results are acknowledged in the ResultStore, so each is inserted once.
// After inserting, the keyboard can switch back to the user's usual keyboard,
// so typing in any language stays on the system keyboard.

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private let store = ResultStore(appGroupId: KeyboardLink.appGroupId)
    private let link = LinkChannel()
    private let model = KeyboardModel()
    private var timer: Timer?
    private var ticks = 0
    private var observer: DarwinObserver?
    private var heightConstraint: NSLayoutConstraint?
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    /// When the keyboard asked the app to start, or opened it.
    private var startRequested: Date?
    private var openRequested: Date?
    private var returnTask: Task<Void, Never>?

    override func loadView() {
        // A custom input view so key taps can play the system input click.
        view = ClickableInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = KeyboardView(
            model: model,
            globe: { [weak self] in GlobeKey(controller: self) },
            actions: KeyboardActions(
                mic: { [weak self] in self?.micTapped() },
                done: { [weak self] in self?.send(.stop) },
                cancel: { [weak self] in self?.send(.cancel) },
                endSession: { [weak self] in self?.send(.end) },
                insertPending: { [weak self] in self?.insertPending(automatic: false) },
                undo: { [weak self] in self?.undoInsert() },
                openApp: { [weak self] in self?.open(KeyboardLink.pairURL) },
                openSettings: { [weak self] in self?.open(URL(string: "app-settings:")!) },
                punctuation: { [weak self] mark in self?.type(mark) },
                space: { [weak self] in self?.type(" ") },
                delete: { [weak self] in self?.deleteBackward() },
                newline: { [weak self] in self?.type("\n") }
            )
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh(full: true)
        observer = DarwinObserver(KeyboardLink.stateChanged) { [weak self] in
            MainActor.assumeIsolated { self?.refresh(full: true) }
        }
        timer?.invalidate()
        // Fast enough for a smooth waveform; the result store is read less often.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                // Fast only while something is moving; otherwise twice a second.
                let fast = self.model.isRecording || self.startRequested != nil || self.openRequested != nil
                    || self.model.state == .starting || self.model.state == .processing
                guard fast || self.ticks % 5 == 0 else { return }
                self.refresh(full: self.ticks % 5 == 0)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
        observer = nil
        returnTask?.cancel()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        heightConstraint?.constant = keyboardHeight
        model.showsGlobe = needsInputModeSwitchKey
        model.compact = traitCollection.userInterfaceIdiom == .phone && traitCollection.verticalSizeClass == .compact
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        model.loadAccent(dark: traitCollection.userInterfaceStyle == .dark)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.returnTitle = Self.returnTitle(for: textDocumentProxy.returnKeyType)
    }

    /// Standard system keyboard heights.
    private var keyboardHeight: CGFloat {
        if traitCollection.userInterfaceIdiom == .pad { return 264 }
        return traitCollection.verticalSizeClass == .compact ? 162 : 216
    }

    // MARK: State

    /// Reads the app's state and decides what the keyboard shows. `full` also
    /// checks the result store, which is slower.
    func refresh(full: Bool) {
        model.showsGlobe = needsInputModeSwitchKey
        model.returnTitle = Self.returnTitle(for: textDocumentProxy.returnKeyType)
        #if DEBUG
        // Visual QA without Full Access, e.g.
        // `defaults write sh.arpan.omil.ios.keyboard omil.debug.preview recording`
        if let preview = UserDefaults.standard.string(forKey: "omil.debug.preview") {
            model.preview(preview)
            return
        }
        #endif
        guard hasFullAccess else {
            model.update(.needsFullAccess)
            return
        }
        if full { model.loadAccent(dark: traitCollection.userInterfaceStyle == .dark) }
        // Let the confirmation finish before showing the next state.
        if case .inserted = model.state { return }

        let setup = link?.readSetup()
        model.macName = setup?.macName
        model.returnAfterInsert = setup?.returnAfterInsert ?? true
        if setup?.paired == false {
            model.update(.needsPairing)
            return
        }

        if full, let pending = store.pendingResult(), let text = pending.cleanedText {
            if pending.autoInsert == true, Date().timeIntervalSince(pending.updatedAt) < 120 {
                insertPending(automatic: true)
                return
            }
            model.pendingText = text
        } else if full {
            model.pendingText = nil
        }

        let state = link?.readState() ?? LinkState()
        let live = state.isLive()
        model.sessionEnds = live ? state.sessionEnds : nil

        if live, state.phase == .recording {
            startRequested = nil
            model.update(.recording(started: state.recordingStarted))
            model.push(level: state.level)
            if model.draft != state.draft { model.draft = state.draft }
            return
        }
        if live, state.phase == .starting {
            model.update(.starting)
            return
        }
        if live, state.phase == .processing {
            startRequested = nil
            model.update(.processing)
            return
        }

        // Waiting on the app: if it doesn't answer, it was suspended; open it.
        if let asked = startRequested {
            if Date().timeIntervalSince(asked) > 1.5 {
                startRequested = nil
                openApp()
            }
            return
        }
        if let opened = openRequested {
            if Date().timeIntervalSince(opened) < 3 { return }
            openRequested = nil
            model.update(.failed("Couldn't open Omil. Open the Omil app, then come back."))
            return
        }
        if live, state.phase == .failed {
            model.update(.failed(state.message ?? "Dictation didn't start. Try again."))
            return
        }
        if case .failed = model.state, !live { return }
        model.update(.idle)
    }

    // MARK: Actions

    private func micTapped() {
        haptics.impactOccurred()
        if case .failed = model.state { model.update(.idle) }
        let state = link?.readState()
        if let state, state.isLive(), state.phase == .ready || state.phase == .failed {
            startRequested = .now
            model.update(.starting)
            link?.send(LinkCommand(.start))
        } else {
            openApp()
        }
    }

    private func send(_ kind: LinkCommand.Kind) {
        haptics.impactOccurred()
        link?.send(LinkCommand(kind))
        switch kind {
        case .stop: model.update(.processing)
        case .cancel: model.update(.idle)
        case .end: model.sessionEnds = nil
        case .start: break
        }
    }

    private func openApp() {
        openRequested = .now
        model.update(.opening)
        open(KeyboardLink.dictateURL)
    }

    /// Keyboards can't call UIApplication.open directly; the host app's
    /// UIApplication sits at the end of the responder chain.
    private func open(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: UIApplication.self), current.responds(to: selector),
               let method = current.method(for: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                unsafeBitCast(method, to: Open.self)(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }

    /// Inserts the latest finished dictation once, with a space before it
    /// when it follows a word.
    private func insertPending(automatic: Bool) {
        guard hasFullAccess, let pending = store.pendingResult(), var text = pending.cleanedText else {
            refresh(full: true)
            return
        }
        guard store.acknowledge(pending.sessionId) else { return }
        if let before = textDocumentProxy.documentContextBeforeInput?.last, !before.isWhitespace,
           let first = text.first, !first.isPunctuation {
            text = " " + text
        }
        textDocumentProxy.insertText(text)
        UIDevice.current.playInputClick()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        model.pendingText = nil
        model.update(.inserted(count: text.count))
        returnTask?.cancel()
        returnTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(automatic ? 1.2 : 0.9))
            guard let self, !Task.isCancelled, case .inserted = self.model.state else { return }
            if self.model.returnAfterInsert {
                self.advanceToNextInputMode()
            }
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            self.model.update(.idle)
            self.refresh(full: true)
        }
    }

    private func undoInsert() {
        guard case .inserted(let count) = model.state else { return }
        returnTask?.cancel()
        for _ in 0..<count { textDocumentProxy.deleteBackward() }
        haptics.impactOccurred()
        model.update(.idle)
        refresh(full: true)
    }

    private func type(_ text: String) {
        UIDevice.current.playInputClick()
        textDocumentProxy.insertText(text)
    }

    private func deleteBackward() {
        UIDevice.current.playInputClick()
        textDocumentProxy.deleteBackward()
    }

    private static func returnTitle(for type: UIReturnKeyType?) -> String {
        switch type {
        case .go: return "go"
        case .google, .yahoo, .search: return "search"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .send: return "send"
        case .done: return "done"
        case .continue: return "continue"
        default: return "return"
        }
    }
}

/// Input view that opts in to the system keyboard click sound.
private final class ClickableInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

// MARK: - Model

enum KeyboardState: Equatable {
    case needsFullAccess
    case needsPairing
    case idle
    /// Opening the Omil app to start the mic session.
    case opening
    case starting
    case recording(started: Date?)
    case processing
    case inserted(count: Int)
    case failed(String)
}

struct KeyboardActions {
    var mic: () -> Void
    var done: () -> Void
    var cancel: () -> Void
    var endSession: () -> Void
    var insertPending: () -> Void
    var undo: () -> Void
    var openApp: () -> Void
    var openSettings: () -> Void
    var punctuation: (String) -> Void
    var space: () -> Void
    var delete: () -> Void
    var newline: () -> Void
}

@MainActor
final class KeyboardModel: ObservableObject {
    static let barCount = 36

    @Published private(set) var state: KeyboardState = .idle
    @Published var showsGlobe = true
    @Published var returnTitle = "return"
    @Published var macName: String?
    @Published var sessionEnds: Date?
    /// A dictation finished in the app, waiting for Insert.
    @Published var pendingText: String?
    /// Live words while listening.
    @Published var draft = ""
    /// Landscape iPhone: shorter rows.
    @Published var compact = false
    @Published private(set) var levels = [Double](repeating: 0, count: barCount)
    @Published private(set) var accent: Color = .accentColor
    @Published private(set) var accentInk: Color = .white
    var returnAfterInsert = true

    func update(_ newState: KeyboardState) {
        guard newState != state else { return }
        if case .recording = newState, !isRecording {
            levels = [Double](repeating: 0, count: Self.barCount)
            draft = ""
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { state = newState }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func push(level: Double) {
        levels.removeFirst()
        levels.append(level)
    }

    /// The app shares its theme accent through the app group (needs Full Access).
    func loadAccent(dark: Bool) {
        guard let defaults = UserDefaults(suiteName: KeyboardLink.appGroupId) else { return }
        let suffix = dark ? "dark" : "light"
        guard let signal = defaults.object(forKey: "omil.keyboard.accent.\(suffix)") as? Int,
              let ink = defaults.object(forKey: "omil.keyboard.accentInk.\(suffix)") as? Int else { return }
        let newAccent = Color(rgb: signal)
        let newInk = Color(rgb: ink)
        if newAccent != accent { accent = newAccent }
        if newInk != accentInk { accentInk = newInk }
    }

    #if DEBUG
    func preview(_ name: String) {
        macName = "Studio Mac"
        switch name {
        case "access": update(.needsFullAccess)
        case "pair": update(.needsPairing)
        case "opening": update(.opening)
        case "recording":
            update(.recording(started: Date().addingTimeInterval(-7)))
            push(level: Double.random(in: 0.1...0.9))
            draft = "Running ten minutes late, start without"
        case "processing", "inserted":
            update(name == "processing" ? .processing : .inserted(count: 0))
        case "failed": update(.failed("Couldn't reach your Mac. Make sure Omil is open on it."))
        case "live":
            sessionEnds = Date().addingTimeInterval(272)
            update(.idle)
        case "":
            update(.idle)
        default:
            pendingText = name
            update(.idle)
        }
    }
    #endif
}

private extension Color {
    init(rgb: Int) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: - Views

private enum KeyColors {
    static let letter = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.28) : .white })
    static let function = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.14) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) })
    static let recording = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0.42, blue: 0.38, alpha: 1) : UIColor(red: 0.92, green: 0.23, blue: 0.20, alpha: 1) })
    static let success = Color(UIColor.systemGreen)
    /// The hairline under each key on the system keyboard.
    static let shadow = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0, alpha: 0.35) : UIColor(white: 0, alpha: 0.3) })
}


/// Modeled on the Wispr Flow keyboard: a toolbar with one big dictation pill
/// (✕ and ✓ on either side while listening) above a compact keypad of
/// numbers and punctuation, then space and return. Full typing stays on the
/// user's own keyboard, one globe tap away.
struct KeyboardView<Globe: View>: View {
    @ObservedObject var model: KeyboardModel
    @ViewBuilder let globe: () -> Globe
    let actions: KeyboardActions

    private var rowHeight: CGFloat { model.compact ? 34 : 42 }

    var body: some View {
        switch model.state {
        case .needsFullAccess:
            Message(symbol: "lock.open.fill",
                    title: "Allow Full Access to dictate",
                    detail: "Settings › Omil › Keyboards › Allow Full Access lets this keyboard talk to the Omil app.",
                    button: "Open Settings", action: actions.openSettings)
        case .needsPairing:
            Message(symbol: "laptopcomputer.and.iphone",
                    title: "Pair Omil with your Mac",
                    detail: "Your Mac does the speech recognition, free and private.",
                    button: "Open Omil", action: actions.openApp)
        default:
            VStack(spacing: 6) {
                DictationBar(model: model, actions: actions)
                    .frame(height: model.compact ? 40 : 50)
                    .padding(.bottom, model.compact ? 0 : 2)
                keyRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
                HStack(spacing: 6) {
                    keyRow([".", ",", "?", "!", "'", "-", "@"])
                    RepeatingKey(action: actions.delete) {
                        Image(systemName: "delete.left")
                            .font(.title3)
                    }
                    .frame(width: 56)
                    .accessibilityLabel("Delete")
                }
                .frame(height: rowHeight)
                spaceRow
            }
            .padding(.horizontal, 3)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }

    private func keyRow(_ keys: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Button { actions.punctuation(key) } label: {
                    Text(key).font(.title3)
                }
                .buttonStyle(KeyStyle(fill: KeyColors.letter))
            }
        }
        .frame(height: rowHeight)
    }

    private var spaceRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobe {
                globe()
                    .frame(width: 46)
                    .background(KeyColors.function, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Button(action: actions.space) {
                Text("space").font(.body)
            }
            .buttonStyle(KeyStyle(fill: KeyColors.letter))
            .accessibilityLabel("Space")
            Button(action: actions.newline) {
                Text(model.returnTitle).font(.body)
            }
            .buttonStyle(KeyStyle(fill: KeyColors.function))
            .frame(width: 92)
        }
        .frame(height: rowHeight)
    }
}

/// The toolbar: a round button on each side and the dictation pill between.
/// Idle: [menu] [🎙 Dictate] [insert last]. Listening: [✕] [waveform 0:07] [✓].
private struct DictationBar: View {
    @ObservedObject var model: KeyboardModel
    let actions: KeyboardActions

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 44)
            pill
            trailing
                .frame(width: 44)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Sides

    @ViewBuilder
    private var leading: some View {
        switch model.state {
        case .recording:
            CircleKey(symbol: "xmark", fill: KeyColors.function, ink: .primary, label: "Cancel", action: actions.cancel)
        case .inserted:
            CircleKey(symbol: "arrow.uturn.backward", fill: KeyColors.function, ink: .primary, label: "Undo", action: actions.undo)
        case .idle where model.sessionEnds != nil:
            CircleKey(symbol: "power", fill: KeyColors.function, ink: .primary, label: "Turn off the mic", action: actions.endSession)
        default:
            CircleKey(symbol: "gearshape", fill: KeyColors.function, ink: .primary, label: "Open Omil", action: actions.openApp)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.state {
        case .recording:
            CircleKey(symbol: "checkmark", fill: model.accent, ink: model.accentInk, label: "Done", action: actions.done)
        case .idle where model.pendingText != nil:
            CircleKey(symbol: "text.insert", fill: KeyColors.letter, ink: .primary,
                      label: "Insert your last dictation", action: actions.insertPending)
        default:
            Color.clear
        }
    }

    // MARK: Pill

    private var pill: some View {
        Button(action: pillAction) {
            pillContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .background(pillFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .disabled(pillDisabled)
        .accessibilityLabel(pillLabel)
        .accessibilityHint(model.isRecording ? "Stops listening and inserts your words."
                           : model.sessionEnds == nil ? "Opens Omil for a moment to turn on the microphone." : "")
    }

    private func pillAction() {
        if model.isRecording { actions.done() } else { actions.mic() }
    }

    private var pillDisabled: Bool {
        switch model.state {
        case .opening, .starting, .processing, .inserted: return true
        default: return false
        }
    }

    private var pillFill: Color {
        switch model.state {
        case .recording: return KeyColors.recording.opacity(0.14)
        case .opening, .starting, .processing, .inserted: return KeyColors.letter
        default: return model.accent
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        switch model.state {
        case .recording(let started):
            HStack(spacing: 10) {
                KeyboardWaveform(levels: model.levels)
                if let started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                        Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(KeyColors.recording)
                    }
                }
            }
        case .opening, .starting, .processing:
            HStack(spacing: 8) {
                ProgressView()
                Text(model.state == .processing ? "Transcribing…" : model.state == .opening ? "Opening Omil…" : "Starting…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        case .inserted:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, KeyColors.success)
                Text("Inserted")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(model.accentInk)
        default:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                Text(model.sessionEnds == nil ? "Start Omil" : "Dictate")
                if let ends = model.sessionEnds {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.remaining(ends, context.date))
                            .monospacedDigit()
                            .opacity(0.6)
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(model.accentInk)
        }
    }

    private var pillLabel: String {
        switch model.state {
        case .recording: return "Done"
        case .processing: return "Transcribing"
        case .opening, .starting: return "Starting"
        case .inserted: return "Inserted"
        default: return model.sessionEnds == nil ? "Start Omil" : "Dictate"
        }
    }

    static func remaining(_ end: Date, _ now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

private struct CircleKey: View {
    let symbol: String
    let fill: Color
    let ink: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct KeyboardWaveform: View {
    let levels: [Double]

    var body: some View {
        // Only as many of the latest levels as fit, so the pill never overflows.
        GeometryReader { proxy in
            let shown = Array(levels.suffix(max(0, Int((proxy.size.width + 2.5) / 5.5))))
            HStack(spacing: 2.5) {
                ForEach(shown.indices, id: \.self) { index in
                    Capsule()
                        .fill(KeyColors.recording.opacity(0.35 + 0.65 * shown[index]))
                        .frame(width: 3, height: 4 + shown[index] * 26)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 32)
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

private struct Message: View {
    let symbol: String
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button(button, action: action)
                .font(.footnote.weight(.semibold))
                .buttonStyle(KeyStyle(fill: KeyColors.letter, cornerRadius: 14, fullWidth: false))
                .frame(height: 28)
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A flat key: its fill brightens while pressed, like system keys.
private struct KeyStyle: ButtonStyle {
    let fill: Color
    var cornerRadius: CGFloat = 8
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, fullWidth ? 0 : 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, maxHeight: .infinity)
            .background(configuration.isPressed ? KeyColors.function : fill,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: KeyColors.shadow, radius: 0, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Fires once on touch down, then repeats while held, like the delete key.
private struct RepeatingKey<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label()
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(repeatTask == nil ? KeyColors.function : KeyColors.letter,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard repeatTask == nil else { return }
                        action()
                        repeatTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(450))
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(for: .milliseconds(90))
                            }
                        }
                    }
                    .onEnded { _ in
                        repeatTask?.cancel()
                        repeatTask = nil
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// The globe key. It must be a UIKit control so the system can show the
/// keyboard list on touch and hold (handleInputModeList).
private struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(textStyle: .title3)
        button.setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "Next Keyboard"
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}
