import android.media.MediaCodecInfo;
import android.media.MediaCodecList;

/**
 * Java port of the denpa Android app's Encoders.kt: collect the
 * names of the hardware MediaCodec encoders and print them in the
 * MEDIACODEC_ENCODERS form denpa's hwenc.ts reads
 * ("h264=c2.qti.avc.encoder,hevc=...").
 *
 * Original: Encoders.kt from danything/denpa
 * (https://github.com/danything/denpa), licensed AGPL-3.0-or-later.
 * Ported from Kotlin to Java by tgw314 on 2026-11-14; this file is
 * AGPL-3.0-or-later as well (see LICENSE in the repository, or
 * licenses/LICENSE-module.txt in the module zip).
 *
 * The module runs this with app_process at server start
 * (CLASSPATH=<this dex> app_process /system/bin DenpaEncoders),
 * because a plain shell script cannot call MediaCodecList.
 * Filtering matches the app exactly: REGULAR_CODECS order (the
 * device's recommended order), isEncoder, isHardwareAccelerated,
 * not isAlias, first match per codec. Any failure prints an empty
 * line, which denpa treats as "no hardware encoders" and falls
 * back to software encoding.
 */
public final class DenpaEncoders {
    public static void main(String[] args) {
        String[][] mimes = {
            {"h264", "video/avc"},
            {"hevc", "video/hevc"},
            {"av1", "video/av01"},
        };
        StringBuilder out = new StringBuilder();
        try {
            MediaCodecInfo[] infos =
                new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos();
            for (String[] pair : mimes) {
                for (MediaCodecInfo info : infos) {
                    if (!info.isEncoder() || !info.isHardwareAccelerated() || info.isAlias()) {
                        continue;
                    }
                    boolean match = false;
                    for (String type : info.getSupportedTypes()) {
                        if (type.equalsIgnoreCase(pair[1])) {
                            match = true;
                            break;
                        }
                    }
                    if (match) {
                        if (out.length() > 0) out.append(',');
                        out.append(pair[0]).append('=').append(info.getName());
                        break;
                    }
                }
            }
        } catch (Throwable ignored) {
            // Print whatever was collected (possibly empty).
        }
        System.out.println(out.toString());
    }
}
