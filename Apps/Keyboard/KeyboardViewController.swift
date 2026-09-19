import UIKit
import SwiftUI
import OmilCore

// MARK: - Omil keyboard
//
// Lightweight coordinator: it NEVER records audio or loads models (no mic
// access in extensions). It requests sessions, inserts completed results via
// textDocumentProxy, and acknowledges exactly once. Shared App Group storage
// cannot wake the containing app, so unavailable/expired sessions surface an
// explicit reactivation state instead of failing silently.

@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private var hosting: UIHostingController<KeyboardView>?
    private let store = ResultStore(appGroupId: SessionCoordinatorAppGroup.id)
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        let kbView = KeyboardView(
            hasFullAccess: hasFullAccess,
            onInsert: { [weak self] in self?.insertPending() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            onRefresh: { [weak self] in self?.refresh() }
        )
        let hc = UIHostingController(rootView: kbView)
        hc.view.backgroundColor = .clear
        addChild(hc)
        view.translatesAutoresizingMaskIntoConstraints = false
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hc.didMove(toParent: self)
        self.hosting = hc
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        // Poll for completed results while visible (the app cannot push to us).
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    var currentState: KeyboardState {
        guard hasFullAccess else { return .needsFullAccess }
        if let pending = store.pendingResult() {
            return .resultReady(text: pending.cleanedText ?? "", sessionId: pending.sessionId.rawValue)
        }
        return .noSession
    }

    func refresh() {
        hosting?.rootView = KeyboardView(
            hasFullAccess: hasFullAccess,
            state: currentState,
            onInsert: { [weak self] in self?.insertPending() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            onRefresh: { [weak self] in self?.refresh() }
        )
    }

    /// Insert the pending result once, then acknowledge. Duplicate taps are
    /// harmless: acknowledge() returns false the second time.
    func insertPending() {
        guard hasFullAccess, let pending = store.pendingResult(), let text = pending.cleanedText else {
            refresh()
            return
        }
        textDocumentProxy.insertText(text)
        if store.acknowledge(pending.sessionId) {
            // First (and only) acknowledgement.
        }
        refresh()
    }
}

enum SessionCoordinatorAppGroup {
    static let id = "group.com.omil.shared"
}

enum KeyboardState: Equatable {
    case noSession
    case needsFullAccess
    case resultReady(text: String, sessionId: String)
}

struct KeyboardView: View {
    var hasFullAccess: Bool = false
    var state: KeyboardState = .noSession
    var onInsert: () -> Void = {}
    var onNextKeyboard: () -> Void = {}
    var onRefresh: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onNextKeyboard) {
                Image(systemName: "globe")
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel("Next keyboard")

            switch state {
            case .needsFullAccess:
                Text("Omil: enable Full Access in Settings → Keyboard to insert dictations.")
                    .font(.caption)
                    .lineLimit(2)
            case .noSession:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Omil Dictation")
                        .font(.caption.bold())
                    Text("Record in the Omil app, then tap Insert here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.bordered)
            case .resultReady(let text, _):
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.caption)
                        .lineLimit(2)
                }
                Spacer()
                Button("Insert", action: onInsert)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Inserts the dictated text at the cursor exactly once")
            }
        }
        .padding(8)
    }
}
