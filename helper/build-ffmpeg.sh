#!/bin/sh
# Build the FFmpeg shared libraries the module ships, from the upstream
# denpa source of the same version plus this repo's patches/*.patch.
#
# The module does not repackage the APK's FFmpeg untouched: the payload
# carries an FFmpeg built with patches/ffmpeg-mediacodec-align.patch
# (align_width/align_height in h264_mediacodec and hevc_mediacodec, see
# patches/README.md). Reproducing that means running upstream's own
# Android build, not reimplementing it:
#
#   1. take denpa's source tarball for the tag (the same one the release
#      attaches as denpa-<version>-source.tar.gz),
#   2. drop this repo's patches into its patches/ (upstream's
#      .github/ffmpeg-android.sh applies patches/ffmpeg-*.patch with
#      `patch -p1 --fuzz=0`),
#   3. run .github/ffmpeg-android.sh for arm64 with the NDK the upstream
#      Android workflow pins,
#   4. check the result really has the align options.
#
# The FFmpeg version, the list of components and the NDK version all come
# from that tarball (Dockerfile's ffmpeg stage and
# .github/workflows/android.yml), so the libraries are the ones the APK
# ships, with the patch on top, and nothing about them is hard-coded here.
#
# Usage:
#   helper/build-ffmpeg.sh                build into work/ffmpeg
#   helper/build-ffmpeg.sh --ndk-version  print the NDK version upstream pins
#   FORCE=1 helper/build-ffmpeg.sh        rebuild even if work/ffmpeg is there
#
# Environment:
#   DENPA_VERSION         upstream denpa version (default: the value below)
#   DENPA_SOURCE_TARBALL  source tarball to use (default:
#                         work/denpa-<version>-source.tar.gz; downloaded
#                         from GitHub when missing)
#   FFMPEG_OUT            where to put the build (default: work/ffmpeg; the
#                         output is jniLibs/arm64-v8a plus assets/licenses)
#   ANDROID_NDK_ROOT      the NDK to build with (default: the version
#                         upstream pins, looked up under the Android SDK)
#
# Needs cmake, meson/ninja, nasm, autoconf/automake/libtool, patch, pkg-config
# (on Debian/Ubuntu: apt-get install -y nasm meson ninja-build autoconf
# automake libtool pkg-config cmake) and a few hundred MB of scratch space.
# Building FFmpeg and its five dependencies takes ~30 minutes on a 4-core
# runner; CI caches work/ffmpeg so it only does it once per FFmpeg version,
# patch and NDK.
set -eu

PROJ=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DENPA_VERSION=${DENPA_VERSION:-2.45.1}
WORK="$PROJ/work"
OUT=${FFMPEG_OUT:-"$WORK/ffmpeg"}
SRC_TARBALL=${DENPA_SOURCE_TARBALL:-"$WORK/denpa-$DENPA_VERSION-source.tar.gz"}
SRC="$WORK/ffmpeg-src"
JNI="$OUT/jniLibs/arm64-v8a"
MARKER="$OUT/.built-from-denpa-magisk"

say() { echo "== $* =="; }
die() { echo "build-ffmpeg: $*" >&2; exit 1; }

mkdir -p "$WORK"

# The source tarball is the same asset the release attaches, and the same
# one upstream's own Android workflow builds from.
if [ ! -f "$SRC_TARBALL" ]; then
	say "download denpa v$DENPA_VERSION source"
	curl -fsSL -o "$SRC_TARBALL" \
		"https://github.com/danything/denpa/archive/refs/tags/v$DENPA_VERSION.tar.gz"
fi
TARBALL_SHA256=$(sha256sum "$SRC_TARBALL" | awk '{print $1}')

rm -rf "$SRC"
mkdir -p "$SRC"
say "extract $(basename "$SRC_TARBALL")"
# On a machine where the extraction directory cannot restore upstream's
# uid/gid (root squash), run this with TAR_OPTIONS=--no-same-owner: tar
# reads that variable itself.
tar -xzf "$SRC_TARBALL" --strip-components=1 -C "$SRC"

[ -f "$SRC/.github/ffmpeg-android.sh" ] || die "no .github/ffmpeg-android.sh in the denpa v$DENPA_VERSION source"
[ -f "$SRC/Dockerfile" ] || die "no Dockerfile in the denpa v$DENPA_VERSION source"
[ -f "$SRC/.github/workflows/android.yml" ] || die "no .github/workflows/android.yml in the denpa v$DENPA_VERSION source"

