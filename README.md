# denpa-magisk

Run [denpa](https://github.com/danything/denpa) (server + tuner agent) as root on Android via Magisk, KernelSU, or APatch. Because it runs as root, the agent uses sysfs/usbfs directly (`USB_BROKER` unset) — no Android app or USB permission dialog is needed.

## Install & Usage

1. Flash the zip from [Releases](https://github.com/tgw314/denpa-magisk/releases) in your root manager and reboot.
2. Open the denpa Web UI at `http://<device>:3000`.

> [!WARNING]
> Do **not** install the official denpa APK alongside this module; they will conflict over the tuner and ports.

- **Control:** Use the manager WebUI (status, logs, start/stop) on KernelSU and APatch. On Magisk, use a root shell:
  ```sh
  sh /data/adb/modules/denpa/ctl.sh start|stop|restart|status
  ```
- **Data directory:** `/data/adb/denpa` (config, DB, recordings)
- **Updates:** Automatic via `updateJson` in `module.prop`. A GitHub Actions job checks for a new upstream release every 6 hours and publishes the module zip here.

## How It Works

- **Payload:** Extracted from the official Android APK at build time (verified against the upstream release's `.sha256`). No denpa binaries are committed to this repo. Two parts of the payload are patched rather than shipped as-is — see [Patched payload](#patched-payload-ffmpeg-mediacodec-align) below.
- **Networking:** The tuner agent listens on port 25252 (TLS). The bundled server connects to it via `127.0.0.1` with a pairing token.
- **Hardware encoding:** Supported MediaCodec encoders are detected at startup via a small `app_process` DEX helper (`helper/`) and passed as `MEDIACODEC_ENCODERS`.

## Patched payload: FFmpeg MediaCodec align

FFmpeg's MediaCodec encoder aligns the coded size to 16 before handing the frame to the hardware encoder. That is enough for most devices, but Qualcomm's Venus encoder (`c2.qti.*`, e.g. on a Snapdragon 8s Gen 3) reads the input buffer with a stride of `ALIGN(width, 128)` and a slice height of `ALIGN(height, 32)`. FFmpeg writes the frame with `stride == width`, so any width that is not a multiple of 128 is read back off by up to 127 bytes per row: a 1440×1080 H.264/H.265 recording comes out with horizontal streaks and a green band along the bottom. 1920 is fine, which is why this only shows up on some sizes.

So the module ships FFmpeg built with [`patches/ffmpeg-mediacodec-align.patch`](patches/ffmpeg-mediacodec-align.patch), which adds `-align_width` / `-align_height` to [`libavcodec/mediacodecenc.c`](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/mediacodecenc.c) for `h264_mediacodec` and `hevc_mediacodec`. Both options default to the upstream 16, so an FFmpeg built with the patch behaves exactly like the stock one unless the options are passed; the padding is zeroed so it cannot leak into the picture as garbage. `helper/patch-server-align.py` then patches the server bundle's `hwenc.js` so the MediaCodec encoder argument arrays pass `-align_width 128 -align_height 32`. The extra border is cropped back to the display size by the `h264_metadata`/`hevc_metadata` filter that this encoder path already uses, so the recording is still 1440×1080.

Scope of the change:

- Only H.264 and H.265 MediaCodec encoding (recording, live and the startup probe). AV1 MediaCodec, VA-API, QSV, AMF, NVENC, Rockchip MPP, VideoToolbox and the software encoders are untouched.
- The coded picture is 1536×1088 instead of 1440×1088 for that example, so at the same `-b:v` each pixel gets slightly fewer bits (~7% fewer).
- Everything else in the payload — denpa's own native libraries, every other server file — is the APK's file, byte for byte.

The libraries are **not** built by hand and pasted into the module: `helper/build-ffmpeg.sh` takes denpa's source tarball for the tag, drops this repo's `patches/` into its `patches/` (upstream's own `.github/ffmpeg-android.sh` applies them with `patch -p1 --fuzz=0`), and runs that script for arm64 with the NDK upstream pins. CI does exactly this before calling `build.sh`, and caches the result; locally, run `helper/build-ffmpeg.sh` once (or point `FFMPEG_DIR` at an existing `jniLibs/arm64-v8a`).

When upstream changes the server bundle, the patch script's anchors no longer match and the build stops instead of shipping an unpatched `hwenc.js`; the patch then has to be re-derived. The same goes for the FFmpeg patch, which is applied with `--fuzz=0`.

## License & Source Code

- **denpa (server):** AGPL-3.0-or-later
- **tuner agent:** MPL-2.0
- **This module (scripts, WebUI, helper):** AGPL-3.0-or-later (see [LICENSE](LICENSE))

`helper/DenpaEncoders.java` is a Java port of upstream's `Encoders.kt`, which is why this repository's own code is also licensed under AGPL-3.0-or-later. Because each module zip redistributes the compiled upstream binaries extracted from the APK, and a patched FFmpeg built from its source:

- Every GitHub Release attaches the corresponding upstream source tarball (`denpa-<version>-source.tar.gz`).
- Every module zip includes the upstream license texts under `licenses/`.
- The two patches this module applies (`patches/ffmpeg-mediacodec-align.patch`, GPL-3.0 as part of the GPL FFmpeg build; `helper/patch-server-align.py`, AGPL-3.0) are in the zip's `licenses/` and in `component-sources.tar` on every release, next to the FFmpeg component sources they apply to.

> [!NOTE]
> This module is meant for running denpa on your own device and home network. denpa is AGPL-licensed: if you modify denpa and let other people use your modified version over a network, AGPL §13 requires you, as the operator, to offer them its Corresponding Source. The unmodified upstream source is at [danything/denpa](https://github.com/danything/denpa) (same version tag); this module's own source is this repository, and the two patches it applies to the payload are in `patches/` and `helper/`.
