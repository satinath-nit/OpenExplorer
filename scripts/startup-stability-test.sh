#!/bin/zsh
set -u

APP_PATH="${1:-/Applications/OpenExplorer.app}"
BINARY="$APP_PATH/Contents/MacOS/OpenExplorer"
LOG_FILE="/private/tmp/openexplorer-startup.log"

if [[ ! -x "$BINARY" ]]; then
    echo "FAIL: missing executable at $BINARY"
    exit 1
fi

pkill -x OpenExplorer 2>/dev/null || true
"$BINARY" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO >"$LOG_FILE" 2>&1 &
APP_PID=$!
sleep 3

if ! kill -0 "$APP_PID" 2>/dev/null; then
    wait "$APP_PID"
    EXIT_CODE=$?
    echo "FAIL: OpenExplorer exited during startup with code $EXIT_CODE"
    sed -n '1,160p' "$LOG_FILE"
    exit 1
fi

kill -TERM "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
echo "PASS: OpenExplorer remained alive for the startup stability window"
