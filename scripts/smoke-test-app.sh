#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_EXECUTABLE="$PROJECT_DIR/release/OpenExplorer.app/Contents/MacOS/OpenExplorer"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "OpenExplorer.app is not packaged. Run ./scripts/package-macos.sh first." >&2
    exit 1
fi

OPENEXPLORER_SMOKE_TEST=1 "$APP_EXECUTABLE"
