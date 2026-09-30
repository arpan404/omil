import UIKit
import SwiftUI
import OmilCore

// MARK: - Omil keyboard
//
// Inserts dictations finished in the Omil app. The keyboard never records
// audio (extensions have no microphone access). While visible it polls the
// shared ResultStore, because the app can't wake it; it inserts a pending
// result through textDocumentProxy and acknowledges it so each result is
// inserted exactly once.

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private let store = ResultStore(appGroupId: SessionCoordinatorAppGroup.id)
    private let model = KeyboardModel()
    private var timer: Timer?
    private var heightConstraint: NSLayoutConstraint?
    private let haptics = UIImpactFeedbackGenerator(style: .light)

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
                insert: { [weak self] in self?.insertPending() },
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
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        heightConstraint?.constant = keyboardHeight
        model.showsGlobe = needsInputModeSwitchKey
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

    func refresh() {
        model.showsGlobe = needsInputModeSwitchKey
        model.returnTitle = Self.returnTitle(for: textDocumentProxy.returnKeyType)
        #if DEBUG
        // Visual QA without Full Access:
        // `defaults write sh.arpan.omil.ios.keyboard omil.debug.preview "text"`
        if let preview = UserDefaults.standard.string(forKey: "omil.debug.preview") {
            model.update(preview.isEmpty ? .empty : .ready(text: preview))
            return
        }
        #endif
        guard hasFullAccess else {
            model.update(.needsFullAccess)
            return
        }
        model.loadAccent(dark: traitCollection.userInterfaceStyle == .dark)
        // Let the "Inserted" confirmation finish before showing the next state.
        guard model.state != .inserted else { return }
        if let pending = store.pendingResult(), let text = pending.cleanedText {
            model.update(.ready(text: text))
        } else {
            model.update(.empty)
        }
    }

    /// Inserts the pending result, then acknowledges it. A second tap finds no
    /// pending result, so nothing is inserted twice.
    func insertPending() {
        guard hasFullAccess, let pending = store.pendingResult(), let text = pending.cleanedText else {
            refresh()
            return
        }
        textDocumentProxy.insertText(text)
        _ = store.acknowledge(pending.sessionId)
        UIDevice.current.playInputClick()
        haptics.impactOccurred()
        model.update(.inserted)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self, self.model.state == .inserted else { return }
            self.model.update(.empty)
            self.refresh()
        }
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

enum SessionCoordinatorAppGroup {
    static let id = "group.sh.arpan.omil.shared"
}

/// Input view that opts in to the system keyboard click sound.
private final class ClickableInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

// MARK: - Model

enum KeyboardState: Equatable {
    case needsFullAccess
    case empty
    case ready(text: String)
    case inserted
}

struct KeyboardActions {
    var insert: () -> Void
    var space: () -> Void
    var delete: () -> Void
    var newline: () -> Void
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var state: KeyboardState = .empty
    @Published var showsGlobe = true
    @Published var returnTitle = "return"
    @Published private(set) var accent: Color = .accentColor
    @Published private(set) var accentInk: Color = .white

    func update(_ newState: KeyboardState) {
        guard newState != state else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { state = newState }
    }

    /// The app shares its theme accent through the app group (needs Full Access).
    func loadAccent(dark: Bool) {
        guard let defaults = UserDefaults(suiteName: SessionCoordinatorAppGroup.id) else { return }
        let suffix = dark ? "dark" : "light"
        guard let signal = defaults.object(forKey: "omil.keyboard.accent.\(suffix)") as? Int,
              let ink = defaults.object(forKey: "omil.keyboard.accentInk.\(suffix)") as? Int else { return }
        let newAccent = Color(rgb: signal)
        let newInk = Color(rgb: ink)
        if newAccent != accent { accent = newAccent }
        if newInk != accentInk { accentInk = newInk }
    }
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
}

struct KeyboardView<Globe: View>: View {
    @ObservedObject var model: KeyboardModel
    @ViewBuilder let globe: () -> Globe
    let actions: KeyboardActions

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                switch model.state {
                case .ready(let text):
                    InsertKey(text: text, accent: model.accent, accentInk: model.accentInk, action: actions.insert)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .empty:
                    Message(symbol: "waveform",
                            title: "Record in Omil, then insert here.",
                            detail: "Your latest dictation appears here, ready to insert.")
                        .transition(.opacity)
                case .needsFullAccess:
                    Message(symbol: "lock.open.fill",
                            title: "Allow Full Access to insert dictations.",
                            detail: "Settings › Omil › Keyboards › Allow Full Access. Omil only reads your finished dictations.")
                        .transition(.opacity)
                case .inserted:
                    Label("Inserted", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomRow
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var bottomRow: some View {
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
            RepeatingKey(action: actions.delete) {
                Image(systemName: "delete.left")
                    .font(.title3)
            }
            .frame(width: 52)
            .accessibilityLabel("Delete")
            Button(action: actions.newline) {
                Text(model.returnTitle).font(.body)
            }
            .buttonStyle(KeyStyle(fill: KeyColors.function))
            .frame(width: 92)
        }
        .frame(height: 44)
    }
}

private struct InsertKey: View {
    let text: String
    let accent: Color
    let accentInk: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ready to Insert")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Label("Insert", systemImage: "text.insert")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accentInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(accent, in: Capsule())
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(KeyStyle(fill: KeyColors.letter, cornerRadius: 12))
        .accessibilityLabel("Insert: \(text)")
        .accessibilityHint("Inserts your dictation at the cursor.")
    }
}

private struct Message: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A flat key: its fill brightens while pressed, like system keys.
private struct KeyStyle: ButtonStyle {
    let fill: Color
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(configuration.isPressed ? KeyColors.function : fill,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
