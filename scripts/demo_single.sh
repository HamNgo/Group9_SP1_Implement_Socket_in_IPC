#!/usr/bin/env bash
# Narrated demo: ONE client offloading a task to the UNIX-socket daemon.
# Usage: ./scripts/demo_single.sh [-n]      (-n = no pauses between steps)
cd "$(dirname "$0")/.." || exit 1

PAUSE=1
[ "${1:-}" = "-n" ] && PAUSE=0
[ -t 0 ] || PAUSE=0

OUT="$PWD/output.txt"
PIDF=/tmp/ipc_group9_server.pid
SOCK=/tmp/ipc_group9_stream.sock
SAMPLE=samples/input.txt
STARTED=0

if [ -t 1 ]; then B=$(tput bold); G=$(tput setaf 2); Y=$(tput setaf 3); N=$(tput sgr0); else B=; G=; Y=; N=; fi

step()  { echo; echo "${B}${G}=== $* ===${N}"; }
say()   { echo "${Y}# $*${N}"; }
run()   { echo "${B}\$ $*${N}"; "$@"; echo; }
pause() { [ "$PAUSE" = 1 ] && read -rp "   [press Enter] " _; }

cleanup() {
    if [ "$STARTED" = 1 ] && [ -f "$PIDF" ]; then kill -TERM "$(cat "$PIDF")" 2>/dev/null; fi
}
trap cleanup EXIT

show_logs() {
    local out=""
    if command -v journalctl >/dev/null 2>&1; then
        out=$(journalctl -t ipc_server -n 8 --no-pager 2>/dev/null | grep ipc_server)
    fi
    if [ -z "$out" ] && [ -r /var/log/syslog ]; then
        out=$(grep ipc_server /var/log/syslog | tail -8)
    fi
    if [ -n "$out" ]; then echo "$out"
    else echo "(syslog not readable here - try: journalctl -t ipc_server)"; fi
}

[ -x bin/server ] && [ -x bin/client ] || make || exit 1
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "A server is already running (PID $(cat "$PIDF")). Stop it first."; exit 1
fi
rm -f "$OUT"

step "1. Start the server as a daemon"
say "double fork + setsid: it detaches from this terminal and runs in the background"
run ./bin/server -o "$OUT"
sleep 0.3
STARTED=1
say "the daemon is running, owns a UNIX socket file, and wrote a PID file"
say "note PPID=1: the daemon was re-parented to init, no terminal (TT = ?)"
run ps -o pid,ppid,tty,stat,cmd -p "$(cat "$PIDF")"
run ls -l "$SOCK"
run cat "$PIDF"
pause

step "2. Health check (PING)"
run ./bin/client --ping
pause

step "3. Offload a task: STATS mode"
say "client reads the file, sends header + data; server analyzes it and replies with the result"
run cat "$SAMPLE"
run ./bin/client -m stats "$SAMPLE"
pause

step "4. Same file, UPPERCASE mode"
run ./bin/client -m upper "$SAMPLE"
pause

step "5. Reverse-lines mode"
run ./bin/client -m reverse "$SAMPLE"
pause

step "6. What the server wrote to output.txt (with timestamps)"
run cat "$OUT"
pause

step "7. Error handling"
say "corrupted data: the checksum does not match, so the server rejects it"
./bin/client --bad-checksum "$SAMPLE"; echo
say "wrong protocol magic number: not our client, rejected"
./bin/client --bad-magic "$SAMPLE"; echo
say "missing input file: caught on the client side"
./bin/client does_not_exist.txt; echo
pause

step "8. Server-side log (syslog, since a daemon has no terminal)"
show_logs
pause

step "9. Graceful shutdown with SIGTERM"
say "server stops accepting, waits for running handlers, logs, removes socket + PID file"
run kill -TERM "$(cat "$PIDF")"
sleep 1
STARTED=0
run bash -c "ls /tmp/ipc_group9* 2>&1 || true"
say "last line of output.txt:"
run tail -n 1 "$OUT"
say "client now fails cleanly because no server is listening:"
./bin/client "$SAMPLE"
echo
echo "${B}${G}Demo finished.${N}"
