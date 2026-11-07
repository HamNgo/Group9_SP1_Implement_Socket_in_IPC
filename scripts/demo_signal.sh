#!/usr/bin/env bash
# Narrated demo: signals, graceful shutdown, and surviving failures.
# Three separate server processes are started, named SERVER 1 / 2 / 3.
# Usage: ./scripts/demo_signal.sh [-n]      (-n = no pauses between steps)
cd "$(dirname "$0")/.." || exit 1
source scripts/history.sh

PAUSE=1
[ "${1:-}" = "-n" ] && PAUSE=0
[ -t 0 ] || PAUSE=0

PIDF=/tmp/ipc_group9_server.pid
SOCK=/tmp/ipc_group9_stream.sock
SAMPLE=samples/input.txt
OUT=$HIST
TMP=$(mktemp -d)
STARTED=0

if [ -t 1 ]; then
    B=$(tput bold); G=$(tput setaf 2); Y=$(tput setaf 3); X=$(tput sgr0)
    C1=$(tput setaf 6); C2=$(tput setaf 5); C3=$(tput setaf 12)
else B=; G=; Y=; X=; C1=; C2=; C3=; fi
COL=("" "$C1" "$C2" "$C3")

SRV=0                 # number of the current/last server (1..3)
declare -a SPID STATE # per-server PID and how it ended

