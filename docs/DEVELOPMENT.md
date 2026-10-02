# Build from source

You need Xcode 26 or later, [Bun](https://bun.sh/), and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Builds are tested on macOS 26.

```sh
brew install bun xcodegen
git clone https://github.com/arpan404/omil.git
cd omil
./scripts/bootstrap-mac.sh
```

The bootstrap script runs `build-local-mac.sh`. It builds and tests the bundled server, regenerates the Xcode project, and builds a signed Release app. It requires a Developer ID Application certificate for the configured Apple team. See [release credentials](RELEASING.md#credentials) for signing setup.

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

