#!/usr/bin/env bash
# Generates sample files and runs every conversion Orbit offers for them through the CLI.
# Usage: scripts/smoke-test.sh [output-dir]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d -t orbit-smoke)}"
FIX="$WORK/fixtures"
OUT="$WORK/out"
mkdir -p "$FIX" "$OUT"

echo "Building orbit CLI…"
swift build --package-path "$ROOT/Packages/OrbitKit" -c debug >/dev/null || exit 1
ORBIT="$ROOT/Packages/OrbitKit/.build/debug/orbit"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required for fixtures"; exit 1; }

echo "Engines:"
"$ORBIT" caps | sed 's/^/  /'

echo "Creating fixtures in $FIX"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=1" -frames:v 1 "$FIX/sample.png"
sips -s format jpeg "$FIX/sample.png" --out "$FIX/sample.jpg" >/dev/null
# HEIC encoding needs the media engine, which virtual machines (CI runners) lack.
sips -s format heic "$FIX/sample.png" --out "$FIX/sample.heic" >/dev/null 2>&1 || rm -f "$FIX/sample.heic"
sips -s format tiff "$FIX/sample.png" --out "$FIX/sample.tiff" >/dev/null
sips -s format bmp "$FIX/sample.png" --out "$FIX/sample.bmp" >/dev/null
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=320x180:rate=10" -t 1 "$FIX/sample.gif"
cat > "$FIX/sample.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">
  <rect width="200" height="120" rx="16" fill="#4f46e5"/>
  <circle cx="100" cy="60" r="34" fill="none" stroke="#fff" stroke-width="6"/>
  <circle cx="134" cy="40" r="8" fill="#fbbf24"/>
</svg>
SVG
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3" -ac 2 "$FIX/sample.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=30" -f lavfi -i "sine=frequency=330" \
  -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$FIX/sample.mp4"
cat > "$FIX/sample.md" <<'MD'
# Orbit Sample

