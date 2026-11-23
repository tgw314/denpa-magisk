#!/bin/sh
# Assemble the denpa module zip (Magisk / KernelSU / APatch) from
# the official Android
# APK. The denpa payload (agent, bun, ffmpeg, server files) is NOT
# kept in this repository: it is downloaded from the official GitHub
# release at build time, verified against the release's own .sha256
# file, and extracted from the APK.
#
# Two things are then patched into that payload. Both are fail-closed:
# the build aborts instead of producing a zip with the wrong file in it.
#   1. the nine FFmpeg shared libraries are replaced with FFmpeg built
#      from the upstream source of the same version plus
#      patches/ffmpeg-mediacodec-align.patch (-align_width/-align_height
#      for h264_mediacodec/hevc_mediacodec). helper/build-ffmpeg.sh
#      produces that set; CI runs it before this script.
#   2. the extracted server bundle's chunk that builds the encoder
#      argument arrays is patched
#      (helper/patch-server-align.py) so the MediaCodec encoders are
#      asked for a 128x32 coded alignment. Without it the new FFmpeg
#      options would never be passed and the patch would do nothing.
# Everything else (denpa's own native libraries, the other encoding
# ways, the rest of the server) is the APK's own file, byte for byte.
#
# Usage: ./build.sh
#   DENPA_VERSION  upstream denpa version to package (default: the
#                  value below; CI passes the latest release)
#   APK_SHA256     expected APK sha256 (default: read from the
#                  release's .sha256 asset)
#   FFMPEG_DIR     the patched FFmpeg build to splice in (default:
#                  work/ffmpeg/jniLibs/arm64-v8a, as helper/build-ffmpeg.sh
#                  produces it). Point it at an existing build to skip
#                  building FFmpeg locally.
# The module revision (for module-only fixes without an upstream
# release) lives in ./module-rev and is bumped by hand.
set -eu

PROJ=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DENPA_VERSION=${DENPA_VERSION:-2.45.1}
MODULE_REV=$(cat "$PROJ/module-rev" 2>/dev/null || echo 1)
APK_NAME="denpa-$DENPA_VERSION-android-arm64.apk"
APK_URL="https://github.com/danything/denpa/releases/download/v$DENPA_VERSION/$APK_NAME"
WORK="$PROJ/work"
APK="$WORK/denpa-$DENPA_VERSION.apk"
ZIP="$PROJ/denpa-v$DENPA_VERSION-r$MODULE_REV.zip"
FFMPEG_DIR=${FFMPEG_DIR:-"$WORK/ffmpeg/jniLibs/arm64-v8a"}

# FFmpeg's own libraries in the APK payload. denpa's other native libraries
# (libbun, libdenpa_agent, libasicend, libasicenctl) are never touched.
FFMPEG_LIBS="libavcodec libavdevice libavfilter libavformat libavutil \
libswresample libswscale libffmpeg libffprobe"

die() { echo "build: $*" >&2; exit 1; }

if [ ! -d "$FFMPEG_DIR" ]; then
	echo "build: no patched FFmpeg build at $FFMPEG_DIR" >&2
	echo "   run helper/build-ffmpeg.sh (needs the NDK), or set FFMPEG_DIR" >&2
	echo "   to an existing jniLibs/arm64-v8a directory" >&2
	exit 1
fi

mkdir -p "$WORK"
if [ ! -f "$APK" ]; then
	echo "== download $APK_URL =="
	curl -fsSL -o "$APK" "$APK_URL"
fi
if [ -z "${APK_SHA256:-}" ]; then
	echo "== fetch release checksum =="
	APK_SHA256=$(curl -fsSL "$APK_URL.sha256" | awk '{print $1}')
fi
echo "== verify sha256 ($APK_SHA256) =="
echo "$APK_SHA256  $APK" | sha256sum -c -

