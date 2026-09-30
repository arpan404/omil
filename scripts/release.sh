#!/bin/bash
set +x
set -euo pipefail
umask 077

cd "$(dirname "$0")/.."

# shellcheck source=scripts/release-env.sh
source scripts/release-env.sh

readonly repository=${GH_REPO:-arpan404/omil}
readonly sparkle_version=2.10.0
readonly sparkle_archive_url="https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz"
readonly release_cache_dir=${OMIL_RELEASE_CACHE_DIR:-"$PWD/.build/release-tools/sparkle-${sparkle_version}"}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/release.sh prepare <version> [build-number]
  ./scripts/release.sh status
  ./scripts/release.sh publish [--notes-file <path>] [--draft] [--prerelease]

prepare updates VERSION, Xcode build settings, and the server package version.
publish builds, signs, notarizes, creates a Sparkle appcast, and creates the
GitHub Release for the Mac version in VERSION. Build iOS separately with
distribute-ios.sh for manual App Store Connect upload.
The Mac updater downloads appcast.xml from the latest stable GitHub Release.

publish reads these credentials from .env or the environment:
  GH_TOKEN (or an authenticated gh CLI)
  APPLE_TEAM_ID
  SPARKLE_PRIVATE_KEY
  SPARKLE_PUBLIC_KEY
  APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER_ID
  DEVELOPER_ID_APPLICATION (optional; detected from the team keychain)


The command loads .env from the repository root first. Values already exported
in the shell take precedence over matching values in .env.

Optional environment variables:
  GH_REPO                 Defaults to arpan404/omil
  OMIL_RELEASE_CACHE_DIR  Sparkle tools cache
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

require_publish_environment() {
  local name
  for name in APPLE_TEAM_ID SPARKLE_PRIVATE_KEY SPARKLE_PUBLIC_KEY; do
    [[ -n "${!name:-}" ]] || fail "set $name in .env"
  done
  gh auth status >/dev/null 2>&1 || fail "authenticate gh or set GH_TOKEN in .env"
}

version_from_project() {
  awk '/MARKETING_VERSION:/ { gsub(/[" ]/, "", $2); print $2; exit }' project.yml
}

build_from_project() {
  awk '/CURRENT_PROJECT_VERSION:/ { gsub(/[" ]/, "", $2); print $2; exit }' project.yml
}

ensure_sparkle_tools() {
  if [[ -x "$release_cache_dir/bin/generate_appcast" ]]; then
    return
  fi

  require_command curl
  require_command tar
  mkdir -p "$release_cache_dir"
  local archive="$release_cache_dir/Sparkle.tar.xz"
  echo "==> downloading Sparkle ${sparkle_version} release tools"
  curl -fsSL "$sparkle_archive_url" -o "$archive"
  tar -xJf "$archive" -C "$release_cache_dir"
  [[ -x "$release_cache_dir/bin/generate_appcast" ]] \
    || fail "Sparkle tools were not found after extraction"
}

show_status() {
  local version build dirty updater_key
  version=$(<VERSION)
  build=$(build_from_project)
  dirty=no
  [[ -n "$(git status --porcelain)" ]] && dirty=yes
  updater_key=missing
  [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]] && updater_key="set"

  echo "Version:       $version"
  echo "Build:         $build"
  echo "Bundle ID:     sh.arpan.omil"
  echo "Repository:    $repository"
  echo "Dirty tree:    $dirty"
  echo "Updater key:   $updater_key"
}

prepare_release() {
  local version=${1:-}
  local build=${2:-}
  [[ -n "$version" ]] || fail "prepare requires a version"
  ./scripts/set-version.sh "$version" "$build"
  echo
  echo "Review, commit, and push the version change before running publish."
}

