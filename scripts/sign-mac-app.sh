#!/bin/bash
# Sign nested code from the inside out, then seal the app.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || { echo 'Usage: sign-mac-app.sh <app> <identity> <team>' >&2; exit 1; }
app=$1
identity=$2
team=$3
sparkle="$app/Contents/Frameworks/Sparkle.framework"
# Sparkle's helpers are ad hoc signed in its prebuilt distribution. Xcode's
# Code Sign on Copy only signs the framework, not these nested helpers.
for component in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  target="$sparkle/Versions/B/$component"
  [[ -e $target ]] || { echo "error: missing Sparkle component: $target" >&2; exit 1; }
  if [[ $component == XPCServices/Downloader.xpc ]]; then
    codesign --force --sign "$identity" --options runtime --timestamp \
      --preserve-metadata=entitlements "$target"
  else
    codesign --force --sign "$identity" --options runtime --timestamp "$target"
  fi
done
codesign --force --sign "$identity" --options runtime --timestamp "$sparkle"
codesign --force --sign "$identity" --options runtime --timestamp \
  --entitlements Apps/Mac/OmilServer.entitlements "$app/Contents/Resources/omil-server"
codesign --force --sign "$identity" --options runtime --timestamp \
  --entitlements Apps/Mac/OmilMac.entitlements "$app"
codesign --verify --deep --strict "$app"
/usr/bin/python3 scripts/verify-mac-signing.py "$app" "$team"