# module.prop version/versionCode follow the upstream version:
# versionCode = MAJOR*1000000 + MINOR*10000 + PATCH*100 + MODULE_REV
VMAJOR=${DENPA_VERSION%%.*}
VREST=${DENPA_VERSION#*.}
VMINOR=${VREST%%.*}
VPATCH=${VREST#*.}
VPATCH=${VPATCH%%.*}
VERSION_CODE=$((VMAJOR * 1000000 + VMINOR * 10000 + VPATCH * 100 + MODULE_REV))
MODULE_VERSION="v$DENPA_VERSION-r$MODULE_REV"

BUILD=$(mktemp -d /tmp/denpa-module-build.XXXXXX)
trap 'rm -rf "$BUILD"' EXIT
STAGE=$BUILD/stage
mkdir -p "$STAGE/payload/lib" "$STAGE/payload/server" \
	"$STAGE/payload/asicen" "$STAGE/licenses"

echo "== module scripts =="
cp "$PROJ/module/module.prop" "$PROJ/module/common.sh" \
	"$PROJ/module/ctl.sh" "$PROJ/module/service.sh" \
	"$PROJ/module/action.sh" "$PROJ/module/customize.sh" \
	"$PROJ/module/uninstall.sh" "$STAGE/"
sed -i \
	-e "s/^version=.*/version=$MODULE_VERSION (denpa v$DENPA_VERSION)/" \
	-e "s/^versionCode=.*/versionCode=$VERSION_CODE/" \
	"$STAGE/module.prop"
sed -i "s/^DENPA_VERSION=.*/DENPA_VERSION=v$DENPA_VERSION/" \
	"$STAGE/common.sh"

echo "== webroot (manager WebUI: KernelSU / APatch) =="
mkdir -p "$STAGE/webroot"
cp "$PROJ/module/webroot/index.html" \
	"$PROJ/module/webroot/kernelsu.js" "$STAGE/webroot/"

echo "== payload: native executables/libraries from the APK =="
(cd "$BUILD" && unzip -q -o "$APK" 'lib/arm64-v8a/*')
cp "$BUILD"/lib/arm64-v8a/*.so "$STAGE/payload/lib/"

echo "== payload: FFmpeg libraries from the patched build =="
ffmpeg_version() { # $1 = libavutil.so
	strings -a "$1" | sed -n 's/^FFmpeg version \([^ ]*\).*/\1/p' | head -n 1
}
needed() { # $1 = .so
	readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' '
}
# Every library of the patched build must be one we know where to put.
for f in "$FFMPEG_DIR"/*.so; do
	lib=${f##*/}
	lib=${lib%.so}
	case " $FFMPEG_LIBS " in
		*" $lib "*) ;;
		*) die "unexpected library in the patched FFmpeg build: $lib" ;;
	esac
done
for lib in $FFMPEG_LIBS; do
	dst="$STAGE/payload/lib/$lib.so"
	src="$FFMPEG_DIR/$lib.so"
	[ -f "$dst" ] || die "the APK payload has no $lib.so"
	[ -f "$src" ] || die "the patched build has no $lib.so"
	soname_dst=$(readelf -d "$dst" | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p')
	soname_src=$(readelf -d "$src" | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p')
	if [ -n "$soname_dst$soname_src" ] && [ "$soname_dst" != "$soname_src" ]; then
		die "SONAME mismatch for $lib.so: apk='$soname_dst' patched='$soname_src'"
	fi
	# A different set of NEEDED entries would mean the libraries were built
	# with other components than the APK's, which this module does not
	# support (the rest of the payload links against them).
	if [ "$(needed "$dst")" != "$(needed "$src")" ]; then
		die "NEEDED mismatch for $lib.so: apk='$(needed "$dst")' patched='$(needed "$src")'"
	fi
	printf '   %-16s %9s B -> %9s B  (SONAME %s)\n' "$lib.so" \
		"$(wc -c < "$dst")" "$(wc -c < "$src")" "${soname_dst:-none}"
	cp -f "$src" "$dst"
done
# Fail closed on the whole point of the patched build: the staged
# libavcodec must carry the new options.
for opt in align_width align_height; do
	strings -a "$STAGE/payload/lib/libavcodec.so" | grep -qx "$opt" ||
		die "$opt missing from the staged libavcodec.so"
done
APK_FFMPEG=$(ffmpeg_version "$BUILD/lib/arm64-v8a/libavutil.so")
NEW_FFMPEG=$(ffmpeg_version "$FFMPEG_DIR/libavutil.so")
echo "   FFmpeg version: APK ${APK_FFMPEG:-unknown} / patched build ${NEW_FFMPEG:-unknown}"
if [ "$APK_FFMPEG" != "$NEW_FFMPEG" ]; then
	echo "   WARNING: the APK ships FFmpeg $APK_FFMPEG but the patched build is" >&2
	echo "   WARNING: $NEW_FFMPEG. helper/build-ffmpeg.sh builds the version" >&2
	echo "   WARNING: upstream pins for this release; a mismatch means FFMPEG_DIR" >&2
	echo "   WARNING: is a build of a different FFmpeg. Re-check on a device if" >&2
	echo "   WARNING: you ship one." >&2
fi
for f in "$BUILD"/lib/arm64-v8a/*.so; do
	lib=${f##*/}
	lib=${lib%.so}
	case " $FFMPEG_LIBS " in
		*" $lib "*) ;;
		*) echo "   kept as-is: $lib" ;;
	esac
