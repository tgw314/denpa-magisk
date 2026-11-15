# denpa-magisk module — AGPL-3.0-or-later.
# Source: https://github.com/tgw314/denpa-magisk
# Shared paths and process control for the denpa module.
# Sourced by ctl.sh, service.sh, action.sh and customize.sh.
# Expects MODDIR to be set.
DATA=/data/adb/denpa
CONF=$DATA/config.sh
PAYLOAD=$MODDIR/payload
LIB=$PAYLOAD/lib
SERVERDIR=$PAYLOAD/server
RUNDIR=$DATA/run
SUPPID=$RUNDIR/supervisor.pid
STOPFLAG=$RUNDIR/stop
AGENTLOG=$DATA/agent.log
SRVLOG=$DATA/server.log
SVCLOG=$DATA/service.log
PORT=3000
AGENT_PORT=25252
DENPA_VERSION=v2.45.1

CGROUP_DIR=/sys/fs/cgroup/denpa

# Processes started from the manager app (WebUI / action button)
# inherit
# the manager app's cgroup and get frozen together with the app when
# it backgrounds. Move our processes into our own top-level group,
# which the app freezer never touches. (Same lesson as the
# coax_tvserver, epgstation, edcb and konomitv modules.)
escape_app_cgroup() {
	mkdir -p "$CGROUP_DIR" 2>/dev/null
	if echo "$1" > "$CGROUP_DIR/cgroup.procs" 2>/dev/null; then
		echo "$2: escaped app cgroup -> /denpa"
	elif echo "$1" > /sys/fs/cgroup/cgroup.procs 2>/dev/null; then
		echo "$2: escaped app cgroup -> root"
	else
		echo "$2: WARNING cgroup move failed; process stays in the app group"
	fi
}

# Start each log fresh; the previous one is kept as <log>.old
# (single generation, so disk use stays bounded).
rotate_log() {
	[ -f "$1" ] && mv -f "$1" "$1.old"
}

load_config() {
	AUTOSTART=1
	[ -f "$CONF" ] && . "$CONF"
}

# Process families, found by comparing /proc/<pid>/exe by identity
# (-ef, a shell builtin check with no per-process fork). The agent
# family includes the asicend helpers it spawns for ASICEN devices.
agent_pids() {
	for p in /proc/[0-9]*; do
		if [ "$p/exe" -ef "$LIB/libdenpa_agent.so" ] 2>/dev/null || \
		   [ "$p/exe" -ef "$LIB/libasicend.so" ] 2>/dev/null || \
		   [ "$p/exe" -ef "$LIB/libasicenctl.so" ] 2>/dev/null; then
			echo "${p#/proc/}"
		fi
	done
}

server_pids() {
	for p in /proc/[0-9]*; do
		if [ "$p/exe" -ef "$LIB/libbun.so" ] 2>/dev/null; then
			echo "${p#/proc/}"
		fi
	done
}

kill_family() {
	for p in $(agent_pids) $(server_pids); do
		kill "$1" "$p" 2>/dev/null
	done
}

supervisor_pid() {
	[ -f "$SUPPID" ] || return 1
	pid=$(cat "$SUPPID" 2>/dev/null) || return 1
	[ -n "$pid" ] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	# A pid alone is not identity: the pid file survives reboots,
	# and after a reboot the number can belong to an unrelated
	# process (observed 2026-11-15: the stale file pointed at a
	# shopping app, so every start was refused as "already
	# running" and stop would have kill -9'd the app). Accept
	# the pid only if its cmdline is our supervisor.
	cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
	case "$cmdline" in
		*ctl.sh*_supervise*) ;;
		*) return 1 ;;
	esac
	echo "$pid"
	return 0
}

