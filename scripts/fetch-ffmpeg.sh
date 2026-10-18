#!/usr/bin/env bash
# Downloads a static, self-contained arm64 ffmpeg into Vendor/ffmpeg/ so release builds can bundle it.
# Builds come from https://ffmpeg.martin-riedl.de (static, signed and notarized macOS builds).
# Override the source with FFMPEG_URL=… if you build your own.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/ffmpeg"
URL="${FFMPEG_URL:-https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading ffmpeg from $URL"
curl -fL --progress-bar -o "$WORK/ffmpeg.zip" "$URL"
mkdir -p "$WORK/unpacked"
ditto -x -k "$WORK/ffmpeg.zip" "$WORK/unpacked"

BIN="$(find "$WORK/unpacked" -type f -name ffmpeg -perm -u+x | head -1)"
[ -n "$BIN" ] || { echo "No ffmpeg executable in the archive"; exit 1; }

if ! file "$BIN" | grep -q "arm64"; then
    echo "Downloaded ffmpeg is not an arm64 binary:"; file "$BIN"; exit 1
fi
# A bundled binary must not depend on Homebrew dylibs.
if otool -L "$BIN" | grep -qE "/opt/homebrew|/usr/local"; then
    echo "Downloaded ffmpeg links against Homebrew libraries; use a static build."; exit 1
fi

mkdir -p "$DEST"
cp "$BIN" "$DEST/ffmpeg"
chmod +x "$DEST/ffmpeg"
xattr -dr com.apple.quarantine "$DEST/ffmpeg" 2>/dev/null || true

{
    echo "Source: $URL"
    echo "Fetched: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "SHA-256: $(shasum -a 256 "$DEST/ffmpeg" | cut -d' ' -f1)"
    echo
    "$DEST/ffmpeg" -hide_banner -version
} > "$DEST/BUILD_INFO.txt"

echo
"$DEST/ffmpeg" -hide_banner -version | head -1
for encoder in libwebp libx264 libx265 libvpx-vp9 libopus libvorbis libmp3lame libsvtav1 h264_videotoolbox; do
    if "$DEST/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q " $encoder "; then
        echo "  ✓ $encoder"
    else
        echo "  ✗ $encoder"
    fi
done
echo "Installed $DEST/ffmpeg — the next app build will bundle it."
