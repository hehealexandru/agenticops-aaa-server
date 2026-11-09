# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Shared paths and helpers for the AgenticOps AAA server scripts.
# Sourced by aaa-entrypoint, aaa-supervise, aaa-healthcheck and radius-user.

RADDB=/etc/freeradius/3.0
DATA=/data
LOG_DIR="$DATA/log"
STATE_DIR="$DATA/state"           # persistent: failure markers
RUN_DIR=/run/aaa                  # volatile: pids, service state, secret file

RADIUS_LOG="$LOG_DIR/radius.log"
SUPERVISOR_LOG="$LOG_DIR/supervisor.log"
RADIUS_SECRET_FILE="$RUN_DIR/radius.secret"
MAIN_PID_FILE="$RUN_DIR/main.pid"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Log a supervisor event to the persistent log and to the console.
aaa_log() {
    local line
    line="$(ts) aaa-server: $*"
    printf '%s\n' "$line" >> "$SUPERVISOR_LOG" 2>/dev/null || true
    printf '%s\n' "$line" >&2
}

service_label() { case "$1" in radius) echo FreeRADIUS ;; *) echo "$1" ;; esac; }
failed_marker() { printf '%s/%s.failed' "$STATE_DIR" "$1"; }
state_file()    { printf '%s/%s.state' "$RUN_DIR" "$1"; }
supervise_pid_file() { printf '%s/%s.supervise.pid' "$RUN_DIR" "$1"; }

# state_get <service> <key>: read one key=value from the volatile state file.
state_get() {
    sed -n "s/^$2=//p" "$(state_file "$1")" 2>/dev/null | head -n 1
}

# state_set <service> <state> <pid> <restarts>: atomically rewrite the state file.
state_set() {
    local f tmp
    f="$(state_file "$1")"
    tmp="$f.tmp.$$"
    printf 'state=%s\npid=%s\nrestarts=%s\nsince=%s\n' "$2" "$3" "$4" "$(ts)" > "$tmp"
    mv -f "$tmp" "$f"
}

# supervisor_pid <service>: print the pid of a live supervisor, or fail.
supervisor_pid() {
    local pid
    pid="$(cat "$(supervise_pid_file "$1")" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

main_pid() {
    local pid
    pid="$(cat "$MAIN_PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

# radius_probe: send a Status-Server request to the local server.
# The shared secret is read from a root-only file (radclient -S), so it never
# appears on a command line. Returns 0 only if the server answers.
radius_probe() {
    [ -r "$RADIUS_SECRET_FILE" ] || return 1
    printf 'Message-Authenticator = 0x00\n' \
        | radclient -q -S "$RADIUS_SECRET_FILE" -r 1 -t 2 127.0.0.1:1812 status >/dev/null 2>&1
}

# radius_config_ok: run "freeradius -C" quietly.
radius_config_ok() { freeradius -C >/dev/null 2>&1; }

# write_failure_report <service> <reason>
# Writes a report to /data/log, creates the persistent failure marker and
# prints the report path. The next container start enters maintenance mode.
write_failure_report() {
    local service="$1" reason="$2" report
    report="$LOG_DIR/$service-failure-$(date '+%Y%m%d-%H%M%S').log"
    {
        echo "AgenticOps AAA server - $(service_label "$service") failure report"
        echo "Time:   $(ts)"
        echo "Reason: $reason"
        echo
        echo "=== Last 10 errors in $RADIUS_LOG ==="
        grep -E ' : (Error|ERROR):' "$RADIUS_LOG" 2>/dev/null | tail -n 10 || true
        echo
        echo "=== Configuration check (freeradius -C) ==="
        if radius_config_ok; then
            echo "OK: the configuration is valid, the failure happened at runtime"
        else
            echo "FAILED (freeradius -XC, last 30 lines):"
            freeradius -XC 2>&1 | tail -n 30
        fi
        echo
        echo "=== Last 50 lines of $RADIUS_LOG ==="
        tail -n 50 "$RADIUS_LOG" 2>/dev/null || echo "(no log)"
        echo
        echo "=== Last 20 lines of $SUPERVISOR_LOG ==="
        tail -n 20 "$SUPERVISOR_LOG" 2>/dev/null || echo "(no log)"
    } > "$report" 2>&1
    mkdir -p "$STATE_DIR"
    printf 'time=%s\nreason=%s\nreport=%s\n' "$(ts)" "$reason" "$report" > "$(failed_marker "$service")"
    printf '%s\n' "$report"
}

# maintenance_banner <service>: explain the failure and how to recover.
maintenance_banner() {
    local marker
    marker="$(failed_marker "$1")"
    cat >&2 <<BANNER

############################################################################
 MAINTENANCE MODE: $(service_label "$1") is NOT running (it failed and was not restarted)
   Failed at: $(sed -n 's/^time=//p' "$marker")
   Reason:    $(sed -n 's/^reason=//p' "$marker")
   Report:    $(sed -n 's/^report=//p' "$marker")
   Logs:      $RADIUS_LOG, $SUPERVISOR_LOG
 Fix the cause, then start it with:  radius-user start
############################################################################

BANNER
}