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
            case "--bench":
                await bench()
                return
            case "--asr-eval":
                await asrEval()
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

    /// Headless benchmark: cleanup latency per corpus case (avg/p95) plus a
    /// mock-backend session round trip (stop -> committed result). The session
    /// number includes the bounded drain loop, NOT audio capture or real ASR.
    /// Runtime environment probe: device, OS, backend availability, assets.
    static func bench() async {
        let url = URL(fileURLWithPath: "Tests/OmilCoreTests/Fixtures/corpus.json")
        guard let corpus = try? CorrectionCorpus.load(from: url) else {
            fputs("omil-eval: corpus not found at \(url.path)\n", stderr)
            exit(2)
        }
        let pipeline = CleanupPipeline()
        var lat: [Double] = []
        for c in corpus.cases {
            let snap = SnapshotBuilder().makeSnapshot(
                sessionId: SessionID(), revision: 1, rawText: c.rawTranscript,
                backend: .mock(name: "bench"), locale: c.locale)
            let t0 = Date()
            _ = pipeline.clean(snapshot: snap)
            lat.append(Date().timeIntervalSince(t0))
        }
        lat.sort()
        let avg = lat.reduce(0, +) / Double(max(1, lat.count))
        let p95 = lat[min(lat.count - 1, Int(Double(lat.count) * 0.95))]
        print(String(format: "cleanup: n=%d avg=%.4fs p95=%.4fs (text-only, M4 Max, no ASR)",
                     lat.count, avg, p95))

        // Mock streaming session: partials + final through stop -> commit.
        let t0 = Date()
        let session = DictationSession()
        let backend = MockTranscriptionBackend(script: [
            (false, "make it 42,"), (true, "make it 42, sorry 21"),
        ])
        do {
            try await session.start(backend: backend)
            await backend.appendAudio(Data(repeating: 0, count: 3200), timestamp: 0.0)
            await backend.appendAudio(Data(repeating: 0, count: 3200), timestamp: 0.2)
            await backend.finishStreaming()
            if let result = await session.stop() {
                let committed = await session.commitForDelivery()
                let dt = Date().timeIntervalSince(t0)
                print("session: cleaned=\"\(result.cleaned.text)\" committed=\(committed != nil)")
                print(String(format: "session mock round-trip=%.3fs (drain loop included; no audio/ASR)", dt))
            } else {
                print("session: no result (cancelled?)")
                exit(1)
            }
        } catch {
            print("session: failed: \(error)")
            exit(1)
        }
    }

    /// Real-backend check over bundled synthetic fixtures (Samantha TTS).
    /// Reports cue retention + cleanup accuracy; skips honestly when the
    /// on-device backend is unavailable. Synthetic only — NOT human eval.
    static func asrEval() async {
        let dir = "Tests/OmilCoreTests/Fixtures/audio-synth"
        let fixtures: [(file: String, intended: String, cues: [String])] = [
            ("make-it-42", "Make it 42.", []),
            ("make-it-42-sorry-21", "Make it 21.", ["sorry"]),
            ("do-not-send", "Do not send 42. Send 21.", []),
            ("alice-bob", "Send Alice 42 and Bob 24.", ["actually"]),
        ]
        #if canImport(Speech)
        if #available(macOS 26, iOS 26, *) {
            let probeBackend = AppleSpeechBackend()
            do {
                try await probeBackend.prepare()
            } catch {
                print("asr-eval: SKIP (backend unavailable: \(error))")
                return
            }
            var retained = 0, totalCues = 0, exact = 0
            for f in fixtures {
                let url = URL(fileURLWithPath: "\(dir)/\(f.file).aiff")
                guard FileManager.default.fileExists(atPath: url.path) else {
                    print("asr-eval: missing \(url.path)"); continue
                }
                let backend = AppleSpeechBackend()
                try? await backend.prepare()
                guard let out = try? await backend.transcribeFile(url: url) else {
                    print("asr-eval: transcription failed for \(f.file)"); continue
                }
                let snap = SnapshotBuilder().makeSnapshot(
                    sessionId: SessionID(), revision: 1, rawText: out.text,
                    backend: .appleSpeech(configuration: "SpeechTranscriber"), locale: "en-US")
                let view = CleanupPipeline().clean(snapshot: snap)
                let ok = view.text == f.intended
                if ok { exact += 1 }
                for cue in f.cues {
                    totalCues += 1
                    if out.text.lowercased().contains(cue) { retained += 1 }
                }
                print("asr-eval[\(f.file)]: asr=\"\(out.text)\" clean=\"\(view.text)\" match=\(ok)")
            }
            print("asr-eval: exact=\(exact)/\(fixtures.count) cueRetention=\(retained)/\(totalCues) (SYNTHETIC TTS, not human speech)")
            if exact != fixtures.count { exit(1) }
        } else {
            print("asr-eval: SKIP (OS < 26)")
        }
        #else
        print("asr-eval: SKIP (Speech framework unavailable)")
        #endif
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
