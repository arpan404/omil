#!/bin/bash
# One-command Mac setup: compile the owned server, then build the app.
# Run from the repo root. Requires: Xcode 26+, xcodegen.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> compiling the bundled Effect/Bun server"
./scripts/build-server.sh

echo "==> generating Xcode project"
xcodegen generate

echo "==> building OmilMac (development sign, local run)"
# Use the team that owns the installed certificate. Ad-hoc builds change their
# signing requirement on each build and lose macOS privacy permission identity.
read -r OMIL_SIGNING_IDENTITY OMIL_DEVELOPMENT_TEAM < <(python3 - <<'SIGNING'
import re
import subprocess

identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
match = re.search(r'([A-F0-9]{40}) "Apple Development: [^\n]*\(([A-Z0-9]+)\)"', identities)
if match:
    print(match[1], match[2])
SIGNING
) || true
if [[ -z "${OMIL_SIGNING_IDENTITY:-}" ]]; then
  echo "Add an Apple Development certificate in Xcode Settings > Accounts, then run this script again." >&2
  exit 1
fi
xcodebuild -project Omil.xcodeproj -scheme OmilMac -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$OMIL_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$OMIL_DEVELOPMENT_TEAM" build

APP=$(find ~/Library/Developer/Xcode/DerivedData/Omil-*/Build/Products/Debug -maxdepth 1 -name "Omil.app" | head -n 1)
echo "==> app: $APP"
echo "Launch the app with: open \"$APP\""
