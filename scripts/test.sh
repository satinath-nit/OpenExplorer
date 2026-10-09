#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

cd "$PROJECT_DIR"
env \
    CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-cache" \
    SDKROOT="$SDK_PATH" \
    swift run --disable-sandbox --scratch-path "$PROJECT_DIR/.build" OpenExplorerCoreChecks
