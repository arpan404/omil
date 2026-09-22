#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

load_dotenv() {
  [[ -f .env ]] || return

  local names=(
    GH_TOKEN
    DEVELOPER_ID_APPLICATION
    APPLE_ID
    APPLE_TEAM_ID
    APPLE_APP_SPECIFIC_PASSWORD
    SPARKLE_PRIVATE_KEY
    SPARKLE_PUBLIC_KEY
    GH_REPO
    OMIL_RELEASE_CACHE_DIR
  )
  local preserved=()
  local name saved_name saved_value

  for name in "${names[@]}"; do
    if [[ -n "${!name:-}" ]]; then
      saved_name="omil_saved_${name}"
      printf -v "$saved_name" '%s' "${!name}"
      preserved+=("$name")
    fi
  done

  set -a
  # .env is a trusted local shell file and is ignored by git.
  # shellcheck disable=SC1091
  source .env
  set +a

  for name in ${preserved[@]+"${preserved[@]}"}; do
    saved_name="omil_saved_${name}"
    saved_value=${!saved_name}
    export "$name=$saved_value"
  done
}

load_dotenv

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
GitHub Release for the version in VERSION.

publish reads these credentials from the environment:
  GH_TOKEN
  DEVELOPER_ID_APPLICATION
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD
  SPARKLE_PRIVATE_KEY
  SPARKLE_PUBLIC_KEY

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
  local missing=()
  local name
  for name in \
    GH_TOKEN \
    DEVELOPER_ID_APPLICATION \
    APPLE_ID \
    APPLE_TEAM_ID \
    APPLE_APP_SPECIFIC_PASSWORD \
    SPARKLE_PRIVATE_KEY \
    SPARKLE_PUBLIC_KEY
  do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done

  if (( ${#missing[@]} > 0 )); then
    printf 'error: missing release environment variables:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
  fi

  [[ "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || fail "SPARKLE_PUBLIC_KEY is not a base64-encoded Ed25519 public key"
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
  echo "Bundle ID:     com.arpan404.omil"
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
  local notes_file=""
  local draft=false
  local prerelease=false

  while (( $# > 0 )); do
    case "$1" in
      --notes-file)
        (( $# >= 2 )) || fail "--notes-file requires a path"
        notes_file=$2
        shift 2
        ;;
      --draft)
        draft=true
        shift
        ;;
      --prerelease)
        prerelease=true
        shift
        ;;
      *) fail "unknown publish option: $1" ;;
    esac
  done

  require_publish_environment
  require_command bun
  require_command codesign
  require_command curl
  require_command ditto
  require_command gh
  require_command git
  require_command xcodebuild
  require_command xcodegen
  require_command xcrun

  [[ -z "$(git status --porcelain)" ]] \
    || fail "the worktree must be clean; commit the prepared version first"

  local version project_version build tag head upstream
  version=$(<VERSION)
  project_version=$(version_from_project)
  build=$(build_from_project)
  [[ "$version" == "$project_version" ]] \
    || fail "VERSION ($version) does not match project.yml ($project_version)"
  tag="v$version"

  git fetch origin --quiet
  upstream=$(git rev-parse '@{upstream}' 2>/dev/null) \
    || fail "the current branch has no upstream"
  head=$(git rev-parse HEAD)
  [[ "$head" == "$upstream" ]] \
    || fail "push the current commit before publishing"

  if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
    fail "GitHub Release $tag already exists"
  fi

  if [[ -n "$notes_file" ]]; then
    [[ -f "$notes_file" ]] || fail "release notes file not found: $notes_file"
    notes_file=$(cd "$(dirname "$notes_file")" && pwd)/$(basename "$notes_file")
  fi

  ensure_sparkle_tools

  local release_tmp_dir archive_path app_path artifacts_dir zip_name zip_path appcast_path generated_notes
  release_tmp_dir=$(mktemp -d /tmp/omil-release.XXXXXX)
  trap 'rm -rf "$release_tmp_dir"' EXIT INT TERM
  archive_path="$release_tmp_dir/Omil.xcarchive"
  artifacts_dir="$release_tmp_dir/artifacts"
  zip_name="Omil-${version}.zip"
  zip_path="$artifacts_dir/$zip_name"
  appcast_path="$artifacts_dir/appcast.xml"
  mkdir -p "$artifacts_dir"

  echo "==> building bundled server"
  ./scripts/build-server.sh

  echo "==> generating Xcode project"
  xcodegen generate

  echo "==> archiving Omil $version ($build)"
  xcodebuild \
    -project Omil.xcodeproj \
    -scheme OmilMac \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    archive \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_KEY"

  app_path="$archive_path/Products/Applications/Omil.app"
  [[ -d "$app_path" ]] || fail "archive did not contain Omil.app"

  echo "==> signing bundled server"
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$app_path/Contents/Resources/omil-server"
  codesign --force --options runtime --timestamp \
    --entitlements Apps/Mac/OmilMac.entitlements \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"

  echo "==> submitting to Apple notarization"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
  xcrun notarytool submit "$zip_path" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"

  echo "==> creating final archive and Sparkle appcast"
  rm -f "$zip_path"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

  if [[ -n "$notes_file" ]]; then
    cp "$notes_file" "$artifacts_dir/Omil-${version}.md"
  else
    generated_notes="$artifacts_dir/Omil-${version}.md"
    printf '# Omil %s\n\nSee the GitHub Release for the full change list.\n' "$version" > "$generated_notes"
  fi

  printf '%s' "$SPARKLE_PRIVATE_KEY" | \
    "$release_cache_dir/bin/generate_appcast" \
      --ed-key-file - \
      --download-url-prefix "https://github.com/${repository}/releases/download/${tag}/" \
      --link "https://github.com/${repository}" \
      --embed-release-notes \
      --maximum-versions 1 \
      -o "$appcast_path" \
      "$artifacts_dir"

  [[ -f "$appcast_path" ]] || fail "Sparkle did not create appcast.xml"

  echo "==> creating GitHub Release $tag"
  local release_args=(
    "$tag"
    "$zip_path"
    "$appcast_path"
    --repo "$repository"
    --target "$head"
    --title "Omil $version"
  )
  if [[ -n "$notes_file" ]]; then
    release_args+=(--notes-file "$notes_file")
  else
    release_args+=(--generate-notes)
  fi
  [[ "$draft" == true ]] && release_args+=(--draft)
  [[ "$prerelease" == true ]] && release_args+=(--prerelease)
  gh release create "${release_args[@]}"

  echo "Published Omil $version ($build)."
  echo "https://github.com/${repository}/releases/tag/${tag}"
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
