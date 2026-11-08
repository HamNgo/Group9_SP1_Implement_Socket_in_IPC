#!/usr/bin/env bash
# Narrated demo: MANY clients at once -> threads + race condition + mutex.
# Usage: ./scripts/demo_multi_client.sh [-n] [num_clients]   (-n = no pauses, default 3 clients)
cd "$(dirname "$0")/.." || exit 1
source scripts/history.sh

PAUSE=1; N=3; N_SET=0
for a in "$@"; do
    case "$a" in
        -n) PAUSE=0 ;;
        [2-9]|10)
            if [[ "$N_SET" == 1 ]]; then
                echo "[FAIL] Specify the client count only once" >&2
                exit 2
            fi
            N="$a"
            N_SET=1
            ;;
        *)
            echo "[FAIL] Invalid argument: $a (usage: demo_multi_client.sh [-n] [2-10])" >&2
            exit 2
            ;;
    esac
done
[ -t 0 ] || PAUSE=0
LINES_PER_FILE=3

PIDF=/tmp/ipc_group9_server.pid
SOCK=/tmp/ipc_group9_stream.sock
SERVER_PID=""
TMP=$(mktemp -d)
STARTED=0
if [ -t 1 ]; then COLOR=1; else COLOR=0; fi

if [ "$COLOR" = 1 ]; then B=$(tput bold); G=$(tput setaf 2); Y=$(tput setaf 3); X=$(tput sgr0); else B=; G=; Y=; X=; fi
recolor() { local m=$1; [ -n "$X" ] && m=${m//"$X"/"$X$2"}; printf '%s' "$m"; }
step()  { echo; echo "${B}${G}=== $(recolor "$*" "$B$G") ===${X}"; }
say()   { echo "${Y}# $(recolor "$*" "$Y")${X}"; }
pause() { [ "$PAUSE" = 1 ] && read -rp "   [press Enter] " _; }

# Return success only if the process is running (not a zombie).
server_alive() {
    local pid="$1"
    local state

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    state=$(awk '$1 == "State:" {print $2; exit}' \
        "/proc/$pid/status" 2>/dev/null) || return 1

    [[ -n "$state" && "$state" != "Z" && "$state" != "X" ]]
}

start_server() {
    local i candidate

    if [[ "$STARTED" == 1 ]]; then
        echo "[FAIL] A demo server is already active" >&2
        return 1
    fi

    ./bin/server -o "$HIST" "$@" >/dev/null || {
        echo "[FAIL] Server failed to start" >&2
        return 1
    }

    # Wait for the daemon to create its PID and socket.
    for ((i = 0; i < 30; i++)); do
        if [[ -s "$PIDF" ]]; then
            candidate=$(cat "$PIDF" 2>/dev/null) || candidate=""

            if server_alive "$candidate" &&
               [[ "$(readlink -f "/proc/$candidate/exe" 2>/dev/null)" == "$PWD/bin/server" ]]; then

                SERVER_PID="$candidate"
                STARTED=1

                if [[ -S "$SOCK" ]]; then
                    echo "[PASS] Server started: PID $SERVER_PID"
                    return 0
                fi
            fi
        fi
        sleep 0.1
    done

    echo "[FAIL] Server startup verification timed out" >&2
    return 1
}

stop_server() {
    [[ "$STARTED" == 1 ]] || return 0

    local pid="$SERVER_PID"
    local i

    if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
        echo "[FAIL] Invalid server PID" >&2
        return 1
    fi

    if server_alive "$pid"; then
        if [[ ! -r "$PIDF" ]] ||
           [[ "$(cat "$PIDF")" != "$pid" ]]; then
            echo "[FAIL] Server PID verification failed" >&2
            return 1
        fi

        if [[ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" != "$PWD/bin/server" ]]; then
            echo "[FAIL] Server executable mismatch" >&2
            return 1
        fi

        if ! kill -TERM "$pid"; then
            echo "[FAIL] Cannot send SIGTERM" >&2
            return 1
        fi
    fi

    # Wait for shutdown and resource cleanup.
    for ((i = 0; i < 350; i++)); do
        if ! server_alive "$pid" &&
           [[ ! -e "$SOCK" && ! -e "$PIDF" ]]; then
            echo "[PASS] Server $pid stopped; socket and PID removed"
            STARTED=0
            SERVER_PID=""
            return 0
        fi
        sleep 0.1
    done

    echo "[FAIL] Server $pid shutdown timed out" >&2
    return 1
}

cleanup() {
    local result=0

    if [[ "$STARTED" == 1 ]]; then
        stop_server || result=1
    fi

    rm -rf -- "$TMP" || result=1
    return "$result"
}

on_exit() {
    local result="$1"
    trap - EXIT

    cleanup || result=1
    exit "$result"
}

trap 'on_exit "$?"' EXIT

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
verify() {
    awk -v expect="$N" -v perfile="$LINES_PER_FILE" \
        -v wanted="${2:-}" '
    /\[SYSTEM\]|\[DEMO\]/ {
        if (st != 0) bad++
        next
    }

    /^=+$/ {
        if (st != 0) torn++
        st = 1
        step = 0
        pid = ""
        tag = ""
        idx = 0
        lines = 0
        next
    }

    /Request from client/ {
        n++
        if (st != 1 || step != 0 ||
            $0 !~ /^\[[^]]+\] Request from client PID=[0-9]+$/)
            bad++
        else {
            pid = $0
            sub(/^.*PID=/, "", pid)
            step = 1
        }
        next
    }

    /^  File      : / {
        if (st != 1 || step != 1 ||
            $0 !~ /^  File      : c[0-9]+\.txt$/)
            bad++
        else {
            tag = $3
            sub(/\.txt$/, "", tag)
            idx = substr(tag, 2) + 0

            if (idx < 1 || idx > expect || tag != "c" idx)
                bad++

            seen[tag]++
            step = 2
        }
        next
    }

    /^  Mode      : STATS$/ {
        if (st != 1 || step != 2) bad++
        else step = 3
        next
    }

    /^  Size      : [0-9]+ bytes$/ {
        if (st != 1 || step != 3) bad++
        else step = 4
        next
    }

    /^  Checksum  : 0x[0-9a-fA-F]+ \(verified\)$/ {
        if (st != 1 || step != 4) bad++
        else step = 5
        next
    }

    /^  Result    : / {
        if (st != 1 || step != 5) bad++
        else step = 6
        next
    }

    /^  Proc time : / {
        if (st != 1 || step != 6) bad++
        else step = 7
        next
    }

    /^--- processed content ---$/ {
        if (st != 1 || step != 7) bad++
        st = 2
        next
    }

    /^--- end/ {
        if (st != 2 ||
            $0 !~ /^--- end \[PID=[0-9]+\] ---$/)
            torn++
        else {
            footer = $0
            sub(/^--- end \[PID=/, "", footer)
            sub(/\] ---$/, "", footer)

            if (footer != pid || lines != perfile)
                bad++
        }

        closed++
        st = 0
        next
    }

    {
        if (st == 2) {
            lines++
            expected = sprintf("[c%d] line %d from client %d", idx, lines, idx)

            if ($0 != expected) {
                if ($0 ~ /^\[c[0-9]+\]/ &&
                    index($0, "[c" idx "]") != 1)
                    mixed++
                else
                    bad++
            }
        } else if ($0 != "")
            bad++
    }

    END {
        if (st != 0) torn++

        for (i = 1; i <= expect; i++)
            if (seen["c" i] != 1) bad++

        printf "   entries found      : %d / %d\n", n, expect
        printf "   torn entries       : %d\n", torn
        printf "   foreign lines      : %d\n", mixed
        printf "   invalid fields/lines: %d\n", bad

        result = (n == expect && closed == expect && torn == 0 && mixed == 0 && bad == 0) ? "CLEAN" : "CORRUPTED"

        print "   RESULT: " result

        if (wanted == "CLEAN" && result != "CLEAN")
            exit 1

        if (wanted == "CORRUPTED" &&
            (n != expect || result != "CORRUPTED"))
            exit 1
    }
    ' "$1"
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
    for i in $(seq 1 "$N"); do
        if wait "${pids[$((i - 1))]}"; then
            rc=0
        else
            rc=$?
        fi

        if [ "$rc" -eq 0 ] &&
           grep -Eq '^[[:space:]]*status[[:space:]]*:[[:space:]]*OK[[:space:]]*$' "$TMP/c$i.log"; then
            ok=$((ok + 1))
        else
            echo "[FAIL] Client c$i: exit code $rc or missing status OK" >&2
            sed -n '1,15p' "$TMP/c$i.log" >&2
        fi
    done
    echo "   clients that received status OK : $ok / $N"
    echo "   peak threads inside the server  : $peak  (1 main + handler threads)"
    if [ "$ok" -ne "$N" ]; then
        echo "[FAIL] Only $ok / $N clients succeeded" >&2
        return 1
    fi
}

legend() {
    say "each row = one line of the file.  left column = which client wrote it"
    say "'!' = this line appeared while the previous client's entry was still unfinished"
}

[ -x bin/server ] && [ -x bin/client ] || make || exit 1
if [[ -e "$SOCK" || -L "$SOCK" ||
      -e "$PIDF" || -L "$PIDF" ]]; then
    echo "[FAIL] Existing Socket/PID detected; inspect before Demo 2" >&2
    exit 1
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
start_server --no-lock --slow-io || exit 1
echo "${B}\$ (launch $N clients at the same moment)${X}"
run_clients || { echo "[FAIL] Client execution failed" >&2; exit 1; }
END_A=$(hist_size)
hist_section "$OFF_A" "$END_A" > "$TMP/runA.txt"
pause

step "2. What ended up in output.txt during RUN A (no mutex)"
legend
view "$TMP/runA.txt"
echo
verify "$TMP/runA.txt" CORRUPTED || { echo "[FAIL] RUN A verification failed" >&2; exit 1; }
say "every client was told 'OK', yet the file is scrambled: a race condition fails silently"
stop_server || exit 1
hist_end "end of DEMO 2 / RUN A (the damage above is intentional)"
pause

step "3. RUN B: same test WITH the mutex"
say "identical code and the same slow disk, but each entry is written inside a critical section"
hist_banner "DEMO 2 / RUN B - multi-client, server started WITH the mutex" \
            "EXPECTED: CLEAN entries below." \
            "$N clients at the same moment"
OFF_B=$(hist_size)
echo "${B}\$ ./bin/server -o output.txt --slow-io${X}"
start_server --slow-io || exit 1
echo "${B}\$ (launch the same $N clients at the same moment)${X}"
run_clients || { echo "[FAIL] Client execution failed" >&2; exit 1; }
END_B=$(hist_size)
hist_section "$OFF_B" "$END_B" > "$TMP/runB.txt"
pause

step "4. What ended up in output.txt during RUN B (with mutex)"
legend
view "$TMP/runB.txt"
echo
verify "$TMP/runB.txt" CLEAN || { echo "[FAIL] RUN B verification failed" >&2; exit 1; }
say "clients still run concurrently, but only one thread at a time writes to the file"
stop_server || exit 1
hist_end "end of DEMO 2 / RUN B"

step "5. Summary"
echo "   without mutex : $(verify "$TMP/runA.txt" | tail -n 1 | sed 's/^ *//')"
echo "   with mutex    : $(verify "$TMP/runB.txt" | tail -n 1 | sed 's/^ *//')"
say "both runs are now in output.txt under their own banners (search it for 'DEMO 2')"
echo; echo "${B}${G}Demo finished.${X}"
