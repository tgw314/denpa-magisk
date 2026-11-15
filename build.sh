#!/bin/sh
# Assemble the denpa module zip (Magisk / KernelSU / APatch) from
# the official Android
# APK. The denpa payload (agent, bun, ffmpeg, server files) is NOT
# kept in this repository: it is downloaded from the official GitHub
# release at build time, verified against the release's own .sha256
# file, and extracted from the APK unmodified.
#
# Usage: ./build.sh
#   DENPA_VERSION  upstream denpa version to package (default: the
#                  value below; CI passes the latest release)
#   APK_SHA256     expected APK sha256 (default: read from the
#                  release's .sha256 asset)
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

echo "== payload: denpa server files (assets/server.zip) =="
(cd "$BUILD" && unzip -q -o "$APK" 'assets/server.zip' 'assets/asicen/*' 'assets/licenses/*')
(cd "$STAGE/payload/server" && unzip -q -o "$BUILD/assets/server.zip")

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
GITREV=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null || echo unknown)
cat > "$STAGE/licenses/SOURCE-denpa.txt" << EOF
The denpa payload in this module is extracted, unmodified, from
the official Android APK $APK_NAME
(sha256: $APK_SHA256).

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

denpa tuner agent (payload/lib/libdenpa_agent.so)
    MPL-2.0 — text: MPL-2.0.txt
    Source: agent/ in the same upstream source tarball

FFmpeg (payload/lib/libav*.so, libffmpeg.so, libffprobe.so)
    GPL-3.0 — texts: ffmpeg/ffmpeg/COPYING.GPLv3, LICENSE.md
    Component versions and source URLs: ffmpeg/SOURCE.txt
    (build script: .github/ffmpeg-android.sh in the upstream
    source tarball; components include x264, GPL-2.0-or-later)
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

Module scripts and WebUI (zip root, webroot/)
    AGPL-3.0-or-later — text: LICENSE-module.txt
    Source: https://github.com/tgw314/denpa-magisk
EOF
cat > "$STAGE/payload/SOURCE.txt" << 'EOF'
The binaries in this directory were extracted unmodified from
the official denpa Android APK. Their license texts, component
map and source pointers are in ../licenses/ (start with
../licenses/README.txt and ../licenses/SOURCE-denpa.txt).
The Corresponding Source is attached to the GitHub Release
this module zip came from.
EOF

echo "== zip =="
rm -f "$ZIP"
(cd "$STAGE" && zip -r -X "$ZIP" . > /dev/null)
ls -la "$ZIP"
md5sum "$ZIP"
