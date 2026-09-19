import Foundation

// MARK: - DictationSession
//
// Session state machine with explicit start/stop/cancel, pause-resilient
// candidate history, single-commit delivery, and stale-result protection.
// Session transcript is append-only; snapshots are versioned views with
// stable token IDs for the finalized prefix.

public enum SessionPhase: String, Sendable, Codable {
    case idle
    case preparing
    case recording
    case processing   // released; ASR finalization + cleanup running
    case ready        // cleaned result available, not yet delivered
    case delivered
    case cancelled
    case failed
}

public enum SessionEvent: Sendable {
    case draftAvailable(text: String)
    case finalized(snapshot: TranscriptSnapshot)
    case cleaned(view: CleanedView)
    case failed(error: SessionError)
}

public enum SessionError: Error, Sendable {
    case backendUnavailable(reason: String)
    case assetMissing(locale: String)
    case audioFailure(underlying: String)
    case cancelled
    case superseded  // a newer session/commit replaced this one
}

public struct SessionResult: Sendable {
    public var sessionId: SessionID
    public var rawSnapshot: TranscriptSnapshot
    public var cleaned: CleanedView
    public var backend: BackendIdentity
    public var duration: Double
    /// Incremented per commit; delivery commits a result exactly once.
    public var commitSequence: Int
}

