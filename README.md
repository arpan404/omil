# Omil

Local-first dictation for Mac, iPhone, and iPad. Hold a shortcut, speak
naturally, release, and get faithful cleaned text — transcribed and cleaned
entirely on device, no account, offline after assets are installed.

- `"make it 42, sorry 21"` → `"Make it 21."` (repairs resolved, cues removed)
- `"make it 42, sorry 21, keep the original"` → `"Make it 42."` (reversals)
- `"Do not send 42. Send 21."` stays intact (negation/scope preserved)

## Status (2026-09-19)

Working implementation, headless-verified: shared `OmilCore` package, native
Mac menu-bar app, iOS app + keyboard extension, 42 tests green, 25/25 corpus
exact, real on-device inference 4/4 over synthetic TTS. Physical-device runs
(mic, AX insertion, keyboard round trip, lifecycle, latency/power) remain —
see `docs/CAPABILITY.md` for the measured-vs-unverified split.

## Start here

- `docs/product-plan.md` — product and build plan
- `docs/research/on-device-speech-stack.md` — speech-stack survey
- `docs/BUILD.md` — setup, build, run, install, device validation
- `docs/CAPABILITY.md` — capability matrix and limits
- `docs/Eval-manifest.md` — corpus and fixture provenance
- `docs/THIRD-PARTY.md` — dependency versions and licenses

## Quick commands

```sh
swift build && swift test
swift run omil-eval --corpus Tests/OmilCoreTests/Fixtures/corpus.json
swift run omil-eval --bench && swift run omil-eval --probe && swift run omil-eval --asr-eval
```
