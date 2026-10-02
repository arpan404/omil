#!/usr/bin/env bash
# Renders the marketing site's media (site/public/media) from the same components as the film.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=../site/public/media
TMP=out/site
mkdir -p "$OUT" "$TMP"
R=./node_modules/.bin/remotion

# A Mac screen still with the Omil window, for the social card.
for spec in changes:457; do
  $R still src/index.ts SiteDesktop "$TMP/desktop-${spec%%:*}.png" --frame=${spec##*:} --scale=2 --log=error
done

# iPhone and iPad keyboards on a transparent background, cropped from the Everywhere chapter.
$R still src/index.ts SiteDevices "$TMP/e-phone-done.png" --frame=226 --image-format=png --scale=2 --log=error
$R still src/index.ts SiteDevices "$TMP/e-pad.png" --frame=312 --image-format=png --scale=2 --log=error
ffmpeg -y -loglevel error -i "$TMP/e-phone-done.png" -vf "crop=1160:2070:780:90" "$TMP/iphone-done.png"
ffmpeg -y -loglevel error -i "$TMP/e-pad.png" -vf "crop=2366:1786:1280:220" "$TMP/ipad.png"
for n in iphone-done ipad; do
  cwebp -quiet -q 86 -alpha_q 100 "$TMP/$n.png" -o "$OUT/$n.webp"
done

# The social card and the icons.
ffmpeg -y -loglevel error -i "$TMP/desktop-changes.png" -vf "scale=1200:-1,crop=1200:630:0:0" "$OUT/og.png"
for s in 64 180 224; do sips -z $s $s public/img/icon.png --out "$TMP/icon-$s.png" >/dev/null; done
cp "$TMP/icon-64.png" "$OUT/icon-64.png"; cp "$TMP/icon-180.png" "$OUT/icon-180.png"; cp "$TMP/icon-224.png" "$OUT/icon.png"
ls -lh "$OUT"