public actor DictationSession {
    public nonisolated let sessionId: SessionID
    private var phase: SessionPhase = .idle
    private var backend: (any TranscriptionBackend)?
    private var assembler = TranscriptAssembler()
    private var pipeline: CleanupPipeline
    private var mode: CleanupMode
    private var finalizedSegments: [SegmentRevision] = []
    private var volatileSegments: [SegmentRevision] = []
    private var alternatives: [AlternativeHypothesis] = []
    private var candidates: [CorrectionCandidate] = []
    private var snapshotRevision = 0
    private var eventContinuation: AsyncStream<SessionEvent>.Continuation?
    private var consumeTask: Task<Void, Never>?
    private var startedAt: Date?
    private var resultCommitted = false
    private var commitSequence = 0
    private var lastResult: SessionResult?
    private var finalizedCountAtSnapshot = -1

    public init(mode: CleanupMode = .clean, dictionary: PersonalDictionary = PersonalDictionary()) {
        self.sessionId = SessionID()
        self.pipeline = CleanupPipeline(dictionary: dictionary)
        self.mode = mode
    }

    public func events() -> AsyncStream<SessionEvent> {
        let (s, c) = AsyncStream<SessionEvent>.makeStream()
        eventContinuation = c
        return s
    }

    public var currentPhase: SessionPhase { phase }

    // MARK: Lifecycle

    public func start(backend: any TranscriptionBackend) async throws {
        guard phase == .idle else { throw SessionError.superseded }
        phase = .preparing
        self.backend = backend
        do {
            try await backend.prepare()
        } catch {
            phase = .failed
            eventContinuation?.yield(.failed(error: .backendUnavailable(reason: "\(error)")))
            throw error
        }
        startedAt = Date()
        phase = .recording
        let stream = await backend.startStreaming(sessionId: sessionId)
        consumeTask = Task { await self.consume(stream: stream, backend: backend) }
    }

    /// Inject a finalized transcript directly (tests, file-based eval, and the
    /// comparison harness run cleanup on human transcripts without audio).
    public func injectFinalTranscript(
        text: String, backend backendIdentity: BackendIdentity, locale: String = "en-US"
    ) async -> CleanedView {
        let builder = SnapshotBuilder()
        snapshotRevision += 1
        let snapshot = builder.makeSnapshot(
            sessionId: sessionId, revision: snapshotRevision, rawText: text,
            backend: backendIdentity, locale: locale)
        return finalizeSnapshot(snapshot)
    }

    /// Stop recording and run final cleanup. Returns nil when cancelled.
    public func stop() async -> SessionResult? {
        if phase == .cancelled { return nil }
        guard phase == .recording || phase == .processing || phase == .ready else { return lastResult }
        if phase != .ready { phase = .processing }
        if let b = backend { await b.finishStreaming() }
        // Wait for the consumer to drain final segments (bounded).
        var spins = 0
        while phase == .processing && spins < 200 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            spins += 1
        }
        if phase == .cancelled { return nil }
        if lastResult != nil && phase != .failed { phase = .ready }
        return lastResult
    }

    /// Immediate cancellation: no result is committed and late backend events
    /// are ignored.
    public func cancel() async {
        guard phase == .recording || phase == .processing || phase == .preparing else { return }
        phase = .cancelled
        consumeTask?.cancel()
        consumeTask = nil
        if let b = backend { await b.cancelStreaming() }
        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// Commit the cleaned result for delivery exactly once. Late or duplicate
    /// calls return nil.
    public func commitForDelivery() -> SessionResult? {
        guard phase == .ready, !resultCommitted, let r = lastResult else { return nil }
        resultCommitted = true
        commitSequence += 1
        phase = .delivered
        var committed = r
        committed.commitSequence = commitSequence
        lastResult = committed
        return committed
    }

    // MARK: Internals

    private func consume(stream: AsyncStream<BackendEvent>, backend: any TranscriptionBackend) async {
        for await event in stream {
            if phase == .cancelled { break }
            switch event {
            case .partial(let seg):
                volatileSegments.removeAll(where: { $0.segmentId == seg.segmentId })
                volatileSegments.append(seg)
                let asm = assembler.assemble(
                    sessionId: sessionId, revision: snapshotRevision,
                    finalized: finalizedSegments, volatile: volatileSegments,
                    alternatives: alternatives, backend: backend.identity, locale: backend.locale)
                eventContinuation?.yield(.draftAvailable(text: asm.draftText))
            case .final(let seg, let alts):
                volatileSegments.removeAll(where: { $0.segmentId == seg.segmentId })
                finalizedSegments.removeAll(where: { $0.segmentId == seg.segmentId })
                finalizedSegments.append(seg)
                alternatives += alts
            case .assetState:
                break
            case .failure(let err):
                phase = .failed
                eventContinuation?.yield(.failed(error: .backendUnavailable(reason: "\(err)")))
            }
        }
        // Stream finished: build the finalized snapshot (unless cancelled).
        // finalizeSnapshot is idempotent per segment count: the tail can run
        // both when the backend finishes early (phase .recording) and again
        // after stop() calls finishStreaming.
        if phase == .cancelled { return }
        if finalizedSegments.count == finalizedCountAtSnapshot, lastResult != nil { return }
        finalizedCountAtSnapshot = finalizedSegments.count
        snapshotRevision += 1
        let asm = assembler.assemble(
            sessionId: sessionId, revision: snapshotRevision,
            finalized: finalizedSegments, volatile: [],
            alternatives: alternatives, backend: backend.identity, locale: backend.locale)
        if phase == .processing || phase == .recording {
            _ = finalizeSnapshot(asm.snapshot)
            if phase == .processing {
                phase = .ready
            }
        }
    }

    @discardableResult
    private func finalizeSnapshot(_ snapshot: TranscriptSnapshot) -> CleanedView {
        let view = pipeline.clean(snapshot: snapshot, mode: mode, priorCandidates: candidates)
        candidates = view.journal.candidates
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        lastResult = SessionResult(
            sessionId: sessionId, rawSnapshot: snapshot, cleaned: view,
            backend: snapshot.backend, duration: duration, commitSequence: 0)
        if phase == .recording || phase == .processing || phase == .idle {
            eventContinuation?.yield(.cleaned(view: view))
            eventContinuation?.yield(.finalized(snapshot: snapshot))
            if phase == .idle {
                // injectFinalTranscript path (no streaming lifecycle).
                phase = .ready
            }
        }
        return view
    }

    public func updateMode(_ m: CleanupMode) { mode = m }
    public func updateDictionary(_ d: PersonalDictionary) {
        pipeline = CleanupPipeline(dictionary: d)
    }
}
