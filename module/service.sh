#!/system/bin/sh
# denpa-magisk module — AGPL-3.0-or-later.
# Source: https://github.com/tgw314/denpa-magisk
# Late-start service: bring denpa up once Android has finished
# booting. Everything runs on this device, so there is no other
# module to wait for.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

load_config
[ "$AUTOSTART" = "1" ] || exit 0

until [ "$(getprop sys.boot_completed)" = "1" ]; do
	sleep 2
done
sleep 3

start_service >> "$SVCLOG" 2>&1
