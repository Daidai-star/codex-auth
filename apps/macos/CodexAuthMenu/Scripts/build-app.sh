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
BUNDLED_CLI_PATH="${BUNDLED_CLI_PATH:-}"
ZIG_EXECUTABLE="${ZIG_EXECUTABLE:-}"

if [ -z "$ZIG_EXECUTABLE" ] && command -v zig >/dev/null 2>&1; then
  ZIG_EXECUTABLE="$(command -v zig)"
fi

build_bundled_cli() {
  if [ -n "$BUNDLED_CLI_PATH" ] && [ -x "$BUNDLED_CLI_PATH" ]; then
    return 0
  fi

  if [ -n "$ZIG_EXECUTABLE" ] && [ -x "$ZIG_EXECUTABLE" ]; then
    local sdk_root
    sdk_root="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
    local machine
    machine="$(uname -m)"
    local zig_target
    case "$machine" in
      arm64) zig_target="aarch64-macos" ;;
      x86_64) zig_target="x86_64-macos" ;;
      *)
        echo "Warning: unsupported macOS architecture for bundled codex-auth: $machine" >&2
        return 1
        ;;
    esac

    local direct_build_path="$BUILD_DIR/codex-auth"
    echo "Building bundled codex-auth CLI..."
    "$ZIG_EXECUTABLE" build-exe \
      "$REPO_ROOT/src/main.zig" \
      -lc \
      -target "$zig_target" \
      --sysroot "$sdk_root" \
      -O ReleaseSafe \
      -femit-bin="$direct_build_path"
    BUNDLED_CLI_PATH="$direct_build_path"
    return 0
  fi

  if [ -x "$REPO_ROOT/zig-out/bin/codex-auth" ]; then
    BUNDLED_CLI_PATH="$REPO_ROOT/zig-out/bin/codex-auth"
    return 0
  fi

  return 1
}

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

if build_bundled_cli; then
  cp "$BUNDLED_CLI_PATH" "$BUNDLE_PATH/Contents/Resources/codex-auth"
  chmod +x "$BUNDLE_PATH/Contents/Resources/codex-auth"
else
  echo "Warning: no bundled codex-auth CLI was found; the app will fall back to PATH." >&2
fi

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
