#!/bin/bash
# Build the standalone Omil inference server binary (no Bun needed at runtime).
# The Mac app embeds dist/omil-server and owns its lifecycle.
set -euo pipefail
cd "$(dirname "$0")/../server"

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to build the server (https://bun.sh)" >&2
  exit 1
fi

bun install
bunx tsc --noEmit
bun test
mkdir -p dist
bun build --compile --target bun-darwin-arm64 --outfile dist/omil-server src/main.ts
chmod +x dist/omil-server
echo "built: server/dist/omil-server ($(du -h dist/omil-server | cut -f1))"