A paragraph with **bold**, *italic*, `code` and a [link](https://example.com).

## Lists

- First item
- Second item
  - Nested item
- Third item

1. One
2. Two

## Table

| Name | Value |
| ---- | ----- |
| Alpha | 1 |
| Beta | 2 |

> A quote worth keeping.

```swift
print("Hello, Orbit")
```

![Sample image](sample.png)

---

Final paragraph.
MD
printf 'name,qty,price\nApple,3,1.25\nBanana,12,0.5\n"Cherry, dark",100,12\n' > "$FIX/sample.csv"
cat > "$FIX/sample.srt" <<'SRT'
1
00:00:01,000 --> 00:00:02,500
Hello there.

2
00:00:03,000 --> 00:00:04,000
<i>General</i> Kenobi.
SRT
mkdir -p "$FIX/sample-folder/sub" && echo "a" > "$FIX/sample-folder/a.txt" && echo "b" > "$FIX/sample-folder/sub/b.txt"

# Derived fixtures exercise our own writers (and LibreOffice reading them).
"$ORBIT" convert --to pdf "$FIX/sample.md" >/dev/null && mv "$FIX/sample.pdf" "$FIX/document.pdf"
"$ORBIT" convert --to docx "$FIX/sample.md" >/dev/null
"$ORBIT" convert --to epub "$FIX/sample.md" >/dev/null
"$ORBIT" convert --to html "$FIX/sample.md" >/dev/null
"$ORBIT" convert --to rtf "$FIX/sample.md" >/dev/null
"$ORBIT" convert --to xlsx "$FIX/sample.csv" >/dev/null
"$ORBIT" convert --to ods "$FIX/sample.csv" >/dev/null
"$ORBIT" convert --to pptx "$FIX/document.pdf" >/dev/null
"$ORBIT" convert --to zip "$FIX/sample-folder" >/dev/null
"$ORBIT" convert --to vtt "$FIX/sample.srt" >/dev/null
"$ORBIT" convert --to m4a "$FIX/sample.wav" >/dev/null
printf 'Plain text line one.\n\nSecond paragraph.\n' > "$FIX/sample.txt"

pass=0
fail=0
skipped=0
failures=()

run_conversions() {
    local file="$1"
    local name
    name="$(basename "$file")"
    local dest="$OUT/$name"
    mkdir -p "$dest"
    while IFS= read -r line; do
        if [[ "$line" == *"[unavailable"* ]]; then skipped=$((skipped + 1)); continue; fi
        local target="${line##*convert→}"
        target="${target%% *}"
        if "$ORBIT" convert --to "$target" --out "$dest" "$file" >/dev/null 2>"$dest/.err"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            failures+=("$name → $target: $(tail -1 "$dest/.err")")
        fi
    done < <("$ORBIT" menu "$file" | grep "convert→")
}

for file in "$FIX"/sample.* "$FIX"/document.pdf "$FIX/sample-folder"; do
    run_conversions "$file"
done

# Extra inputs that the glob above doesn't cover.
run_conversions "$FIX/document.pptx"
run_conversions "$FIX/sample-folder.zip"

conversions_pass=$pass
conversions_fail=$fail

# Tools
TOOLS_OUT="$OUT/tools"
mkdir -p "$TOOLS_OUT"
tool() {
    local label="$1"; shift
    if "$ORBIT" tool "$@" --out "$TOOLS_OUT" >/dev/null 2>"$TOOLS_OUT/.err"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failures+=("tool $label: $(tail -1 "$TOOLS_OUT/.err")")
    fi
}
MP3="$OUT/sample.wav/sample.mp3"
HEIC="$FIX/sample.heic"
[ -f "$HEIC" ] || HEIC="$FIX/sample.jpg"
MOV="$OUT/sample.mp4/sample.mov"
PAGE="$OUT/document.pdf/document PNG/document-1.png"

tool "image compress"     imageCompress --option medium "$FIX/sample.jpg"
tool "png compress"       imageCompress --option strong "$FIX/sample.png"
tool "image resize 50%"   imageResize --option 50 "$HEIC"
tool "image resize 300w"  imageResize --option custom --text 300w "$FIX/sample.png"
tool "image crop"         imageCrop --crop 10,10,200,100 "$FIX/sample.jpg"
tool "image rotate"       imageRotate --option right "$FIX/sample.jpg"
tool "image flip"         imageRotate --option flipH "$FIX/sample.png"
tool "image cutout"       imageRemoveBackground "$FIX/sample.jpg"
tool "image clean"        imageStripMetadata "$FIX/sample.jpg"
tool "image text"         imageExtractText "$PAGE"
tool "images to pdf"      imagesToPDF "$FIX/sample.png" "$FIX/sample.jpg"
tool "video compress"     videoCompress --option strong "$FIX/sample.mp4"
tool "video trim"         videoTrim --start 0.5 --end 2 "$FIX/sample.mp4"
tool "video crop"         videoCrop --crop 0,0,321,181 "$FIX/sample.mp4"
tool "video rotate"       videoRotate --option left "$FIX/sample.mp4"
tool "video resize"       videoResize --option 480 "$FIX/sample.mp4"
tool "video mute"         videoMute "$FIX/sample.mp4"
tool "video speed"        videoSpeed --option 2 "$FIX/sample.mp4"
tool "video frame"        videoSnapshot "$FIX/sample.mp4"
tool "video split"        videoSplit --option half "$FIX/sample.mp4"
tool "video merge"        videoMerge "$FIX/sample.mp4" "$MOV"
tool "audio trim"         audioTrim --start 1 --end 2 "$MP3"
tool "audio compress"     audioCompress --option strong "$FIX/sample.wav"
tool "audio normalize"    audioNormalize "$MP3"
tool "audio speed"        audioSpeed --option 1.5 "$FIX/sample.wav"
tool "audio fade"         audioFade --option both "$MP3"
tool "audio split"        audioSplit --option half "$FIX/sample.wav"
tool "audio merge"        audioMerge "$FIX/sample.wav" "$MP3"
tool "pdf split"          pdfSplit --option pages "$FIX/document.pdf"
tool "pdf ranges"         pdfSplit --option custom --text "1, 2" "$FIX/document.pdf"
tool "pdf rotate"         pdfRotate --option right "$FIX/document.pdf"
tool "pdf ocr"            pdfOCR "$OUT/sample.png/sample.pdf"
tool "pdf protect"        pdfProtect --password secret "$FIX/document.pdf"
tool "pdf unlock"         pdfUnlock --password secret "$TOOLS_OUT/document-protected.pdf"
tool "pdf merge"          pdfMerge "$FIX/document.pdf" "$FIX/sample.png"
tool "subtitle shift"     subtitleShift --option 1 "$FIX/sample.srt"
tool "subtitle custom"    subtitleShift --option custom --text -0.5 "$FIX/sample.vtt"
tool "extract zip"        archiveExtract "$FIX/sample-folder.zip"
tool "zip files"          compressZip "$FIX/sample.png" "$FIX/sample.md"

echo
echo "Conversions: $conversions_pass passed, $conversions_fail failed, $skipped unavailable on this Mac"
echo "Tools: $((pass - conversions_pass)) passed, $((fail - conversions_fail)) failed"
for f in "${failures[@]+"${failures[@]}"}"; do echo "  ✗ $f"; done
echo "Outputs: $OUT"
[ "$fail" -eq 0 ]
