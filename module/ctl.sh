#!/system/bin/sh
# denpa-magisk module — AGPL-3.0-or-later.
# Source: https://github.com/tgw314/denpa-magisk
# Control entry point: ctl.sh start|stop|restart|status|state
MODDIR=${0%/*}
. "$MODDIR/common.sh"

case "$1" in
	start) start_service ;;
	stop) stop_service ;;
	restart) stop_service; start_service ;;
	_supervise) supervise ;;
	status) show_status ;;
	state) stack_state ;;
	*) echo "usage: ctl.sh start|stop|restart|status|state" >&2; exit 2 ;;
esac
