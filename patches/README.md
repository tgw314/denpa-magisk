# patches/

FFmpeg patches that the module build applies on top of the upstream
denpa FFmpeg source. They are applied by **upstream's own**
`.github/ffmpeg-android.sh` (in the denpa source tarball of the same
tag): that script does

    for p in "$root"/patches/ffmpeg-*.patch; do patch -p1 --fuzz=0 < "$p"; done

so `helper/build-ffmpeg.sh` copies this directory into the extracted
denpa source tree before running it. `--fuzz=0` is what makes a stale
patch stop the build instead of half-applying.

Nothing here is upstreamed as of this writing; the patches are kept
here, next to the build that needs them.

The libraries are not built by hand and pasted into the module:
`helper/build-ffmpeg.sh` takes denpa's source tarball for the tag,
drops this repo's `patches/` into its `patches/`, and runs upstream's
script for arm64 with the NDK upstream pins. CI does exactly this
before calling `build.sh` and caches the result; locally, run
`helper/build-ffmpeg.sh` once (or point `FFMPEG_DIR` at an existing
`jniLibs/arm64-v8a`).

## ffmpeg-mediacodec-align.patch

Adds `-align_width` / `-align_height` to `h264_mediacodec` and
`hevc_mediacodec` (`libavcodec/mediacodecenc.c`, +39/-5, 6 hunks).

Why: FFmpeg's MediaCodec encoder already aligns the coded size to 16
(the workaround for MediaCodec's alignment requirement), but Qualcomm's
Venus hardware (e.g. the `c2.qti.*` encoders on a Snapdragon 8s Gen 3)
reads the input buffer with a stride of `ALIGN(width, 128)` and a slice
height of `ALIGN(height, 32)`. FFmpeg writes `stride == width`, so for a
width that is not a multiple of 128 (1440, for instance) every row is
read 96 bytes off, which shows up as horizontal streaks and a green band
at the bottom of the encoded picture. Aligning the coded size to
128x32 makes `stride == width` hold by construction; the extra border is
cropped back to the display size by the `h264_metadata`/`hevc_metadata`
bitstream filter that the same encoder path already uses.

The default stays 16/16, so an FFmpeg built with this patch behaves
exactly like the stock one unless the options are passed; the module's
server patch (`helper/patch-server-align.py`) is what passes
`-align_width 128 -align_height 32`. Only H.264/HEVC have the options
(those are the only two the patch touches), so AVC and HEVC are the only
codecs the server patch changes; AV1 MediaCodec, VA-API, NVENC, QSV,
AMF, RKMPP and the software encoders are untouched.

One cost: the coded picture is 1536×1088 instead of 1440×1088 in that
example, so at the same `-b:v` each pixel gets slightly fewer bits
(~7% fewer).

The patch applies to FFmpeg 9.0.2 and 9.1 (the file is identical in both).

## Server bundle patch (helper/patch-server-align.py)

The FFmpeg patch only adds the options; something has to pass them.
`build.sh` runs `helper/patch-server-align.py` on the extracted server
bundle: it scans the bundle's JS files for the anchors of the code
that builds the MediaCodec encoder argument arrays (located by
content, not by file name — upstream renamed the chunk from
`chunks/hwenc.js` to `chunks/transcode.js` in denpa 2.61.0) and
rewrites those arrays to pass `-align_width 128 -align_height 32` for
H.264/H.265 MediaCodec only, in both the recording (`hwArgs`) and live
(`liveHwArgs`) paths.

It is fail-closed: unless exactly one file carries the anchors, with
the expected occurrence counts, the build stops instead of shipping
an unpatched (or half-patched) bundle. When upstream changes that
code's shape, the anchors have to be re-derived — the same goes for
the FFmpeg patch above, which is applied with `--fuzz=0`.
