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
        var selectedRange: CFRange
        var valuePrefix: String
    }

    private var target: CapturedTarget?
    private var committedSequences = Set<Int>()
    private let lock = NSLock()

    var isTrusted: Bool { AXIsProcessTrusted() }

    var capturedBundleId: String? {
        lock.lock(); defer { lock.unlock() }
        return target?.bundleId
    }

    func requestTrust() {
        let opts = [axPromptKey as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Capture the frontmost app's focused text field. Call at recording start.
    @discardableResult
    func captureTarget() -> Bool {
        lock.lock()
        target = nil
        lock.unlock()
        guard isTrusted else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, axAttr(.focusedUIElement), &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        let element = (el as! AXUIElement)
        // Only text-ish roles.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.role), &role)
        let roleStr = (role as? String) ?? ""
        guard ["AXTextField", "AXTextArea", "AXComboBox", "AXStaticText"].contains(roleStr) else { return false }
        var selText: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.selectedText), &selText)
        var rangeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.selectedTextRange), &rangeValue)
        var range = CFRange(location: 0, length: 0)
        if let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() {
            AXValueGetValue(rv as! AXValue, .cfRange, &range)
        }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.value), &value)
        let valueStr = (value as? String) ?? ""
        let prefix = String(valueStr.prefix(max(0, min(range.location + 64, valueStr.count))))
        lock.lock()
        target = CapturedTarget(
            pid: app.processIdentifier, bundleId: app.bundleIdentifier,
            element: element, selectedText: selText as? String,
            selectedRange: range, valuePrefix: prefix)
        lock.unlock()
        return true
    }

    func capturePrecondition() -> SelectionPrecondition {
        lock.lock(); defer { lock.unlock() }
        guard let t = target else { return SelectionPrecondition() }
        return SelectionPrecondition(
            selectedText: t.selectedText, rangeLocation: t.selectedRange.location,
            rangeLength: t.selectedRange.length, surroundingHash: t.valuePrefix.hashValue)
    }

    func revalidate(precondition: SelectionPrecondition) -> DestinationCheck {
        lock.lock(); defer { lock.unlock() }
        guard let t = target else { return .stale(reason: "no captured destination") }
        // Focus may have moved to another app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid else {
            return .stale(reason: "frontmost app changed; result retained for explicit insertion")
        }
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
        committedSequences.insert(sequence)
        return InsertionReceipt(
            sessionId: sessionId,
            destination: DestinationIdentity(appBundleId: t.bundleId, fieldIdentifier: "ax-focused-field"),
            precondition: precondition, insertedText: text,
            replacedSelection: t.selectedText, commitSequence: sequence, undoSupported: true)
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
