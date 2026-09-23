import AppKit
import CoreGraphics
import OmilCore

// MARK: - ClipboardInserter
//
// Explicit copy/paste recovery when AX insertion is unavailable or fails.
// Preserves prior contents, restores only while Omil still owns the write,
// and never overwrites a newer user copy.

final class ClipboardInserter: @unchecked Sendable {
    private var ownership = ClipboardOwnership()
    private let lock = NSLock()
    private let pasteboard: NSPasteboard

    struct PreparedPaste: Sendable {
        var previousItems: [[String: Data]]
    }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Copy `text` to the clipboard, remembering prior contents.
    /// Returns nil if any existing representation cannot be saved intact.
    func prepare(text: String) -> PreparedPaste? {
        let pb = pasteboard
        lock.lock(); defer { lock.unlock() }
        var previousItems: [[String: Data]] = []
        if pb.types?.isEmpty == false && pb.pasteboardItems == nil { return nil }
        for item in pb.pasteboardItems ?? [] {
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations[type.rawValue] = data
            }
            previousItems.append(representations)
        }
        pb.declareTypes([.string], owner: nil)
        guard pb.setString(text, forType: .string) else {
            pb.clearContents()
            _ = Self.write(previousItems, to: pb)
            return nil
        }
        let owned = pb.changeCount
        ownership.recordWrite(changeCount: owned, text: text)
        return PreparedPaste(previousItems: previousItems)
    }

    /// Simulate Cmd+V into the frontmost app.
    @discardableResult
    func paste() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // v
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        guard let keyDown, let keyUp else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Restore prior clipboard contents, but only while Omil still owns the
    /// write (same change count + same content). Returns true when restored.
    @discardableResult
    func restoreIfOwned(prepared: PreparedPaste) -> Bool {
        Thread.sleep(forTimeInterval: 0.4) // host paste-consumption window (see docs)
        let pb = pasteboard
        lock.lock(); defer { lock.unlock() }
        let current = pb.string(forType: .string)
        guard ownership.shouldRestore(currentChangeCount: pb.changeCount, currentContent: current) else {
            return false // user copied after Omil; never overwrite
        }
        pb.clearContents()
        guard Self.write(prepared.previousItems, to: pb) else { return false }
        ownership = ClipboardOwnership()
        return true
    }

    private static func write(_ snapshots: [[String: Data]], to pasteboard: NSPasteboard) -> Bool {
        if snapshots.isEmpty { return true }
        var items: [NSPasteboardItem] = []
        for representations in snapshots {
            let item = NSPasteboardItem()
            for (type, data) in representations {
                guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else { return false }
            }
            items.append(item)
        }
        return pasteboard.writeObjects(items)
    }

    func currentOwnership() -> ClipboardOwnership {
        lock.lock(); defer { lock.unlock() }
        return ownership
    }
}


/// Automatic clipboard writes are strictly opt-in. Explicit Copy actions are separate.
@MainActor
enum TranscriptClipboard {
    @discardableResult
    static func copyIfEnabled(_ text: String, enabled: Bool = false, to pasteboard: NSPasteboard = .general) -> Bool {
        guard enabled, !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
