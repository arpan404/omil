#!/bin/bash
# One-command Mac setup: compile the owned server, then build the app.
# Run from the repo root. Requires: Xcode 26+, xcodegen.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> compiling the bundled Effect/Bun server"
./scripts/build-server.sh

echo "==> generating Xcode project"
xcodegen generate

echo "==> building OmilMac (ad-hoc sign, local run)"
xcodebuild -project Omil.xcodeproj -scheme OmilMac -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" build

APP=$(find ~/Library/Developer/Xcode/DerivedData/Omil-*/Build/Products/Debug -maxdepth 1 -name "OmilMac.app" | head -n 1)
echo "==> app: $APP"
echo "Launch the app with: open \"$APP\""
