#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$APP_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$BUILD_DIR/release-assets}"
SCRATCH_PATH="${SCRATCH_PATH:-/tmp/codex-auth-menubar/swift-build}"
APP_NAME="CodexAuthMenu"
APP_BUNDLE_PATH="$BUILD_DIR/$APP_NAME.app"
APP_VERSION="${APP_VERSION:-$(awk -F'\"' '/app_version/ { print $2; exit }' "$REPO_ROOT/src/version.zig")}"
ARCHIVE_NAME="${ARCHIVE_NAME:-}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
TARGET_ARCH="${TARGET_ARCH:-}"

normalize_arch() {
  case "$1" in
    arm64|aarch64)
      echo "arm64"
      ;;
    x86_64|amd64)
      echo "x86_64"
      ;;
    *)
      return 1
      ;;
  esac
}

if [ -z "$TARGET_ARCH" ] && [ -n "$TARGET_TRIPLE" ]; then
  case "$TARGET_TRIPLE" in
    arm64-*|aarch64-*)
      TARGET_ARCH="arm64"
      ;;
    x86_64-*|amd64-*)
      TARGET_ARCH="x86_64"
      ;;
  esac
fi

if [ -z "$TARGET_ARCH" ]; then
  if ! TARGET_ARCH="$(normalize_arch "$(uname -m)")"; then
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
  fi
fi

case "$TARGET_ARCH" in
  arm64)
    arch_label="ARM64"
    ;;
  x86_64)
    arch_label="X64"
    ;;
  *)
    echo "Unsupported target architecture: $TARGET_ARCH" >&2
    exit 1
    ;;
esac

if [ -z "$APP_VERSION" ]; then
  echo "Unable to resolve app version from src/version.zig" >&2
  exit 1
fi

if [ -z "$ARCHIVE_NAME" ]; then
  ARCHIVE_NAME="CodexAuthMenu-macOS-$arch_label.zip"
fi

bash "$SCRIPT_DIR/build-app.sh"

mkdir -p "$OUTPUT_DIR"
ditto -c -k --keepParent "$APP_BUNDLE_PATH" "$OUTPUT_DIR/$ARCHIVE_NAME"

echo "Packaged $OUTPUT_DIR/$ARCHIVE_NAME"
