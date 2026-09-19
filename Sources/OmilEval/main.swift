import Foundation
import OmilCore

// MARK: - omil-eval
//
// Reproducible evaluation command:
//   swift run omil-eval [--split dev|heldout] [--corpus <path>] [--input-kind human-transcript]
//
// Prints exact/acceptable match, correction coverage, harmful edits,
// over-edits, abstentions, and per-case failures. Exits non-zero when any
// held-out mandatory case fails.

@main
struct OmilEval {
    static func main() async {
        var split: String? = nil
        var corpusPath: String? = nil
        var inputKind = "human-transcript"
        var strictMandatory = true
        var debugText: String? = nil

        var args = CommandLine.arguments.dropFirst()
        while let a = args.first {
            args = args.dropFirst()
            switch a {
            case "--split":
                split = args.first; args = args.dropFirst()
            case "--corpus":
                corpusPath = args.first; args = args.dropFirst()
            case "--input-kind":
                inputKind = args.first ?? inputKind; args = args.dropFirst()
            case "--no-strict":
                strictMandatory = false
            case "--debug":
                debugText = args.first; args = args.dropFirst()
            case "--probe":
                await probe()
                return
            default:
                break
            }
        }

        if let text = debugText {
            debug(text: text)
            return
        }

        let url: URL = {
            if let p = corpusPath { return URL(fileURLWithPath: p) }
            // Default: repo-relative eval corpus next to the package.
            let candidates = [
                URL(fileURLWithPath: "Tests/OmilCoreTests/Fixtures/corpus.json"),
                URL(fileURLWithPath: "corpus.json"),
            ]
            for c in candidates {
                if FileManager.default.fileExists(atPath: c.path) { return c }
            }
            return candidates[0]
        }()

        let corpus: CorrectionCorpus
        do {
            corpus = try CorrectionCorpus.load(from: url)
        } catch {
            fputs("omil-eval: cannot load corpus at \(url.path): \(error)\n", stderr)
            exit(2)
        }

        let evaluator = CorpusEvaluator()
        let t0 = Date()
        let result = evaluator.evaluate(corpus, split: split, inputKind: inputKind)
        let dt = Date().timeIntervalSince(t0)

        let splitLabel = split ?? "all"
        print("omil-eval corpus=\(corpus.version) split=\(splitLabel) input=\(inputKind)")
        print(String(format: "cases=%d exact=%d (%.1f%%) acceptable=%d (%.1f%%)",
                     result.total, result.exactMatch, pct(result.exactMatch, result.total),
                     result.acceptableMatch, pct(result.acceptableMatch, result.total)))
        print("coverage: mustEdit=\(result.mustEditCovered)/\(result.mustEditCases) abstentions=\(result.abstentions) harmful=\(result.harmfulEdits) overEdits=\(result.overEdits)")
        print(String(format: "evalLatency=%.3fs (text-only cleanup; ASR excluded)", dt))
        if !result.failures.isEmpty {
            print("failures:")
            for f in result.failures {
                print("  - \(f.id)\n    expected: \(f.expected)\n    actual:   \(f.actual)")
            }
        }

        if strictMandatory {
            let mandatoryIds: Set<String> = [
                "mandatory-plain", "mandatory-replace", "mandatory-reversal-repeat",
                "mandatory-reversal-original", "mandatory-negation", "mandatory-scope",
            ]
            let failedIds = Set(result.failures.map { $0.id })
            let missing = mandatoryIds.intersection(failedIds)
            if !missing.isEmpty {
                fputs("omil-eval: MANDATORY CASES FAILED: \(missing.sorted().joined(separator: ", "))\n", stderr)
                exit(1)
            }
        }
        if !result.failures.isEmpty { exit(1) }
    }

    static func pct(_ a: Int, _ b: Int) -> Double {
        guard b > 0 else { return 0 }
        return Double(a) / Double(b) * 100
    }

    /// Runtime environment probe: device, OS, backend availability, assets.
    static func probe() async {
        let dev = CapabilityMatrix.currentDevice()
        print("device model=\(dev.model) os=\(dev.os) memoryGB=\(dev.memoryGB)")
        let status = await SpeechSupportProbe().probe()
        print("speechTranscriberAvailable=\(status.speechTranscriberAvailable)")
        print("dictationAvailable=\(status.dictationAvailable)")
        print("sfOnDeviceAvailable=\(status.sfOnDeviceAvailable)")
        print("installedLocales=\(status.installedLocales.joined(separator: ","))")
        print("detail=\(status.detail)")
        let matrix = CapabilityMatrix()
        for state in ["foreground", "background"] {
            let e = matrix.eligible(status: status, memoryGB: dev.memoryGB, executionState: state)
            print("eligible[\(state)]=\(e.supported) notes=\(e.notes)")
        }
        #if canImport(Speech)
        if #available(macOS 26, iOS 26, *) {
            let b = AppleSpeechBackend()
            do {
                try await b.prepare()
                print("applePrepare=ok")
            } catch {
                print("applePrepare=failed: \(error)")
            }
            print("assetState=\(await b.currentAssetState())")
            print("negotiatedFormat=\(await b.diagnosticFormat() ?? "none")")
        } else {
            print("applePrepare=skipped (OS < 26)")
        }
        #endif
    }

    static func debug(text: String) {
        let snap = SnapshotBuilder().makeSnapshot(
            sessionId: SessionID(), revision: 1, rawText: text,
            backend: .mock(name: "debug"), locale: "en-US")
        print("tokens:")
        for (i, t) in snap.tokens.enumerated() {
            print("  [\(i)] '\(t.text)' kind=\(t.kind) protected=\(t.isProtected)")
        }
        let view = CleanupPipeline().clean(snapshot: snap)
        print("output: \(view.text)")
        print("accepted:")
        for e in view.journal.acceptedEdits {
            print("  \(e.op) targets=\(e.targetTokenIds.map { $0.rawValue }) rep=\(e.replacementText ?? "nil") anchor=\(e.replacementAnchor.map(String.init) ?? "nil") rule=\(e.ruleVersion)")
        }
        print("rejected: \(view.journal.rejectedEdits.map { "\($0.op)" })")
        print("abstentions:")
        for a in view.journal.abstentions {
            print("  \(a.reason): \(a.detail)")
        }
        print("candidates: \(view.journal.candidates.map { "\($0.slotKey)=\($0.valueText)" })")
    }
}
