#!/bin/bash
# Package a notarized app with a drag-to-Applications install shortcut.
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
[[ $# -eq 2 ]] || { echo 'Usage: build-mac-dmg.sh <notarized-app> <output-dmg>' >&2; exit 1; }
app=$1
dmg=$2
[[ -d $app && ! -e $dmg ]] || { echo 'error: app missing or DMG already exists' >&2; exit 1; }
# shellcheck source=scripts/release-env.sh
source scripts/release-env.sh
[[ -n ${DEVELOPER_ID_APPLICATION:-} && -n ${APPLE_TEAM_ID:-} ]] || { echo 'error: signing identity and team required' >&2; exit 1; }
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
/usr/bin/python3 scripts/verify-mac-signing.py "$app" "$APPLE_TEAM_ID"
work=$(mktemp -d "$(dirname "$dmg")/dmg-work.XXXXXX")
mount="$work/mounted"
mounted=false
cleanup() {
  if [[ $mounted == true ]]; then hdiutil detach "$mount" -quiet || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
mkdir "$mount"
# Build tooling lives in an isolated cache, not in the system Python installation.
tools="$PWD/.build/release-tools/dmgbuild-1.6.5"
if [[ ! -x "$tools/bin/dmgbuild" ]]; then
  /usr/bin/python3 -m venv "$tools"
  "$tools/bin/python" -m pip install --disable-pip-version-check 'dmgbuild==1.6.5'
fi
xcrun swift scripts/dmg/background.swift "$work/background.png"
"$tools/bin/dmgbuild" -s scripts/dmg/settings.py -D "app=$app" \
  -D "background=$work/background.png" 'Omil' "$dmg"
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$dmg"
./scripts/notarize-file.sh "$dmg" "${dmg%.dmg}-notarization"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
hdiutil verify "$dmg"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount"
mounted=true
"$tools/bin/python" scripts/dmg/verify-layout.py "$mount"
[[ $(readlink "$mount/Applications") == /Applications ]] || { echo 'error: missing Applications shortcut' >&2; exit 1; }
codesign --verify --deep --strict "$mount/Omil.app"
xcrun stapler validate "$mount/Omil.app"
spctl --assess --type execute --verbose=2 "$mount/Omil.app"
hdiutil detach "$mount" -quiet
mounted=false
(cd "$(dirname "$dmg")" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "Notarized installer DMG: $dmg"
