# Omil capability matrix (measured 2026-09-19)

Reference host: MacBook Pro M4 Max, 128 GB, macOS 26.2, Xcode 26.6 / Swift 6.3.

## Measured results (not targets)

| Check | Result | How |
| --- | --- | --- |
| Text cleanup corpus (human transcripts) | 25/25 exact, 0 harmful, 0 over-edits, coverage 14/14 | `omil-eval --corpus …` |
| Mandatory examples (all 6 incl. negation + scope) | pass | `swift test` (MandatoryCorrectionTests) |
| Unit tests | 42/42 pass | `swift test` |
| Real on-device inference (synthetic TTS, Samantha) | 4/4 exact, cue retention 2/2 | `omil-eval --asr-eval` |
| Apple `SpeechTranscriber` availability (en-US) | available, assets ready | `omil-eval --probe` |
| Negotiated audio format | 16 kHz mono (negotiated, not assumed) | `--probe` |
| Cleanup latency (text-only, 25 cases) | avg 0.1 ms, p95 0.3 ms | `omil-eval --bench` |
| Mock session stop→commit round trip | 0.013 s (drain loop, no audio/ASR) | `--bench` |
| Mac / iOS / keyboard targets | build succeeds | `xcodebuild` both schemes |
| Mac app launch | runs, stays resident | process check |

The plan's provisional targets (p95 < 800 ms Mac / < 1.5 s iPhone, warm,
5–30 s dictations, stop→visible-insertion) are **not yet measured** — they
require physical-device runs with real audio, real ASR, and delivery. The
numbers above are component measurements with stated exclusions.

## Supported workflows (headless-verified)

- Record → transcribe (Apple primary, SFSpeech on-device fallback, mock for tests)
- Verbatim and Clean modes, independent of transcription choice
- Visible recording state; explicit start, stop, cancel
- Raw / Cleaned / Diff inspection; replayable edit journal
- Guarded insertion: destination revalidation, single commit, duplicate/ack protection
- Clipboard fallback with ownership (never overwrites newer user copies)
- Scoped undo (refuses after unrelated user typing)
- Keyboard session handoff: request → complete → insert-once → ack; expired/
  unacknowledged sessions surface explicit states, never silent failure
- Offline after asset install; no account; no network inference path exists

## Known limits / unverified (need physical devices)

- No human-speech evaluation yet — synthetic TTS only, labeled as such.
- No microphone recording test (no mic in this environment).
- No AX insertion test against a live host app (needs granted Accessibility trust).
- No keyboard round trip on device (needs provisioning + Full Access grant).
- No background/lock/interrupt/suspend lifecycle runs on iPhone/iPad.
- No latency, memory, energy, or thermal measurements on device.
- Local-model cleanup proposals (Foundation Models / Qwen3) not integrated:
  the deterministic engine passes the corpus, so no quality gap currently
  justifies the cost. The validator accepts external proposals, so the
  comparison harness is ready when a gap is demonstrated.
- Comparison ASR backend (Parakeet/WhisperKit) not integrated: Apple backend
  passes the synthetic + text suites; integration is deferred until a device/
  locale segment needs it.
- Locales: English only. Other locales are explicit future capabilities with
  their own suites, not promises.

## Execution-state support (policy, pending validation)

| State | Mac | iPhone foreground | iPhone background/keyboard |
| --- | --- | --- | --- |
| Record + local inference | verified build, untested mic | verified build | code-complete, untested |
| Keyboard insertion of completed result | n/a | n/a | code-complete, needs Full Access + provisioning |
| Live Activity / AudioRecordingIntent entry | n/a | deferred (system-owned recording; documented) | — |
