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

The patch applies to FFmpeg 9.0.2 and 9.1 (the file is identical in both).
