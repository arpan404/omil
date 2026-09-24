#!/bin/bash
# Build the same signed Mac app used for local installation.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/build-local-mac.sh "$@"
