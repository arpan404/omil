# Omil capability matrix (measured 2026-09-19)

Reference host: MacBook Pro M4 Max, 128 GB, macOS 26.2, Xcode 26.6 / Swift 6.3,
Bun 1.4.0, whisper.cpp + llama.cpp (brew).

## Topology (changed 2026-09-19)

Inference moved to the **Omil server core on the user's Mac**
(`server/`, Effect/TS): Whisper large-v3-turbo transcribes, Qwen3 4B Instruct
proposes ordinary repairs, a deterministic TypeScript resolver handles
restarts/reversals/scope/structure, and a validator applies only grounded
edits (type compatibility, subject scope, negation, preservation with
fallback). The Mac client owns the bundled server process by default;
an external server is an explicit override. iPhone/iPad reach a server over
the LAN — no third party, but the Mac must be reachable and the LAN trusted.
The Mac app has no Swift inference fallback. Its deterministic Swift engine
remains test infrastructure for the shared transcript and delivery model.

## Measured results, server core (2026-09-19, reference Mac)

| Check | Result | How |
| --- | --- | --- |
| TS corpus parity (deterministic path, no model) | 25/25 exact, 0 harmful | `cd server && bun test` (corpus.test.ts reads the Swift corpus) |
| Hybrid battery (all 6 mandatory incl. reversals + scope) | 6/6 exact | `/v1/cleanup` live (Qwen proposals + deterministic + validator) |
| Whisper large-v3-turbo transcription (synthetic TTS) | 4/4 correct, cues retained ("sorry", "actually") | `/v1/transcribe` live |
| End-to-end speech→clean (synthetic) | 4/4 | transcribe + cleanup above |
| Whisper latency, short clips, warm | 2–4 s | wall clock, M4 Max |
| Qwen cleanup latency, warm llama-server | 0–1 s | wall clock (first boot loads 2.5 GB model, tens of seconds) |
| Cold model downloads | ~1.6 GB Whisper + ~2.5 GB Qwen, SHA-pinned TOFU | `bun src/main.ts --download-models` |
| Model catalog | 6 Whisper sizes + 3 Qwen sizes listed, select validated | `/v1/models`, `/v1/models/select` live (incl. 400 on unknown id) |
| Prompt override | set → used (flagged) → reset round-trip | `/v1/prompt` live |
| Compiled engine (`bun build --compile`, 62 MB) | boots standalone, token auth, transcribe works | embedded binary on :3229 vs fresh data dir |
| App-owned Effect/Bun server | embedded binary launches, authenticates, prepares models, and shuts down with app | clean build + live health/prepare smoke test |

Qwen evidence: zero-shot+few-shot proposes correct simple repairs but fails
reversals and scoped restatements and once proposed a scope-violating deletion
— which is why reversals/scope/structure are deterministic and the validator
enforces type compatibility + subject scope on every proposal. Qwen's role is
ordinary cue repairs only; conflicts lose to deterministic edits.

## Measured results (not targets)

| Check | Result | How |
| --- | --- | --- |
| Text cleanup corpus, Swift engine (human transcripts) | 25/25 exact, 0 harmful, 0 over-edits, coverage 14/14 | `omil-eval --corpus …` |
| Mandatory examples (all 6 incl. negation + scope) | pass | `swift test` (MandatoryCorrectionTests) |
| Unit tests (Swift) | 53/53 pass | `swift test` |
| Server unit tests (TS validator, tokenizer, corpus parity) | 43/43 pass | `cd server && bun test` |
| Apple `SpeechTranscriber` availability (en-US, fallback path) | available, assets ready | `omil-eval --probe` |
| Cleanup latency, Swift engine (text-only, 25 cases) | avg 0.1 ms, p95 0.3 ms | `omil-eval --bench` |
| Mock session stop→commit round trip | 0.013 s (drain loop, no audio/ASR) | `--bench` |
| Mac / iOS / keyboard targets | build succeeds | `xcodebuild` both schemes |
| Mac app launch | runs, stays resident | process check |

The plan's provisional targets (p95 < 800 ms Mac / < 1.5 s iPhone, warm,
5–30 s dictations, stop→visible-insertion) are **not yet measured** — they
require physical-device runs with real audio, real ASR, and delivery. The
numbers above are component measurements with stated exclusions.

## Supported workflows (headless-verified)

- Record → upload WAV → Whisper transcription in the Effect/Bun service
- Verbatim and Clean modes, with cleanup performed by the service
- Server-owned snippets with exact/inline expansion and longest-trigger matching
- App-category writing styles, selected by the SwiftUI client and applied by the service
- Hold-to-talk, hands-free toggle, and Escape-to-cancel shortcuts
- Microphone-sensitive recording meter; explicit start, stop, cancel
- Raw / Cleaned / Diff inspection; replayable edit journal
- Guarded insertion: destination revalidation, single commit, duplicate/ack protection
- Clipboard fallback with ownership (never overwrites newer user copies)
- Scoped undo (refuses after unrelated user typing)
- Keyboard session handoff: request → complete → insert-once → ack; expired/
  unacknowledged sessions surface explicit states, never silent failure
- No account; the Mac defaults to its loopback-only managed server

## Known limits / unverified (need physical devices)

- No human-speech evaluation yet — synthetic TTS only, labeled as such.
- Native `whisper-cli` and `llama-server` still need to be present on the Mac;
  packaging those native sidecars is separate from ownership of the Effect/Bun process.
- No microphone recording test through the Swift apps (no mic in this environment).
- No AX insertion test against a live host app (needs granted Accessibility trust).
- No iPhone→Mac round trip on device (needs LAN + token setup, provisioning for keyboard).
- No background/lock/interrupt/suspend lifecycle runs on iPhone/iPad.
- No latency, memory, energy, or thermal measurements on device (server-side
  warm numbers above are component timings, not product p95s).
- Parakeet/WhisperKit are not integrated. Whisper in the Bun service covers
  the target segment.
- Locales: English only. Other locales are explicit future capabilities with
  their own suites, not promises.

## Execution-state support (policy, pending validation)

| State | Mac | iPhone foreground | iPhone background/keyboard |
| --- | --- | --- | --- |
| Record + local inference | verified build, untested mic | verified build | code-complete, untested |
| Keyboard insertion of completed result | n/a | n/a | code-complete, needs Full Access + provisioning |
| Live Activity / AudioRecordingIntent entry | n/a | deferred (system-owned recording; documented) | — |
