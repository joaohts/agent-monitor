#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AgentMonitor"
APP_DIR="$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

# Stop any running instance so we can replace the binary
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.2

mkdir -p "$BIN_DIR" "$RES_DIR"

# Generate AppIcon.icns from assets/icon.png if present.
# Pads to square (larger dim) so non-square sources don't get distorted.
make_icon() {
    local SRC="$1" OUT="$2"
    local TMP; TMP=$(mktemp -d)
    local SQ="$TMP/square.png"

    local W H S
    W=$(sips -g pixelWidth  "$SRC" | awk '/pixelWidth/ {print $2}')
    H=$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/ {print $2}')
    S=$(( W > H ? W : H ))
    sips -p $S $S "$SRC" --out "$SQ" >/dev/null

    local ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for spec in "16x16:16" "16x16@2x:32" "32x32:32" "32x32@2x:64" \
                "128x128:128" "128x128@2x:256" "256x256:256" "256x256@2x:512" \
                "512x512:512" "512x512@2x:1024"; do
        local name=${spec%:*} px=${spec#*:}
        sips -z $px $px "$SQ" --out "$ICONSET/icon_${name}.png" >/dev/null
    done

    iconutil -c icns "$ICONSET" -o "$OUT"
    rm -rf "$TMP"
}

if [ -f assets/icon.png ]; then
    echo "→ generating icon..."
    make_icon assets/icon.png "$RES_DIR/AppIcon.icns"
fi

echo "→ compiling..."
# -O omitted for fast dev builds (~2-3s vs ~15s). Pass RELEASE=1 to opt-in.
OPT_FLAGS=""
if [ "${RELEASE:-0}" = "1" ]; then
    OPT_FLAGS="-O"
fi
swiftc AgentMonitor.swift \
    -o "$BIN_DIR/$APP_NAME" \
    -parse-as-library \
    -framework SwiftUI -framework AppKit \
    $OPT_FLAGS

cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentMonitor</string>
    <key>CFBundleDisplayName</key><string>Agent Monitor</string>
    <key>CFBundleIdentifier</key><string>com.local.agentmonitor</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleExecutable</key><string>AgentMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF

echo "→ launching $APP_DIR"
open "$APP_DIR"
