import Foundation

// MARK: - Identities

/// Stable identity contract per product plan. String.Index is never persisted.
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
    public var description: String { rawValue }
}

public struct SnapshotID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct TokenID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct EditID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct CandidateID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

// MARK: - Tokens

public enum TokenKind: String, Codable, Sendable {
    case word
    case number
    case punctuation
    case filler
    case cue
    case whitespace
}

public struct Token: Hashable, Codable, Sendable {
    public let id: TokenID
    public var text: String
    public var normalized: String
    public var kind: TokenKind
    /// Seconds since session start, when known.
    public var startTime: Double?
    public var endTime: Double?
    public var isProtected: Bool

    public init(
        id: TokenID, text: String, normalized: String? = nil,
        kind: TokenKind = .word, startTime: Double? = nil,
        endTime: Double? = nil, isProtected: Bool = false
    ) {
        self.id = id
        self.text = text
        self.normalized = normalized ?? text.lowercased()
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.isProtected = isProtected
    }
}

// MARK: - Alternatives

public struct AlternativeHypothesis: Hashable, Codable, Sendable {
    public let hypothesisId: String
    public let segmentId: String
    public let rank: Int
    public let text: String
    /// Token IDs are scoped to this hypothesis; they are NOT interchangeable
    /// with snapshot token IDs without explicit mapping.
    public let tokenTexts: [String]

    public init(hypothesisId: String = UUID().uuidString, segmentId: String, rank: Int, text: String, tokenTexts: [String]) {
        self.hypothesisId = hypothesisId
        self.segmentId = segmentId
        self.rank = rank
        self.text = text
        self.tokenTexts = tokenTexts
    }
}

// MARK: - Segments & snapshots

public struct SegmentRevision: Hashable, Codable, Sendable {
    public let segmentId: String
    public let revision: Int
    public let text: String
    public let isFinal: Bool
    public let startTime: Double?
    public let endTime: Double?

    public init(segmentId: String, revision: Int, text: String, isFinal: Bool, startTime: Double? = nil, endTime: Double? = nil) {
        self.segmentId = segmentId
        self.revision = revision
        self.text = text
        self.isFinal = isFinal
        self.startTime = startTime
        self.endTime = endTime
    }
}

public enum BackendIdentity: Hashable, Codable, Sendable {
    case appleSpeech(configuration: String)
    case sfspeech(locale: String)
    case mock(name: String)
    case server
    case unknown(name: String)

    public var displayName: String {
        switch self {
        case .appleSpeech(let c): return "AppleSpeech(\(c))"
        case .sfspeech(let l): return "SFSpeech(\(l))"
        case .mock(let n): return "Mock(\(n))"
        case .server: return "OmilServer(Whisper+Cleanup)"
        case .unknown(let n): return n
        }
    }
}

/// Immutable recognizer output. Derived views link back to token IDs here.
public struct TranscriptSnapshot: Hashable, Codable, Sendable {
    public let sessionId: SessionID
    public let snapshotId: SnapshotID
    public let revision: Int
    public let backend: BackendIdentity
    public let locale: String
    public let rawText: String
    public let tokens: [Token]
    public let segments: [SegmentRevision]
    public let alternatives: [AlternativeHypothesis]
    public let createdAt: Date

    public init(
        sessionId: SessionID, snapshotId: SnapshotID = SnapshotID(),
        revision: Int, backend: BackendIdentity, locale: String,
        rawText: String, tokens: [Token], segments: [SegmentRevision] = [],
        alternatives: [AlternativeHypothesis] = [], createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.snapshotId = snapshotId
        self.revision = revision
        self.backend = backend
        self.locale = locale
        self.rawText = rawText
        self.tokens = tokens
        self.segments = segments
        self.alternatives = alternatives
        self.createdAt = createdAt
    }

    public func token(id: TokenID) -> Token? {
        tokens.first(where: { $0.id == id })
    }

    public func indexOf(id: TokenID) -> Int? {
        tokens.firstIndex(where: { $0.id == id })
    }
}

// MARK: - Edits

public enum EditOperation: String, Codable, Sendable {
    case deleteFiller
    case deleteRepeat
    case deleteCue
    case replaceFromSource
    case selectCandidate
    case revertEdit
    case normalizeNumber
    case normalizeDate
    case punctuation
    case formattingCommand
    case dictionarySubstitution
}

