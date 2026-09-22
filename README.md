# Omil

Omil is local voice dictation for macOS. Hold Right Option, speak, and release
to insert the result into the app you were using. A selected Whisper model
transcribes the audio. A hybrid pipeline combines deterministic correction
rules with a selected Qwen model, then validates every proposed edit.

Inference runs on your Mac. Omil does not require an account or send recordings
to a hosted transcription service.

> Omil is under active development. The Mac app is the primary client. The iOS
> app and keyboard extension are present in the repository but still need
> physical-device validation.

## What it does

- Hold Right Option for push-to-talk, or press Control + Option + O to toggle
  recording.
- Review the raw transcript, cleaned text, and applied edits before reinserting
  a result.
- Add snippets, preferred spellings, and writing styles for different app
  categories.
- Insert text through macOS Accessibility, with a guarded clipboard fallback.
- Keep dictation history and preferences on the Mac.
- Follow the system appearance or choose a light or dark theme.
- Keep the inference server private to the Mac by default, or explicitly share
  it with an iPhone or iPad on the local network using generated credentials.
- Queue simultaneous transcription and cleanup requests without mixing the
  model, dictionary, snippet, style, or cleanup settings chosen by each client.

## How it works

The SwiftUI app records audio and manages a bundled Effect and Bun server. The
server calls `whisper.cpp` with one of nine transcription models and
`llama.cpp` with one of six cleanup models. The Engine screen controls model
selection, downloads, deletion, and local-network access. A validator rejects
cleanup edits that change the meaning of the transcript.

The managed server listens only on loopback until local-network sharing is
enabled. Omil then shows the endpoint and bearer token an iPhone or iPad needs
to use the same Mac-hosted engine. Transcription and cleanup have independent
single-worker queues so multiple devices can submit work safely.

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

On first launch, Omil asks for microphone access and downloads the selected
models. Accessibility permission enables direct text insertion. Input
Monitoring permission enables global shortcuts when Omil is not focused.

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
