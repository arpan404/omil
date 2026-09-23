# Omil

Omil is a free, local alternative to [Wispr Flow](https://wisprflow.ai) for Apple silicon Macs. The feature set is similar.

Hold Right Option, speak, and release. The text goes into the field you were using. Clean mode strips fillers, applies spoken corrections, and tidies repeated words and numbers. Verbatim mode leaves the wording alone and only fixes spacing, capitalization, and punctuation. There is a personal dictionary, snippets, an editable cleanup prompt, and a history that stores the raw transcript, the edits, and the clean text. You can also start from a toggle shortcut, the menu bar, or a floating Start control. History can replay a saved recording or transcribe it again. The Engine screen is where you pick models.

Wispr Flow needs an account, and the paid plan is what you use after the trial. Omil does not charge, and there is no account. Dictation stays on your Mac.

An iPhone or iPad can send recordings to the Mac over the local network. Each device has its own speech sensitivity and cleanup prompt. Omil has no Windows or Android app, and the iOS app and keyboard extension have not been tested on a physical device yet.

## Requirements

- An Apple silicon Mac on macOS 14 or later. Tested on macOS 26 with Xcode 26. Deployment target is macOS 14.
- Xcode 26 or later, [Bun](https://bun.sh/), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- The speech-to-text and cleanup command-line tools named in [How Omil works](docs/SYSTEM.md).

## Build

```sh
brew install bun xcodegen
git clone https://github.com/arpan404/omil.git
cd omil
./scripts/bootstrap-mac.sh
```

The script compiles the bundled server, type-checks and tests it, regenerates the Xcode project, and builds a Debug app. It prints the path to `Omil.app`.

A Release build, signed with your Apple Development certificate and installed over `/Applications/Omil.app`:

```sh
./scripts/build-local-mac.sh --install
```

Pass a version and build number when you want that install to carry them without editing project files:

```sh
./scripts/build-local-mac.sh --install 0.2.0 2
```

The build writes `Omil.app` to `.build/local-derived-data/Build/Products/Release/`. `--install` replaces `/Applications/Omil.app` and opens it. Signing uses team `BVT55BT25R` and the hardened runtime, for both the app and the bundled Sparkle framework. This script installs locally. The release commands further down publish a notarized build. Install each build at `/Applications/Omil.app` so microphone, Accessibility, and Input Monitoring stay tied to the same app. Switching from an earlier ad hoc build may ask for those permissions once more.

On first launch, Omil asks for the microphone and downloads the selected models. Accessibility permission is what types into other apps. Input Monitoring is what makes the global shortcut work while Omil is in the background. Right-click the floating pill to hide it without stopping the recording. Settings → General → Floating pill offers Off, While dictating, and Always. Always leaves a draggable Start control on screen between recordings.

Dictation started from the Omil window or menu bar returns to the last field in another app when that field is still there. If focus moved, the transcript stays in Omil.

Speech sensitivity is separate on Mac and iPhone. Balanced is the default. Distant voice keeps quieter or shorter speech. Filter more noise is less likely to treat background sound as speech.

## Development

Swift package tests:

```sh
swift test
```

Server tests:

```sh
cd server
bun install
bun test
```

After editing `project.yml`:

```sh
xcodegen generate
git diff -- Omil.xcodeproj
```

Set a release version and bump its build number:

```sh
./scripts/release.sh prepare 0.2.0
```

Commit and push that change. Copy [`.env.release.example`](.env.release.example) to `.env` and fill in the credentials. Shell credentials override `.env`.

```sh
cp .env.release.example .env
./scripts/release.sh status
./scripts/release.sh publish --notes-file RELEASE_NOTES.md
```

`publish` writes `Omil-<version>.zip` and `appcast.xml`, signs the update with Sparkle's EdDSA key, and uploads both to a GitHub Release. The app reads `appcast.xml` from the latest release.

## Limits

- Dictation is English only.
- The command-line tools listed under Requirements must already be installed on the Mac.
- The first run downloads the selected model weights.
- Mobile recording, keyboard handoff, background behavior, latency, and power use have not been checked on a device.
- Repeatable speech tests use synthetic audio. Human-speech evaluation has not been run.

[How Omil works](docs/SYSTEM.md) is the architecture writeup.
