import Foundation

// MARK: - CorrectionCorpus
//
// Versioned evaluation corpus. Each case: raw transcript, intended output,
// protected spans, allowed alternatives, locale, tags, and split (dev/heldout).
// Human transcripts AND actual ASR output both run through this corpus; the
// runner records which input kind was used.

public struct CorpusCase: Codable, Sendable {
    public var id: String
    public var rawTranscript: String
    public var intendedOutput: String
    public var acceptableAlternatives: [String]
    public var protectedSpans: [String]
    public var locale: String
    public var tags: [String]
    public var split: String // "dev" | "heldout"
    public var mustEdit: Bool // true when abstention (no edits) counts as failure
}

public struct CorrectionCorpus: Codable, Sendable {
    public var version: String
    public var cases: [CorpusCase]

    public static func load(from url: URL) throws -> CorrectionCorpus {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CorrectionCorpus.self, from: data)
    }

    public static var bundledURL: URL? {
        // Main-target builds do not bundle resources; the eval command and
        // tests pass explicit paths. Kept as a hook for app-bundled corpora.
        nil
    }
}

// MARK: - Metrics

public struct EvalResult: Sendable {
    public var total: Int
    public var exactMatch: Int
    public var acceptableMatch: Int // exact or in acceptableAlternatives
    public var mustEditCases: Int
    public var mustEditCovered: Int // mustEdit && output != input-ish (an edit happened)
    public var harmfulEdits: Int    // protected span lost
    public var overEdits: Int       // already-clean input was changed
    public var abstentions: Int
    public var failures: [(id: String, expected: String, actual: String)]

    public init() {
        total = 0; exactMatch = 0; acceptableMatch = 0
        mustEditCases = 0; mustEditCovered = 0
        harmfulEdits = 0; overEdits = 0; abstentions = 0
        failures = []
    }
}

public struct CorpusEvaluator: Sendable {
    let pipeline: CleanupPipeline
    public init(pipeline: CleanupPipeline = CleanupPipeline()) {
        self.pipeline = pipeline
    }

    public func evaluate(_ corpus: CorrectionCorpus, split: String? = nil, inputKind: String = "human-transcript") -> EvalResult {
        var r = EvalResult()
        let cases = split.map { s in corpus.cases.filter { $0.split == s } } ?? corpus.cases
        for c in cases {
            r.total += 1
            let snap = SnapshotBuilder().makeSnapshot(
                sessionId: SessionID(), revision: 1, rawText: c.rawTranscript,
                backend: .mock(name: inputKind), locale: c.locale)
            let view = pipeline.clean(snapshot: snap)
            let actual = view.text
            if actual == c.intendedOutput { r.exactMatch += 1 }
            if actual == c.intendedOutput || c.acceptableAlternatives.contains(actual) {
                r.acceptableMatch += 1
            } else {
                r.failures.append((c.id, c.intendedOutput, actual))
            }
            if c.mustEdit {
                r.mustEditCases += 1
                if !view.journal.acceptedEdits.isEmpty { r.mustEditCovered += 1 }
            } else if !view.journal.acceptedEdits.isEmpty, c.tags.contains("already-clean") {
                r.overEdits += 1
            }
            if view.journal.acceptedEdits.isEmpty { r.abstentions += 1 }
            for span in c.protectedSpans {
                if !actual.contains(span) {
                    // Allow case-insensitive match.
                    if !actual.lowercased().contains(span.lowercased()) {
                        r.harmfulEdits += 1
                        break
                    }
                }
            }
        }
        return r
    }
}
