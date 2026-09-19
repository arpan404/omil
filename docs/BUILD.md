# Omil build, run, and device-validation guide

## Requirements

- macOS 26.x with Xcode 26.x (verified: macOS 26.2, Xcode 26.6, Swift 6.3)
- Apple-silicon Mac for the Mac app; iOS 17+ / macOS 14+ deployment targets
- `xcodegen` (`brew install xcodegen`) to regenerate `Omil.xcodeproj`
- No SwiftPM dependencies — `Package.swift` has zero external packages

## Layout

- `Sources/OmilCore` — shared package: audio, transcription, cleanup, session, delivery
- `Sources/OmilEval` — `omil-eval` command (corpus eval, bench, probe, asr-eval, debug)
- `Tests/OmilCoreTests` — 42 tests + `Fixtures/corpus.json` (25 cases) + synthetic TTS audio
- `Apps/Mac` — menu-bar Mac app (`OmilMac`)
- `Apps/iOS` — containing app (`OmilIOS`)
- `Apps/Keyboard` — keyboard extension (`OmilKeyboard`)
- `project.yml` — xcodegen spec; `Omil.xcodeproj` is generated (committed for convenience)

## Core package (no signing needed)

```sh
swift build
swift test                       # 47 tests, all headless
swift run omil-eval --corpus Tests/OmilCoreTests/Fixtures/corpus.json
swift run omil-eval --bench      # cleanup latency + mock session round trip
swift run omil-eval --probe      # device, backend availability, negotiated format
swift run omil-eval --asr-eval   # on-device Apple inference over synthetic TTS
swift run omil-eval --debug "make it 42, sorry 21"   # tokens + edits + journal
```

## Omil server core (inference; runs on your Mac)

```sh
brew install whisper-cpp llama.cpp   # sidecar binaries (one time)
cd server && bun install
bun src/main.ts --download-models    # ~1.6 GB + ~2.5 GB, first run only (detached-safe)
bun src/main.ts                      # http://127.0.0.1:3217; prints LAN token on first boot
cd server && bun test                # 13 tests
```

- `GET /v1/health` — readiness, no auth, never downloads.
- `POST /v1/transcribe?language=en` — WAV bytes, Bearer token → transcript + segments.
- `POST /v1/cleanup` — `{text, mode, dictionary}` → cleaned text + grounded edits + abstentions.
- Token: `server/data/omil-token` (0600). Rotate by deleting it and restarting.
- Auto-start: copy `server/com.omil.server.plist.example` to
  `~/Library/LaunchAgents/` (edit paths), `launchctl load` it.
- Mac app: Settings → General → Omil inference core (`127.0.0.1`, token).
  iPhone/iPad: same screen with the Mac's LAN address.

## Mac app (direct-distribution build)

One command (server binary → Xcode project → ad-hoc build):

```sh
./scripts/bootstrap-mac.sh
open ~/Library/Developer/Xcode/DerivedData/Omil-*/Build/Products/Debug/OmilMac.app
```

What bootstrap does: `scripts/build-server.sh` typechecks, tests, and
compiles `server/dist/omil-server` (standalone, no Bun at runtime);
`xcodegen generate` embeds it in the app; `xcodebuild` builds ad-hoc signed.

The Mac app owns the inference server: it launches the embedded engine at
startup, restarts it on crashes, and stops it on quit. First launch shows
Settings → General → **Install prerequisites** (one button): whisper.cpp +
llama.cpp sidecars (prebuilt Apple-silicon bottles fetched directly, SHA
verified, no Homebrew needed) plus the selected Whisper/Qwen weights with
progress. Switch Whisper/LLM models or override the rewrite prompt in the
same section; the server switches without reinstalling the app.

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

1. Launch `OmilMac.app` — the mic icon appears in the menu bar and the
   recorder window opens.
2. First Start prompts for **microphone access**; grant it. Without it,
   Start fails with an actionable message.
3. Focus a text field in another app (e.g. TextEdit), then Start in Omil
   (menu bar, recorder window, hold Right Option, or Ctrl+Option+O).
4. Speak, then Stop. Watch the live draft, then Raw / Cleaned / Diff tabs.
5. With **Accessibility** granted (Settings → Permissions → Ask for
   access…), text is inserted into the focused field and Undo reverses only
   Omil's insertion. Without it, Omil copies the result and guides manual
   paste — prior clipboard contents are restored only if untouched.
6. Try the guards: click elsewhere mid-processing (result retained for
   explicit "Insert again"), Cancel mid-recording (nothing inserted),
   type after insertion then Undo (refused).
7. Settings → General → Download system assets (explicit, versioned).
   Settings → Dictionary for confirmed substitutions. History tab for
   retention toggle + Clear (raw audio is never stored).

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

- Apple Speech (`SpeechTranscriber`, en-US): system-managed assets, already
  installed on the reference Mac (`omil-eval --probe` shows
  `assetState=ready`). No app download needed.
- Legacy fallback (`SFSpeechRecognizer`, on-device enforced): no download.
- No other model is bundled. Any future model pack must ship a manifest entry
  (`ModelManifestEntry`: version, languages, size, RAM class, license,
  checksum) and verify SHA-256 before install (`ModelAssets.verify`).

Offline check: install assets once, enable Airplane Mode, run
`omil-eval --asr-eval` — inference completes with no network.

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
