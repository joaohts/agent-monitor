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
</dict>
</plist>
EOF

echo "→ launching $APP_DIR"
open "$APP_DIR"
