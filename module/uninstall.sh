#!/system/bin/sh
# denpa-magisk module — AGPL-3.0-or-later.
# Source: https://github.com/tgw314/denpa-magisk
# Stop denpa and drop runtime state. The config, database and
# recordings in /data/adb/denpa are kept on purpose; delete that
# directory by hand for a full reset.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
stop_service
rm -rf "$RUNDIR"
