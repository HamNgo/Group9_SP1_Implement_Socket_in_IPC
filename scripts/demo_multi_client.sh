#!/usr/bin/env bash
set -euo pipefail

# Scenario 2: Concurrent Client Communication
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SOCKET_PATH="/tmp/ipc_group9_stream.sock"

if [[ ! -x ./bin/client ]]; then
    echo "[ERROR] Client executable not found. Run make first."
    exit 1
fi

if [[ ! -S "$SOCKET_PATH" ]]; then
    echo "[ERROR] Server is not running."
    exit 1
fi

# Prepare three input files
mkdir -p samples

echo "Client A: UNIX Domain Socket communication." > samples/input_A.txt
echo "Client B: Multithreading and concurrency." > samples/input_B.txt
printf "Client C: Mutex synchronization.\nFile I/O processing.\n" > samples/input_C.txt

# Create temporary log directory
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

echo "======================================="
echo " SCENARIO 2: MULTI-CLIENT DEMONSTRATION"
echo "======================================="

# Launch three clients concurrently
./bin/client -m stats samples/input_A.txt > "$LOG_DIR/A.log" 2>&1 &
PID_A=$!

./bin/client -m upper samples/input_B.txt > "$LOG_DIR/B.log" 2>&1 &
PID_B=$!

./bin/client -m reverse samples/input_C.txt > "$LOG_DIR/C.log" 2>&1 &
PID_C=$!

echo "[INFO] Three clients launched concurrently."

FAILED=0

# Wait for every client to finish
for CLIENT in A B C; do
    PID_VAR="PID_${CLIENT}"
    PID="${!PID_VAR}"

    if wait "$PID"; then
        echo "[INFO] Client $CLIENT finished."
    else
        echo "[ERROR] Client $CLIENT failed."
        FAILED=1
    fi
done

# Display and validate client responses
for CLIENT in A B C; do
    echo
    echo "----- CLIENT $CLIENT -----"
    cat "$LOG_DIR/$CLIENT.log"

    if ! grep -Eq 'status[[:space:]]*:[[:space:]]*OK' "$LOG_DIR/$CLIENT.log"; then
        echo "[ERROR] Client $CLIENT did not return OK."
        FAILED=1
    fi
done

echo
if [[ "$FAILED" -eq 0 ]]; then
    echo "[PASS] All three clients completed successfully."
else
    echo "[FAIL] One or more clients failed."
    exit 1
fi