# Runtime layout under /data/adb/denpa. This mirrors the official
# app's DENPA_HOME: config/ (tuners.json, channels.json, tls/),
# data/ (denpa.db), media/ (raw + encoded recordings).
ensure_layout() {
	mkdir -p "$DATA/config" "$DATA/data" "$DATA/media/raw" \
		"$DATA/media/encoded" "$DATA/tmp" "$RUNDIR" "$RUNDIR/asicen" \
		"$DATA/asicen"
	# ASICEN firmware is module payload (never executed, only fed
	# to devices by asicend); refresh it from the module's CURRENT
	# location on every start. Paths captured at install time
	# cannot be trusted (customize.sh runs in modules_update/).
	cp -f "$PAYLOAD/asicen/asicen-loader.bin" "$DATA/asicen/" 2>/dev/null
	# The payload executables are stored in the zip without modes
	# (the manager installer flattens everything to 0644 anyway),
	# so restore the exec bits on every start.
	for f in libdenpa_agent.so libbun.so libffmpeg.so libffprobe.so \
		libasicend.so libasicenctl.so; do
		[ -f "$LIB/$f" ] && chmod 755 "$LIB/$f"
	done
	# User environment for the denpa server (docs/config.md keys).
	# Seeded once, never overwritten. The app fixes paths, PORT and
	# TUNER_AGENT_URL itself; here the launcher fixes them instead,
	# so keys for those are ignored even if written in this file.
	if [ ! -f "$DATA/denpa.env" ]; then
		cat > "$DATA/denpa.env" << 'EOE'
# denpa server environment (docs/config.md). The launcher reads
# KEY=VALUE lines only. Paths, PORT and TUNER_AGENT_URL are fixed
# by the launcher and cannot be changed here. After editing,
# restart the module.
TZ=Asia/Tokyo
# Who may use denpa without logging in (docs/auth.md).
TRUSTED_NETWORKS=127.0.0.0/8,::1/128,192.168.0.0/16,10.0.0.0/8
EOE
	fi
}

# The pair token shared by the agent and the server
# ($DATA/config/tls/pair-token, same file layout as install.sh and
# the Android app). The agent creates it on first start if absent;
# the server needs it at start for TUNER_AGENT_URL, so the launcher
# creates it first. 32 random bytes, base64url, like the app.
ensure_pair_token() {
	token_file="$DATA/config/tls/pair-token"
	if [ -s "$token_file" ]; then
		cat "$token_file"
		return 0
	fi
	mkdir -p "$DATA/config/tls"
	token=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
	[ -n "$token" ] || token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
	echo "$token" > "$token_file"
	chmod 600 "$token_file" 2>/dev/null
	echo "$token"
}

# The MEDIACODEC_ENCODERS value ("h264=c2.qti.avc.encoder,..."):
# the names of the hardware MediaCodec encoders, which denpa's
# hwenc probe needs spelled out (without names, ffmpeg picks by
# MIME type and lands on the software c2.android.* encoders).
# A shell script cannot call MediaCodecList, so a tiny Java port
# of the app's Encoders.kt is run through app_process instead.
# Prints an empty line on any failure (= software encoding).
mediacodec_encoders() {
	dex="$PAYLOAD/denpa-encoders.dex"
	[ -f "$dex" ] || { echo ""; return; }
	out="$RUNDIR/encoders.out"
	: > "$out"
	CLASSPATH="$dex" /system/bin/app_process /system/bin DenpaEncoders \
		> "$out" 2>/dev/null &
	hpid=$!
	n=0
	while kill -0 "$hpid" 2>/dev/null && [ $n -lt 10 ]; do
		sleep 1; n=$((n + 1))
	done
	kill -9 "$hpid" 2>/dev/null
	wait "$hpid" 2>/dev/null
	v=$(tr -d '\r\n' < "$out")
	case "$v" in
		''|*[!A-Za-z0-9=,._-]*) v= ;;
	esac
	echo "$v"
}

device_name() {
	name=$(settings get global device_name 2>/dev/null)
	case "$name" in ''|null) name=$(getprop ro.product.model) ;; esac
	echo "${name:-Android}"
}

