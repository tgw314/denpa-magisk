#!/system/bin/sh
# denpa-magisk module — AGPL-3.0-or-later.
# Source: https://github.com/tgw314/denpa-magisk
# Action button: restart denpa and show its state.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

echo "== denpa =="
stop_service
start_service
sleep 3
show_status
echo
echo "-- last agent log lines --"
tail -n 8 "$AGENTLOG" 2>/dev/null
echo
echo "-- last server log lines --"
tail -n 8 "$SRVLOG" 2>/dev/null
