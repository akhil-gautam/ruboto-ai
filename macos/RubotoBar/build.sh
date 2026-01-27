#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RubotoBar"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

echo "Building $APP_NAME..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"

# Compile
swiftc \
    -parse-as-library \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework Carbon \
    "$SCRIPT_DIR/AppDelegate.swift"

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>RubotoBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.ruboto.bar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>RubotoBar</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>RubotoBar needs to control apps to run automations.</string>
</dict>
</plist>
EOF

echo "Built: $APP_DIR"
echo "Run: open $APP_DIR"