# S() ends with a full reset, which would also cancel the colour of the line it sits in.
# recolor() re-applies the line's own colour after every reset inside the text.
recolor() { local m=$1; [ -n "$X" ] && m=${m//"$X"/"$X$2"}; printf '%s' "$m"; }
step()  { echo; echo "${B}${G}=== $(recolor "$*" "$B$G") ===${X}"; }
say()   { echo "${Y}# $(recolor "$*" "$Y")${X}"; }
cmd()   { echo "${B}\$ $(recolor "$*" "$B")${X}"; }
pause() { [ "$PAUSE" = 1 ] && read -rp "   [press Enter] " _; }
S()     { echo "${B}${COL[$1]}SERVER $1${X}"; }                  # coloured name

alive()   { [ -r "/proc/$1/status" ] && ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status"; }
threads() { ls "/proc/$1/task" 2>/dev/null | wc -l; }
wait_gone() { local i; for i in $(seq 1 150); do alive "$1" || return 0; sleep 0.1; done; return 1; }
show_files() {
    if ls "$SOCK" "$PIDF" >/dev/null 2>&1; then ls -1 "$SOCK" "$PIDF" 2>/dev/null | sed 's/^/   /'
    else echo "   (none: socket file and PID file are both gone)"; fi
}

roster() {
    echo "   ${B}Servers so far:${X}"
    local i st
    for i in $(seq 1 "$SRV"); do
        st=${STATE[$i]}
        if [ "$i" = "$SRV" ] && [ "$st" = "running" ] && alive "${SPID[$i]}"; then st="running"; fi
        printf "   %s  PID %-6s %s\n" "$(S "$i")" "${SPID[$i]}" "$st"
    done
}

cleanup() {
    if [ "$STARTED" = 1 ] && [ -f "$PIDF" ]; then kill -TERM "$(cat "$PIDF")" 2>/dev/null; sleep 0.5; fi
    rm -rf "$TMP"
}
trap cleanup EXIT

start_server() {
    SRV=$((SRV + 1))
    hist_note "starting SERVER $SRV"
    echo "   starting $(S "$SRV") ..."
    ./bin/server -o "$OUT" | sed 's/^/   /' || { echo "server failed to start"; exit 1; }
    STARTED=1; sleep 0.3
    SPID[$SRV]=$(cat "$PIDF")
    STATE[$SRV]="running"
    echo "   $(S "$SRV") is up: PID ${SPID[$SRV]}"
}

[ -x bin/server ] && [ -x bin/client ] || make || exit 1
if [ -f "$PIDF" ] && alive "$(cat "$PIDF")"; then
    echo "A server is already running (PID $(cat "$PIDF")). Stop it first."; exit 1
fi
rm -f "$SOCK" "$PIDF"
hist_banner "DEMO 3 - signals and shutdown" \
            "SERVER 1: survives a crashing client, then stopped politely (SIGTERM)" \
            "SERVER 2: killed hard (SIGKILL) - EXPECTED: it has NO 'Shutdown' line" \
            "SERVER 3: starts over SERVER 2's stale socket, then stopped politely"
START=$(hist_size)

step "0. The plan: three server processes, one after the other"
echo "   $(S 1)  step 1-3   survives a crashing client, then is stopped politely (SIGTERM)"
echo "   $(S 2)  step 4     is killed hard (SIGKILL) and leaves a mess behind"
echo "   $(S 3)  step 5-6   starts on top of that mess, works, then is stopped politely"
echo
say "only ONE server runs at any time. They take turns, because they all use the same socket file."
say "SIGTERM = polite (finish work, clean up)   SIGKILL = instant death (cannot be caught)   SIGPIPE = ignored"
say "a --slow client sends its file in 5 chunks over ~2 s, so a request stays 'in flight' for a while"
pause

step "1. Start $(S 1)"
cmd "./bin/server -o output.txt"
start_server
echo "   threads: $(threads "${SPID[1]}")  (just the main thread, idle)"
pause

step "2. $(S 1): a client crashes in the middle of sending"
say "the server is blocked reading that client's data when the client is killed (SIGKILL)"
cmd "./bin/client --slow $SAMPLE &     then:  kill -9 <client>"
./bin/client --slow "$SAMPLE" >"$TMP/crash.log" 2>&1 &
CPID=$!
sleep 0.8
echo "   $(S 1) threads while the request is in flight: $(threads "${SPID[1]}")  (main + 1 handler)"
hist_note "step 2: client killed mid-transfer (SERVER 1, PID ${SPID[1]}, keeps running)"
{ kill -9 "$CPID"; wait "$CPID"; } 2>/dev/null
sleep 0.5
echo "   client killed. $(S 1) still alive: $(alive "${SPID[1]}" && echo YES || echo NO)"
echo "   $(S 1) threads now: $(threads "${SPID[1]}")  (the handler noticed, cleaned up and exited)"
cmd "./bin/client --ping"
./bin/client --ping | sed 's/^/   /'
say "SIGPIPE is ignored, the half-received data was discarded, nothing leaked, the server carries on"
pause

step "3. $(S 1): graceful shutdown, SIGTERM while a request is in flight"
cmd "./bin/client --slow $SAMPLE &"
./bin/client --slow "$SAMPLE" >"$TMP/slow.log" 2>&1 &
CPID=$!
sleep 0.8
echo "   $(S 1) threads: $(threads "${SPID[1]}")  (a request is being received right now)"
cmd "kill -TERM ${SPID[1]}        <-- signal sent to $(S 1) mid-request"
hist_note "step 3: SIGTERM sent to SERVER 1 (PID ${SPID[1]}) while a request is in flight"
kill -TERM "${SPID[1]}"
sleep 0.4
say "a) it stopped accepting new connections: socket file is gone, a new client is refused"
show_files
cmd "./bin/client --ping"
./bin/client --ping 2>&1 | sed 's/^/   /'
say "b) but $(S 1) is still alive, finishing the request it already accepted"
echo "   $(S 1) alive: $(alive "${SPID[1]}" && echo YES || echo NO)"
wait "$CPID"
say "c) the in-flight client gets a normal, complete answer (look at the reply time: it started before the signal)"
sed 's/^/   /' "$TMP/slow.log"
wait_gone "${SPID[1]}"
STARTED=0; STATE[1]="stopped gracefully (SIGTERM): finished its request, cleaned up"
say "d) only now does $(S 1) exit, and it removed its files"
echo "   $(S 1) alive: $(alive "${SPID[1]}" && echo YES || echo NO)"
show_files
say "e) its last words in the output file:"
tail -n 1 "$OUT" | sed 's/^/   /'
echo; roster
pause

step "4. Start $(S 2), then kill it hard (SIGKILL) while a request is in flight"
say "SIGKILL cannot be caught: no handler runs, no cleanup, no goodbye"
start_server
cmd "./bin/client --slow $SAMPLE &      then:  kill -9 ${SPID[2]}   (that is $(S 2))"
./bin/client --slow "$SAMPLE" >"$TMP/kill.log" 2>&1 &
CPID=$!
sleep 0.8
hist_note "step 4: SIGKILL sent to SERVER 2 (PID ${SPID[2]}) mid-request - no 'Shutdown' line will follow"
kill -9 "${SPID[2]}"
wait "$CPID" 2>/dev/null
STARTED=0; STATE[2]="KILLED (SIGKILL): no cleanup, no goodbye"
sleep 0.3
say "the client got no answer:"
sed 's/^/   /' "$TMP/kill.log"
say "and $(S 2) left garbage behind: a stale socket file and PID file"
show_files
echo; roster
pause

step "5. Start $(S 3) on top of $(S 2)'s mess"
say "$(S 3) probes the old socket with connect(): refused -> nobody owns it -> delete it and bind again"
cmd "./bin/server -o output.txt"
start_server
cmd "./bin/client $SAMPLE"
./bin/client "$SAMPLE" | sed 's/^/   /'
pause

step "6. Stop $(S 3) politely, then read the whole history"
cmd "kill -TERM ${SPID[3]}"
hist_note "step 6: SIGTERM sent to SERVER 3 (PID ${SPID[3]})"
kill -TERM "${SPID[3]}"
wait_gone "${SPID[3]}"; STARTED=0; STATE[3]="stopped gracefully (SIGTERM)"
show_files
echo; roster
echo
say "the [SYSTEM] and [DEMO] lines of this demo in output.txt, labelled with the server each PID belongs to:"
SEDARGS=()
for i in $(seq 1 "$SRV"); do SEDARGS+=(-e "s/PID=${SPID[$i]}/PID=${SPID[$i]}   <- SERVER $i/"); done
hist_section "$START" | grep -E "SYSTEM|DEMO" | sed "${SEDARGS[@]}" | sed 's/^/   /'
say "$(S 2) has a 'started' line but no 'Shutdown' line: that is how you can tell it was killed"
echo
say "requests that were fully received and stored (these PIDs are CLIENT processes, not servers):"
hist_section "$START" | grep -E "Request from|File +:" | sed 's/^/   /'
say "the two interrupted transfers (crashed client, killed $(S 2)) were never stored: no partial data"
hist_end "end of DEMO 3"
echo; echo "${B}${G}Demo finished.${X}"
