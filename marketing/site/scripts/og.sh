#!/usr/bin/env bash
# Renders the link preview image (public/media/og.png) from og/og.html with headless Chrome.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --allow-file-access-from-files --virtual-time-budget=4000 \
  --screenshot="$PWD/public/media/og.png" "file://$PWD/og/og.html" 2>/dev/null
sips -g pixelWidth -g pixelHeight public/media/og.png | tail -2
ls -lh public/media/og.png
