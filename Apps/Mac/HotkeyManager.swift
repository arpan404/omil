import AppKit
import OmilCore

/// Monitors both Omil and other apps. Global key events require Accessibility access.
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    static let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    @Published private(set) var pushToTalkKeyCode: Int
    @Published private(set) var pushToTalkModifiers: NSEvent.ModifierFlags
    @Published private(set) var pushToTalkCharacter: String
    @Published var toggleEnabled: Bool {
        didSet { defaults.set(toggleEnabled, forKey: "omil.toggleEnabled") }
    }
    var capturingShortcut = false {
        didSet {
            if capturingShortcut, pushActive {
                pushActive = false
                onPushStop?()
            }
        }
    }

    var onPushStart: (() -> Void)?
    var onPushStop: (() -> Void)?
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    var canCancel: () -> Bool = { false }

    private var monitors: [Any] = []
    private var pushActive = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pushToTalkKeyCode = defaults.object(forKey: "omil.pttKeyCode") as? Int ?? 61
        pushToTalkModifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "omil.pttModifiers")))
        pushToTalkCharacter = defaults.string(forKey: "omil.pttCharacter") ?? ""
        toggleEnabled = defaults.object(forKey: "omil.toggleEnabled") as? Bool ?? true
    }

    func start() {
        stop()
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            // AppKit delivers event monitors on the main thread.
            MainActor.assumeIsolated { _ = self?.handle(event) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }) { monitors.append(monitor) }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if pushActive { onPushStop?() }
        pushActive = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard !capturingShortcut else { return false }
        switch event.type {
        case .flagsChanged:
            handleFlags(keyCode: event.keyCode, flags: event.modifierFlags)
            return false
        case .keyDown:
            return handleKeyDown(keyCode: event.keyCode, flags: event.modifierFlags, isRepeat: event.isARepeat)
        case .keyUp:
            return handleKeyUp(keyCode: event.keyCode)
        default: return false
        }
    }

    func handleFlags(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard !capturingShortcut else { return }
        if !pushToTalkModifiers.isEmpty {
            if pushActive, !flags.contains(pushToTalkModifiers) {
                pushActive = false
                onPushStop?()
            }
            return
        }
        guard keyCode == UInt16(pushToTalkKeyCode), let flag = Self.modifierFlag(for: Int(keyCode)) else { return }
        let down = flags.contains(flag)
        if down, !pushActive {
            pushActive = true
            onPushStart?()
        } else if !down, pushActive {
            pushActive = false
            onPushStop?()
        }
    }

    @discardableResult
    func handleKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Bool {
        guard !capturingShortcut else { return false }
        if keyCode == 53, canCancel() {
            if !isRepeat {
                pushActive = false
                onCancel?()
            }
            return true
        }
        let modifiers = flags.intersection(Self.shortcutModifiers)
        if !pushToTalkModifiers.isEmpty, keyCode == UInt16(pushToTalkKeyCode), modifiers == pushToTalkModifiers {
            if !isRepeat, !pushActive {
                pushActive = true
                onPushStart?()
            }
            return true
        }
        if toggleEnabled, keyCode == 31, modifiers == [.control, .option] {
            if !isRepeat { onToggle?() }
            return true
        }
        return false
    }

    @discardableResult
    func handleKeyUp(keyCode: UInt16) -> Bool {
        guard !capturingShortcut, !pushToTalkModifiers.isEmpty,
              keyCode == UInt16(pushToTalkKeyCode), pushActive else { return false }
        pushActive = false
        onPushStop?()
        return true
    }

    @discardableResult
    func setPushToTalk(keyCode: Int, modifiers: NSEvent.ModifierFlags = [], character: String = "") -> Bool {
        let modifiers = modifiers.intersection(Self.shortcutModifiers)
        guard (modifiers.isEmpty && Self.modifierFlag(for: keyCode) != nil)
            || (!modifiers.isEmpty && Self.modifierFlag(for: keyCode) == nil && keyCode != 53) else { return false }
        // Reserve the hands-free shortcut so one press cannot start both modes.
        guard !(keyCode == 31 && modifiers == [.control, .option]) else { return false }
        if pushActive { onPushStop?() }
        pushActive = false
        pushToTalkKeyCode = keyCode
        pushToTalkModifiers = modifiers
        pushToTalkCharacter = character.uppercased()
        defaults.set(keyCode, forKey: "omil.pttKeyCode")
        defaults.set(Int(modifiers.rawValue), forKey: "omil.pttModifiers")
        defaults.set(pushToTalkCharacter, forKey: "omil.pttCharacter")
        return true
    }

    static func modifierFlag(for code: Int) -> NSEvent.ModifierFlags? {
        switch code {
        case 58, 61: return .option
        case 59, 62: return .control
        case 54, 55: return .command
        case 56, 60: return .shift
        case 63: return .function
        default: return nil
        }
    }

    var pushToTalkName: String {
        if !pushToTalkModifiers.isEmpty {
            var parts: [String] = []
            if pushToTalkModifiers.contains(.control) { parts.append("⌃") }
            if pushToTalkModifiers.contains(.option) { parts.append("⌥") }
            if pushToTalkModifiers.contains(.shift) { parts.append("⇧") }
            if pushToTalkModifiers.contains(.command) { parts.append("⌘") }
            let special = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
            parts.append(special[pushToTalkKeyCode] ?? (pushToTalkCharacter.isEmpty ? "Key \(pushToTalkKeyCode)" : pushToTalkCharacter))
            return parts.joined()
        }
        switch pushToTalkKeyCode {
        case 61: return "Right Option"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 62: return "Right Control"
        case 55: return "Left Command"
        case 54: return "Right Command"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        case 63: return "Fn"
        default: return "Choose a shortcut"
        }
    }
}
