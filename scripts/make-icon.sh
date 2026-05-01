#!/usr/bin/env bash
# Render Sources/KithApp/Resources/AppIcon.svg → AppIcon.icns at the same
# path. Run this once after editing the SVG; the resulting .icns is checked
# in so CI doesn't need an SVG toolchain.
#
# Output is the standard 10-slice macOS iconset (16/32/128/256/512 px @1x
# and @2x), packed via /usr/bin/iconutil.
#
# Requires: rsvg-convert (brew install librsvg) — clean output, used by
# preference. Falls back to /usr/bin/qlmanage if rsvg-convert is missing,
# which works but adds a faint gray fringe on transparent rounded corners.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$REPO_ROOT/Sources/KithApp/Resources/AppIcon.svg"
OUT_ICNS="$REPO_ROOT/Sources/KithApp/Resources/AppIcon.icns"

if [[ ! -f "$SVG" ]]; then
  echo "error: $SVG not found" >&2
  exit 1
fi

if command -v rsvg-convert >/dev/null 2>&1; then
  RENDERER="rsvg"
elif command -v qlmanage >/dev/null 2>&1; then
  RENDERER="qlmanage"
  echo "note: rsvg-convert not found; falling back to qlmanage (less crisp)" >&2
else
  echo "error: need rsvg-convert (brew install librsvg) or /usr/bin/qlmanage" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# Standard macOS iconset slices: name @ size in px.
slices=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

render_png() {
  local out="$1" size="$2"
  case "$RENDERER" in
    rsvg)
      rsvg-convert -w "$size" -h "$size" "$SVG" -o "$out"
      ;;
    qlmanage)
      # qlmanage emits at the requested size capped to the source's aspect
      # ratio. The SVG is square, so this works.
      local tmp="$WORK/ql"
      mkdir -p "$tmp"
      qlmanage -t -s "$size" -o "$tmp" "$SVG" >/dev/null 2>&1
      mv "$tmp/$(basename "$SVG").png" "$out"
      rm -rf "$tmp"
      ;;
  esac
}

for slice in "${slices[@]}"; do
  name="${slice%%:*}"
  size="${slice##*:}"
  echo "==> $name ($size px)"
  render_png "$ICONSET/$name" "$size"
done

echo "==> iconutil pack"
/usr/bin/iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "==> wrote $OUT_ICNS ($(du -h "$OUT_ICNS" | awk '{print $1}'))"
