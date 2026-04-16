#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../../.." && pwd)"
SCRATCH_PATH="${SCRATCH_PATH:-/tmp/codex-auth-menubar/swift-build}"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="CodexAuthMenu"
BUILD_DIR="${BUILD_DIR:-$APP_DIR/build}"
BUNDLE_PATH="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE_PATH="$BUNDLE_PATH/Contents/MacOS/$APP_NAME"
ICON_PATH="$APP_DIR/Resources/AppIcon.icns"
ICON_PREVIEW_PATH="$APP_DIR/Resources/AppIcon.png"

if [ ! -f "$ICON_PATH" ] || [ ! -f "$ICON_PREVIEW_PATH" ]; then
  swift "$APP_DIR/Scripts/generate-icon.swift"
fi

swift build \
  --package-path "$APP_DIR" \
  --scratch-path "$SCRATCH_PATH" \
  --configuration "$CONFIGURATION"

rm -rf "$BUNDLE_PATH"
mkdir -p "$BUNDLE_PATH/Contents/MacOS"
mkdir -p "$BUNDLE_PATH/Contents/Resources"

cp "$SCRATCH_PATH/$CONFIGURATION/$APP_NAME" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"
cp "$ICON_PATH" "$BUNDLE_PATH/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_PREVIEW_PATH" ]; then
  cp "$ICON_PREVIEW_PATH" "$BUNDLE_PATH/Contents/Resources/AppIcon.png"
fi

cat > "$BUNDLE_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>dev.loongphy.codex-auth-menu</string>
  <key>CFBundleName</key>
  <string>Codex 账号</string>
  <key>CFBundleDisplayName</key>
  <string>Codex 账号</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built $BUNDLE_PATH"
echo "Open it with: open '$BUNDLE_PATH'"
