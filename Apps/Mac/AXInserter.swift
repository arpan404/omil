import AppKit
import ApplicationServices
import OmilCore

// AX attribute names via NSAccessibility (the C macros are CFSTR defines and
// are not visible to Swift).
private func axAttr(_ a: NSAccessibility.Attribute) -> CFString {
    a.rawValue as CFString
}

// The prompt key is documented as "AXTrustedCheckOptionPrompt"; spelled as a
// literal because the C global imports as shared mutable state.
nonisolated(unsafe) private let axPromptKey = "AXTrustedCheckOptionPrompt" as CFString

enum InsertionRebase {
    static func replay(
        original: String, range: CFRange, receipts: [InsertionReceipt]
    ) -> (text: String, range: CFRange)? {
        guard !receipts.isEmpty else { return nil }
        var expected = original
        var cursor = range
        for receipt in receipts {
            guard cursor.location == receipt.precondition.rangeLocation,
                  cursor.length == receipt.precondition.rangeLength else { return nil }
            let ns = expected as NSString
            guard cursor.location >= 0, cursor.length >= 0,
                  cursor.location + cursor.length <= ns.length else { return nil }
            expected = ns.replacingCharacters(
                in: NSRange(location: cursor.location, length: cursor.length),
                with: receipt.insertedText
            )
            cursor = CFRange(location: cursor.location + (receipt.insertedText as NSString).length, length: 0)
        }
        return (expected, cursor)
    }
}

// MARK: - AXInserter
//
// Direct focused-field insertion via Accessibility: captures the destination
// and selection at recording start, revalidates before insertion, commits
// once, and supports scoped undo. Never restores whole-field snapshots.

final class AXInserter: TextDestination, @unchecked Sendable {
    let identity = DestinationIdentity(appBundleId: nil, fieldIdentifier: "ax-focused-field")

    struct CapturedTarget {
        var pid: pid_t
        var bundleId: String?
        var element: AXUIElement
        var selectedText: String?
        var selectedRange: CFRange?
        var valueHash: Int?
        var valueSnapshot: String?
    }

    private var target: CapturedTarget?
    private var committedSequences = Set<Int>()
    private let lock = NSLock()

    var isTrusted: Bool { AXIsProcessTrusted() }

    var capturedBundleId: String? {
        lock.lock(); defer { lock.unlock() }
        return target?.bundleId
    }

