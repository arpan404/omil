# Omil

Omil is a free, local alternative to [Wispr Flow](https://wisprflow.ai) for Apple silicon Macs. The feature set is similar.

Hold Right Option, speak, and release. The text goes into the field you were using. You can start another recording while the previous one transcribes and cleans up. Clean mode removes fillers, applies spoken corrections, and copyedits grammar and spelling. Verbatim mode leaves the wording alone and only fixes spacing, capitalization, and punctuation. There is a personal dictionary, snippets, an editable cleanup prompt, and a history that stores the raw transcript, the edits, and the clean text. You can also start from a toggle shortcut, the menu bar, or a floating Start control. History can replay a saved recording or transcribe it again. The Engine screen is where you pick models. History keeps the latest 200 transcripts. On Mac, it renders rows lazily and loads 25 items at a time as you scroll. Search covers the entire retained history.

Wispr Flow needs an account, and the paid plan is what you use after the trial. Omil does not charge, and there is no account. Dictation stays on your Mac.

An iPhone or iPad can send recordings to the Mac over the local network. Each device has its own speech sensitivity and cleanup prompt. Omil has no Windows or Android app, and the iOS app and keyboard extension have not been tested on a physical device yet.

## Requirements

- An Apple silicon Mac on macOS 14 or later. Tested on macOS 26 with Xcode 26. Deployment target is macOS 14.
- To run the installed app: Homebrew for automatic installation of the speech-to-text and cleanup tools. If Homebrew is missing, Omil links to its install page and shows a manual command.
- To build the app: Xcode 26 or later, [Bun](https://bun.sh/), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Build

```sh
brew install bun xcodegen
git clone https://github.com/arpan404/omil.git
cd omil
./scripts/bootstrap-mac.sh
```

The script compiles the bundled server, type-checks and tests it, regenerates the Xcode project, and builds a Debug app. It prints the path to `Omil.app`.

A Release build, signed with the Developer ID Application certificate and installed over `/Applications/Omil.app`:

```sh
./scripts/build-local-mac.sh --install
```

Pass a version and build number when you want that install to carry them without editing project files:

```sh
./scripts/build-local-mac.sh --install 0.2.0 2
```

The build writes `Omil.app` to `.build/local-derived-data/Build/Products/Release/`. `--install` replaces `/Applications/Omil.app` and opens it. Signing uses team `5J88TLUP2J` and the hardened runtime, for both the app and the bundled Sparkle framework. This script installs locally. The release commands further down publish a notarized build. Install each build at `/Applications/Omil.app` so microphone, Accessibility, and Input Monitoring stay tied to the same app. Switching from an earlier ad hoc build may ask for those permissions once more.

On first launch, Omil uses Homebrew to install `whisper.cpp` and `llama.cpp` if their commands are missing, then downloads the selected models. If Homebrew is unavailable or installation fails, the Speech engine screen shows the install link, a manual command, and a retry button. Accessibility permission is what types into other apps. Input Monitoring is what makes the global shortcut work while Omil is in the background. Right-click the floating pill to hide it without stopping the recording. Settings → General → Floating pill offers Off, While dictating, and Always. Always leaves a draggable Start control on screen between recordings.

The model picker offers Whisper small Q8 and large-v3 turbo Q8 for transcription, plus Qwen3.5 0.8B, 2B, and 4B at Q4 for cleanup. New installs start with large-v3 turbo Q8 and Qwen3.5 2B. Previously downloaded models stay on disk when the catalog changes.

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

To create a downloadable Mac DMG locally, fill in `.env` using `.env.release.example`
as a reference. Keep your existing `.env` if you already have one. The local DMG
needs `APPLE_TEAM_ID`, `SPARKLE_PUBLIC_KEY`, and an App Store Connect team API
key. It detects your Developer ID Application certificate automatically, or uses
`DEVELOPER_ID_APPLICATION` if you set it. Password authentication is not used.

Create a team API key in [App Store Connect](https://appstoreconnect.apple.com/)
under Users and Access → Integrations → App Store Connect API → Team Keys. Save
its Key ID and Issuer ID, and download the `.p8` private key. Apple allows that key
to be downloaded only once. Store it outside the repository or under the ignored
`.build/signing/` directory. Set these values in your local `.env`:

```dotenv
APPLE_API_KEY_PATH="/absolute/path/to/AuthKey_YOURKEYID.p8"
APPLE_API_KEY_ID="YOURKEYID"
APPLE_API_ISSUER_ID="your-team-issuer-uuid"
```

These must be credentials for a team API key, not an individual API key. The same
API key authenticates Mac notarization and Xcode's iOS provisioning. Give the key
access to the signing and provisioning resources required by your team. Read
[Apple's API key setup](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
for permissions and key creation. Private `.p8` files are ignored by git.

```sh
./scripts/distribute-mac.sh --check
./scripts/distribute-mac.sh
# Optional version and build number for this build:
./scripts/distribute-mac.sh 0.2.0 2
```

The script builds your current working tree, including uncommitted changes, and
creates a signed and notarized Apple silicon build for macOS 14 or later. It waits
for Apple to accept the submission, staples the ticket, checks Gatekeeper, and
creates a signed and
notarized DMG with a custom installer window and an Applications shortcut. Open
the DMG, drag Omil.app onto Applications, eject the image, and launch Omil from
Applications. Launching directly from the image offers to install and open the
app before starting permissions or engine setup. Existing installations use
Finder's replacement flow. The DMG, SHA-256 checksum, and Apple
diagnostics go into a new folder under `.build/distribution/`. It does not install
the app or publish a release. Shell credentials override `.env`. The local DMG
does not need a GitHub token or Sparkle private key.

To build iOS locally for manual App Store upload, configure the team API credentials
above, install your Apple Distribution certificate, and run:

```sh
./scripts/distribute-ios.sh --check
./scripts/distribute-ios.sh
# Optional version and build number:
./scripts/distribute-ios.sh 0.2.0 2
```

The default `IOS_EXPORT_METHOD=app-store-connect` creates a signed IPA and retains
`OmilIOS.xcarchive` in a new folder under `.build/distribution/`. Upload the IPA
manually using Transporter, or open the archive in Xcode Organizer. The script
checks the app and keyboard signatures, profile expiry, bundle IDs, versions, and
App Group entitlements. It does not upload or publish the iOS app. For registered
test devices, you can explicitly set `IOS_EXPORT_METHOD=release-testing`.

To publish the Mac app on GitHub, set a release version and bump its build number:

```sh
./scripts/release.sh prepare 0.2.0
```

Commit and push the changes. Fill in the credentials listed in
[`.env.release.example`](.env.release.example), keeping your existing `.env`.
Publishing requires GitHub authentication, Mac notarization credentials, and both
Sparkle keys. Shell credentials override `.env`.

```sh
./scripts/release.sh status
./scripts/release.sh publish
# Optional reviewed notes, or a draft for inspection:
./scripts/release.sh publish --notes-file RELEASE_NOTES.md --draft
```

`publish` requires a clean worktree whose commit is pushed to its upstream. It
builds a notarized installer DMG, generates `CHANGELOG.md` from commits
since the previous stable GitHub Release, and includes release notes, a commit
manifest, and `SHA256SUMS`. All files and Apple diagnostics remain in
`.build/distribution/GitHub-release.*` if a step fails.

Choose Omil → Check for Updates from the app menu, or use the menu-bar panel.
When a new version is available, the sidebar shows its version and an Update Now
button that opens the download and installation flow without entering Settings.
Automatic checks are enabled by default and respect an existing user preference.

The Mac updater uses
`https://github.com/arpan404/omil/releases/latest/download/appcast.xml`.
The script generates that feed with the Sparkle private key, verifies the DMG's
Ed25519 signature against the public key embedded in the app, and checks the
download URL and build number. Build numbers must increase above the previous
feed so existing installations detect updates. Every asset uploads to a draft
before a stable release becomes GitHub's latest release. `--draft` keeps it
unpublished; `--prerelease` publishes without replacing the stable updater feed.

GitHub releases contain only the Mac distribution and its release metadata.
GitHub is the automatic update source for the Mac app. iOS builds stay local for
manual upload to Apple. The DMG is the only app download published on GitHub and
is also used by Sparkle for automatic updates.

While the Mac app is running and automatic update checks are enabled, it quietly
checks for sidebar update availability every 4 minutes 30 seconds to 5 minutes
30 seconds, choosing a fresh random interval each time. It also checks on launch
and checks when returning to the foreground if the next check is due. Checks wait
when Sparkle is busy; sleeping Macs do not check until they wake. Manual checks
remain available from the menu and settings.

Run `/usr/bin/python3 scripts/tests/release-workflow.py` to check the release
workflow. It uses temporary Git repositories and mocked Apple/GitHub operations,
with real Ed25519 signature verification. It covers successful publication,
a failed Mac build, an invalid updater signature, and prerelease handling.

## Limits

- Dictation is English only.
- Automatic tool installation requires Homebrew and an internet connection.
- The first run downloads the selected model weights.
- Mobile recording, keyboard handoff, background behavior, latency, and power use have not been checked on a device.
- Repeatable speech tests use synthetic audio. Human-speech evaluation has not been run.

## Repository layout

| Path | What it is |
| --- | --- |
| `Apps/Mac`, `Apps/iOS`, `Apps/Keyboard` | The Mac app, the iPhone and iPad app, and the keyboard extension |
| `Sources/OmilCore`, `Sources/OmilDesign` | Shared Swift code: dictation pipeline, keyboard link, design tokens |
| `Sources/OmilEval` | Command-line speech evaluation |
| `Tests` | Swift tests |
| `server` | The local speech and cleanup server (Bun) bundled into the Mac app |
| `scripts` | Build, signing, release and verification scripts |
| `docs` | Architecture notes and research |
| `marketing/site` | The website (Astro) |
| `marketing/video` | The launch film (Remotion), which also renders the website's media |
| `project.yml` | XcodeGen spec for `Omil.xcodeproj` |

[How Omil works](docs/SYSTEM.md) is the architecture writeup.
