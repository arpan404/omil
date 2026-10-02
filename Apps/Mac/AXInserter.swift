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

/// Change detection looks only at the text around the cursor, so output
/// elsewhere in a large field (a terminal buffer, a chat log) does not make
/// the captured cursor stale.
enum InsertionContext {
    static let radius = 200

    static func hash(of value: String, around range: CFRange?) -> Int {
        let ns = value as NSString
        guard let range, range.location >= 0, range.length >= 0,
              range.location + range.length <= ns.length else { return value.hashValue }
        let start = max(0, range.location - radius)
        let end = min(ns.length, range.location + range.length + radius)
        return ns.substring(with: NSRange(location: start, length: end - start)).hashValue
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
        /// False when the host rejects AXSelectedText writes (terminals,
        /// Messages); those fields can only receive a paste at the cursor.
        var directlyWritable: Bool
    }

    /// The app Omil will deliver to, kept even when its focused field could
    /// not be identified. `pastesWithoutField` is true only when the user was
    /// working in that app at recording start, so a blind paste is expected.
    private var app: (pid: pid_t, bundleId: String?, pastesWithoutField: Bool)?
    private var target: CapturedTarget?
    private var committedSequences = Set<Int>()
    private let lock = NSLock()

    var isTrusted: Bool { AXIsProcessTrusted() }

    var capturedBundleId: String? {
        lock.lock(); defer { lock.unlock() }
        return app?.bundleId
    }

    var capturedPID: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return app?.pid
    }

    var hasCapturedField: Bool {
        lock.lock(); defer { lock.unlock() }
        return target != nil
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

    /// Remembers the app even when no field is found, so delivery can still
    /// paste into it. Returns true only when a text field was captured.
    @discardableResult
    func captureTarget(pid: pid_t?, bundleId: String?, pastesWithoutField: Bool = false) -> Bool {
        lock.lock()
        target = nil
        app = pid.map { ($0, bundleId, pastesWithoutField) }
        lock.unlock()
        guard isTrusted, let pid else { return false }
        return captureField(pid: pid, bundleId: bundleId)
    }

    /// Captures the field focused now. Delivery calls this after bringing the
    /// target app forward when the field could not be found at recording start.
    @discardableResult
    func recaptureField() -> Bool {
        lock.lock()
        let app = self.app
        lock.unlock()
        guard isTrusted, let app else { return false }
        return captureField(pid: app.pid, bundleId: app.bundleId)
    }

    private func captureField(pid: pid_t, bundleId: String?) -> Bool {
        guard let element = Self.focusedElement(pid: pid), Self.isTextInput(element) else { return false }
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
        let text = value as? String
        lock.lock()
        target = CapturedTarget(
            pid: pid, bundleId: bundleId,
            element: element, selectedText: selText as? String,
            selectedRange: range, valueHash: text.map { InsertionContext.hash(of: $0, around: range) },
            valueSnapshot: text,
            directlyWritable: Self.isSettable(element, .selectedText))
        lock.unlock()
        return true
    }

    /// The element receiving key events in `pid`. Asks the system-wide element
    /// first, which reports focus regardless of which app or display is active,
    /// then the app itself. Chromium and Electron apps answer "no value" until
    /// their accessibility tree exists, so a miss asks Electron to build it
    /// and retries briefly.
    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1)
        for attempt in 0..<3 {
            if let element = copyElement(system, .focusedUIElement) {
                var owner: pid_t = 0
                if AXUIElementGetPid(element, &owner) == .success, owner == pid { return element }
            }
            if let element = copyElement(appEl, .focusedUIElement) { return element }
            if attempt == 0 {
                AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private static func copyElement(_ parent: AXUIElement, _ attribute: NSAccessibility.Attribute) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, axAttr(attribute), &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 1)
        return element
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: NSAccessibility.Attribute) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, axAttr(attribute), &settable) == .success && settable.boolValue
    }

    /// Text roles, plus anything that accepts a selected-text write or exposes
    /// an editable value with a cursor (web editors often report AXGroup).
    private static func isTextInput(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, axAttr(.role), &role)
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role as? String ?? "") {
            return true
        }
        if isSettable(element, .selectedText) { return true }
        var range: CFTypeRef?
        return isSettable(element, .value)
            && AXUIElementCopyAttributeValue(element, axAttr(.selectedTextRange), &range) == .success
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
        current.valueHash = InsertionContext.hash(of: expected, around: range)
        current.valueSnapshot = expected
        target = current
        return SelectionPrecondition(
            selectedText: current.selectedText, rangeLocation: range.location,
            rangeLength: 0, surroundingHash: current.valueHash
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
        guard let app else { return .stale(reason: "no captured destination") }
        // Focus may have moved to another app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid else {
            return .stale(reason: "frontmost app changed; result retained for explicit insertion")
        }
        // The app is still in front but its field was never identified:
        // a paste lands wherever its cursor is.
        guard let t = target else {
            return app.pastesWithoutField ? .pasteOnly : .stale(reason: "no text field found; result retained")
        }
        // A focus query that fails cannot show the field changed, and the
        // app is still in front, so paste rather than drop the result.
        guard let focused = Self.focusedElement(pid: t.pid) else { return .pasteOnly }
        guard CFEqual(focused, t.element) else {
            return .stale(reason: "focused field changed; result retained")
        }
        // A paste goes to the live cursor, so only direct writes need the
        // cursor and its surrounding text to match the capture.
        guard t.directlyWritable, t.selectedRange != nil else { return .pasteOnly }
        if let originalHash = t.valueHash {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(t.element, axAttr(.value), &value) == .success,
                  let text = value as? String,
                  InsertionContext.hash(of: text, around: t.selectedRange) == originalHash else {
                return .stale(reason: "field text changed; result retained")
            }
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
