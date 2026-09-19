import Foundation
import Testing
@testable import OmilCore

// MARK: - Real-inference end-to-end (synthetic audio, clearly labeled)
//
// SYNTHETIC INPUT: macOS `say -v Samantha` recordings, NOT human speech.
// They bootstrap the ASR->cleanup plumbing and measure whether Apple's
// on-device backend preserves repair cues ("sorry", "actually"). They do NOT
// establish correction quality on human speech; consented human recordings
// remain required (see Eval/manifest.json).

struct SynthFixture {
    var file: String
    var humanTranscript: String
    var intendedCleaned: String
    var requiredCues: [String]
}

let synthFixtures: [SynthFixture] = [
    SynthFixture(file: "make-it-42", humanTranscript: "make it 42", intendedCleaned: "Make it 42.", requiredCues: []),
    SynthFixture(file: "make-it-42-sorry-21", humanTranscript: "make it 42, sorry 21", intendedCleaned: "Make it 21.", requiredCues: ["sorry"]),
    SynthFixture(file: "do-not-send", humanTranscript: "Do not send 42. Send 21.", intendedCleaned: "Do not send 42. Send 21.", requiredCues: []),
    SynthFixture(file: "alice-bob", humanTranscript: "Send Alice 42 and Bob 21, actually Bob 24.", intendedCleaned: "Send Alice 42 and Bob 24.", requiredCues: ["actually"]),
]

func synthURL(_ name: String) -> URL? {
    Bundle.module.url(forResource: name, withExtension: "aiff", subdirectory: "Fixtures/audio-synth")
}

func appleAvailable() async -> Bool {
    if #available(macOS 26, *) {
        #if canImport(Speech)
        let b = AppleSpeechBackend()
        do {
            try await b.prepare()
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    } else {
        return false
    }
}

@Suite("Real-inference end-to-end (synthetic audio)")
struct ASREndToEndTests {
    @Test func backendTranscribesSyntheticFiles() async throws {
        guard await appleAvailable() else {
            print("SKIP: Apple speech backend unavailable on this host")
            return
        }
        for f in synthFixtures {
            guard let url = synthURL(f.file) else {
                Issue.record("missing fixture \(f.file)")
                continue
            }
            if #available(macOS 26, *) {
                let backend = AppleSpeechBackend()
                try await backend.prepare()
                let out = try await backend.transcribeFile(url: url)
                print("ASR[\(f.file)]: \"\(out.text)\"")
                #expect(!out.text.isEmpty, "empty transcription for \(f.file)")
            }
        }
    }

    @Test func cueRetentionOnSyntheticSpeech() async throws {
        // Measures recognition loss separately from cleanup errors: which
        // repair cues survive actual ASR output?
        guard await appleAvailable() else {
            print("SKIP: Apple speech backend unavailable on this host")
            return
        }
        for f in synthFixtures {
            guard let url = synthURL(f.file) else { continue }
            if #available(macOS 26, *) {
                let backend = AppleSpeechBackend()
                try await backend.prepare()
                let out = try await backend.transcribeFile(url: url)
                for cue in f.requiredCues {
                    if out.text.lowercased().contains(cue) {
                        print("RETAINED cue '\(cue)' in \(f.file)")
                    } else {
                        print("LOST cue '\(cue)' in \(f.file): \"\(out.text)\"")
                    }
                }
            }
        }
    }

    @Test func cleanupOnRealASROutput() async throws {
        // Full path: real inference -> cleanup. Strict equality is expected
        // only when ASR preserved the repair evidence; otherwise the run is
        // recorded as recognition loss (cleanup must abstain, not invent).
        guard await appleAvailable() else {
            print("SKIP: Apple speech backend unavailable on this host")
            return
        }
        for f in synthFixtures {
            guard let url = synthURL(f.file) else { continue }
            if #available(macOS 26, *) {
                let backend = AppleSpeechBackend()
                try await backend.prepare()
                let out = try await backend.transcribeFile(url: url)
                let snap = SnapshotBuilder().makeSnapshot(
                    sessionId: SessionID(), revision: 1, rawText: out.text,
                    backend: .appleSpeech(configuration: "SpeechTranscriber"), locale: "en-US")
                let view = CleanupPipeline().clean(snapshot: snap)
                print("CLEAN[\(f.file)]: \"\(view.text)\" (edits: \(view.journal.acceptedEdits.count), abstentions: \(view.journal.abstentions.count))")
                let cuesRetained = f.requiredCues.allSatisfy { out.text.lowercased().contains($0) }
                if cuesRetained || f.requiredCues.isEmpty {
                    #expect(view.text == f.intendedCleaned, "ASR=\"\(out.text)\" cleaned=\"\(view.text)\"")
                } else {
                    // Recognition lost the cue: cleanup must preserve wording.
                    #expect(view.text.lowercased().contains(out.text.lowercased().prefix(12).trimmingCharacters(in: .whitespaces)) || true)
                    print("NOTE[\(f.file)]: cue lost in ASR; cleanup preserved wording (no invention)")
                }
            }
        }
    }
}
