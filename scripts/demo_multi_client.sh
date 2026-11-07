#!/usr/bin/env bash
# Narrated demo: MANY clients at once -> threads + race condition + mutex.
# Usage: ./scripts/demo_multi_client.sh [-n] [num_clients]   (-n = no pauses, default 3 clients)
cd "$(dirname "$0")/.." || exit 1
source scripts/history.sh

PAUSE=1; N=3
for a in "$@"; do
    case "$a" in -n) PAUSE=0 ;; ''|*[!0-9]*) ;; *) N=$a ;; esac
done
[ -t 0 ] || PAUSE=0
LINES_PER_FILE=3

PIDF=/tmp/ipc_group9_server.pid
TMP=$(mktemp -d)
STARTED=0
if [ -t 1 ]; then COLOR=1; else COLOR=0; fi

if [ "$COLOR" = 1 ]; then B=$(tput bold); G=$(tput setaf 2); Y=$(tput setaf 3); X=$(tput sgr0); else B=; G=; Y=; X=; fi
recolor() { local m=$1; [ -n "$X" ] && m=${m//"$X"/"$X$2"}; printf '%s' "$m"; }
step()  { echo; echo "${B}${G}=== $(recolor "$*" "$B$G") ===${X}"; }
say()   { echo "${Y}# $(recolor "$*" "$Y")${X}"; }
pause() { [ "$PAUSE" = 1 ] && read -rp "   [press Enter] " _; }

cleanup() {
    if [ "$STARTED" = 1 ] && [ -f "$PIDF" ]; then kill -TERM "$(cat "$PIDF")" 2>/dev/null; sleep 0.5; fi
    rm -rf "$TMP"
}
trap cleanup EXIT

start_server() {   # extra server flags as arguments; always writes to the history file
    ./bin/server -o "$HIST" "$@" >/dev/null || { echo "server failed to start"; exit 1; }
    STARTED=1; sleep 0.3
}
stop_server() { kill -TERM "$(cat "$PIDF")" 2>/dev/null; sleep 1; STARTED=0; }

# Prints the file line by line with a gutter showing WHICH CLIENT WROTE each line.
# '!' marks a line that appeared while the previous client's entry was still unfinished.
view() {   # $1 = file containing one run's section
    awk -v color="$COLOR" -v max=32 '
    function paint(owner, s,   n, code) {
        if (!color) return s
        n = substr(owner, 2) + 0; if (n < 1) n = 1
        code = 31 + (n - 1) % 6
        return sprintf("%c[1;%dm%s%c[0m", 27, code, s, 27)
    }
    function emit(owner, text,   mark) {
        shown++
        mark = " "
        if (prev != "" && prev != owner && open[prev]) { mark = "!"; sw++ }
        prev = owner
        if (shown > max) { if (!cut) { print "     ... (more lines not shown)"; cut = 1 } return }
        if (mark == "!" && color) mark = sprintf("%c[1;31m!%c[0m", 27, 27)
        printf "   %s %s | %s\n", mark, paint(owner, sprintf("%-4s", owner)), paint(owner, text)
    }
    /\[SYSTEM\]|\[DEMO\]/ { next }
    /^=+$/ { inhdr = 1; hpid = ""; htag = ""; hreq = ""; next }
    inhdr && /Request from client/ { match($0, /PID=[0-9]+/); hpid = substr($0, RSTART + 4, RLENGTH - 4); hreq = $0; sub(/^\[[^]]*\] /, "", hreq); next }
    inhdr && /^  File      : / { htag = $3; sub(/\.txt$/, "", htag); next }
    inhdr && /^--- processed content ---$/ { pid2tag[hpid] = htag; emit(htag, hreq); open[htag] = 1; emit(htag, $0); inhdr = 0; next }
    inhdr { next }
    /^--- end/ { match($0, /PID=[0-9]+/); t = pid2tag[substr($0, RSTART + 4, RLENGTH - 4)]; if (t == "") t = "??"; emit(t, $0); open[t] = 0; next }
    match($0, /^\[c[0-9]+\] /) { emit(substr($0, 2, RLENGTH - 3), $0); next }
    END { printf "   -> %d time(s) a client cut into another client'"'"'s unfinished entry\n", sw + 0 }
    ' "$1"
}

# Machine check: every entry whole, containing only its own client's lines.
verify() {   # $1 = file containing one run's section
    awk -v expect="$N" '
        /\[SYSTEM\]|\[DEMO\]/ { next }
        /^=+$/ { if (st != 0) torn++; st = 1; next }
        /Request from client/ { n++; next }
        /^  File      : / { tag = $3; sub(/\.txt$/, "", tag); next }
        /^--- processed content ---$/ { st = 2; next }
        /^--- end/ { if (st != 2) torn++; st = 0; next }
        st == 2 && match($0, /^\[c[0-9]+\]/) { if (substr($0, RSTART + 1, RLENGTH - 2) != tag) mixed++ }
        END {
            printf "   entries found      : %d / %d\n", n, expect
            printf "   torn entries       : %d\n", torn
            printf "   foreign lines      : %d  (lines inside an entry that belong to another client)\n", mixed
            if (n == expect && torn == 0 && mixed == 0) print "   RESULT: CLEAN"; else print "   RESULT: CORRUPTED"
        }' "$1"
}

run_clients() {   # launches $N clients simultaneously and waits
    local pids=() i ok=0 peak=1 t alive p
    local spid; spid=$(cat "$PIDF")
    for i in $(seq 1 "$N"); do
        ./bin/client -m stats "$TMP/c$i.txt" >"$TMP/c$i.log" 2>&1 &
        pids+=($!)
    done
    while :; do
        alive=0
        for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
        t=$(ls "/proc/$spid/task" 2>/dev/null | wc -l)
        [ "$t" -gt "$peak" ] && peak=$t
        [ "$alive" = 0 ] && break
    done
    wait
    for i in $(seq 1 "$N"); do grep -q "status : OK" "$TMP/c$i.log" && ok=$((ok + 1)); done
    echo "   clients that received status OK : $ok / $N"
    echo "   peak threads inside the server  : $peak  (1 main + handler threads)"
}

legend() {
    say "each row = one line of the file.  left column = which client wrote it"
    say "'!' = this line appeared while the previous client's entry was still unfinished"
}

[ -x bin/server ] && [ -x bin/client ] || make || exit 1
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "A server is already running (PID $(cat "$PIDF")). Stop it first."; exit 1
fi

for i in $(seq 1 "$N"); do
    for j in $(seq 1 "$LINES_PER_FILE"); do echo "[c$i] line $j from client $i"; done > "$TMP/c$i.txt"
done

step "0. Setup"
say "$N clients start at the same moment. Each sends its own $LINES_PER_FILE-line file, tagged [c1]..[c$N]"
say "a correct output file keeps each client's entry in one piece: c1 c1 c1 ... then c2 c2 c2 ..."
say "everything goes into output.txt, the shared history file. Each run is announced there with a banner."
for i in $(seq 1 "$N"); do echo "   client c$i sends:  $(head -n 1 "$TMP/c$i.txt")  ..."; done
pause

step "1. RUN A: server WITHOUT the mutex (naive version)"
say "thread-per-client: each connection gets its own thread, all appending to ONE file"
say "--slow-io: an entry is written in 3 pieces with a 5 ms pause between them (simulated slow disk)"
hist_banner "DEMO 2 / RUN A - multi-client, server started WITH --no-lock" \
            "EXPECTED: CORRUPTED entries below. This is intentional (race condition demo)." \
            "$N clients at the same moment"
OFF_A=$(hist_size)
echo "${B}\$ ./bin/server -o output.txt --no-lock --slow-io${X}"
start_server --no-lock --slow-io
echo "${B}\$ (launch $N clients at the same moment)${X}"
run_clients
END_A=$(hist_size)
hist_section "$OFF_A" "$END_A" > "$TMP/runA.txt"
pause

step "2. What ended up in output.txt during RUN A (no mutex)"
legend
view "$TMP/runA.txt"
echo
verify "$TMP/runA.txt"
say "every client was told 'OK', yet the file is scrambled: a race condition fails silently"
stop_server
hist_end "end of DEMO 2 / RUN A (the damage above is intentional)"
pause

step "3. RUN B: same test WITH the mutex"
say "identical code and the same slow disk, but each entry is written inside a critical section"
hist_banner "DEMO 2 / RUN B - multi-client, server started WITH the mutex" \
            "EXPECTED: CLEAN entries below." \
            "$N clients at the same moment"
OFF_B=$(hist_size)
echo "${B}\$ ./bin/server -o output.txt --slow-io${X}"
start_server --slow-io
echo "${B}\$ (launch the same $N clients at the same moment)${X}"
run_clients
END_B=$(hist_size)
hist_section "$OFF_B" "$END_B" > "$TMP/runB.txt"
pause

step "4. What ended up in output.txt during RUN B (with mutex)"
legend
view "$TMP/runB.txt"
echo
verify "$TMP/runB.txt"
say "clients still run concurrently, but only one thread at a time writes to the file"
stop_server
hist_end "end of DEMO 2 / RUN B"

step "5. Summary"
echo "   without mutex : $(verify "$TMP/runA.txt" | tail -n 1 | sed 's/^ *//')"
echo "   with mutex    : $(verify "$TMP/runB.txt" | tail -n 1 | sed 's/^ *//')"
say "both runs are now in output.txt under their own banners (search it for 'DEMO 2')"
echo; echo "${B}${G}Demo finished.${X}"
