import Foundation

// MARK: - TranscriptionBackend contract

public struct AudioFormatRequirements: Hashable, Sendable {
    public var sampleRate: Double?
    public var channelCount: Int?
    public var description: String
    public init(sampleRate: Double? = nil, channelCount: Int? = nil, description: String) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.description = description
    }
}

public struct BackendCapabilities: Hashable, Sendable {
    public var supportsStreaming: Bool
    public var supportsPartials: Bool
    public var supportsTimestamps: Bool
    public var supportsAlternatives: Bool
    public var requiresAssetDownload: Bool
    public init(supportsStreaming: Bool, supportsPartials: Bool, supportsTimestamps: Bool, supportsAlternatives: Bool, requiresAssetDownload: Bool) {
        self.supportsStreaming = supportsStreaming
        self.supportsPartials = supportsPartials
        self.supportsTimestamps = supportsTimestamps
        self.supportsAlternatives = supportsAlternatives
        self.requiresAssetDownload = requiresAssetDownload
    }
}

public enum AssetState: Sendable, Equatable {
    case ready
    case downloading(progress: Double)
    case notInstalled
    case unavailable(reason: String)
}

public enum BackendEvent: Sendable {
    case partial(segment: SegmentRevision)
    case final(segment: SegmentRevision, alternatives: [AlternativeHypothesis])
    case assetState(AssetState)
    case failure(BackendError)
}

public enum BackendError: Error, Sendable {
    case notAvailable(reason: String)
    case assetMissing(locale: String)
    case audioFormatUnsupported(detail: String)
    case cancelled
    case interrupted(reason: String)
    case recognitionFailed(underlying: String)
}

public protocol TranscriptionBackend: Sendable {
    var identity: BackendIdentity { get }
    var capabilities: BackendCapabilities { get }
    /// The audio format this backend negotiated. Never assume 16 kHz.
    var requiredAudioFormat: AudioFormatRequirements { get }
    var locale: String { get }

    /// Prepare assets (downloads). Throws when unavailable.
    func prepare() async throws
    func currentAssetState() async -> AssetState

    /// Stream audio buffers; events carry identified segment revisions with
    /// finality, timing, and alternatives when available.
    func startStreaming(sessionId: SessionID) async -> AsyncStream<BackendEvent>
    func appendAudio(_ data: Data, timestamp: Double) async
    func finishStreaming() async
    func cancelStreaming() async
}

// MARK: - Mock backend (tests, plumbing, offline UI)

public actor MockTranscriptionBackend: TranscriptionBackend {
    public nonisolated let identity: BackendIdentity
    public nonisolated let capabilities = BackendCapabilities(
        supportsStreaming: true, supportsPartials: true, supportsTimestamps: true,
        supportsAlternatives: true, requiresAssetDownload: false)
    public nonisolated let requiredAudioFormat = AudioFormatRequirements(
        sampleRate: 16_000, channelCount: 1, description: "mock 16kHz mono PCM")
    public nonisolated let locale: String

    /// Script: ordered (isFinal, text) results emitted as audio is appended.
    var script: [(isFinal: Bool, text: String)]
    var events: AsyncStream<BackendEvent>.Continuation?
    var stream: AsyncStream<BackendEvent>?
    var appendCount = 0
    var cancelled = false

    public init(name: String = "mock", locale: String = "en-US", script: [(Bool, String)] = []) {
        self.identity = .mock(name: name)
        self.locale = locale
        self.script = script
    }

    public func prepare() async throws {}
    public func currentAssetState() async -> AssetState { .ready }

    public func startStreaming(sessionId: SessionID) async -> AsyncStream<BackendEvent> {
        let (s, c) = AsyncStream<BackendEvent>.makeStream()
        self.stream = s
        self.events = c
        self.appendCount = 0
        self.cancelled = false
        return s
    }

    public func appendAudio(_ data: Data, timestamp: Double) async {
        guard !cancelled, let cont = events else { return }
        // Emit one script line per append (test-controlled).
        if appendCount < script.count {
            let line = script[appendCount]
            let seg = SegmentRevision(segmentId: "seg-\(appendCount)", revision: appendCount, text: line.text, isFinal: line.isFinal)
            if line.isFinal {
                cont.yield(.final(segment: seg, alternatives: []))
            } else {
                cont.yield(.partial(segment: seg))
            }
        }
        appendCount += 1
    }

    public func finishStreaming() async {
        events?.finish()
        events = nil
    }

    public func cancelStreaming() async {
        cancelled = true
        events?.finish()
        events = nil
    }
}

// MARK: - TranscriptAssembler

/// Merges volatile + finalized backend segments into immutable snapshots.
/// Volatile text is for UI draft display only; cleanup runs on finalized
/// snapshots, and the session retains earlier clauses for later corrections.
public struct TranscriptAssembler: Sendable {
    public init() {}

    public struct Assembly: Sendable {
        public var draftText: String  // volatile, visibly unstable
        public var finalizedText: String
        public var snapshot: TranscriptSnapshot
    }

    public func assemble(
        sessionId: SessionID, revision: Int,
        finalized: [SegmentRevision], volatile: [SegmentRevision],
        alternatives: [AlternativeHypothesis],
        backend: BackendIdentity, locale: String
    ) -> Assembly {
        let finalizedText = finalized.sorted(by: { $0.revision < $1.revision }).map { $0.text }.joined(separator: " ")
        let draftText = (finalized + volatile).sorted(by: { $0.revision < $1.revision }).map { $0.text }.joined(separator: " ")
        let builder = SnapshotBuilder()
        let snapshot = builder.makeSnapshot(
            sessionId: sessionId, revision: revision, rawText: finalizedText,
            backend: backend, locale: locale,
            segments: finalized, alternatives: alternatives)
        return Assembly(draftText: draftText, finalizedText: finalizedText, snapshot: snapshot)
    }
}