done

echo "== payload: denpa server files (assets/server.zip) =="
(cd "$BUILD" && unzip -q -o "$APK" 'assets/server.zip' 'assets/asicen/*' 'assets/licenses/*')
(cd "$STAGE/payload/server" && unzip -q -o "$BUILD/assets/server.zip")

echo "== payload: server bundle: mediacodec align 128x32 =="
python3 "$PROJ/helper/patch-server-align.py" "$STAGE/payload/server"
# The chunk that carries the encoder argument arrays is found by content
# (its file name is the bundler's and changes: chunks/hwenc.js up to
# 2.59.0, chunks/transcode.js in 2.61.0). Read the patched path back for
# the check and for the provenance note below.
SERVER_CHUNK=$(grep -rlF --include='*.js' 'function mediacodecAlign(codec)' \
	"$STAGE/payload/server" | sed "s|^$STAGE/payload/server/||") || :
if [ -z "$SERVER_CHUNK" ] ||
	[ "$(printf '%s\n' "$SERVER_CHUNK" | wc -l)" -ne 1 ]; then
	die "expected one patched server chunk, found: ${SERVER_CHUNK:-none}"
fi
grep -qF '...mediacodecAlign(codec),' \
	"$STAGE/payload/server/$SERVER_CHUNK" ||
	die "$SERVER_CHUNK is not patched"

echo "== payload: MediaCodec encoder helper (app_process DEX) =="
# A port of the app's Encoders.kt (helper/DenpaEncoders.java),
# run by the module through app_process to collect the hardware
# encoder names for MEDIACODEC_ENCODERS. Needs an Android SDK
# (android.jar + d8) and a JDK on the build machine.
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-"$HOME/Android/Sdk"}}
JAVAC=${JAVAC:-"$HOME/.local/jdk-17/bin/javac"}
[ -x "$JAVAC" ] || JAVAC=javac
case "$JAVAC" in */*) PATH="$(dirname "$JAVAC"):$PATH" ;; esac
PLATFORM=$(ls "$SDK/platforms" | sort -V | tail -n 1)
D8=$(ls "$SDK"/build-tools/*/d8 | sort -V | tail -n 1)
mkdir -p "$BUILD/classes" "$BUILD/dexout"
"$JAVAC" -cp "$SDK/platforms/$PLATFORM/android.jar" \
	-d "$BUILD/classes" "$PROJ/helper/DenpaEncoders.java"
"$D8" --min-api 29 --output "$BUILD/dexout" "$BUILD/classes/DenpaEncoders.class"
cp "$BUILD/dexout/classes.dex" "$STAGE/payload/denpa-encoders.dex"

echo "== payload: ASICEN firmware =="
cp "$BUILD/assets/asicen/asicen-loader.bin" "$STAGE/payload/asicen/"

echo "== licenses (from the APK) + source note =="
(cd "$BUILD/assets/licenses" && tar -cf - .) | (cd "$STAGE/licenses" && tar -xf -)
cp "$PROJ/helper/DenpaEncoders.java" "$STAGE/licenses/"
cp "$PROJ/third_party/MPL-2.0.txt" "$STAGE/licenses/"
cp "$PROJ/third_party/LGPL-2.0.txt" "$PROJ/third_party/LGPL-2.1.txt" \
	"$STAGE/licenses/"