# The NDK the upstream Android workflow pins, so the libraries are built
# the same way the APK's are.
NDK_VERSION=$(sed -n 's/^[[:space:]]*NDK_VERSION:[[:space:]]*"\([^"]*\)".*$/\1/p' \
	"$SRC/.github/workflows/android.yml" | head -n 1)
[ -n "$NDK_VERSION" ] || die "cannot read NDK_VERSION from the upstream Android workflow"

if [ "${1:-}" = --ndk-version ]; then
	echo "$NDK_VERSION"
	exit 0
fi
[ $# -eq 0 ] || die "usage: helper/build-ffmpeg.sh [--ndk-version]"

if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
	SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-"$HOME/Android/Sdk"}}
	ANDROID_NDK_ROOT="$SDK/ndk/$NDK_VERSION"
	[ -d "$ANDROID_NDK_ROOT" ] || die "NDK $NDK_VERSION not found under $SDK (install it with sdkmanager \"ndk;$NDK_VERSION\", or set ANDROID_NDK_ROOT)"
	export ANDROID_NDK_ROOT
fi
# What we actually build with (the pin above is what CI installs; a local
# ANDROID_NDK_ROOT may be another revision, and that has to be visible).
if [ -f "$ANDROID_NDK_ROOT/source.properties" ]; then
	NDK_REVISION=$(sed -n 's/^Pkg\.Revision *= *//p' "$ANDROID_NDK_ROOT/source.properties")
fi
NDK_REVISION=${NDK_REVISION:-$(basename "$ANDROID_NDK_ROOT")}
[ "$NDK_REVISION" = "$NDK_VERSION" ] ||
	echo "   note: upstream pins NDK $NDK_VERSION, building with $NDK_REVISION" >&2

PATCHES=
for p in "$PROJ"/patches/ffmpeg-*.patch; do
	[ -e "$p" ] || continue
	PATCHES="$PATCHES $p"
done
[ -n "$PATCHES" ] || die "no patches/ffmpeg-*.patch in $PROJ"

# What we are about to build. IDENTITY is what the skip check compares;
# PROVENANCE also records when and by what (it is shipped as the note
# next to the build, not as the cache key).
PATCH_SHA256=$(cat $PATCHES | sha256sum | awk '{print $1}')
IDENTITY="denpa v$DENPA_VERSION source sha256 $TARBALL_SHA256
patches sha256 $PATCH_SHA256 ($(for p in $PATCHES; do printf '%s ' "${p##*/}"; done))
NDK $NDK_REVISION"
STAMP="$IDENTITY
built by helper/build-ffmpeg.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "${FORCE:-0}" != 1 ] && [ -f "$MARKER" ] &&
	[ -f "$JNI/libavcodec.so" ] &&
	[ "$(cat "$MARKER")" = "$IDENTITY" ]; then
	say "work/ffmpeg is already built from these inputs (FORCE=1 to rebuild)"
	echo "$STAMP"
	exit 0
fi

# Upstream's script applies patches/ffmpeg-*.patch from the source tree.
say "apply $PROJ/patches/ffmpeg-*.patch to the copy of the source"
mkdir -p "$SRC/patches"
cp $PATCHES "$SRC/patches/"
for p in $PATCHES; do
	echo "   ${p##*/}"
done

for tool in patch cmake meson ninja nasm pkg-config; do
	command -v "$tool" > /dev/null || die "$tool not found in PATH"
done

say "build FFmpeg with NDK $NDK_REVISION (this takes a while)"
(cd "$SRC" && ANDROID_NDK_ROOT="$ANDROID_NDK_ROOT" \
	bash .github/ffmpeg-android.sh "$OUT" arm64) ||
	die "ffmpeg-android.sh failed"

# Fail closed on the whole point of the patch: the options must be in the
# library we are about to ship.
for opt in align_width align_height; do
	strings -a "$JNI/libavcodec.so" | grep -qx "$opt" ||
		die "$opt missing from $JNI/libavcodec.so"
done

printf '%s\n' "$IDENTITY" > "$MARKER"
printf '%s\n' "$STAMP" > "$OUT/PROVENANCE.txt"
say "done"
grep -E '^ffmpeg |^SVT-AV1 |^Opus |^x264 |^dav1d |^zimg ' "$OUT/assets/licenses/ffmpeg/versions.txt" 2>/dev/null || true
ls -l "$JNI"