public struct ProposedEdit: Hashable, Codable, Sendable {
    public let editId: EditID
    public let snapshotId: SnapshotID
    public let snapshotRevision: Int
    public let op: EditOperation
    /// Ordered target token IDs in the input snapshot.
    public let targetTokenIds: [TokenID]
    /// Evidence token IDs (cue, repair source, etc.).
    public let evidenceTokenIds: [TokenID]
    public let candidateId: CandidateID?
    public let dependsOn: [EditID]
    public let reason: String
    public let ruleVersion: String
    /// For replacement: literal replacement token texts (must be validated as
    /// copying an identified source span or an approved normalization).
    public let replacementText: String?
    public let sourceDescription: String?
    /// Token index in the input snapshot where `replacementText` is emitted.
    /// nil = the repair value stays in place (no insertion needed).
    public let replacementAnchor: Int?

    public init(
        editId: EditID = EditID(), snapshotId: SnapshotID, snapshotRevision: Int,
        op: EditOperation, targetTokenIds: [TokenID], evidenceTokenIds: [TokenID] = [],
        candidateId: CandidateID? = nil, dependsOn: [EditID] = [],
        reason: String, ruleVersion: String,
        replacementText: String? = nil, sourceDescription: String? = nil,
        replacementAnchor: Int? = nil
    ) {
        self.editId = editId
        self.snapshotId = snapshotId
        self.snapshotRevision = snapshotRevision
        self.op = op
        self.targetTokenIds = targetTokenIds
        self.evidenceTokenIds = evidenceTokenIds
        self.candidateId = candidateId
        self.dependsOn = dependsOn
        self.reason = reason
        self.ruleVersion = ruleVersion
        self.replacementText = replacementText
        self.sourceDescription = sourceDescription
        self.replacementAnchor = replacementAnchor
    }
}

public enum AbstentionReason: String, Codable, Sendable {
    case ambiguousScope
    case missingEvidence
    case conflictingEdits
    case protectedContent
    case staleSnapshot
    case quotedContent
    case weakCue
}

public struct Abstention: Hashable, Codable, Sendable {
    public let reason: AbstentionReason
    public let detail: String
    public let tokenIds: [TokenID]
    public init(reason: AbstentionReason, detail: String, tokenIds: [TokenID] = []) {
        self.reason = reason
        self.detail = detail
        self.tokenIds = tokenIds
    }
}

// MARK: - Journal & views

public struct CorrectionCandidate: Hashable, Codable, Sendable {
    public let candidateId: CandidateID
    /// Slot key identifies which value slot this candidate fills
    /// (e.g. "number@3", "recipient@1", "day@0").
    public let slotKey: String
    public let valueText: String
    public let sourceTokenIds: [TokenID]
    public let supersedes: CandidateID?
    public let editId: EditID

    public init(candidateId: CandidateID = CandidateID(), slotKey: String, valueText: String, sourceTokenIds: [TokenID], supersedes: CandidateID? = nil, editId: EditID) {
        self.candidateId = candidateId
        self.slotKey = slotKey
        self.valueText = valueText
        self.sourceTokenIds = sourceTokenIds
        self.supersedes = supersedes
        self.editId = editId
    }
}

public struct EditJournal: Hashable, Codable, Sendable {
    public let sessionId: SessionID
    public let baseSnapshotId: SnapshotID
    public var acceptedEdits: [ProposedEdit]
    public var rejectedEdits: [ProposedEdit]
    public var abstentions: [Abstention]
    public var candidates: [CorrectionCandidate]
    public var derivedRevision: Int

    public init(sessionId: SessionID, baseSnapshotId: SnapshotID) {
        self.sessionId = sessionId
        self.baseSnapshotId = baseSnapshotId
        self.acceptedEdits = []
        self.rejectedEdits = []
        self.abstentions = []
        self.candidates = []
        self.derivedRevision = 0
    }
}

public struct CleanedView: Hashable, Codable, Sendable {
    public let sessionId: SessionID
    public let snapshotId: SnapshotID
    public let text: String
    public let journal: EditJournal
    public let mode: CleanupMode
    public let backend: BackendIdentity
    public let rulesVersion: String

    public init(sessionId: SessionID, snapshotId: SnapshotID, text: String, journal: EditJournal, mode: CleanupMode, backend: BackendIdentity, rulesVersion: String) {
        self.sessionId = sessionId
        self.snapshotId = snapshotId
        self.text = text
        self.journal = journal
        self.mode = mode
        self.backend = backend
        self.rulesVersion = rulesVersion
    }
}

public enum CleanupMode: String, Codable, Sendable {
    case verbatim
    case clean
}