    var capturedPID: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return target?.pid
    }

    var capturedContext: ServerCleanupContext? {
        lock.lock(); defer { lock.unlock() }
        guard let target, let value = target.valueSnapshot,
              let range = target.selectedRange else { return nil }
        let text = value as NSString
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= text.length else { return nil }
        let beforeStart = max(0, range.location - 400)
        let afterStart = range.location + range.length
        let afterEnd = min(text.length, afterStart + 200)
        let before = text.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart))
        let after = text.substring(with: NSRange(location: afterStart, length: afterEnd - afterStart))
        guard !before.isEmpty || !after.isEmpty else { return nil }
        return ServerCleanupContext(before: before, after: after)
    }

    func requestTrust() {
        let opts = [axPromptKey as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Capture the frontmost app's focused text field. Call at recording start.
    @discardableResult
    func captureTarget(application: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Bool {
        captureTarget(pid: application?.processIdentifier, bundleId: application?.bundleIdentifier)
    }

    @discardableResult
    func captureTarget(pid: pid_t?, bundleId: String?) -> Bool {
        lock.lock()
        target = nil
        lock.unlock()
        guard isTrusted else { return false }
        guard let pid else { return false }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, axAttr(.focusedUIElement), &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        let element = (el as! AXUIElement)
        AXUIElementSetMessagingTimeout(element, 1)
        // Only text-ish roles.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.role), &role)
        let roleStr = (role as? String) ?? ""
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(roleStr) else { return false }
        var selText: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.selectedText), &selText)
        var rangeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.selectedTextRange), &rangeValue)
        var range: CFRange?
        if let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() {
            var candidate = CFRange(location: 0, length: 0)
            if AXValueGetValue(rv as! AXValue, .cfRange, &candidate) {
                range = candidate
            }
        }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.value), &value)
        lock.lock()
        target = CapturedTarget(
            pid: pid, bundleId: bundleId,
            element: element, selectedText: selText as? String,
            selectedRange: range, valueHash: (value as? String)?.hashValue,
            valueSnapshot: value as? String)
        lock.unlock()
        return true
    }

    func capturePrecondition() -> SelectionPrecondition {
        lock.lock(); defer { lock.unlock() }
        guard let t = target else { return SelectionPrecondition() }
        return SelectionPrecondition(
            selectedText: t.selectedText, rangeLocation: t.selectedRange?.location,
            rangeLength: t.selectedRange?.length, surroundingHash: t.valueHash)
    }

    /// Several recordings can capture the same cursor before any result lands.
    /// Replay only Omil's confirmed insertions, then compare the entire field
    /// and cursor with the live target before advancing this capture.
    func rebaseAfterOmilInsertions(
        _ insertions: [(receipt: InsertionReceipt, by: AXInserter)]
    ) -> SelectionPrecondition? {
        lock.lock(); defer { lock.unlock() }
        guard var current = target,
              let original = current.valueSnapshot,
              let selectedRange = current.selectedRange else { return nil }
        var sameField: [InsertionReceipt] = []
        for (receipt, prior) in insertions {
            guard let previous = prior.target,
                  current.pid == previous.pid,
                  CFEqual(current.element, previous.element) else { continue }
            sameField.append(receipt)
        }
        guard let replayed = InsertionRebase.replay(
            original: original, range: selectedRange, receipts: sameField
        ) else { return nil }
        let expected = replayed.text
        let expectedRange = replayed.range
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current.element, axAttr(.value), &value) == .success,
              value as? String == expected else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current.element, axAttr(.selectedTextRange), &selected) == .success,
              let selected, CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selected as! AXValue, .cfRange, &range),
              range.location == expectedRange.location,
              range.length == expectedRange.length else { return nil }
        var selectedText: CFTypeRef?
        AXUIElementCopyAttributeValue(current.element, axAttr(.selectedText), &selectedText)
        current.selectedRange = range
        current.selectedText = selectedText as? String
        current.valueHash = expected.hashValue
        current.valueSnapshot = expected
        target = current
        return SelectionPrecondition(
            selectedText: current.selectedText, rangeLocation: range.location,
            rangeLength: 0, surroundingHash: expected.hashValue
        )
    }

    /// Some hosts expose their text value but no selection. For those hosts,
    /// continue a burst only when earlier Omil pastes formed an exact append
    /// to the same field. Any other edit keeps the captured target stale.
    func rebaseAfterOmilAppendPastes(_ pastes: [(text: String, by: AXInserter)]) -> SelectionPrecondition? {
        lock.lock(); defer { lock.unlock() }
        guard var current = target, current.selectedRange == nil,
              let original = current.valueSnapshot else { return nil }
        var expected = original
        var matched = false
        for (text, prior) in pastes {
            guard let previous = prior.target,
                  current.pid == previous.pid,
                  CFEqual(current.element, previous.element) else { continue }
            expected += text
            matched = true
        }
        guard matched else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current.element, axAttr(.value), &value) == .success,
              value as? String == expected else { return nil }
        current.valueSnapshot = expected
        current.valueHash = expected.hashValue
        target = current
        return SelectionPrecondition(surroundingHash: expected.hashValue)
    }

    func revalidate(precondition: SelectionPrecondition) -> DestinationCheck {
        lock.lock(); defer { lock.unlock() }
        guard let t = target else { return .stale(reason: "no captured destination") }
        // Focus may have moved to another app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid else {
            return .stale(reason: "frontmost app changed; result retained for explicit insertion")
        }
        let appEl = AXUIElementCreateApplication(t.pid)
        AXUIElementSetMessagingTimeout(appEl, 1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, axAttr(.focusedUIElement), &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
              CFEqual(focused, t.element) else {
            return .stale(reason: "focused field changed; result retained")
        }
        if let originalHash = t.valueHash {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(t.element, axAttr(.value), &value) == .success,
                  (value as? String)?.hashValue == originalHash else {
                return .stale(reason: "field text changed; result retained")
            }
        }
        guard t.selectedRange != nil else { return .pasteOnly }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(t.element, axAttr(.selectedTextRange), &rangeValue) == .success,
              let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() else {
            return .stale(reason: "selection unreadable; result retained")
        }
        var range = CFRange(location: 0, length: 0)
        AXValueGetValue(rv as! AXValue, .cfRange, &range)
        if range.location != (precondition.rangeLocation ?? -1) || range.length != (precondition.rangeLength ?? -2) {
            return .stale(reason: "selection moved; result retained for explicit insertion")
        }
        var selText: CFTypeRef?
        AXUIElementCopyAttributeValue(t.element, axAttr(.selectedText), &selText)
        if (selText as? String) != precondition.selectedText {
            return .stale(reason: "selected text changed; result retained")
        }
        return .ok
    }

    func insert(text: String, precondition: SelectionPrecondition, sessionId: SessionID, sequence: Int) throws -> InsertionReceipt {
        lock.lock(); defer { lock.unlock() }
        if committedSequences.contains(sequence) { throw DeliveryError.duplicateCommit }
        guard let t = target else { throw DeliveryError.destinationChanged(reason: "no captured destination") }
        // Direct selected-text replacement (scoped: only the selection changes).
        let status = AXUIElementSetAttributeValue(t.element, axAttr(.selectedText), text as CFTypeRef)
        guard status == .success else {
            throw DeliveryError.insertionFailed(underlying: "AXSelectedText set failed (\(status.rawValue))")
        }
        if let original = t.valueSnapshot, let range = t.selectedRange {
            let ns = original as NSString
            let expected = ns.replacingCharacters(
                in: NSRange(location: range.location, length: range.length), with: text
            )
            var actual: CFTypeRef?
            if AXUIElementCopyAttributeValue(t.element, axAttr(.value), &actual) == .success,
               let current = actual as? String, current != expected {
                if current == original {
                    throw DeliveryError.insertionFailed(underlying: "AXSelectedText write made no change")
                }
                throw DeliveryError.destinationChanged(reason: "field changed during insertion; result retained")
            }
        }
        committedSequences.insert(sequence)
        return InsertionReceipt(
            sessionId: sessionId,
            destination: DestinationIdentity(appBundleId: t.bundleId, fieldIdentifier: "ax-focused-field"),
            precondition: precondition, insertedText: text,
            replacedSelection: t.selectedText, commitSequence: sequence, undoSupported: true)
    }

    /// A simulated paste is only treated as an insertion when the same
    /// captured field now contains exactly the expected replacement.
    func receiptAfterPaste(
        text: String, precondition: SelectionPrecondition,
        sessionId: SessionID, sequence: Int
    ) -> InsertionReceipt? {
        lock.lock(); defer { lock.unlock() }
        guard let t = target, let original = t.valueSnapshot,
              let range = t.selectedRange else { return nil }
        let ns = original as NSString
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= ns.length else { return nil }
        let expected = ns.replacingCharacters(
            in: NSRange(location: range.location, length: range.length), with: text
        )
        var actual: CFTypeRef?
        guard AXUIElementCopyAttributeValue(t.element, axAttr(.value), &actual) == .success,
              actual as? String == expected else { return nil }
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(t.element, axAttr(.selectedTextRange), &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var actualRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selection as! AXValue, .cfRange, &actualRange),
              actualRange.location == range.location + (text as NSString).length,
              actualRange.length == 0 else { return nil }
        return InsertionReceipt(
            sessionId: sessionId,
            destination: DestinationIdentity(appBundleId: t.bundleId, fieldIdentifier: "ax-focused-field"),
            precondition: precondition, insertedText: text,
            replacedSelection: t.selectedText, commitSequence: sequence,
            undoSupported: false
        )
    }

    /// Scoped undo: replace our inserted text with the prior selection, but
    /// only when the field still shows exactly what we inserted.
    func undo(receipt: InsertionReceipt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = target else { return false }
        let base = receipt.precondition.rangeLocation ?? 0
        let len = (receipt.insertedText as NSString).length
        let range = CFRange(location: base, length: len)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(t.element, axAttr(.value), &value) == .success,
              let str = value as? String else { return false }
        let ns = str as NSString
        guard base + len <= ns.length, ns.substring(with: NSRange(location: base, length: len)) == receipt.insertedText else {
            return false // user typed after Omil; refuse
        }
        // Select our span, then restore the prior selection text.
        var r = range
        guard let rangeValue = AXValueCreate(.cfRange, &r) else { return false }
        guard AXUIElementSetAttributeValue(t.element, axAttr(.selectedTextRange), rangeValue) == .success else { return false }
        let restore = receipt.replacedSelection ?? ""
        return AXUIElementSetAttributeValue(t.element, axAttr(.selectedText), restore as CFTypeRef) == .success
    }
}
