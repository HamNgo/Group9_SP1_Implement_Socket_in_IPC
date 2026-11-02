#!/usr/bin/env bash
set -euo pipefail

# Scenario 3: Graceful Shutdown using SIGTERM

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="/tmp/ipc_group9_server.pid"
SOCKET_PATH="/tmp/ipc_group9_stream.sock"

echo "======================================="
echo " SCENARIO 3: GRACEFUL SHUTDOWN"
echo "======================================="

# Check PID file
if [[ ! -f "$PID_FILE" ]]; then
    echo "[ERROR] Server PID file not found."
    exit 1
fi

read -r SERVER_PID < "$PID_FILE"

if [[ ! "$SERVER_PID" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Invalid Server PID."
    exit 1
fi

# Check whether the process exists
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[ERROR] Server process is not running."
    exit 1
fi

# Verify the executable before sending a signal
EXPECTED_EXE="$(readlink -f "$PROJECT_DIR/bin/server")"
RUNNING_EXE="$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null || true)"

if [[ "$RUNNING_EXE" != "$EXPECTED_EXE" ]]; then
    echo "[ERROR] PID does not belong to this project's Server."
    exit 1
fi

echo "[INFO] Server PID: $SERVER_PID"
echo "[INFO] Sending SIGTERM..."

kill -TERM "$SERVER_PID"

# Allow up to 30 seconds for shutdown
for ((i = 0; i < 150; i++)); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null &&
       [[ ! -e "$SOCKET_PATH" ]] &&
       [[ ! -e "$PID_FILE" ]]; then
        echo "[PASS] Server terminated successfully."
        echo "[PASS] Socket file removed."
        echo "[PASS] PID file removed."
        echo "[PASS] Graceful Shutdown completed."
        exit 0
    fi
    sleep 0.2
done

echo "[FAIL] Shutdown did not finish within 30 seconds."
exit 1


