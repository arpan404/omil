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

    struct PreparedPaste {
        var previousChangeCount: Int
        var previousString: String?
        var omilChangeCount: Int
    }

    /// Copy `text` to the clipboard, remembering prior contents.
    func prepare(text: String) -> PreparedPaste {
        let pb = NSPasteboard.general
        lock.lock(); defer { lock.unlock() }
        let prevCount = pb.changeCount
        let prevString = pb.string(forType: .string)
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        let owned = pb.changeCount
        ownership.recordWrite(changeCount: owned, text: text)
        return PreparedPaste(previousChangeCount: prevCount, previousString: prevString, omilChangeCount: owned)
    }

    /// Simulate Cmd+V into the frontmost app.
    func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // v
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Restore prior clipboard contents, but only while Omil still owns the
    /// write (same change count + same content). Returns true when restored.
    @discardableResult
    func restoreIfOwned(prepared: PreparedPaste) -> Bool {
        Thread.sleep(forTimeInterval: 0.4) // host paste-consumption window (see docs)
        let pb = NSPasteboard.general
        lock.lock(); defer { lock.unlock() }
        let current = pb.string(forType: .string)
        guard ownership.shouldRestore(currentChangeCount: pb.changeCount, currentContent: current) else {
            return false // user copied after Omil; never overwrite
        }
        pb.declareTypes([.string], owner: nil)
        if let prev = prepared.previousString {
            pb.setString(prev, forType: .string)
        } else {
            pb.clearContents()
        }
        ownership = ClipboardOwnership()
        return true
    }

    func currentOwnership() -> ClipboardOwnership {
        lock.lock(); defer { lock.unlock() }
        return ownership
    }
}
