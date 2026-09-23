#!/bin/bash
# Build a Release-configured Mac app for local use with a stable development signature.
set -euo pipefail

cd "$(dirname "$0")/.."

install_after_build=false
if [[ ${1:-} == --install ]]; then
  install_after_build=true
  shift
fi

if [[ $# -ne 0 && $# -ne 2 ]]; then
  echo "usage: $0 [--install] [version build-number]" >&2
  exit 1
fi

team_id=BVT55BT25R
# The certificate's subject OU is the signing Team ID; its display name uses
# the development account ID above.
signing_team_id=5J88TLUP2J
signing_identities=()
while IFS= read -r identity; do
  signing_identities+=("$identity")
done < <(security find-identity -v -p codesigning | awk -v team="$team_id" '
  index($0, "\"Apple Development:") && index($0, "(" team ")\"") { print $2 }
')
if [[ ${#signing_identities[@]} -ne 1 ]]; then
  echo "error: expected one valid Apple Development signing identity for team $team_id; found ${#signing_identities[@]}" >&2
  echo "Run 'security find-identity -v -p codesigning' to inspect your keychain." >&2
  exit 1
fi

build_settings=(
  CODE_SIGN_STYLE=Manual
  "CODE_SIGN_IDENTITY=${signing_identities[0]}"
  "DEVELOPMENT_TEAM=$team_id"
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  ENABLE_HARDENED_RUNTIME=YES
)

if [[ $# -eq 2 ]]; then
  version=$1
  build_number=$2
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "error: version must be a semantic version such as 0.2.0" >&2
    exit 1
  fi
  if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: build number must be a positive integer" >&2
    exit 1
  fi
  build_settings+=("MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build_number")
fi

echo "==> building the bundled server"
./scripts/build-server.sh

echo "==> generating the Xcode project"
xcodegen generate

derived_data="$PWD/.build/local-derived-data"
echo "==> building OmilMac (Release configuration, Apple Development signing)"
xcodebuild -project Omil.xcodeproj -scheme OmilMac -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" \
  "${build_settings[@]}" build

app="$derived_data/Build/Products/Release/Omil.app"
codesign --verify --deep --strict "$app"
signed_team=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ "$signed_team" != "$signing_team_id" ]]; then
  echo "error: built app has TeamIdentifier=$signed_team; expected $signing_team_id" >&2
  exit 1
fi
sparkle_team=$(codesign -dv --verbose=4 "$app/Contents/Frameworks/Sparkle.framework" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ "$sparkle_team" != "$signed_team" ]]; then
  echo "error: Sparkle and Omil have different signing teams ($sparkle_team vs $signed_team)" >&2
  exit 1
fi

echo "==> app: $app"
if [[ "$install_after_build" == false ]]; then
  printf 'Launch with: open %q\n' "$app"
fi

if [[ "$install_after_build" == true ]]; then
  echo "==> installing at /Applications/Omil.app"
  staging_dir=$(mktemp -d /Applications/.Omil-staging-XXXXXX)
  trap 'rm -rf "$staging_dir"' EXIT
  ditto "$app" "$staging_dir/Omil.app"
  codesign --verify --deep --strict "$staging_dir/Omil.app"

  if pgrep -f '^/Applications/Omil.app/Contents/MacOS/Omil$' >/dev/null; then
    osascript -e 'tell application id "com.arpan404.omil" to quit'
    for _ in {1..15}; do
      if ! pgrep -f '^/Applications/Omil.app/Contents/MacOS/Omil$' >/dev/null; then
        break
      fi
      sleep 1
    done
    if pgrep -f '^/Applications/Omil.app/Contents/MacOS/Omil$' >/dev/null; then
      echo "error: Omil did not quit; the installed app was not replaced" >&2
      exit 1
    fi
  fi

  if [[ -d /Applications/Omil.app ]]; then
    backup_parent="$HOME/Library/Application Support/Omil/AppBackups"
    mkdir -p "$backup_parent"
    backup_dir=$(mktemp -d "$backup_parent/backup-XXXXXX")
    mv /Applications/Omil.app "$backup_dir/Omil.app"
  fi

  if ! mv "$staging_dir/Omil.app" /Applications/Omil.app; then
    if [[ -n ${backup_dir:-} ]]; then
      mv "$backup_dir/Omil.app" /Applications/Omil.app
    fi
    echo "error: installation failed; the previous app was restored" >&2
    exit 1
  fi
  if ! codesign --verify --deep --strict /Applications/Omil.app; then
    rm -rf /Applications/Omil.app
    if [[ -n ${backup_dir:-} ]]; then
      mv "$backup_dir/Omil.app" /Applications/Omil.app
    fi
    echo "error: installed signature verification failed; the previous app was restored" >&2
    exit 1
  fi

  lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
  "$lsregister" -u "$app" || true
  old_adhoc_app="$PWD/.build/adhoc-derived-data/Build/Products/Release/Omil.app"
  if [[ -d "$old_adhoc_app" ]]; then
    "$lsregister" -u "$old_adhoc_app" || true
  fi
  "$lsregister" -f /Applications/Omil.app
  open /Applications/Omil.app
  echo "==> installed and opened /Applications/Omil.app"
fi
