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

- **Payload:** Extracted from the official Android APK at build time (verified against the upstream release's `.sha256`). No denpa binaries are committed to this repo. Two parts of the payload are patched rather than shipped as-is — see [Patched payload](#patched-payload) below.
- **Networking:** The tuner agent listens on port 25252 (TLS). The bundled server connects to it via `127.0.0.1` with a pairing token.
- **Hardware encoding:** Supported MediaCodec encoders are detected at startup via a small `app_process` DEX helper (`helper/`) and passed as `MEDIACODEC_ENCODERS`.

## Patched payload

Two payload parts are patched at build time so Qualcomm Venus encoders (`c2.qti.*`) don't corrupt picture widths that aren't multiples of 128 (e.g. 1440×1080): FFmpeg is built with [`patches/ffmpeg-mediacodec-align.patch`](patches/ffmpeg-mediacodec-align.patch), and the server bundle is patched to pass `-align_width 128 -align_height 32` to the H.264/H.265 MediaCodec encoders. Everything else in the payload is the APK's file, byte for byte. Details: [patches/README.md](patches/README.md).

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
