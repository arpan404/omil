#!/bin/bash
# One-command Mac setup: Xcode project -> ad-hoc build.
# Run from the repo root. Requires: Xcode 26+, xcodegen.
# The inference server runs separately (see docs/BUILD.md); this app is a
# pure client and embeds no engine.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> generating Xcode project"
xcodegen generate

echo "==> building OmilMac (ad-hoc sign, local run)"
xcodebuild -project Omil.xcodeproj -scheme OmilMac -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" build

APP=$(find ~/Library/Developer/Xcode/DerivedData/Omil-*/Build/Products/Debug -maxdepth 1 -name "OmilMac.app" | head -n 1)
echo "==> app: $APP"
echo "Run the server first: (cd server && bun src/main.ts)"
echo "Launch the app with: open \"$APP\""
