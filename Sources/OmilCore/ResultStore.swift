import Foundation

// MARK: - Shared session store (App Group coordination)
//
// The containing app owns recording/inference; the keyboard inserts completed
// results. This store is the public-App-Group-compatible handoff: session IDs,
// commands, result state, cancellation, completion, and insertion ack.
// Shared storage alone cannot wake a suspended app; the keyboard treats a
// missing/expired session as an explicit reactivation state.

public enum SessionCommand: String, Codable, Sendable {
    case requestStart
    case requestStop
    case requestCancel
}

public enum SharedSessionState: String, Codable, Sendable {
    case requested
    case recording
    case completed
    case cancelled
    case expired
}

public struct SharedSession: Codable, Sendable {
    public var sessionId: SessionID
    public var state: SharedSessionState
    public var command: SessionCommand?
    public var cleanedText: String?
    public var rawText: String?
    public var mode: CleanupMode
    public var createdAt: Date
    public var updatedAt: Date
    /// Insertion acknowledgement: keyboard sets this once per session.
    public var acknowledgedDelivery: Bool
    public var acknowledgedAt: Date?
    /// Monotonic per session; the keyboard ignores replays with old values.
    public var resultSequence: Int

    public init(sessionId: SessionID = SessionID(), mode: CleanupMode = .clean) {
        self.sessionId = sessionId
        self.state = .requested
        self.mode = mode
        self.createdAt = Date()
        self.updatedAt = Date()
        self.acknowledgedDelivery = false
        self.resultSequence = 0
    }
}

/// Transport-agnostic store. Production uses UserDefaults(suiteName:) with the
/// App Group; tests and the Mac app use the in-memory/file-backed variant.
/// All mutations bump updatedAt and are idempotent by (sessionId, sequence).
public final class ResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: SharedSession] = [:]
    private let defaults: UserDefaults?
    private let keyPrefix = "omil.session."

    /// - Parameter appGroupId: e.g. "group.com.omil.shared". nil = in-memory
    ///   (Mac direct build without groups, tests).
    public init(appGroupId: String? = nil) {
        if let id = appGroupId {
            self.defaults = UserDefaults(suiteName: id)
        } else {
            self.defaults = nil
        }
    }

    // MARK: App side

    @discardableResult
    public func createSession(mode: CleanupMode = .clean) -> SharedSession {
        let s = SharedSession(mode: mode)
        lock.lock(); sessions[s.sessionId.rawValue] = s; lock.unlock()
        persist(s)
        return s
    }

    public func updateState(_ id: SessionID, state: SharedSessionState) {
        mutate(id) { $0.state = state }
    }

    public func publishResult(_ id: SessionID, cleaned: String, raw: String, sequence: Int) {
        mutate(id) {
            // Ignore stale replays.
            guard sequence > $0.resultSequence else { return }
            $0.cleanedText = cleaned
            $0.rawText = raw
            $0.resultSequence = sequence
            $0.state = .completed
        }
    }

    public func cancelSession(_ id: SessionID) {
        mutate(id) { $0.state = .cancelled }
    }

    public func expireSession(_ id: SessionID) {
        mutate(id) {
            if $0.state == .requested || $0.state == .recording { $0.state = .expired }
        }
    }

    // MARK: Keyboard side

    /// Next insertable result: completed, unacknowledged. Returns nil when the
    /// keyboard must show reactivation instead of inserting.
    public func pendingResult() -> SharedSession? {
        lock.lock(); defer { lock.unlock() }
        refreshFromDiskLocked()
        return sessions.values
            .filter { $0.state == .completed && !$0.acknowledgedDelivery && $0.cleanedText != nil }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
    }

    /// Acknowledge exactly once. Returns true on the first ack, false for
    /// duplicates (duplicate delivery protection).
    @discardableResult
    public func acknowledge(_ id: SessionID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        refreshFromDiskLocked()
        guard var s = sessions[id.rawValue] else { return false }
        guard !s.acknowledgedDelivery else { return false }
        s.acknowledgedDelivery = true
        s.acknowledgedAt = Date()
        s.updatedAt = Date()
        sessions[id.rawValue] = s
        persist(s)
        return true
    }

    public func session(_ id: SessionID) -> SharedSession? {
        lock.lock(); defer { lock.unlock() }
        refreshFromDiskLocked()
        return sessions[id.rawValue]
    }

    // MARK: Internals

    private func mutate(_ id: SessionID, _ f: (inout SharedSession) -> Void) {
        lock.lock(); defer { lock.unlock() }
        refreshFromDiskLocked()
        guard var s = sessions[id.rawValue] else { return }
        f(&s)
        s.updatedAt = Date()
        sessions[id.rawValue] = s
        persist(s)
    }

    private func persist(_ s: SharedSession) {
        guard let d = defaults else { return }
        if let data = try? JSONEncoder().encode(s) {
            d.set(data, forKey: keyPrefix + s.sessionId.rawValue)
        }
    }

    private func refreshFromDiskLocked() {
        guard let d = defaults else { return }
        for (key, value) in d.dictionaryRepresentation() {
            guard key.hasPrefix(keyPrefix), let data = value as? Data,
                  let s = try? JSONDecoder().decode(SharedSession.self, from: data) else { continue }
            // Keep the newest copy.
            if let existing = sessions[s.sessionId.rawValue], existing.updatedAt >= s.updatedAt { continue }
            sessions[s.sessionId.rawValue] = s
        }
    }
}
