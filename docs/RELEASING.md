# Building and publishing releases

GitHub Releases carry the Mac DMG and its metadata, nothing else. The Mac app updates itself from there. iOS builds stay on your machine for manual upload to Apple.

## Credentials

Copy `.env.release.example` to `.env` and fill it in. Keep your existing `.env` if you have one. Values set in the shell override `.env`.

Create a team API key in [App Store Connect](https://appstoreconnect.apple.com/) under Users and Access → Integrations → App Store Connect API → Team Keys. It must be a team key, not an individual one. Note the Key ID and Issuer ID and download the `.p8` file. Apple lets you download it once. Keep it outside the repository or in `.build/signing/`, which git ignores.

```dotenv
APPLE_API_KEY_PATH="/absolute/path/to/AuthKey_YOURKEYID.p8"
APPLE_API_KEY_ID="YOURKEYID"
APPLE_API_ISSUER_ID="your-team-issuer-uuid"
```

The same key handles Mac notarization and iOS provisioning. [Apple's guide](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) covers the permissions it needs.

| Task | Also needs |
| --- | --- |
| Local Mac DMG | `APPLE_TEAM_ID`, `SPARKLE_PUBLIC_KEY`, a Developer ID Application certificate |
| Local iOS build | An Apple Distribution certificate |
| Publishing | GitHub authentication and both Sparkle keys |

The Developer ID certificate is found automatically. Set `DEVELOPER_ID_APPLICATION` to choose one. Signing uses team `5J88TLUP2J` and the hardened runtime, for the app and the bundled Sparkle framework.

## Mac DMG

```sh
./scripts/distribute-mac.sh --check
./scripts/distribute-mac.sh
./scripts/distribute-mac.sh 0.2.0 2   # with a version and build number
```

This builds your working tree, including uncommitted changes. It signs and notarizes the app, staples the ticket, checks Gatekeeper, and builds a notarized DMG with an Applications shortcut. The DMG, its SHA-256 checksum, and Apple's diagnostics go into a new folder under `.build/distribution/`.

It does not install the app or publish anything.

## iOS

```sh
./scripts/distribute-ios.sh --check
./scripts/distribute-ios.sh
./scripts/distribute-ios.sh 0.2.0 2
```

This writes a signed IPA and `OmilIOS.xcarchive` to a new folder under `.build/distribution/`. Upload the IPA with Transporter or open the archive in Xcode Organizer. The script checks the app and keyboard signatures, profile expiry, bundle IDs, versions, and App Group entitlements. It does not upload.

For registered test devices, set `IOS_EXPORT_METHOD=release-testing`.

## Publishing a Mac release

Set the version and bump the build number, then commit and push:

```sh
./scripts/release.sh prepare 0.2.0
```

Then publish:

```sh
./scripts/release.sh status
./scripts/release.sh publish
./scripts/release.sh publish --notes-file RELEASE_NOTES.md --draft
```

`publish` needs a clean worktree whose commit is pushed. It builds the notarized DMG, writes `CHANGELOG.md` from the commits since the last stable release, and uploads release notes, a commit manifest, and `SHA256SUMS`. If a step fails, everything stays in `.build/distribution/GitHub-release.*`.

Assets upload to a draft first, so a release only becomes "latest" when it is complete. `--draft` leaves it unpublished. `--prerelease` publishes without replacing the stable update feed.

## Updates

The app reads `https://github.com/arpan404/omil/releases/latest/download/appcast.xml`. `release.sh` signs that feed with the Sparkle private key, verifies the DMG's Ed25519 signature against the public key in the app, and checks the download URL and build number.

The build number must be higher than the previous release, or installed copies will not see the update.

With automatic checks on (the default), the running app checks at launch, when it returns to the foreground, and about every five minutes. When a new version exists, the sidebar shows it with an Update Now button. Omil → Check for Updates does the same by hand.

## Testing the release scripts

```sh
/usr/bin/python3 scripts/tests/release-workflow.py
```

It runs against temporary Git repositories with Apple and GitHub mocked, and real Ed25519 verification. It covers a successful release, a failed Mac build, an invalid update signature, and prereleases.
