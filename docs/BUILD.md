# Omil build, run, and device-validation guide

## Requirements

- macOS 26.x with Xcode 26.x (verified: macOS 26.2, Xcode 26.6, Swift 6.3)
- Apple-silicon Mac for the Mac app; iOS 17+ / macOS 14+ deployment targets
- `xcodegen` (`brew install xcodegen`) to regenerate `Omil.xcodeproj`
- No SwiftPM dependencies — `Package.swift` has zero external packages

## Layout

- `Sources/OmilCore` — shared package: audio, transcription, cleanup, session, delivery
- `Sources/OmilEval` — `omil-eval` command (corpus eval, bench, probe, asr-eval, debug)
- `Tests/OmilCoreTests` — 53 tests + `Fixtures/corpus.json` (25 cases) + synthetic TTS audio
- `Apps/Mac` — menu-bar Mac app (`OmilMac`)
- `Apps/iOS` — containing app (`OmilIOS`)
- `Apps/Keyboard` — keyboard extension (`OmilKeyboard`)
- `project.yml` — xcodegen spec; `Omil.xcodeproj` is generated (committed for convenience)

## Core package (no signing needed)

```sh
swift build
swift test                       # 53 tests, all headless
swift run omil-eval --corpus Tests/OmilCoreTests/Fixtures/corpus.json
swift run omil-eval --bench      # cleanup latency + mock session round trip
swift run omil-eval --probe      # device, backend availability, negotiated format
swift run omil-eval --asr-eval   # on-device Apple inference over synthetic TTS
swift run omil-eval --debug "make it 42, sorry 21"   # tokens + edits + journal
```

## Omil server core (inference; owned by the Mac app)

```sh
brew install whisper-cpp llama.cpp   # sidecar binaries (one time)
cd server && bun install
bun src/main.ts --download-models    # ~1.6 GB + ~2.5 GB, first run only (detached-safe)
bun src/main.ts                      # standalone development / mobile-LAN hosting
cd server && bun test                # 43 tests
```

- `GET /v1/health` — readiness, no auth, never downloads.
- `POST /v1/models/prepare` authenticates, downloads, verifies, and pins selected models. Send `{ "model": "<catalog-id>" }` to prepare only one model.
- `POST /v1/transcribe?language=en` — WAV bytes, Bearer token → transcript + segments.
- `POST /v1/cleanup` — `{text, mode, dictionary, snippets, style}` → cleaned text + grounded edits + abstentions and personalization metadata.
- The Mac app uses its own data directory and 0600 token, binds to loopback,
  selects a free port, launches the bundled binary, and stops it on exit.
- Engine → Use another server opts out of the managed process and stores the
  chosen host, port, and token.
- iPhone/iPad connect to a standalone server using the Mac's LAN address.

## Mac app (direct-distribution build)

One command (Xcode project → ad-hoc build):

```sh
./scripts/bootstrap-mac.sh
```

The build embeds the compiled Effect/Bun server. Launching the app is enough;
no terminal command, host, or token is required for local dictation:

```sh
open ~/Library/Developer/Xcode/DerivedData/Omil-*/Build/Products/Debug/OmilMac.app
```

Manual equivalent of bootstrap:

```sh
./scripts/build-server.sh
xcodegen generate   # only after editing project.yml
xcodebuild -project Omil.xcodeproj -scheme OmilMac -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" build
open ~/Library/Developer/Xcode/DerivedData/Omil-*/Build/Products/Debug/OmilMac.app
```

Release signing (requires credentials): sign the same target with
`Developer ID Application: …` + hardened runtime, then notarize:

```sh
xcodebuild -project Omil.xcodeproj -scheme OmilMac -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application: Arpan Bhandari (5J88BTUP2J)" build
xcrun notarytool submit <OmilMac.zip> --wait --keychain-profile omil-notary
```

Remaining distribution steps if credentials are unavailable: create the
notary keychain profile, staple the ticket, dish out the `.dmg`. No code
changes are needed. Do NOT publish a release without authorization.

### Mac test run (for the tester)

1. Launch `OmilMac.app` — the mic icon appears in the menu bar and the main
   Omil window opens. First launch shows guided onboarding while the owned
   server starts and prepares its models. If no window appears, click the menu-bar
   icon → Open Omil.
2. Engine shows the managed local endpoint and model-preparation status.
   Use another server only when intentionally moving inference elsewhere.
3. Dictate tab (or the floating pill while recording): first Start prompts for **microphone access**; grant it.
   Without it, Start fails with an actionable message.
3. Focus a text field in another app (e.g. TextEdit), then Start (big round
   button, menu bar, hold Right Option, or Ctrl+Option+O). Speak, then Stop.
   Watch the live draft + timer, then Raw / Cleaned / Diff tabs.
4. With **Accessibility** granted (Settings → Permissions → Ask for
   access…), text is inserted into the focused field and Undo reverses only
   Omil's insertion. Without it, Omil copies the result and guides manual
   paste — prior clipboard contents are restored only if untouched.
5. Models tab: **Install prerequisites** (one button), switch Whisper/rewrite
   models, override the rewrite prompt, restart the owned server, reveal logs.
6. Try the guards: click elsewhere mid-processing (result retained for
   explicit "Insert again"), Cancel mid-recording (nothing inserted),
   type after insertion then Undo (refused).

### Mac first-run permissions (all runtime-prompted, all optional-degradable)

1. Microphone (recording) — without it, recording fails with a clear error.
2. Accessibility (direct insertion) — without it, Omil keeps the result and
   offers explicit copy/paste recovery instead of failing.
3. Input Monitoring (background push-to-talk) — without it, use the menu-bar
   Start/Stop buttons or the toggle shortcut while the app is frontmost.

## iOS app + keyboard (simulator, no signing needed)

```sh
xcodebuild -project Omil.xcodeproj -scheme OmilIOS -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=No build
```

Device install requires: Apple Development signing, the App Group
`group.com.omil.shared` registered to the App ID, and the keyboard enabled in
Settings → General → Keyboard → Keyboards with **Full Access** (otherwise the
keyboard shows an explicit "needs Full Access" state and inserts nothing).

## Model assets

- The app-owned Effect/Bun service owns Whisper and Qwen model downloads.
- The Mac app does not download or run Apple Speech assets.
- `bun src/main.ts --download-models` installs the selected server models.
- Model files stay on the server Mac and are verified before use.

Offline check: finish model preparation, disconnect the WAN, then dictate from
the Mac app. No third-party connection is used.

## Device-validation checklist (physical hardware)

- [ ] Mac: push-to-talk → speak → release → text appears in TextEdit/Pages;
      destination change (click elsewhere mid-processing) retains the result.
- [ ] Mac: cancel mid-recording inserts nothing; undo reverses only Omil's text.
- [ ] Mac: clipboard fallback restores the prior clipboard; newer user copies win.
- [ ] iPhone: in-app record → Stop → result; switch to Notes → Omil keyboard →
      Insert appears exactly once; second tap does nothing.
- [ ] iPhone: keyboard without Full Access shows the reactivation state.
- [ ] iPhone: background/lock/interrupt/suspend/terminate matrix per CAPABILITY.md.
- [ ] Airplane-mode run after asset install (app traffic vs system assets).
- [ ] Consented human recordings replacing the synthetic fixtures.

## Regenerating the project

```sh
xcodegen generate
git diff Omil.xcodeproj   # review before committing
```
