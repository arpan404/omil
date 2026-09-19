import Foundation

// MARK: - Delivery
//
// TextDestination prepares + revalidates an insertion target, commits once,
// and returns a receipt describing supported undo. Clipboard ownership uses
// change-count semantics: restore only while Omil still owns the write, never
// overwrite a newer user copy.

public struct DestinationIdentity: Hashable, Sendable, Codable {
    public var appBundleId: String?
    public var fieldIdentifier: String?
    public var sessionHint: String?
    public init(appBundleId: String? = nil, fieldIdentifier: String? = nil, sessionHint: String? = nil) {
        self.appBundleId = appBundleId
        self.fieldIdentifier = fieldIdentifier
        self.sessionHint = sessionHint
    }
}

public struct SelectionPrecondition: Hashable, Sendable, Codable {
    public var selectedText: String?
    public var rangeLocation: Int?
    public var rangeLength: Int?
    public var surroundingHash: Int? // hash of nearby text for change detection
    public init(selectedText: String? = nil, rangeLocation: Int? = nil, rangeLength: Int? = nil, surroundingHash: Int? = nil) {
        self.selectedText = selectedText
        self.rangeLocation = rangeLocation
        self.rangeLength = rangeLength
        self.surroundingHash = surroundingHash
    }
}

public struct InsertionReceipt: Hashable, Sendable, Codable {
    public var sessionId: SessionID
    public var destination: DestinationIdentity
    public var precondition: SelectionPrecondition
    public var insertedText: String
    public var replacedSelection: String?
    public var committedAt: Date
    public var commitSequence: Int
    public var undoSupported: Bool
    public init(sessionId: SessionID, destination: DestinationIdentity, precondition: SelectionPrecondition, insertedText: String, replacedSelection: String? = nil, commitSequence: Int, undoSupported: Bool) {
        self.sessionId = sessionId
        self.destination = destination
        self.precondition = precondition
        self.insertedText = insertedText
        self.replacedSelection = replacedSelection
        self.committedAt = Date()
        self.commitSequence = commitSequence
        self.undoSupported = undoSupported
    }
}

public enum DestinationCheck: Sendable {
    case ok
    /// Destination changed or cannot be verified: retain for explicit insertion.
    case stale(reason: String)
}

public protocol TextDestination: Sendable {
    var identity: DestinationIdentity { get }
    /// Snapshot the target + selection at recording start.
    func capturePrecondition() -> SelectionPrecondition
    /// Revalidate before insertion.
    func revalidate(precondition: SelectionPrecondition) -> DestinationCheck
    /// Insert once. Returns a receipt; throws on failure.
    func insert(text: String, precondition: SelectionPrecondition, sessionId: SessionID, sequence: Int) throws -> InsertionReceipt
}

public enum DeliveryError: Error, Sendable {
    case destinationChanged(reason: String)
    case insertionFailed(underlying: String)
    case duplicateCommit
}

/// In-memory destination used by tests and the fallback recorder. Models a
/// single text field with selection + typing so destination-change and undo
/// semantics are verifiable without a host app.
public final class MemoryDestination: TextDestination, @unchecked Sendable {
    public let identity: DestinationIdentity
    private let lock = NSLock()
    public var content: String
    public var selectedRange: NSRange
    private var committedSequences = Set<Int>()

    public init(content: String = "", selectedRange: NSRange = NSRange(location: 0, length: 0), bundleId: String? = "test.host") {
        self.content = content
        self.selectedRange = selectedRange
        self.identity = DestinationIdentity(appBundleId: bundleId)
    }

    public func simulateTyping(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        let ns = content as NSString
        let loc = min(selectedRange.location, ns.length)
        content = ns.replacingCharacters(in: NSRange(location: loc, length: 0), with: s)
        selectedRange = NSRange(location: loc + (s as NSString).length, length: 0)
    }

    public func simulateFocusChange() {
        lock.lock(); defer { lock.unlock() }
        selectedRange = NSRange(location: (content as NSString).length, length: 0)
    }