cp "$PROJ/LICENSE" "$STAGE/licenses/LICENSE-module.txt"
# The two patches that make the payload different from the APK's own files
# (AGPL-3.0: the Corresponding Source of the modified server chunk is the
# upstream chunk plus this script).
cp "$PROJ/patches/ffmpeg-mediacodec-align.patch" \
	"$PROJ/helper/patch-server-align.py" "$STAGE/licenses/"
GITREV=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null || echo unknown)
cat > "$STAGE/licenses/SOURCE-denpa.txt" << EOF
The denpa payload in this module is extracted from the official Android
APK $APK_NAME
(sha256: $APK_SHA256), except for the parts listed under MODIFIED PARTS
below.

denpa (server) is AGPL-3.0-or-later; the tuner agent is MPL-2.0
(license text: MPL-2.0.txt in this directory; its source is agent/
in the source tarball below).
The Corresponding Source for denpa v$DENPA_VERSION is available
from the same place this module's payload came from:
  https://github.com/danything/denpa/releases/tag/v$DENPA_VERSION
  https://github.com/danything/denpa (tag v$DENPA_VERSION)
The GitHub Release of this module also carries the upstream source
tarball (denpa-$DENPA_VERSION-source.tar.gz) as an asset, and the
asicen-userland source tarball (a GPL-2.0 component; see
asicen-userland/SOURCE.txt for its origin and checksum), and the
FFmpeg component source tarballs listed in ffmpeg/SOURCE.txt.
See README.txt in this directory for a component-by-component map
of license texts and source pointers (ffmpeg, bun, OpenSSL, Siano
firmware, and the module's own code).

MODIFIED PARTS (the rest of the payload is the APK's own file, byte for
byte). This module patches what the APK ships, so that the payload is
NOT unmodified:

  payload/lib/libavcodec.so, libavdevice.so, libavfilter.so,
  libavformat.so, libavutil.so, libswresample.so, libswscale.so,
  libffmpeg.so and libffprobe.so
      FFmpeg ${NEW_FFMPEG:-unknown} built from the upstream source, with
      patches/ffmpeg-mediacodec-align.patch applied: it adds
      -align_width/-align_height to h264_mediacodec and hevc_mediacodec
      so the coded size can be aligned to the 128x32 that Qualcomm's
      MediaCodec (Venus, c2.qti.*) reads the input buffer with. The build
      is upstream's own .github/ffmpeg-android.sh from the denpa
      v$DENPA_VERSION source tarball, with this module's patches/ dropped
      into its patches/ directory and without touching anything else.
      The patch is in this directory (ffmpeg-mediacodec-align.patch) and
      in component-sources.tar on the module's GitHub Release; the build
      driver is helper/build-ffmpeg.sh in the module source.

  payload/server/$SERVER_CHUNK
      The upstream chunk with the 128x32 alignment passed to the
      MediaCodec encoders (found by content: chunks/hwenc.js up to
      2.59.0, chunks/transcode.js in 2.61.0). Both places that build a
      MediaCodec encoder argument array (hwArgs, used by recording and
      the hardware probe, and liveHwArgs) gain
      '...mediacodecAlign(codec)' and a helper that returns
      ['-align_width', '128', '-align_height', '32'] for h264 and hevc
      only (AV1, VA-API, QSV, AMF, NVENC, RKMPP and the software
      encoders are untouched). The chunk's .js.map, when the bundle
      ships one, still describes the unpatched file. Applied by
      patch-server-align.py (in this directory and in the module source,
      which also carries it in component-sources.tar); it fails instead
      of guessing when the bundle's anchors change.

So the Corresponding Source for this module is the denpa v$DENPA_VERSION
source tarball attached to the module's GitHub Release, plus
ffmpeg-mediacodec-align.patch and patch-server-align.py.

The module also ships a small helper, payload/denpa-encoders.dex,
compiled from DenpaEncoders.java (included in this directory): a
Java port of the denpa app's Encoders.kt, so it is AGPL-3.0-or-later
as well. It is built with javac (against android.jar) and
d8 --min-api 29; see build.sh in the module source.
The module's own code (scripts, WebUI, helper) is AGPL-3.0-or-later
(text: LICENSE-module.txt in this directory). Its full source is
available at https://github.com/tgw314/denpa-magisk
(commit $GITREV).
EOF
cat > "$STAGE/licenses/README.txt" << 'EOF'
Component map for this module zip
=================================
License texts and source pointers for everything in the zip.
Start with SOURCE-denpa.txt for the payload's provenance.

denpa server (payload/server/)
    AGPL-3.0-or-later — text: LICENSE
    Source: denpa-<version>-source.tar.gz attached to the module's
    GitHub Release (or the danything/denpa tag of the same version)
    payload/server/app/build/server/chunks/ (the chunk that builds the
    MediaCodec encoder args) is patched, see "Module patches" below.

denpa tuner agent (payload/lib/libdenpa_agent.so)
    MPL-2.0 — text: MPL-2.0.txt
    Source: agent/ in the same upstream source tarball

FFmpeg (payload/lib/libav*.so, libffmpeg.so, libffprobe.so)
    GPL-3.0 — texts: ffmpeg/ffmpeg/COPYING.GPLv3, LICENSE.md
    Component versions and source URLs: ffmpeg/SOURCE.txt
    (build script: .github/ffmpeg-android.sh in the upstream
    source tarball; components include x264, GPL-2.0-or-later)
    Built by this module with ffmpeg-mediacodec-align.patch applied,
    see "Module patches" below.
    Their source tarballs are bundled, unmodified, in
    component-sources.tar on the module's GitHub Release.

asicen-userland (payload/lib/libasicend.so, libasicenctl.so,
firmware in payload/asicen/)
    GPL-2.0 — text: asicen-userland/LICENSE
    Source pointer and checksum: asicen-userland/SOURCE.txt
    Its source tarball is bundled, unmodified, in
    component-sources.tar on the module's GitHub Release.

bun runtime (payload/lib/libbun.so)
    MIT and bundled components — see bun/LICENSE.md
    LGPL texts for its LGPL components (JavaScriptCore: LGPL-2.0,
    tinycc: LGPL-2.1): LGPL-2.0.txt, LGPL-2.1.txt

OpenSSL and Siano firmware (bundled)
    LICENSE.openssl / LICENCE.siano

Module helper (payload/denpa-encoders.dex)
    AGPL-3.0-or-later — source: DenpaEncoders.java (here)

Module patches (what this module changes in the payload)
    ffmpeg-mediacodec-align.patch   FFmpeg align_width/align_height
                                    (GPL-3.0, applies to the FFmpeg
                                    source in component-sources.tar)
    patch-server-align.py           patches the server bundle's
                                    MediaCodec chunk (AGPL-3.0). The
                                    modified chunk is the upstream one
                                    plus this patch; both are also in
                                    component-sources.tar on the
                                    module's GitHub Release.

Module scripts and WebUI (zip root, webroot/)
    AGPL-3.0-or-later — text: LICENSE-module.txt
    Source: https://github.com/tgw314/denpa-magisk
EOF
cat > "$STAGE/payload/SOURCE.txt" << 'EOF'
The binaries in this directory were extracted from the official denpa
Android APK, except the FFmpeg libraries (libav*.so, libsw*.so,
libffmpeg.so, libffprobe.so), which are rebuilt from the upstream
FFmpeg source with this module's align patch, and the server chunk
that builds the MediaCodec encoder args, which is patched. See
../licenses/SOURCE-denpa.txt ("MODIFIED PARTS"). Their license texts,
component map and source pointers are in ../licenses/ (start with
../licenses/README.txt). The Corresponding Source is attached to the
GitHub Release this module zip came from.
EOF

echo "== zip =="
rm -f "$ZIP"
(cd "$STAGE" && zip -r -X "$ZIP" . > /dev/null)
ls -la "$ZIP"
md5sum "$ZIP"
