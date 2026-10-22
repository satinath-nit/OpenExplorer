#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="OpenExplorer"
RELEASE_DIR="$PROJECT_DIR/release"
APP_DIR="$RELEASE_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET_ARCH="${OPENEXPLORER_ARCH:-$(uname -m)}"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"

cd "$PROJECT_DIR"
env \
    CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-cache" \
    SDKROOT="$SDK_PATH" \
    swift build -c release --arch "$TARGET_ARCH" --product OpenExplorer -debug-info-format none --disable-sandbox --scratch-path "$PROJECT_DIR/.build"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
BINARY_PATH="$PROJECT_DIR/.build/out/Products/Release/OpenExplorer"
if [[ ! -f "$BINARY_PATH" ]]; then
    BINARY_PATH="$PROJECT_DIR/.build/$TARGET_ARCH-apple-macosx/release/OpenExplorer"
fi
cp "$BINARY_PATH" "$CONTENTS_DIR/MacOS/OpenExplorer"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/OpenExplorer.icns" "$CONTENTS_DIR/Resources/OpenExplorer.icns"

codesign --force --deep --sign - "$APP_DIR"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_DIR" || true
fi

DMG_PATH="$RELEASE_DIR/OpenExplorer-$APP_VERSION-$TARGET_ARCH.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"

echo "Created: $APP_DIR"
echo "Created: $DMG_PATH"