# Extra user environment from denpa.env for the server. Lines are
# parsed literally (KEY=VALUE), never sourced: a typo in the file
# must not become shell code running as root.
apply_user_env() {
	[ -f "$DATA/denpa.env" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			''|'#'*) ;;
			*=*)
				key=${line%%=*}
				case "$key" in *[!A-Za-z0-9_]*|'') ;; *)
					export "$key=${line#*=}" ;;
				esac
				;;
		esac
	done < "$DATA/denpa.env"
}

start_agent() {
	env \
		DENPA_HOME="$DATA" \
		TMPDIR="$DATA/tmp" \
		HOME="$DATA" \
		TUNERS_FILE="$DATA/config/tuners.json" \
		CHANNELS_FILE="$DATA/config/channels.json" \
		MEDIA_DIR="$DATA/media" \
		AGENT_PORT="$AGENT_PORT" \
		AGENT_NAME="$(device_name)" \
		ASICEN_USERLAND_DIR="$LIB" \
		ASICEN_RUNTIME_DIR="$RUNDIR/asicen" \
		ASICEN_FIRMWARE="$DATA/asicen/asicen-loader.bin" \
		"$LIB/libdenpa_agent.so" >> "$AGENTLOG" 2>&1 &
	agent_pid=$!
	escape_app_cgroup "$agent_pid" agent
}

start_server() {
	token=$(cat "$DATA/config/tls/pair-token")
	enc=$(cat "$RUNDIR/encoders.txt" 2>/dev/null)
	apply_user_env
	cd "$SERVERDIR/app" || return 1
	env \
		DENPA_HOME="$DATA" \
		TMPDIR="$DATA/tmp" \
		HOME="$DATA" \
		NODE_ENV=production \
		DENPA_VERSION="$DENPA_VERSION" \
		DENPA_DB="$DATA/data/denpa.db" \
		MEDIA_DIR="$DATA/media" \
		RAW_DIR="$DATA/media/raw" \
		ENCODED_DIR="$DATA/media/encoded" \
		MPEG2_DIR="$SERVERDIR/mpeg2" \
		FONT_DIR="$SERVERDIR/font" \
		TUNER_AGENT_URL="https://127.0.0.1:$AGENT_PORT#pair=$token" \
		PORT="$PORT" \
		BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 \
		MEDIACODEC_ENCODERS="$enc" \
		FFMPEG="$LIB/libffmpeg.so" \
		FFPROBE="$LIB/libffprobe.so" \
		"$LIB/libbun.so" "$SERVERDIR/app/server.js" >> "$SRVLOG" 2>&1 &
	server_pid=$!
	escape_app_cgroup "$server_pid" server
	cd "$DATA" || true
}

