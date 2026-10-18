# Third-Party Notices

Orbit's own source code is released under the MIT License (see `LICENSE`).

## FFmpeg

Release builds of Orbit may ship an unmodified `ffmpeg` executable inside the app
bundle (`Orbit.app/Contents/MacOS/ffmpeg`). Orbit runs it as a separate process and
does not link against it.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
FFmpeg is licensed under the GNU Lesser General Public License (LGPL) version 2.1
or later; builds that enable GPL components (such as libx264 or libx265) are
licensed under the GNU General Public License (GPL) version 2 or later.

- Source code: https://ffmpeg.org/download.html
- License: https://ffmpeg.org/legal.html

The exact build that is bundled, along with its configuration and the place to
obtain its corresponding source, is recorded in `Vendor/ffmpeg/BUILD_INFO.txt`
when the app is built with `scripts/fetch-ffmpeg.sh`.

## Optional engines (not bundled)

Orbit can use these if they are installed on your Mac. They are not distributed with Orbit:

- LibreOffice (MPL 2.0) — https://www.libreoffice.org
- libwebp's `cwebp` (BSD) — https://developers.google.com/speed/webp
- Pages, Keynote and Numbers — Apple Inc.
