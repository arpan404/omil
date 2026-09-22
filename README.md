# Omil

Local-first dictation for Mac, iPhone, and iPad. Hold a shortcut, speak
naturally, release, and get faithful cleaned text.

- `"make it 42, sorry 21"` → `"Make it 21."` (repairs resolved, cues removed)
- `"make it 42, sorry 21, keep the original"` → `"Make it 42."` (reversals)
- `"Do not send 42. Send 21."` stays intact (negation/scope preserved)

## Architecture

Inference runs in the **Omil server core** (`server/`, Effect/TypeScript),
which the Mac app embeds, starts, monitors, and stops automatically:
**Whisper large-v3-turbo** transcribes, **Qwen3 4B Instruct**
proposes cleanup edits, and a validator applies only grounded edits. Swift
apps are thin clients: they capture audio, display results, and insert text
locally. iPhone/iPad connect to the Mac over your LAN — no third party is
ever involved, but the Mac must be reachable and your LAN trusted. The Mac
app does not fall back to a Swift inference path when the server is offline.

## Status (2026-09-21)

Server core live on the reference Mac: Whisper large-v3-turbo transcribes
(4/4 synthetic), hybrid Qwen cleanup passes all 6 mandatory cases, 43 Bun
tests + 53 Swift tests green, and the redesigned SwiftUI Mac client builds.
Still ahead:
physical-device runs (mic, AX insertion, iPhone→Mac round trip, lifecycle,
latency/power) and human-speech evaluation — see `docs/CAPABILITY.md`.

## The Omil server core (Mac)

The normal Mac app needs no server command, host, or token. It creates a
private token, starts the bundled server on an available loopback port, and
prepares the selected models. Engine → Use another server is the explicit
override for a remote or separately managed service.

Server development and standalone iPhone/iPad hosting:

```sh
brew install whisper-cpp llama.cpp   # sidecar binaries (one time)
cd server && bun install
bun src/main.ts --download-models    # ~1.6 GB Whisper + ~2.5 GB Qwen, first run only
bun src/main.ts                      # serves http://127.0.0.1:3217 (token printed on first boot)
```

iPhone/iPad use the standalone server's LAN address and token. The managed
Mac server intentionally listens only on loopback.

```sh
cd server && bun test                # 43 tests
curl http://127.0.0.1:3217/v1/health # model readiness (no auth)
```

## Start here

- `docs/product-plan.md` — product and build plan
- `docs/research/on-device-speech-stack.md` — speech-stack survey
- `docs/research/wispr-flow-mac-ux.md` — first-party UX and feature research
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