# The supervisor loop (ctl.sh _supervise runs detached): keep the
# agent and the server alive independently, restarting each with
# backoff after a crash. No USB_BROKER is set on purpose: with it
# unset, the agent uses its sysfs/usbfs host and opens /dev/bus/usb
# directly as root, exactly like on Linux.
supervise() {
	escape_app_cgroup $$ supervisor
	rm -f "$STOPFLAG"
	echo $$ > "$SUPPID"
	ensure_layout
	ensure_pair_token > /dev/null
	# The codec set does not change while the device is up, so
	# collect the hardware encoder names once per supervisor run.
	mediacodec_encoders > "$RUNDIR/encoders.txt"
	echo "$(date '+%Y-%m-%d %H:%M:%S') MEDIACODEC_ENCODERS=$(cat "$RUNDIR/encoders.txt")" >> "$SVCLOG"
	agent_pid= server_pid=
	agent_next=0 server_next=0
	agent_backoff=5 server_backoff=5
	agent_started=0 server_started=0
	while [ ! -f "$STOPFLAG" ]; do
		now=$(date +%s)
		if [ -n "$agent_pid" ] && ! kill -0 "$agent_pid" 2>/dev/null; then
			echo "$(date '+%Y-%m-%d %H:%M:%S') agent exited" >> "$SVCLOG"
			agent_pid=
			[ $((now - agent_started)) -gt 60 ] && agent_backoff=5
			agent_next=$((now + agent_backoff))
			agent_backoff=$((agent_backoff * 2))
			[ $agent_backoff -gt 60 ] && agent_backoff=60
		fi
		if [ -n "$server_pid" ] && ! kill -0 "$server_pid" 2>/dev/null; then
			echo "$(date '+%Y-%m-%d %H:%M:%S') server exited" >> "$SVCLOG"
			server_pid=
			[ $((now - server_started)) -gt 60 ] && server_backoff=5
			server_next=$((now + server_backoff))
			server_backoff=$((server_backoff * 2))
			[ $server_backoff -gt 60 ] && server_backoff=60
		fi
		if [ -z "$agent_pid" ] && [ "$now" -ge "$agent_next" ]; then
			start_agent
			agent_started=$now
		fi
		if [ -z "$server_pid" ] && [ "$now" -ge "$server_next" ]; then
			start_server
			server_started=$now
		fi
		sleep 3
	done
	# Stop flag seen: TERM both parts once (the agent waits for an
	# ongoing recording to finish; stop_service escalates if the
	# supervisor itself does not return).
	[ -n "$server_pid" ] && kill -TERM "$server_pid" 2>/dev/null
	[ -n "$agent_pid" ] && kill -TERM "$agent_pid" 2>/dev/null
	rm -f "$SUPPID"
}

start_service() {
	load_config
	if pid=$(supervisor_pid); then
		echo "denpa already running (supervisor pid $pid)"
		return 0
	fi
	ensure_layout
	rm -f "$STOPFLAG"
	# Rotate once per supervisor session, not per restart attempt:
	# in a crash loop the attempts must accumulate in one log.
	rotate_log "$SVCLOG"
	rotate_log "$AGENTLOG"
	rotate_log "$SRVLOG"
	nohup sh "$MODDIR/ctl.sh" _supervise >> "$SVCLOG" 2>&1 &
	echo "denpa supervisor started"
}

stop_service() {
	mkdir -p "$RUNDIR"
	: > "$STOPFLAG"
	n=0
	while [ $n -lt 15 ]; do
		supervisor_pid > /dev/null || break
		sleep 1; n=$((n + 1))
	done
	# The agent may still be waiting for a recording to finish.
	# The user's stop wins: sweep the families, TERM then KILL.
	kill_family -TERM
	sleep 2
	kill_family -KILL
	if pid=$(supervisor_pid); then
		kill -9 "$pid" 2>/dev/null
		echo "denpa supervisor killed (pid $pid)"
	fi
	rm -f "$SUPPID"
	echo "denpa stopped"
}

stack_state() {
	if [ -n "$(agent_pids)" ] && [ -n "$(server_pids)" ]; then
		echo running
	elif [ -n "$(agent_pids)" ] || [ -n "$(server_pids)" ]; then
		echo partial
	else
		echo stopped
	fi
}

show_status() {
	ap=$(agent_pids)
	sp=$(server_pids)
	if [ -n "$ap" ]; then
		echo "agent: running (pids: $(echo $ap | tr '\n' ' ')), https://127.0.0.1:$AGENT_PORT"
	else
		echo "agent: NOT running"
	fi
	if [ -n "$sp" ]; then
		echo "server: running (pids: $(echo $sp | tr '\n' ' ')), http://127.0.0.1:$PORT"
		pid=$(echo "$sp" | head -n 1)
		[ -r "/proc/$pid/cgroup" ] && echo "server cgroup: $(grep '^0::' "/proc/$pid/cgroup" | cut -d: -f3)"
	else
		echo "server: NOT running"
	fi
	if pid=$(supervisor_pid); then
		echo "supervisor: running (pid $pid)"
	else
		echo "supervisor: NOT running"
	fi
	echo "config: $DATA/config/tuners.json / $DATA/denpa.env"
	echo "recordings: $DATA/media"
}
