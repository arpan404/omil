#!/bin/bash
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
# shellcheck source=scripts/release-env.sh
source scripts/release-env.sh
fail() { echo "error: $*" >&2; exit 1; }
usage() {
  echo 'Usage: ./scripts/distribute-ios.sh [--check] [version build-number]'
  echo 'Loads .env, archives iOS + keyboard, and exports a verified signed IPA.'
  echo 'IOS_EXPORT_METHOD: app-store-connect (manual upload, default) or release-testing (registered devices).'
  echo 'Requires APPLE_TEAM_ID, Apple Distribution certificate, and App Store Connect team API credentials.'
}
case ${1:-} in -h|--help) usage; exit 0 ;; esac
check_only=false
if [[ ${1:-} == --check ]]; then check_only=true; shift; fi
[[ $# -eq 0 || $# -eq 2 ]] || { usage >&2; exit 1; }
settings=()
if [[ $# -eq 2 ]]; then
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $2 =~ ^[1-9][0-9]*$ ]] || fail 'expected numeric version and positive build number'
  settings+=("MARKETING_VERSION=$1" "CURRENT_PROJECT_VERSION=$2")
fi
for tool in xcodebuild xcodegen codesign security ditto shasum; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
[[ ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || fail 'set APPLE_TEAM_ID in .env'
configure_apple_api_auth
method=${IOS_EXPORT_METHOD:-app-store-connect}
case $method in release-testing|app-store-connect) ;; *) fail 'IOS_EXPORT_METHOD must be release-testing or app-store-connect' ;; esac
security find-identity -v -p codesigning | awk -v team="$APPLE_TEAM_ID" '
  index($0, "\"Apple Distribution:") && index($0, "(" team ")\"") { found=1 }
  END { exit !found }
' || fail "no Apple Distribution identity for $APPLE_TEAM_ID in your keychain"
echo "iOS local prerequisites verified. Xcode checks provisioning during archive/export."
[[ $check_only == false ]] || exit 0
output_dir=$(distribution_directory)
archive="$output_dir/OmilIOS.xcarchive"
xcodegen generate
xcodebuild -project Omil.xcodeproj -scheme OmilIOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates "${provisioning_auth[@]}" archive CODE_SIGN_STYLE=Automatic \
  "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" ${settings[@]+"${settings[@]}"}
/usr/bin/python3 - "$output_dir/ExportOptions.plist" "$APPLE_TEAM_ID" "$method" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(method=sys.argv[3], teamID=sys.argv[2], signingStyle='automatic',
        signingCertificate='Apple Distribution', destination='export',
        manageAppVersionAndBuildNumber=False, stripSwiftSymbols=True), f)
PY
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output_dir/export" \
  -exportOptionsPlist "$output_dir/ExportOptions.plist" -allowProvisioningUpdates "${provisioning_auth[@]}"
ipas=("$output_dir/export/"*.ipa)
[[ ${#ipas[@]} -eq 1 && -f ${ipas[0]} ]] || fail 'export must contain exactly one IPA'
verification="$output_dir/verification"
mkdir "$verification"
ditto -x -k "${ipas[0]}" "$verification"
/usr/bin/python3 scripts/verify-ios.py "$verification" "$APPLE_TEAM_ID" "$method"
apps=("$verification/Payload/"*.app)
app=${apps[0]}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
name="Omil-${version}-${build}-ios-${method}.ipa"
mv "${ipas[0]}" "$output_dir/$name"
(cd "$output_dir" && shasum -a 256 "$name" > "$name.sha256")
rm -rf "$verification"
echo "Signed IPA: $output_dir/$name"
echo "Archive: $archive"
if [[ $method == app-store-connect ]]; then
  echo "Upload the IPA manually using Transporter, or use the archive in Xcode Organizer."
fi
