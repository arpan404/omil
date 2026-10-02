#!/usr/bin/env bash
# Renders the marketing site's media (site/public/media) from the same components as the film.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=../site/public/media
TMP=out/site
mkdir -p "$OUT" "$TMP"
R=./node_modules/.bin/remotion


# iPhone and iPad keyboards on a transparent background, cropped from the Everywhere chapter.
$R still src/index.ts SiteDevices "$TMP/e-phone-done.png" --frame=226 --image-format=png --scale=2 --log=error
$R still src/index.ts SiteDevices "$TMP/e-pad.png" --frame=312 --image-format=png --scale=2 --log=error
ffmpeg -y -loglevel error -i "$TMP/e-phone-done.png" -vf "crop=1160:2070:780:90" "$TMP/iphone-done.png"
ffmpeg -y -loglevel error -i "$TMP/e-pad.png" -vf "crop=2366:1786:1280:220" "$TMP/ipad.png"
for n in iphone-done ipad; do
  cwebp -quiet -q 86 -alpha_q 100 "$TMP/$n.png" -o "$OUT/$n.webp"
done

# The icons. The social card (og.png) is rendered by the site itself: `bun run og` in ../site.
ICON=public/img/icon.png
for s in 64 180 192 512; do sips -z $s $s "$ICON" --out "$OUT/icon-$s.png" >/dev/null; done
sips -z 32 32 "$ICON" --out "$TMP/icon-32.png" >/dev/null
sips -s format ico "$TMP/icon-32.png" --out "$OUT/../favicon.ico" >/dev/null
ls -lh "$OUT"
