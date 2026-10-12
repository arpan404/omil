# Omil App Store release package

Target: one iOS app for iPhone and iPad. Version 0.1.9, build 11 is the prepared archive candidate. This package is not an Apple submission; read [release readiness](READINESS.md) before uploading.

## What to upload

- `screenshots/iphone/*.png`: five 6.9-inch iPhone screenshots, 1320 × 2868.
- `screenshots/ipad/*.png`: five 13-inch iPad screenshots, 2064 × 2752.
- `en-US/*.txt`: paste the matching fields into App Store Connect. Release notes may not be requested for a first release.
- `APP-REVIEW-NOTES.txt`: review instructions, after resolving the documented blockers.
- `app-store-connect.json`: bundle IDs, suggested category/pricing, versions, URLs, and locale.
- `PRIVACY-AND-COMPLIANCE.md`: source-backed privacy, export, and questionnaire guidance.
- `source/`: editable screenshot layout, headline copy, font, and icon.
- `screenshots/raw/`: unmodified simulator captures for reproducing the layouts.

Upload the five images in numeric filename order for each device family. Both sets show the same real functionality using device-specific UI. The metadata prominently discloses the user's Mac requirement. Do not upload `raw` and designed screenshots together unless you deliberately want both.

## Recreate screenshots

From the repository root:

```sh
xcodegen generate
xcodebuild -project Omil.xcodeproj -scheme OmilIOS -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/app-store/simulator CODE_SIGNING_ALLOWED=NO build
python3 scripts/capture-app-store-screenshots.py \
  --app .build/app-store/simulator/Build/Products/Debug-iphonesimulator/OmilIOS.app
python3 scripts/render-app-store-screenshots.py
```

Open `http://127.0.0.1:4322/release/app-store/source/` and choose **Export all 10 screenshots**. Edit `source/screens.json` for headline copy and `source/index.html` for the layout. The default simulator IDs are iPhone 17 Pro Max and iPad Pro 13-inch M5 on iOS 26.5. Pass `--iphone` and `--ipad` to select other available simulators. The capture script replaces only those simulators' app fixture preferences and never touches the physical phone. Fixture launch arguments are Debug-only.

Validate assets with `python3 scripts/verify-app-store-artifacts.py`. `SHA256SUMS` records the submitted asset candidates and source. `SOURCE-PROVENANCE.json` records the capture dimensions and fixture basis.

## Build a distribution candidate

```sh
IOS_EXPORT_METHOD=app-store-connect ./scripts/distribute-ios.sh 0.1.9 11
```

The script does not upload or submit. It verifies the exported app and keyboard signatures, bundle IDs, App Groups, profiles, and versions. The current Apple account must resolve the provisioning blocker first. Use the next unused build number if 11 has already been uploaded. The Mac release version is unchanged.

## Public links

- Privacy policy: `https://omil.arpan.sh/privacy/`
- Support: `https://omil.arpan.sh/support/`
- Security: `https://omil.arpan.sh/security/`
- Terms: `https://omil.arpan.sh/terms/`

Website source is in `marketing/site/src/pages/` with shared copy in `marketing/site/src/data/policies.ts`. Keep the policy text aligned with the actual app behavior and verify the live URLs before submission.
