#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

version=${1:-}
build=${2:-}

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 <semantic-version> [build-number]" >&2
  exit 1
fi

if [[ -z "$build" ]]; then
  current_build=$(awk '/CURRENT_PROJECT_VERSION:/ { gsub(/[" ]/, "", $2); print $2; exit }' project.yml)
  build=$((current_build + 1))
fi

if [[ ! "$build" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: build number must be a positive integer" >&2
  exit 1
fi

printf '%s\n' "$version" > VERSION
VERSION="$version" BUILD="$build" perl -0pi -e '
  s/MARKETING_VERSION: "[^"]+"/MARKETING_VERSION: "$ENV{VERSION}"/;
  s/CURRENT_PROJECT_VERSION: "[^"]+"/CURRENT_PROJECT_VERSION: "$ENV{BUILD}"/;
' project.yml
VERSION="$version" perl -0pi -e 's/"version": "[^"]+"/"version": "$ENV{VERSION}"/' server/package.json

xcodegen generate

echo "Omil version $version ($build)"
echo "Create the release with: git tag v$version"
