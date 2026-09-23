# Omil

**Local dictation for Mac. A Wispr Flow alternative without cloud transcription.**

Talk naturally, and Omil puts your words into the app you were using. Whisper
transcribes; Qwen cleans up filler words and spoken corrections. Both run on
your Mac, with no account required.

## What you get

- Hold Right Option to dictate into the selected text field. You can also use
  the toggle shortcut, menu bar, or an always-visible floating Start control.
- Choose Clean or Verbatim. Add preferred spellings and snippets, or edit the
  cleanup prompt in Advanced settings.
- Compare Raw, Changes, and Clean versions in History. Replay saved recordings
  or transcribe them again.
- Adjust speech sensitivity for a distant voice or background noise.
- Keep the server private to your Mac, or enable local network sharing for an
  iPhone or iPad.

The Mac app is the primary client. The iOS app and keyboard extension are
still being tested on physical devices.

## How it works

The Mac app records audio and runs a local server. `whisper.cpp` transcribes
speech; `llama.cpp` runs the selected Qwen cleanup model. Omil checks proposed
edits before applying them. The Engine screen manages models and local network
access.

You can optionally connect an iPhone or iPad to the Mac server over your local
network. Each device sends its own speech sensitivity and cleanup prompt. The
server keeps those requests separate.

On Mac, Settings → General → Floating pill offers Off, While dictating, and
Always. Always keeps a draggable Start control on screen between recordings.

## Requirements

- An Apple silicon Mac running macOS 14 or later
- Xcode 26 or later
- [Bun](https://bun.sh/) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `whisper.cpp` and `llama.cpp` command-line tools
- About 4.1 GB for the default Whisper and Qwen models

The current toolchain is tested on macOS 26 with Xcode 26. The deployment
target remains macOS 14.

## Build the Mac app

Install the build tools and native inference sidecars:

```sh
brew install bun xcodegen whisper-cpp llama.cpp
```

Clone and build Omil:

```sh
git clone https://github.com/arpan404/omil.git
cd omil
./scripts/bootstrap-mac.sh
```

The script installs server dependencies, type-checks and tests the server,
compiles the bundled server, regenerates the Xcode project, and builds the Mac
app. It prints the path to `Omil.app` when it finishes.

To build a local Mac app in Release configuration with Apple Development signing, run:

```sh
./scripts/build-local-mac.sh --install
```

To give that build a different app version without editing project files, pass
the version and build number:

```sh
./scripts/build-local-mac.sh --install 0.2.0 2
```

The script builds the bundled server, regenerates the Xcode project, and puts
`Omil.app` in `.build/local-derived-data/Build/Products/Release/`. With `--install`,
it replaces `/Applications/Omil.app` and opens it. It requires
the Apple Development certificate for team `BVT55BT25R`; it does not notarize
or publish the app. Install each build at the same path (`/Applications/Omil.app`)
to keep macOS privacy permissions tied to the same app identity. Switching from
an earlier ad hoc build may require one final permission grant. The app and its
bundled Sparkle framework use the same signing identity with hardened runtime.

On first launch, Omil asks for microphone access and downloads the selected
models. Accessibility permission enables direct text insertion. Input
Monitoring permission enables global shortcuts when Omil is not focused.
Right-click the floating pill to hide it without stopping the recording.
The menu bar can show or hide the pill, and Settings offers all three display
modes.
The Omil window and menu bar can return to the last focused field in another
app when that field is still available. If focus changed, the transcript stays
in Omil.
Mac Settings and iPhone Settings each have a Speech sensitivity choice. Balanced
is the default. Distant voice can catch quieter or shorter speech, while Filter
more noise is less likely to treat background sound as speech. Each app sends
its own choice with the recording; these settings apply when using the Omil
server.

## Development

Run the Swift package tests:

```sh
swift test
```

Run the server tests:

```sh
cd server
bun install
bun test
```

After changing `project.yml`, regenerate and review the Xcode project:

```sh
xcodegen generate
git diff -- Omil.xcodeproj
```

Set a release version and increment its internal build number with:

```sh
./scripts/release.sh prepare 0.2.0
```

Commit and push that version change. Copy
[`.env.release.example`](.env.release.example) to `.env`, fill in the
credentials, and publish the signed, notarized release. The CLI loads `.env`
automatically, while credentials exported in your shell take precedence.

```sh
cp .env.release.example .env
./scripts/release.sh status
./scripts/release.sh publish --notes-file RELEASE_NOTES.md
```

The command creates `Omil-<version>.zip` and `appcast.xml`, signs the update
with Sparkle's EdDSA key, and uploads both files to a GitHub Release. The app
checks the `appcast.xml` attached to the latest release.

## Current limitations

- Dictation is English-only.
- The native `whisper-cli` and `llama-server` sidecars must be installed on the
  Mac.
- The first run downloads the selected model weights.
- Mobile recording, keyboard handoff, background behavior, latency, and power
  use have not been validated on physical devices.
- Human-speech evaluation is still pending. Current repeatable speech tests use
  synthetic audio fixtures.

## Documentation

[How Omil works](docs/SYSTEM.md) explains the runtime, dictation pipeline,
model lifecycle, local storage, insertion safeguards, and mobile handoff.
