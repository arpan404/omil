#!/bin/bash
# One-command Mac setup: server binary -> Xcode project -> ad-hoc build.
# Run from the repo root. Requires: bun, Xcode 26+, ~5 GB free for models
# (downloaded later, in-app, with one button).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> building inference server binary"
./scripts/build-server.sh

echo "==> generating Xcode project"
xcodegen generate

echo "==> building OmilMac (ad-hoc sign, local run)"
xcodebuild -project Omil.xcodeproj -scheme OmilMac -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" build

APP=$(find ~/Library/Developer/Xcode/DerivedData/Omil-*/Build/Products/Debug -maxdepth 1 -name "OmilMac.app" | head -n 1)
echo "==> app: $APP"
echo "Launch it with: open \"$APP\""
