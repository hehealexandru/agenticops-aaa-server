#!/bin/bash
# Lint and integration tests for the AgenticOps AAA server image.
#
#   tests/run.sh                 shellcheck, docker build, then all container tests
#   SKIP_BUILD=1 tests/run.sh    reuse an existing $IMAGE
#
# Requires: docker (Docker Engine), shellcheck. Takes about 2 minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-agenticops-aaa-server:test}"
KEY="AgenticOpsLabKey2026"
PW="AgentPass99"
C="aaa-test-$$"
VOL="aaa-test-data-$$"
SPY_PATH="/tmp/spy:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

passed=0
failed=0

ok()   { passed=$((passed + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { failed=$((failed + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

cleanup() {
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Start the test container. Extra docker run options go first, e.g. -e VAR=x.
run_tty() {
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker run -dit --name "$C" -v "$VOL:/data" -e AAA_RADIUS_KEY="$KEY" \
        --health-interval=2s --health-start-period=1s --health-retries=1 --health-timeout=5s \
        "$@" "$IMAGE" >/dev/null
}

ex()  { docker exec "$C" "$@"; }
exi() { docker exec -i "$C" "$@"; }
on_volume() { docker run --rm -v "$VOL:/data" --entrypoint /bin/sh "$IMAGE" -c "$1"; }

# wait_until <seconds> <command...>
wait_until() {
    local t="$1"; shift
    for _ in $(seq $((t * 4))); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}

health()     { docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null; }
is_healthy() { [ "$(health)" = healthy ]; }
is_exited()  { [ "$(docker inspect -f '{{.State.Status}}' "$C")" = exited ]; }
rad_pid()    { ex sed -n 's/^pid=//p' /run/aaa/radius.state; }
answering()  { ex aaa-healthcheck; }
new_pid()    { local p; p="$(rad_pid)"; [ -n "$p" ] && [ "$p" != "$1" ] && answering; }

auth() { printf '%s\n' "$2" | exi radius-user test "$1" 2>&1 || true; }

# console <script>: attach to the container console through a pseudo-terminal
# (like GNS3 does), type the given lines and print what the console shows.
# A line "^C" sends Ctrl-C, a line "...N" waits N seconds.
console() {
    python3 - "$C" "$1" <<'PY'
import os, pty, select, subprocess, sys, time
name, script = sys.argv[1], sys.argv[2]
master, slave = pty.openpty()
proc = subprocess.Popen(["docker", "attach", name], stdin=slave, stdout=slave, stderr=slave)
out = b""
def drain(seconds):
    global out
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                out += os.read(master, 4096)
            except OSError:
                return
drain(1)
for line in script.split("\n"):
    if line == "^C":
        os.write(master, b"\x03")
    elif line.startswith("..."):
        drain(float(line[3:]))
        continue
    else:
        os.write(master, line.encode() + b"\r")
    drain(0.5)
drain(1)
proc.kill()
sys.stdout.write(out.decode(errors="replace"))
PY
}

console_ctrl_c() {
    console $'sleep 30\n...1\n^C\necho alive-$((40+2))\n...2' | grep -q 'alive-42'
}

missing=()
for tool in docker shellcheck python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "tests/run.sh: missing required tools: ${missing[*]}" >&2
    echo "  Ubuntu: sudo apt install ${missing[*]/docker/docker-ce}" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
step "shellcheck"
check "shellcheck -x on all scripts" shellcheck -x bin/* lib/*.sh tests/*.sh

if [ "${SKIP_BUILD:-0}" != 1 ]; then
    step "docker build"
    docker build -q -t "$IMAGE" . >/dev/null
    ok "image $IMAGE built"
fi

# ---------------------------------------------------------------------------
step "startup and authentication"
run_tty
check "container becomes healthy (Status-Server answered)" wait_until 30 is_healthy
check "tini is PID 1" sh -c "docker exec $C cat /proc/1/cmdline | tr '\\0' ' ' | grep -q '^/usr/bin/tini'"
check "Ctrl-C on the console interrupts a command, the shell survives" console_ctrl_c
printf '%s\n%s\n' "$PW" "$PW" | exi radius-user add ai-agent agent >/dev/null 2>&1
check "profile ai-agent created" sh -c "docker exec $C radius-user list | grep -q '^ai-agent .*agent'"
check "correct password -> Access-Accept" grep -q "Access-Accept" <<< "$(auth ai-agent "$PW")"
check "wrong password -> Access-Reject"   grep -q "Access-Reject" <<< "$(auth ai-agent WrongPass1)"
acct_start() {
    printf 'User-Name = "ai-agent"\nAcct-Status-Type = Start\nAcct-Session-Id = "test-1"\nNAS-IP-Address = 127.0.0.1\n' \
        | exi radclient -q -r 1 -t 2 -S /run/aaa/radius.secret 127.0.0.1:1813 acct
}
check "accounting Start -> Accounting-Response" acct_start
check "accounting record written in /data/radacct" ex sh -c 'grep -q "Acct-Session-Id = \"test-1\"" /data/radacct/127.0.0.1/detail-*'

# ---------------------------------------------------------------------------
step "shared secret never on a command line"
exi sh -c 'mkdir -p /tmp/spy && cat > /tmp/spy/radclient && chmod 755 /tmp/spy/radclient' <<'SPY'
#!/bin/sh
echo "$*" >> /tmp/spy/args
exec /usr/bin/radclient "$@"
SPY
printf '%s\n' "$PW" | docker exec -i -e PATH="$SPY_PATH" "$C" radius-user test ai-agent >/dev/null 2>&1 || true
docker exec -e PATH="$SPY_PATH" "$C" aaa-healthcheck >/dev/null 2>&1 || true
args="$(ex cat /tmp/spy/args 2>/dev/null || true)"
check "radclient was called by radius-user test and aaa-healthcheck" [ "$(wc -l <<< "$args")" -ge 2 ]
check "radclient arguments use -S <file>" grep -q -- "-S /run/aaa/radius.secret" <<< "$args"
absent() { ! grep -qF -- "$1" <<< "$2"; }
check "AAA_RADIUS_KEY absent from radclient arguments" absent "$KEY" "$args"
check "secret file is root-only (600)" sh -c "[ \"\$(docker exec $C stat -c %a /run/aaa/radius.secret)\" = 600 ]"

# ---------------------------------------------------------------------------
step "intentional restart"
pid="$(rad_pid)"
check "radius-user restart succeeds" sh -c "docker exec $C radius-user restart | grep -q 'FreeRADIUS restarted'"
check "FreeRADIUS has a new pid and answers" new_pid "$pid"
check "intentional restart is not counted as a crash" sh -c "docker exec $C grep -q '^restarts=0' /run/aaa/radius.state"

# ---------------------------------------------------------------------------
step "crash recovery"
pid="$(rad_pid)"
ex pkill -KILL -x freeradius
check "supervisor restarts FreeRADIUS after kill -9" wait_until 15 new_pid "$pid"
check "crash is logged in /data/log/supervisor.log" ex grep -q "exited unexpectedly (status 137)" /data/log/supervisor.log
check "restart counter is 1" ex grep -q '^restarts=1' /run/aaa/radius.state
check "authentication works after the restart" grep -q "Access-Accept" <<< "$(auth ai-agent "$PW")"
check "no zombie processes" sh -c "! docker exec $C ps -eo stat= | grep -q '^Z'"

# ---------------------------------------------------------------------------
step "clean stop"
t0="$(date +%s)"
docker stop -t 10 "$C" >/dev/null
t1="$(date +%s)"
check "docker stop finishes in under 5 s (took $((t1 - t0)) s)" [ $((t1 - t0)) -lt 5 ]
check "exit code 0 on docker stop" [ "$(docker inspect -f '{{.State.ExitCode}}' "$C")" = 0 ]
check "FreeRADIUS stop logged" on_volume "tail -n 3 /data/log/supervisor.log | grep -q 'FreeRADIUS stopped'"
check "no failure marker after a clean stop" on_volume "[ ! -e /data/state/radius.failed ]"

# ---------------------------------------------------------------------------
step "give up after too many crashes (AAA_MAX_RESTARTS=2)"
run_tty -e AAA_MAX_RESTARTS=2
check "container healthy" wait_until 30 is_healthy
for i in 1 2 3; do
    pid="$(rad_pid)"
    ex pkill -KILL -x freeradius || true
    [ "$i" = 3 ] || wait_until 15 new_pid "$pid" || true
done
check "container stops by itself" wait_until 20 is_exited
check "exit code 1 (visible failure)" [ "$(docker inspect -f '{{.State.ExitCode}}' "$C")" = 1 ]
check "failure marker /data/state/radius.failed written" on_volume "grep -q 'exited unexpectedly 3 times' /data/state/radius.failed"
check "failure report written in /data/log" on_volume "ls /data/log/radius-failure-*.log"
check "console shows the give-up message" sh -c "docker logs $C 2>&1 | grep -q 'giving up and stopping the container'"

# ---------------------------------------------------------------------------
step "maintenance mode after a failure"
run_tty
check "console shows MAINTENANCE MODE banner" wait_until 10 sh -c "docker logs $C 2>&1 | grep -q 'MAINTENANCE MODE'"
check "FreeRADIUS is not started" sh -c "! docker exec $C pidof freeradius"
check "health is unhealthy" wait_until 15 sh -c "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $C)\" = unhealthy ]"
check "radius-user status reports maintenance mode" sh -c "docker exec $C radius-user status | grep -q 'MAINTENANCE MODE'"
check "profiles can be managed in maintenance mode" sh -c "printf '%s\n%s\n' '$PW' '$PW' | docker exec -i $C radius-user add netadmin admin 2>&1 | grep -q \"Profile 'netadmin' created\""
check "radius-user start brings FreeRADIUS up" sh -c "docker exec $C radius-user start | grep -q 'FreeRADIUS started'"
check "failure marker removed" ex sh -c '[ ! -e /data/state/radius.failed ]'
check "container becomes healthy" wait_until 30 is_healthy
check "authentication works (profile from maintenance mode)" grep -q "Access-Accept" <<< "$(auth netadmin "$PW")"

# ---------------------------------------------------------------------------
step "broken configuration at startup -> maintenance mode"
docker stop "$C" >/dev/null
on_volume "printf 'broken-user\tCrypt-Password := \n\tthis is not valid\n' > /data/users.d/broken-user"
run_tty
check "console shows MAINTENANCE MODE banner" wait_until 10 sh -c "docker logs $C 2>&1 | grep -q 'MAINTENANCE MODE'"
check "reason is the configuration check" ex grep -q "configuration check failed at startup" /data/state/radius.failed
check "radius-user start refuses a broken configuration" sh -c "! docker exec $C radius-user start"
check "failure marker kept after the refused start" ex test -e /data/state/radius.failed
ex rm -f /data/users.d/broken-user
ex radius-user rebuild --no-restart
check "radius-user start works after the fix" sh -c "docker exec $C radius-user start | grep -q 'FreeRADIUS started'"
check "container becomes healthy" wait_until 30 is_healthy

step "exit on the console"
console $'exit\n...2' >/dev/null
check "container stops when the console shell exits" wait_until 10 is_exited
check "exit code 0" [ "$(docker inspect -f '{{.State.ExitCode}}' "$C")" = 0 ]

# ---------------------------------------------------------------------------
step "without a TTY (docker run -d)"
docker rm -f "$C" >/dev/null
docker run -d --name "$C" -v "$VOL:/data" -e AAA_RADIUS_KEY="$KEY" \
    --health-interval=2s --health-start-period=1s --health-retries=1 "$IMAGE" >/dev/null
check "container becomes healthy" wait_until 30 is_healthy
check "authentication works" grep -q "Access-Accept" <<< "$(auth ai-agent "$PW")"
t0="$(date +%s)"
docker stop -t 10 "$C" >/dev/null
t1="$(date +%s)"
check "docker stop finishes in under 5 s (took $((t1 - t0)) s)" [ $((t1 - t0)) -lt 5 ]
check "exit code 0" [ "$(docker inspect -f '{{.State.ExitCode}}' "$C")" = 0 ]

# ---------------------------------------------------------------------------
step "input validation"
check "refuses to start without AAA_RADIUS_KEY" sh -c "! docker run --rm $IMAGE"
check "refuses a non-numeric AAA_MAX_RESTARTS" sh -c "! docker run --rm -e AAA_RADIUS_KEY=$KEY -e AAA_MAX_RESTARTS=abc $IMAGE"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ]