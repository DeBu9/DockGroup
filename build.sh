#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

swift build -c release --disable-sandbox

# Regenerate the app icon whenever its renderer/tool changes.
ICON="$ROOT/Resources/AppIcon.icns"
ICON_TOOL="$ROOT/Tools/IconGen/main.swift"
ICON_RENDERER="$ROOT/Sources/DockGroup/IconRenderer.swift"
if [ ! -f "$ICON" ] || [ "$ICON_TOOL" -nt "$ICON" ] || [ "$ICON_RENDERER" -nt "$ICON" ]; then
    /usr/bin/xcrun swiftc -O -sdk "$(/usr/bin/xcrun --show-sdk-path)" \
        -target arm64-apple-macosx13.0 \
        "$ICON_TOOL" "$ICON_RENDERER" -o /tmp/dockgroup-icongen
    /tmp/dockgroup-icongen "$ICON"
fi

APP="$ROOT/dist/DockGroup.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$ROOT/.build/release/DockGroup" "$APP/Contents/MacOS/DockGroup"
cp -f "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ICON" ]; then
    cp -f "$ICON" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/DockGroup"

/usr/bin/codesign --force --deep --sign - "$APP" 2>/dev/null || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP" 2>/dev/null || true
fi

echo "Built: $APP"
