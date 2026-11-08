
    
  
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
cleanup() {
    # Only stop the daemon this script started.
    if [[ -n "$SERVER_PID" && -r "$PIDF" ]] &&
       [[ "$(cat "$PIDF")" == "$SERVER_PID" ]]; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

[[ -x bin/server && -x bin/client ]] || make || exit 1
[[ -f "$SAMPLE" ]] || { echo "Missing $SAMPLE" >&2; exit 1; }
if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "Server already running. Stop it before Demo 1." >&2
    exit 1
fi

hist_banner "DEMO 1 - single client" "IPC and file processing: stats, upper, reverse"
START=$(hist_size)

step "1. Start daemon and check UNIX socket"
run ./bin/server -o "$OUT" || exit 1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$PIDF" && -S "$SOCK" ]] && break
    sleep 0.2
done
[[ -s "$PIDF" && -S "$SOCK" ]] || { echo "Server did not start correctly" >&2; exit 1; }
SERVER_PID=$(cat "$PIDF")
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


