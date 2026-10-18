#!/usr/bin/env bash
# Regenerates the README visuals (docs/demo.gif, docs/tools.png) by rendering the real wheel views offscreen.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t orbit-promo)"
trap 'rm -rf "$WORK"' EXIT

make -C "$ROOT" build >/dev/null
"$ROOT/.build/xcode/Build/Products/Debug/Orbit.app/Contents/MacOS/Orbit" --render-promo "$WORK"

FFMPEG="$ROOT/Vendor/ffmpeg/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"
"$FFMPEG" -hide_banner -loglevel error -y -framerate 25 -i "$WORK/frames/frame-%03d.png" \
  -vf "scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=floyd_steinberg:diff_mode=rectangle" \
  -loop 0 "$ROOT/docs/demo.gif"
sips -Z 1400 "$WORK/tools.png" --out "$ROOT/docs/tools.png" >/dev/null
ls -lh "$ROOT/docs/demo.gif" "$ROOT/docs/tools.png"
