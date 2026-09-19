import AppKit
import OmilCore

// MARK: - HotkeyManager
//
// Global push-to-talk (hold Right Option by default) and a toggle shortcut
// (Ctrl+Option+O). Uses global event monitors (needs Input Monitoring for
// background use); all recording controls are also clickable/keyboard-
// navigable in the menu bar UI, so dictation never depends on the hotkey.

@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published var pushToTalkKeyCode: Int = 61 // Right Option
    @Published var toggleEnabled = true

    var onPushStart: (() -> Void)?
    var onPushStop: (() -> Void)?
    var onToggle: (() -> Void)?

    private var monitors: [Any] = []
    private var pushActive = false
    private let defaults = UserDefaults.standard

    private init() {
        pushToTalkKeyCode = defaults.integer(forKey: "omil.pttKeyCode").nonzero ?? 61
    }

    func start() {
        stop()
        // Modifier-key push-to-talk via flagsChanged. Primitives are extracted
        // synchronously; only they cross into the MainActor hop (NSEvent is
        // not Sendable).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            let code = e.keyCode
            let flags = e.modifierFlags
            Task { @MainActor in self?.handleFlags(keyCode: code, flags: flags) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            let code = e.keyCode
            let flags = e.modifierFlags
            Task { @MainActor in self?.handleFlags(keyCode: code, flags: flags) }
            return e
        }) { monitors.append(m) }
        // Toggle shortcut: Ctrl+Option+O.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            let flags = e.modifierFlags
            let chars = e.charactersIgnoringModifiers
            Task { @MainActor in self?.handleToggle(flags: flags, chars: chars) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            let flags = e.modifierFlags
            let chars = e.charactersIgnoringModifiers
            Task { @MainActor in self?.handleToggle(flags: flags, chars: chars) }
            return e
        }) { monitors.append(m) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        pushActive = false
    }

    private func handleFlags(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        // Right Option down/up. keyCode 61 = right option.
        if keyCode == UInt16(pushToTalkKeyCode) {
            let down = flags.contains(.option)
            if down, !pushActive {
                pushActive = true
                onPushStart?()
            } else if !down, pushActive {
                pushActive = false
                onPushStop?()
            }
        }
    }

    private func handleToggle(flags: NSEvent.ModifierFlags, chars: String?) {
        guard toggleEnabled else { return }
        if flags.contains([.control, .option]), chars?.lowercased() == "o" {
            onToggle?()
        }
    }

    func setPushToTalk(keyCode: Int) {
        pushToTalkKeyCode = keyCode
        defaults.set(keyCode, forKey: "omil.pttKeyCode")
    }

    /// Human-readable name for the configured push-to-talk modifier.
    var pushToTalkName: String {
        switch pushToTalkKeyCode {
        case 61: return "Right Option (hold)"
        case 58: return "Left Option (hold)"
        case 59: return "Left Control (hold)"
        case 62: return "Right Control (hold)"
        case 55: return "Left Command (hold)"
        case 54: return "Right Command (hold)"
        case 56: return "Left Shift (hold)"
        case 60: return "Right Shift (hold)"
        case 63: return "Fn (hold)"
        default: return "key code \(pushToTalkKeyCode) (hold)"
        }
    }
}

private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