publish_release() {
  local notes_file="" draft=false prerelease=false
  while (( $# > 0 )); do
    case "$1" in
      --notes-file)
        (( $# >= 2 )) || fail "--notes-file requires a path"
        notes_file=$2; shift 2 ;;
      --draft) draft=true; shift ;;
      --prerelease) prerelease=true; shift ;;
      *) fail "unknown publish option: $1" ;;
    esac
  done
  for tool in gh git xcrun curl tar shasum; do require_command "$tool"; done
  require_publish_environment
  [[ -z "$(git status --porcelain)" ]] || fail "commit the release changes first; publishing requires a clean worktree"
  [[ -z "$notes_file" || -f "$notes_file" ]] || fail "notes file not found: $notes_file"
  ./scripts/distribute-mac.sh --check

  local version build tag head upstream previous="" output_dir artifacts_dir
  version=$(<VERSION)
  [[ "$version" == "$(version_from_project)" ]] || fail 'VERSION and project.yml differ'
  build=$(build_from_project)
  tag="v$version"
  git fetch origin --tags --quiet
  upstream=$(git rev-parse '@{upstream}') || fail 'the current branch has no upstream'
  head=$(git rev-parse HEAD)
  [[ "$head" == "$upstream" ]] || fail 'push the current commit before publishing'
  if git rev-parse "$tag" >/dev/null 2>&1; then
    [[ "$(git rev-parse "$tag^{commit}")" == "$head" ]] || fail "$tag points to another commit"
  fi
  # Query the full release list so auth/network errors cannot look like an absent release.
  local releases
  releases=$(gh release list --repo "$repository" --limit 1000 --json tagName,isDraft,isPrerelease)
  if printf '%s' "$releases" | /usr/bin/python3 -c 'import json,sys; sys.exit(not any(r["tagName"]==sys.argv[1] for r in json.load(sys.stdin)))' "$tag"; then
    fail "GitHub Release $tag already exists"
  fi
  previous=$(printf '%s' "$releases" | /usr/bin/python3 -c 'import json,sys; print(next((r["tagName"] for r in json.load(sys.stdin) if not r["isDraft"] and not r["isPrerelease"]), ""))')
  if [[ -n "$previous" ]]; then git rev-parse "$previous^{commit}" >/dev/null || fail "previous release tag $previous is not available locally"; fi
  mkdir -p .build/distribution
  output_dir=$(mktemp -d "$PWD/.build/distribution/GitHub-release.XXXXXX")
  artifacts_dir="$output_dir/artifacts"
  mkdir "$artifacts_dir"
  echo "Release work directory: $output_dir"
  if [[ -n "$previous" ]]; then
    local assets
    assets=$(gh release view "$previous" --repo "$repository" --json assets --jq '.assets[].name')
    if [[ "$assets" == *appcast.xml* ]]; then
      mkdir "$output_dir/previous"
      gh release download "$previous" --repo "$repository" --pattern appcast.xml --dir "$output_dir/previous"
      /usr/bin/python3 - "$output_dir/previous/appcast.xml" "$build" <<'PYBUILD'
import sys, xml.etree.ElementTree as ET
ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
versions=[]
for item in ET.parse(sys.argv[1]).findall('./channel/item'):
    node=item.find(ns+'version')
    value=node.text if node is not None else item.find('enclosure').get(ns+'version')
    versions.append(int(value))
if versions and int(sys.argv[2]) <= max(versions):
    raise SystemExit('Increase CURRENT_PROJECT_VERSION so Sparkle can detect the update')
PYBUILD
    fi
  fi
  ensure_sparkle_tools
  /usr/bin/python3 scripts/changelog.py "$version" "$repository" "$previous" "$head" > "$artifacts_dir/CHANGELOG.md"
  if [[ -n "$notes_file" ]]; then cp "$notes_file" "$artifacts_dir/RELEASE_NOTES.md"; else cp "$artifacts_dir/CHANGELOG.md" "$artifacts_dir/RELEASE_NOTES.md"; fi

  OMIL_DISTRIBUTION_DIR="$output_dir/mac" ./scripts/distribute-mac.sh "$version" "$build"
  local mac_zips=("$output_dir/mac/"*-macos-arm64.zip)
  [[ ${#mac_zips[@]} -eq 1 && -f ${mac_zips[0]} ]] || fail 'expected one notarized Mac ZIP'
  cp "${mac_zips[0]}" "$artifacts_dir/"
  local zip_name zip_path appcast_path
  zip_name=$(basename "${mac_zips[0]}")
  zip_path="$artifacts_dir/$zip_name"
  appcast_path="$artifacts_dir/appcast.xml"
  local feed public_key
  feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$output_dir/mac/Omil.app/Contents/Info.plist")
  [[ "$feed" == "https://github.com/$repository/releases/latest/download/appcast.xml" ]] || fail 'Mac updater feed does not match the release repository'
  public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$output_dir/mac/Omil.app/Contents/Info.plist")
  [[ "$public_key" == "$SPARKLE_PUBLIC_KEY" ]] || fail 'Mac updater public key mismatch'
  cp "$artifacts_dir/RELEASE_NOTES.md" "$artifacts_dir/${zip_name%.zip}.md"
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$release_cache_dir/bin/generate_appcast" \
    --ed-key-file - --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
    --link "https://github.com/$repository/releases/tag/$tag" --embed-release-notes \
    --maximum-versions 1 --maximum-deltas 0 -o "$appcast_path" "$artifacts_dir"
  local signature
  signature=$(/usr/bin/python3 - "$appcast_path" "$zip_name" "$repository" "$tag" "$build" <<'PYFEED'
import sys, xml.etree.ElementTree as ET
path,name,repo,tag,build=sys.argv[1:]
def require(condition, message):
    if not condition:
        raise SystemExit(message)
ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items=ET.parse(path).findall('./channel/item')
require(len(items)==1, 'Expected one update in appcast')
item=items[0]; enc=item.find('enclosure')
require(enc.get('url')==f'https://github.com/{repo}/releases/download/{tag}/{name}', 'Incorrect updater download URL')
node=item.find(ns+'version')
require((node.text if node is not None else enc.get(ns+'version'))==build, 'Incorrect updater build')
require(enc.get(ns+'edSignature'), 'Missing Sparkle signature')
print(enc.get(ns+'edSignature'))
PYFEED
  )
  xcrun swift scripts/verify-appcast.swift "$public_key" "$signature" "$zip_path"
  # shellcheck disable=SC2016
  printf '\n## Mac installation\n\nDownload `%s`, unzip it, and move Omil.app to Applications. Existing installs update through the signed GitHub Sparkle feed. Requires Apple silicon and macOS 14+.\n' "$zip_name" >> "$artifacts_dir/RELEASE_NOTES.md"
  /usr/bin/python3 - "$artifacts_dir/release.json" "$version" "$build" "$head" "$APPLE_TEAM_ID" <<'PYMANIFEST'
import json,sys,datetime
with open(sys.argv[1], 'w') as f:
    json.dump(dict(version=sys.argv[2], build=sys.argv[3], commit=sys.argv[4], team=sys.argv[5],
        createdAt=datetime.datetime.now(datetime.timezone.utc).isoformat()), f, indent=2)
PYMANIFEST
  (cd "$artifacts_dir" && shasum -a 256 ./*.zip ./*.xml ./*.md ./*.json > SHA256SUMS)
  [[ "$(git rev-parse HEAD)" == "$head" && -z "$(git status --porcelain)" ]] \
    || fail 'the source changed during the build; no release was published'
  # Upload every asset as a draft before making the release visible to the updater.
  local release_args=("$tag" "$artifacts_dir/"* --repo "$repository" --target "$head" \
    --title "Omil $version" --notes-file "$artifacts_dir/RELEASE_NOTES.md" --draft)
  [[ "$prerelease" == true ]] && release_args+=(--prerelease)
  gh release create "${release_args[@]}"
  if [[ "$draft" == false ]]; then
    if [[ "$prerelease" == true ]]; then
      gh release edit "$tag" --repo "$repository" --draft=false --latest=false
    else
      gh release edit "$tag" --repo "$repository" --draft=false --latest=true
    fi
  fi
  echo "Release: https://github.com/$repository/releases/tag/$tag"
  echo "Verified artifacts and Apple logs: $output_dir"
}

command_name=${1:-}
case "$command_name" in
  prepare)
    shift
    prepare_release "$@"
    ;;
  status)
    shift
    (( $# == 0 )) || fail "status takes no arguments"
    show_status
    ;;
  publish)
    shift
    publish_release "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    usage >&2
    fail "unknown command: $command_name"
    ;;
esac
