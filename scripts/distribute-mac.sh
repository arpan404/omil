#!/bin/bash
# Build a signed, notarized ZIP from the current working tree. No publishing.
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage: ./scripts/distribute-mac.sh [--check] [version build-number]

Loads the repository's .env, preserving values already exported in your shell.
Builds the Mac app and server, signs with Developer ID, notarizes with Apple,
staples the ticket, verifies Gatekeeper acceptance, and creates a local ZIP.
The build includes uncommitted changes and does not publish or install anything.

Required: APPLE_TEAM_ID, SPARKLE_PUBLIC_KEY
Notarization: APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
Optional: DEVELOPER_ID_APPLICATION (otherwise auto-detected for APPLE_TEAM_ID)

--check validates local tools, credentials, and the signing identity without
building or uploading. Outputs go into a new directory under .build/distribution.
USAGE
}

fail() { echo "error: $*" >&2; exit 1; }

case ${1:-} in
  -h|--help) usage; exit 0 ;;
esac
check_only=false
if [[ ${1:-} == --check ]]; then check_only=true; shift; fi
[[ $# -eq 0 || $# -eq 2 ]] || { usage >&2; exit 1; }
if [[ $# -eq 2 ]]; then
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "invalid version"
  [[ $2 =~ ^[1-9][0-9]*$ ]] || fail "build number must be a positive integer"
fi

# shellcheck source=scripts/release-env.sh
source scripts/release-env.sh

for tool in bun xcodegen xcodebuild codesign security xcrun ditto shasum spctl; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[[ -x /usr/bin/python3 ]] || fail "Xcode's Python 3 is required"
xcrun --find notarytool >/dev/null || fail "notarytool is unavailable; select a full Xcode installation"
xcrun --find stapler >/dev/null || fail "stapler is unavailable"
[[ ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || fail "set APPLE_TEAM_ID in .env"
[[ ${SPARKLE_PUBLIC_KEY:-} =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "set SPARKLE_PUBLIC_KEY to your base64 Ed25519 public key"
configure_apple_api_auth

identities=$(security find-identity -v -p codesigning)
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
  selected=$(printf '%s\n' "$identities" | awk -v identity="$DEVELOPER_ID_APPLICATION" -v team="$APPLE_TEAM_ID" '
    index($0, "\"Developer ID Application:") && index($0, "(" team ")\"") &&
    ($2 == identity || index($0, "\"" identity "\"")) { print $2 }
  ')
else
  selected=$(printf '%s\n' "$identities" | awk -v team="$APPLE_TEAM_ID" '
    index($0, "\"Developer ID Application:") && index($0, "(" team ")\"") { print $2 }
  ')
fi
[[ -n $selected && $selected != *$'\n'* ]] || fail "expected one valid Developer ID Application identity for $APPLE_TEAM_ID; inspect security find-identity -v -p codesigning"
export DEVELOPER_ID_APPLICATION="$selected" APPLE_TEAM_ID SPARKLE_PUBLIC_KEY
echo "Local release prerequisites verified for team $APPLE_TEAM_ID."
if [[ $check_only == true ]]; then exit 0; fi

./scripts/build-local-mac.sh "$@"
mkdir -p .build/distribution
output_dir=$(distribution_directory)
app="$output_dir/Omil.app"
ditto .build/local-derived-data/Build/Products/Release/Omil.app "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
submission_zip="$output_dir/notarization-upload.zip"
result_json="$output_dir/notarization-result.json"

codesign --verify --deep --strict "$app"
codesign --verify --strict "$app/Contents/Resources/omil-server"
/usr/bin/python3 scripts/verify-mac-signing.py "$app" "$APPLE_TEAM_ID"
echo "==> submitting Omil $version ($build) to Apple; waiting for notarization"
ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_zip"
submit_exit=0
xcrun notarytool submit "$submission_zip" "${notary_auth[@]}" \
  --wait --output-format json > "$result_json" || submit_exit=$?
json_field() {
  /usr/bin/python3 - "$result_json" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get(sys.argv[2], ""))
except (ValueError, OSError):
    pass
PY
}
submission_id=$(json_field id)
status=$(json_field status)
if [[ -n $submission_id ]]; then
  echo "Notarization submission: $submission_id ($status)"
  xcrun notarytool log "$submission_id" "${notary_auth[@]}" "$output_dir/notarization-log.json" \
    || echo "Could not retrieve Apple's diagnostic log." >&2
fi
[[ $submit_exit -eq 0 && $status == Accepted ]] \
  || fail "notarization was not accepted; inspect $result_json and notarization-log.json in $output_dir"

echo "==> stapling and verifying notarization"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

zip_name="Omil-${version}-${build}-macos-arm64.zip"
zip_path="$output_dir/$zip_name"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"
# Verify the actual shipped ZIP, including its stapled ticket.
verification_dir="$output_dir/verification"
mkdir "$verification_dir"
ditto -x -k "$zip_path" "$verification_dir"
codesign --verify --deep --strict "$verification_dir/Omil.app"
codesign --verify --strict "$verification_dir/Omil.app/Contents/Resources/omil-server"
xcrun stapler validate "$verification_dir/Omil.app"
spctl --assess --type execute --verbose=2 "$verification_dir/Omil.app"
rm -rf "$verification_dir"
rm "$submission_zip"
(cd "$output_dir" && shasum -a 256 "$zip_name" > "$zip_name.sha256")
printf '\nNotarized ZIP: %s\nChecksum: %s.sha256\nApple logs: %s\n' "$zip_path" "$zip_path" "$output_dir"
