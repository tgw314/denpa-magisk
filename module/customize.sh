#!/system/bin/sh
# denpa-magisk module — AGPL-3.0-or-later.
# Source: https://github.com/tgw314/denpa-magisk
# Install-time setup: persistent data under /data/adb/denpa so that
# module updates (which replace the module directory) keep the
# config, the database and the recordings.
# NOTE: nothing module-owned is baked into the persistent config
# here. customize.sh runs with MODPATH pointing at modules_update/,
# which moves to modules/ on reboot; ensure_layout() re-derives the
# module-owned paths from the module's current location on every
# start.
DATA=/data/adb/denpa
mkdir -p "$DATA/run"
if [ ! -f "$DATA/config.sh" ]; then
	cat > "$DATA/config.sh" << 'EOC'
# denpa module config. Read by the module's service script.
# AUTOSTART: start denpa at boot (1) or only by hand (0).
AUTOSTART=1
EOC
fi
MODDIR=$MODPATH
. "$MODPATH/common.sh"
ensure_layout
for f in libdenpa_agent.so libbun.so libffmpeg.so libffprobe.so \
	libasicend.so libasicenctl.so; do
	set_perm "$MODPATH/payload/lib/$f" 0 0 0755
done
set_perm "$MODPATH/ctl.sh" 0 0 0755
ui_print "- denpa installed (payload: official APK $DENPA_VERSION, unmodified)"
ui_print "- Config: /data/adb/denpa/config/tuners.json"
ui_print "- Recordings: /data/adb/denpa/media"
ui_print "- Do NOT use the official denpa app at the same time"
ui_print "- Reboot, then open http://127.0.0.1:3000 on this phone"