    public func capturePrecondition() -> SelectionPrecondition {
        lock.lock(); defer { lock.unlock() }
        let ns = content as NSString
        let sel: String? = selectedRange.length > 0 ? ns.substring(with: selectedRange) : nil
        let window = ns.substring(with: NSRange(location: max(0, selectedRange.location - 32), length: min(ns.length, 64)))
        return SelectionPrecondition(
            selectedText: sel, rangeLocation: selectedRange.location,
            rangeLength: selectedRange.length, surroundingHash: window.hashValue)
    }

    public func revalidate(precondition: SelectionPrecondition) -> DestinationCheck {
        lock.lock(); defer { lock.unlock() }
        if selectedRange.location != (precondition.rangeLocation ?? -1) ||
            selectedRange.length != (precondition.rangeLength ?? -2) {
            return .stale(reason: "selection moved (\(precondition.rangeLocation ?? -1) -> \(selectedRange.location))")
        }
        let ns = content as NSString
        let window = ns.substring(with: NSRange(location: max(0, selectedRange.location - 32), length: min(ns.length, 64)))
        if window.hashValue != (precondition.surroundingHash ?? 0) {
            return .stale(reason: "surrounding text changed (concurrent typing?)")
        }
        return .ok
    }

    public func insert(text: String, precondition: SelectionPrecondition, sessionId: SessionID, sequence: Int) throws -> InsertionReceipt {
        lock.lock(); defer { lock.unlock() }
        if committedSequences.contains(sequence) { throw DeliveryError.duplicateCommit }
        // Revalidate inline (same lock).
        if selectedRange.location != (precondition.rangeLocation ?? -1) ||
            selectedRange.length != (precondition.rangeLength ?? -2) {
            throw DeliveryError.destinationChanged(reason: "selection moved")
        }
        let ns = content as NSString
        let replaced: String? = selectedRange.length > 0 ? ns.substring(with: selectedRange) : nil
        content = ns.replacingCharacters(in: selectedRange, with: text)
        selectedRange = NSRange(location: selectedRange.location + (text as NSString).length, length: 0)
        committedSequences.insert(sequence)
        return InsertionReceipt(
            sessionId: sessionId, destination: identity, precondition: precondition,
            insertedText: text, replacedSelection: replaced,
            commitSequence: sequence, undoSupported: true)
    }
}

// MARK: - Clipboard ownership

/// Tracks Omil's clipboard writes by change count. Restore only while Omil
/// still owns the write; never overwrite a newer user copy.
public struct ClipboardOwnership: Sendable {
    public var lastOmilChangeCount: Int?
    public var lastOmilText: String?

    public init() {}

    public mutating func recordWrite(changeCount: Int, text: String) {
        lastOmilChangeCount = changeCount
        lastOmilText = text
    }

    /// Should Omil restore `previousContent`? Only when the clipboard still
    /// contains Omil's write at the recorded change count.
    public func shouldRestore(currentChangeCount: Int, currentContent: String?) -> Bool {
        guard let owned = lastOmilChangeCount, let ownedText = lastOmilText else { return false }
        return currentChangeCount == owned && currentContent == ownedText
    }

    /// Should Omil overwrite the clipboard with a new result? Never when the
    /// user copied after Omil's write.
    public func mayOverwrite(currentChangeCount: Int) -> Bool {
        guard let owned = lastOmilChangeCount else { return true }
        return currentChangeCount == owned
    }
}

// MARK: - Scoped undo

/// Undo reverses only Omil's insertion when the destination still matches the
/// receipt. It never restores a whole-field snapshot over later typing.
public struct ScopedUndo: Sendable {
    public init() {}

    public enum UndoResult: Sendable {
        case undone(replacedWith: String?)
        case refused(reason: String)
    }

    public func undo(receipt: InsertionReceipt, currentContent: String, currentSelection: NSRange) -> UndoResult {
        let ns = currentContent as NSString
        let insertedLen = (receipt.insertedText as NSString).length
        // Expected: insertion point right after the original selection location.
        let base = receipt.precondition.rangeLocation ?? 0
        let range = NSRange(location: base, length: insertedLen)
        guard base + insertedLen <= ns.length else {
            return .refused(reason: "field shorter than insertion; user edited after Omil")
        }
        guard ns.substring(with: range) == receipt.insertedText else {
            return .refused(reason: "inserted text no longer present; user edited after Omil")
        }
        _ = currentSelection
        return .undone(replacedWith: receipt.replacedSelection)
    }
}
