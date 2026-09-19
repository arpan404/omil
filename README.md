# Omil

Local-first dictation for Mac, iPhone, and iPad. Hold a shortcut, speak
naturally, release, and get faithful cleaned text.

- `"make it 42, sorry 21"` → `"Make it 21."` (repairs resolved, cues removed)
- `"make it 42, sorry 21, keep the original"` → `"Make it 42."` (reversals)
- `"Do not send 42. Send 21."` stays intact (negation/scope preserved)

## Architecture

Inference runs in the **Omil server core** (`server/`, Effect/TypeScript on
your Mac): **Whisper large-v3-turbo** transcribes, **Qwen3 4B Instruct**
proposes cleanup edits, and a validator applies only grounded edits. Swift
apps are thin clients: they capture audio, display results, and insert text
locally. iPhone/iPad connect to the Mac over your LAN — no third party is
ever involved, but the Mac must be reachable and your LAN trusted. The
deterministic local engine remains as an offline fallback.

## Status (2026-09-19)

Server core live on the reference Mac: Whisper large-v3-turbo transcribes
(4/4 synthetic), hybrid Qwen cleanup passes all 6 mandatory cases, 39 bun
tests + 47 Swift tests green, both Xcode schemes build. Still ahead:
physical-device runs (mic, AX insertion, iPhone→Mac round trip, lifecycle,
latency/power) and human-speech evaluation — see `docs/CAPABILITY.md`.

## The Omil server core (Mac)

```sh
brew install whisper-cpp llama.cpp   # sidecar binaries (one time)
cd server && bun install
bun src/main.ts --download-models    # ~1.6 GB Whisper + ~2.5 GB Qwen, first run only
bun src/main.ts                      # serves http://127.0.0.1:3217 (token printed on first boot)
```

Paste the printed token into the Mac app Settings → General → Omil inference
core (host `127.0.0.1`). iPhone/iPad use the Mac's LAN address + the same
token. Optional auto-start: `server/com.omil.server.plist.example` (LaunchAgent).

```sh
cd server && bun test                # 13 tests
curl http://127.0.0.1:3217/v1/health # model readiness (no auth)
```

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
