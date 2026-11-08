#!/usr/bin/env bash
# Demo 1: One client -> UNIX Socket -> daemon -> output file.
# Usage: bash scripts/demo_single.sh [-n] (-n: no pauses)
cd "$(dirname "$0")/.." || exit 1
source scripts/history.sh

PIDF=/tmp/ipc_group9_server.pid
SOCK=/tmp/ipc_group9_stream.sock
SAMPLE=samples/input.txt
OUT="$HIST"
SERVER_PID=""
PAUSE=1
[[ "${1:-}" == "-n" || ! -t 0 ]] && PAUSE=0

step()  { printf '\n=== %s ===\n' "$1"; }
run()   { printf '$'; printf ' %q' "$@"; printf '\n'; "$@"; }
pause() { [[ "$PAUSE" == 0 ]] || read -rp '[Enter to continue] ' _; }
# Check whether daemon is still alive (zombies count as stopped).

daemon_alive() {
    local pid="$1"
    local state

    # Check whether the process exists.
    kill -0 "$pid" 2>/dev/null || return 1

    # Read process state safely.
    # The /proc entry may disappear while the daemon exits.
    state=$(awk '$1 == "State:" {print $2; exit}' \
        "/proc/$pid/status" 2>/dev/null) || return 1

    # Missing process, zombie or dead process = not alive.
    [[ -n "$state" && "$state" != "Z" && "$state" != "X" ]]
}


cleanup() {
    [[ -n "$SERVER_PID" ]] || return 0

    if daemon_alive "$SERVER_PID"; then
        if [[ ! -r "$PIDF" ]] ||
           [[ "$(cat "$PIDF")" != "$SERVER_PID" ]]; then
            echo "[FAIL] Server PID verification failed" >&2
            return 1
        fi

        if [[ "$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null)" != "$PWD/bin/server" ]]; then
            echo "[FAIL] Server executable mismatch" >&2
            return 1
        fi

        if ! kill -TERM "$SERVER_PID"; then
            echo "[FAIL] Cannot send SIGTERM" >&2
            return 1
        fi
    fi

    local i
    for ((i = 0; i < 350; i++)); do
        if ! daemon_alive "$SERVER_PID" &&
           [[ ! -e "$SOCK" && ! -e "$PIDF" ]]; then
            echo "[PASS] Daemon stopped; socket and PID file removed"
            return 0
        fi
        sleep 0.1
    done

    echo "[FAIL] Graceful shutdown timed out" >&2
    return 1
}

on_exit() {
    local status="$1"
    trap - EXIT
    cleanup || status=1
    exit "$status"
}

trap 'on_exit "$?"' EXIT

[[ -x bin/server && -x bin/client ]] || make || exit 1
[[ -f "$SAMPLE" ]] || { echo "Missing $SAMPLE" >&2; exit 1; }
if [[ -e "$SOCK" || -L "$SOCK" ||
      -e "$PIDF" || -L "$PIDF" ]]; then
    echo "[FAIL] Existing Socket/PID detected; inspect before Demo 1" >&2
    exit 1
fi

hist_banner "DEMO 1 - single client" "IPC and file processing: stats, upper, reverse"
START=$(hist_size)

step "1. Start daemon and check UNIX socket"
run ./bin/server -o "$OUT" || exit 1
expected_exe=$(readlink -f "$PWD/bin/server") || exit 1

for ((attempt = 0; attempt < 30; attempt++)); do
    if [[ -s "$PIDF" ]]; then
        candidate=$(cat "$PIDF" 2>/dev/null) || candidate=""

        if [[ "$candidate" =~ ^[1-9][0-9]*$ ]] &&
           daemon_alive "$candidate" &&
           [[ "$(readlink -f "/proc/$candidate/exe" 2>/dev/null)" == "$expected_exe" ]]; then
            SERVER_PID="$candidate"
            [[ -S "$SOCK" ]] && break
        fi
    fi
    sleep 0.1
done

if [[ -z "$SERVER_PID" || ! -S "$SOCK" ]] ||
   ! daemon_alive "$SERVER_PID" ||
   [[ "$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null)" != "$expected_exe" ]]; then
    echo "[FAIL] Server startup/PID verification failed" >&2
    exit 1
fi

echo "[PASS] Verified server PID $SERVER_PID and UNIX socket"
run ps -o pid,ppid,tty,stat,cmd -p "$SERVER_PID" || exit 1
run ls -l "$SOCK" || exit 1
pause

step "2. Check connection (PING)"
run ./bin/client --ping || exit 1
pause

step "3. Send input file (STATS)"
run cat "$SAMPLE" || exit 1
run ./bin/client -m stats "$SAMPLE" || exit 1
pause

step "4. Process with UPPER and REVERSE"
run ./bin/client -m upper "$SAMPLE" || exit 1
run ./bin/client -m reverse "$SAMPLE" || exit 1
pause

step "5. Show output written by server"
hist_section "$START"
hist_end "end of DEMO 1"
echo "Demo 1 finished; stopping its daemon."


