# Omil

Free dictation for Apple silicon Macs. Hold Right Option, speak, and let go. Omil types the text into the field you were using.

It does what [Wispr Flow](https://wisprflow.ai) does, but it runs on your Mac. There is no account and nothing to pay.

[Download the latest release](https://github.com/arpan404/omil/releases/latest), open the DMG, and drag Omil to Applications. It needs macOS 14 or later.

## What it does

- Clean mode removes fillers, follows spoken corrections ("Friday. No wait, Thursday."), and fixes grammar and spelling.
- Verbatim mode keeps your wording and only fixes spacing, capitalization, and punctuation.
- A dictionary corrects names and terms it mishears. Snippets expand a short phrase into longer text. You can edit the cleanup prompt.
- History keeps the last 200 dictations with the raw transcript, the edits, and the clean text. You can search it, replay a recording, or transcribe it again.
- You can start the next recording while the last one is still being cleaned up.
- Besides holding the key, you can start from a toggle shortcut, the menu bar, or a floating Start control.
- An iPhone or iPad can send recordings to the Mac over the local network. This has not been tested on a physical device yet.

## First launch

Omil uses Homebrew to install `whisper.cpp` and `llama.cpp` if they are missing, then downloads the models you selected. Without Homebrew, the Engine screen shows the install link, a command to run yourself, and a retry button.

It asks for three permissions:

- Microphone, to record.
- Accessibility, to type into other apps.
- Input Monitoring, so the shortcut works while Omil is in the background.

The Engine screen is where you pick models. Speech: Whisper small Q8 or large-v3 turbo Q8. Cleanup: Qwen3.5 0.8B, 2B, or 4B at Q4. New installs start with large-v3 turbo Q8 and Qwen3.5 2B.

## Settings worth knowing

- Settings → General → Floating pill: Off, While dictating, or Always. Always keeps a draggable Start control on screen. Right-click the pill to hide it without stopping the recording.
- Speech sensitivity: Balanced is the default. Distant voice keeps quieter speech. Filter more noise ignores more background sound. Mac and iPhone each have their own setting.
- If you start dictation from the Omil window or the menu bar, the text goes to the last field you used in another app. If that field is gone, the text stays in Omil.

## Build from source

You need Xcode 26 or later, [Bun](https://bun.sh/), and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Builds are tested on macOS 26.

```sh
brew install bun xcodegen
git clone https://github.com/arpan404/omil.git
cd omil
./scripts/bootstrap-mac.sh
```

The script builds and tests the bundled server, regenerates the Xcode project, builds a Debug app, and prints the path to `Omil.app`.

For a signed Release build installed over `/Applications/Omil.app`:

```sh
./scripts/build-local-mac.sh --install
./scripts/build-local-mac.sh --install 0.2.0 2   # with a version and build number
```

Always install to `/Applications/Omil.app`. macOS ties the three permissions to that app, so a copy somewhere else asks for them again.

## Tests

```sh
swift test                          # Swift packages
cd server && bun install && bun test   # server
```

After editing `project.yml`, run `xcodegen generate` and review `git diff -- Omil.xcodeproj`.

## Limits

- English only.
- Installing the speech tools needs Homebrew and an internet connection. The first run also downloads the model weights.
- The iOS app and keyboard have not been checked on a device: recording, handoff, background behavior, latency, and power use are all untested.
- Speech tests use synthetic audio. No evaluation with human speech has been run.
- No Windows or Android app.

## Repository layout

| Path | What it is |
| --- | --- |
| `Apps/Mac`, `Apps/iOS`, `Apps/Keyboard` | The Mac app, the iPhone and iPad app, and the keyboard extension |
| `Sources/OmilCore`, `Sources/OmilDesign` | Shared Swift code |
| `Sources/OmilEval` | Command-line speech evaluation |
| `Tests` | Swift tests |
| `server` | The local speech and cleanup server (Bun), bundled into the Mac app |
| `scripts` | Build, signing, and release scripts |
| `marketing/site` | The website (Astro) |
| `marketing/video` | The launch film (Remotion) |
| `project.yml` | XcodeGen spec for `Omil.xcodeproj` |

## More

- [How Omil works](docs/SYSTEM.md)
- [Building and publishing releases](docs/RELEASING.md)
