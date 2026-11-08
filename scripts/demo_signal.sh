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

alive() {
    local pid="$1" state

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    state=$(awk '$1 == "State:" {print $2; exit}'         "/proc/$pid/status" 2>/dev/null) || return 1

    [[ -n "$state" && "$state" != "Z" && "$state" != "X" ]]
}
threads() { ls "/proc/$1/task" 2>/dev/null | wc -l; }
wait_gone() {
    local pid="$1" i

    for ((i = 0; i < 350; i++)); do
        if ! alive "$pid" &&
           [[ ! -e "$SOCK" && ! -e "$PIDF" ]]; then
            echo "   [PASS] Server $pid stopped; Socket/PID removed"
            return 0
        fi
        sleep 0.1
    done

    echo "   [FAIL] Server $pid shutdown timed out or files remain" >&2
    return 1
}
show_files() {
    if [[ -e "$SOCK" ]]; then
        printf '   [EXISTS] Socket: %s\n' "$SOCK"
    else
        echo "   [REMOVED] Socket"
    fi

    if [[ -e "$PIDF" ]]; then
        printf '   [EXISTS] PID file: %s\n' "$PIDF"
    else
        echo "   [REMOVED] PID file"
    fi
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
    local rc=0 pid="${SPID[$SRV]:-}"

    if [[ "$STARTED" == 1 ]]; then
        if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
            echo "[FAIL] Cannot identify demo server PID" >&2
            rc=1
        elif alive "$pid"; then
            if [[ ! -r "$PIDF" ]] ||
               [[ "$(cat "$PIDF")" != "$pid" ]] ||
               [[ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" != "$(readlink -f "$PWD/bin/server")" ]]; then
                echo "[FAIL] Server ownership verification failed" >&2
                rc=1
            else
                kill -TERM "$pid" || rc=1
                wait_gone "$pid" || rc=1
            fi
        elif [[ -e "$SOCK" || -e "$PIDF" ]]; then
            echo "[FAIL] Server exited but resources remain" >&2
            rc=1
        fi
    fi

    rm -rf -- "$TMP" || rc=1
    return "$rc"
}

on_exit() {
    local rc="$1"
    trap - EXIT
    cleanup || rc=1
    exit "$rc"
}

trap 'on_exit "$?"' EXIT

start_server() {
    local next=$((SRV + 1))
    local pid="" i

    if [[ "$STARTED" == 1 ]]; then
        echo "[FAIL] Previous demo server is still active" >&2
        return 1
    fi

    hist_note "starting SERVER $next"
    echo "   starting $(S "$next") ..."

    if ! ./bin/server -o "$OUT" >"$TMP/start_$next.log" 2>&1; then
        sed 's/^/   /' "$TMP/start_$next.log"
        echo "[FAIL] Server failed to start" >&2
        return 1
    fi

    sed 's/^/   /' "$TMP/start_$next.log"

    for ((i = 0; i < 30; i++)); do
        if [[ -s "$PIDF" ]]; then
            pid=$(cat "$PIDF" 2>/dev/null) || pid=""

            if alive "$pid" &&
               [[ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" == "$(readlink -f "$PWD/bin/server")" ]]; then
                SRV="$next"
                SPID[$SRV]="$pid"
                STARTED=1

                if [[ -S "$SOCK" ]]; then
                    STATE[$SRV]="running"
                    echo "   [PASS] $(S "$SRV") started: PID $pid"
                    return 0
                fi
            fi
        fi
        sleep 0.1
    done

    echo "[FAIL] Server startup verification timed out" >&2
    return 1
}

[ -x bin/server ] && [ -x bin/client ] || make || exit 1
if [ -f "$PIDF" ] && alive "$(cat "$PIDF")"; then
    echo "A server is already running (PID $(cat "$PIDF")). Stop it first."; exit 1
fi
if [[ -e "$SOCK" || -L "$SOCK" || -e "$PIDF" || -L "$PIDF" ]]; then
    echo "[FAIL] Socket/PID file already exists; inspect before running Demo 3" >&2
    exit 1
fi
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
start_server || exit 1
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
if ! kill -KILL "$CPID" 2>/dev/null; then
    echo "   [FAIL] Could not kill the in-flight client" >&2
    exit 1
fi

if wait "$CPID" 2>/dev/null; then
    echo "   [FAIL] Crashed client unexpectedly exited successfully" >&2
    exit 1
fi

# Wait for the handler to detect the disconnected client.
for ((attempt=0; attempt<30; attempt++)); do
    [[ "$(threads "${SPID[1]}")" == 1 ]] && break
    sleep 0.1
done

if ! alive "${SPID[1]}" ||
   [[ "$(readlink -f "/proc/${SPID[1]}/exe" 2>/dev/null)" != "$(readlink -f "$PWD/bin/server")" ]]; then
    echo "   [FAIL] SERVER 1 did not survive the client crash" >&2
    exit 1
fi

if [[ "$(threads "${SPID[1]}")" != 1 ]]; then
    echo "   [FAIL] SERVER 1 handler did not finish after client crash" >&2
    exit 1
fi

echo "   [PASS] SERVER 1 remains alive; crashed client's handler exited"

cmd "./bin/client --ping"

if ! ./bin/client --ping >"$TMP/ping_after_crash.log" 2>&1; then
    echo "   [FAIL] SERVER 1 did not respond to PING after client crash" >&2
    cat "$TMP/ping_after_crash.log" >&2
    exit 1
fi

if ! grep -Eq 'status[[:space:]]*:[[:space:]]*OK' "$TMP/ping_after_crash.log"; then
    echo "   [FAIL] SERVER 1 PING response did not contain status OK" >&2
    cat "$TMP/ping_after_crash.log" >&2
    exit 1
fi

sed 's/^/   /' "$TMP/ping_after_crash.log"
echo "   [PASS] SERVER 1 responded to PING after client crash"
say "SERVER 1 handles a dropped client and continues accepting requests"
pause

step "3. $(S 1): graceful shutdown, SIGTERM while a request is in flight"
cmd "./bin/client --slow $SAMPLE &"
./bin/client --slow "$SAMPLE" >"$TMP/slow.log" 2>&1 &
CPID=$!
sleep 0.8
inflight_threads=$(threads "${SPID[1]}")

if ! alive "$CPID" ||
   ! alive "${SPID[1]}" ||
   [[ ! "$inflight_threads" =~ ^[0-9]+$ ]] ||
   (( inflight_threads < 2 )); then
    echo "   [FAIL] No confirmed in-flight request before SIGTERM" >&2
    exit 1
fi

echo "   [PASS] In-flight request confirmed: client PID $CPID, server threads $inflight_threads"

cmd "kill -TERM ${SPID[1]}        <-- signal sent to $(S 1) mid-request"
hist_note "step 3: SIGTERM sent to SERVER 1 (PID ${SPID[1]}) while a request is in flight"

if ! kill -TERM "${SPID[1]}"; then
    echo "   [FAIL] Could not send SIGTERM to SERVER 1" >&2
    exit 1
fi

sleep 0.4

if ! alive "${SPID[1]}" || ! alive "$CPID"; then
    echo "   [FAIL] Server/client did not remain active while finishing the request" >&2
    exit 1
fi

echo "   [PASS] SERVER 1 remained alive to finish the in-flight request"
say "a) it stopped accepting new connections: socket file is gone, a new client is refused"
show_files
cmd "./bin/client --ping"
if ./bin/client --ping >"$TMP/ping_after_term.log" 2>&1; then
    echo "   [FAIL] New client connected after SIGTERM" >&2
    cat "$TMP/ping_after_term.log" >&2
    exit 1
fi

if ! grep -q 'Cannot connect to' "$TMP/ping_after_term.log"; then
    echo "   [FAIL] PING failed for an unexpected reason" >&2
    cat "$TMP/ping_after_term.log" >&2
    exit 1
fi

sed 's/^/   /' "$TMP/ping_after_term.log"
echo "   [PASS] New connections rejected after SIGTERM"
say "b) but $(S 1) is still alive, finishing the request it already accepted"
echo "   $(S 1) alive: $(alive "${SPID[1]}" && echo YES || echo NO)"
if ! wait "$CPID"; then
    echo "   [FAIL] In-flight client exited with an error" >&2
    cat "$TMP/slow.log" >&2
    exit 1
fi

if ! grep -Eq 'status[[:space:]]*:[[:space:]]*OK' "$TMP/slow.log"; then
    echo "   [FAIL] In-flight client did not receive status OK" >&2
    cat "$TMP/slow.log" >&2
    exit 1
fi

echo "   [PASS] In-flight client completed successfully"
say "c) the in-flight client gets a normal, complete answer (look at the reply time: it started before the signal)"
sed 's/^/   /' "$TMP/slow.log"
wait_gone "${SPID[1]}" || exit 1
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
start_server || exit 1
cmd "./bin/client --slow $SAMPLE &      then:  kill -9 ${SPID[2]}   (that is $(S 2))"
./bin/client --slow "$SAMPLE" >"$TMP/kill.log" 2>&1 &
CPID=$!
sleep 0.8
hist_note "step 4: SIGKILL sent to SERVER 2 (PID ${SPID[2]}) mid-request - no 'Shutdown' line will follow"
if ! kill -KILL "${SPID[2]}"; then
    echo "[FAIL] Cannot send SIGKILL to SERVER 2" >&2
    exit 1
fi

if wait "$CPID" 2>/dev/null; then
    echo "[FAIL] Client unexpectedly succeeded after SIGKILL" >&2
    exit 1
fi

for ((attempt=0; attempt<30; attempt++)); do
    alive "${SPID[2]}" || break
    sleep 0.1
done

if alive "${SPID[2]}"; then
    echo "[FAIL] SERVER 2 is still alive" >&2
    exit 1
fi

if [[ ! -S "$SOCK" || ! -f "$PIDF" ]] ||
   [[ "$(cat "$PIDF")" != "${SPID[2]}" ]]; then
    echo "[FAIL] Expected stale socket/PID not found" >&2
    exit 1
fi

if hist_section "$START" | grep -Fq "Shutdown gracefully PID=${SPID[2]}"; then
    echo "[FAIL] SERVER 2 unexpectedly logged graceful shutdown" >&2
    exit 1
fi

echo "   [PASS] SIGKILL: client failed, server stopped, stale files remain"
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
start_server || exit 1
cmd "./bin/client $SAMPLE"
if ! ./bin/client "$SAMPLE" >"$TMP/recovery.log" 2>&1; then
    echo "[FAIL] Recovery client failed" >&2
    cat "$TMP/recovery.log" >&2
    exit 1
fi

if ! grep -Eq 'status[[:space:]]*:[[:space:]]*OK' "$TMP/recovery.log"; then
    echo "[FAIL] Recovery client did not receive OK" >&2
    cat "$TMP/recovery.log" >&2
    exit 1
fi

sed 's/^/   /' "$TMP/recovery.log"
echo "   [PASS] SERVER 3 recovered and processed client successfully"
pause

step "6. Stop $(S 3) politely, then read the whole history"
cmd "kill -TERM ${SPID[3]}"
hist_note "step 6: SIGTERM sent to SERVER 3 (PID ${SPID[3]})"
kill -TERM "${SPID[3]}"
wait_gone "${SPID[3]}" || exit 1; STARTED=0; STATE[3]="stopped gracefully (SIGTERM)"
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
