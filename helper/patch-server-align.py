#!/usr/bin/env python3
"""Patch the denpa server bundle so the MediaCodec encoders get
-align_width 128 -align_height 32 (the ffmpeg-mediacodec-align patch).

Usage: patch-server-align.py <payload/server dir>

The server bundle (assets/server.zip in the APK) carries one compiled
chunk that builds the ffmpeg encoder argument arrays. Its file name is
the chunker's, not denpa's, and it changed upstream (chunks/hwenc.js up
to 2.59.0, chunks/transcode.js in 2.61.0), so the chunk is found by
content: the JS files under the given directory are scanned for the
anchors below, exactly one file may carry them. Two branches there
return an encoder array for the MediaCodec way: hwArgs() (recording, and
the hardware probe) and liveHwArgs() (live). Both get

    ...mediacodecAlign(codec),

right after `...mediacodecName(way),`, and a new helper next to
highProfile() returns the two ffmpeg options for h264/hevc only:

    ["-align_width", "128", "-align_height", "32"]

AV1 (av1_mediacodec) is left alone: the FFmpeg patch only implements the
alignment for h264_mediacodec/hevc_mediacodec, so passing the option to
av1_mediacodec would make ffmpeg die on an unknown option. Every other
way (vaapi/qsv/amf/nvenc/rkmpp/videotoolbox), the software encoders and
the rest of the server are untouched.

Fail-closed: every anchor must match exactly as expected, and exactly one
file may carry them, otherwise the script exits 1 and the build stops
(nothing is written in that case). That is also how an upstream change is
noticed: the anchors are tied to the compiled chunk, not to the denpa
source, so when upstream drops a new server bundle this script refuses to
build until it is re-derived.
"""

import sys
import pathlib

# Anchor 1: the MediaCodec encoder array of both hwArgs() and liveHwArgs().
# It must occur exactly twice (recording + live).
CALL_ANCHOR = "\t\t\t...mediacodecName(way),\n"
CALL_PATCHED = CALL_ANCHOR + "\t\t\t...mediacodecAlign(codec),\n"
CALL_COUNT = 2

# Anchor 2: end of highProfile(), i.e. the MediaCodec/VideoToolbox helper
# block; the new helper goes right after it.
DEF_ANCHOR = (
    'function highProfile(codec) {\n'
    '\treturn codec === "h264" ? ["-profile:v", "high"] : [];\n'
    '}\n'
)

DEF_PATCHED = DEF_ANCHOR + """
/**
* **MediaCodec のエンコーダにだけ渡す、符号化する面のアライン** (このモジュールの
* ffmpeg-mediacodec-align パッチ。`libavcodec/mediacodecenc.c` の `align_width`・
* `align_height`)。QTI (Venus) のカラーブッファは幅を 128・高さを 32 に切り上げた
* 大きさで読むので、1440 のような 128 で割り切れない幅をそのまま渡すと横筋や下端が
* 化ける。H.264・H.265 にだけ渡す (パッチはこの 2 つにしか入っていないので、AV1 に
* 渡すと ffmpeg が知らない選択肢として落ちる)。既定の 16 に戻すときは空を返す
*/
function mediacodecAlign(codec) {
\tif (codec !== "h264" && codec !== "hevc") return [];
\treturn [
\t\t"-align_width",
\t\t"128",
\t\t"-align_height",
\t\t"32"
\t];
}
"""


def fail(message):
    print("patch-server-align: %s" % message, file=sys.stderr)
    sys.exit(1)


def find_chunk(root):
    """The one JS file of the bundle that carries the anchors (rel, text)."""
    hits = []
    near = []  # files that look like the chunk but miss the anchors
    for path in sorted(root.rglob("*.js")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        rel = path.relative_to(root)
        if CALL_ANCHOR in text or DEF_ANCHOR in text:
            hits.append((rel, text))
        elif "mediacodecName" in text or "function highProfile" in text:
            near.append(rel)
    if len(hits) > 1:
        fail(
            "the mediacodec anchors occur in %d files of %s (%s), expected 1"
            % (len(hits), root, ", ".join(str(rel) for rel, _ in hits))
        )
    if not hits:
        message = "no JS file under %s carries the mediacodec anchors" % root
        if near:
            message += " (mediacodecName/highProfile found in %s)" % ", ".join(
                str(rel) for rel in near
            )
        fail(message)
    return hits[0]


def main(argv):
    if len(argv) != 2:
        fail("usage: patch-server-align.py <payload/server dir>")
    root = pathlib.Path(argv[1])
    if not root.is_dir():
        fail("%s is not a directory" % root)
    chunk, text = find_chunk(root)
    chunk = str(chunk)

    if "mediacodecAlign" in text:
        fail("%s is already patched (mediacodecAlign present)" % chunk)

    call_hits = text.count(CALL_ANCHOR)
    if call_hits != CALL_COUNT:
        fail(
            "anchor %r occurs %d time(s), expected %d"
            % ("...mediacodecName(way),", call_hits, CALL_COUNT)
        )
    def_hits = text.count(DEF_ANCHOR)
    if def_hits != 1:
        fail(
            "anchor %r occurs %d time(s), expected 1"
            % ("function highProfile(codec) { ... }", def_hits)
        )

    patched = text.replace(CALL_ANCHOR, CALL_PATCHED)
    patched = patched.replace(DEF_ANCHOR, DEF_PATCHED, 1)

    # Post-conditions on the patched text: one definition, two calls, the
    # two option names once each (inside the helper), and the h264/hevc
    # guard still in place.
    checks = [
        ("function mediacodecAlign(codec) {", 1),
        ("...mediacodecAlign(codec),", CALL_COUNT),
        ('"-align_width"', 1),
        ('"-align_height"', 1),
        ('if (codec !== "h264" && codec !== "hevc") return [];', 1),
        ("...mediacodecName(way),", CALL_COUNT),
    ]
    for needle, want in checks:
        got = patched.count(needle)
        if got != want:
            fail("post-check failed: %r occurs %d time(s), expected %d" % (needle, got, want))

    # Everything else must be byte-identical: the only changes are the two
    # inserted call lines and the inserted helper block.
    # Byte lengths (the doc comment is UTF-8, so len() on the str is not bytes).
    def nbytes(text):
        return len(text.encode("utf-8"))

    delta_calls = CALL_COUNT * nbytes("\t\t\t...mediacodecAlign(codec),\n")
    delta_def = nbytes(DEF_PATCHED) - nbytes(DEF_ANCHOR)
    delta = nbytes(patched) - nbytes(text)
    if delta != delta_calls + delta_def:
        fail("unexpected size change (%d bytes)" % delta)

    (root / chunk).write_text(patched, encoding="utf-8")

    for number, line in enumerate(patched.splitlines(), 1):
        if "mediacodecAlign(codec)" in line or '"align_width"' in line:
            print("   %s:%d: %s" % (chunk, number, line.strip()))
    print("   patched %s (+%d bytes)" % (chunk, delta))


if __name__ == "__main__":
    main(sys.argv)
