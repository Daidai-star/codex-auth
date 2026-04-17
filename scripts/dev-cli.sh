#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build and run codex-auth directly from src/main.zig.

Usage:
  ./scripts/dev-cli.sh -- <codex-auth args>
  ./scripts/dev-cli.sh list
  ./scripts/dev-cli.sh help

Environment:
  ZIG_EXECUTABLE            Override the Zig executable path
  CODEX_AUTH_DEV_BUILD_DIR  Override the temporary build directory
  SDKROOT                   Override the macOS SDK path
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${CODEX_AUTH_DEV_BUILD_DIR:-${TMPDIR:-/tmp}/codex-auth-dev-build}"
BIN_PATH="$BUILD_DIR/codex-auth"

resolve_zig() {
  if [[ -n "${ZIG_EXECUTABLE:-}" && -x "${ZIG_EXECUTABLE}" ]]; then
    printf '%s\n' "${ZIG_EXECUTABLE}"
    return
  fi

  local candidate
  while IFS= read -r candidate; do
    if [[ -n "$candidate" && "$candidate" != "$SCRIPT_DIR/zig" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(type -a -p zig 2>/dev/null | awk '!seen[$0]++')

  if [[ -x "/tmp/codex-auth-refresh/zig-0.15.1/zig" ]]; then
    printf '%s\n' "/tmp/codex-auth-refresh/zig-0.15.1/zig"
    return
  fi

  echo "Zig executable not found. Set ZIG_EXECUTABLE or add zig to PATH." >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--script-help" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--" ]]; then
  shift
fi

ZIG_BIN="$(resolve_zig)"
mkdir -p "$BUILD_DIR"

case "$(uname -s)" in
  Darwin)
    if ! command -v xcrun >/dev/null 2>&1; then
      echo "xcrun is required on macOS to resolve the active SDK." >&2
      exit 1
    fi

    SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
    case "$(uname -m)" in
      arm64|aarch64)
        ZIG_TARGET="aarch64-macos"
        ;;
      x86_64|amd64)
        ZIG_TARGET="x86_64-macos"
        ;;
      *)
        echo "Unsupported macOS architecture: $(uname -m)" >&2
        exit 1
        ;;
    esac

    "$ZIG_BIN" build-exe \
      "$REPO_ROOT/src/main.zig" \
      -lc \
      -target "$ZIG_TARGET" \
      --sysroot "$SDK_PATH" \
      -O Debug \
      -femit-bin="$BIN_PATH"
    ;;
  *)
    "$ZIG_BIN" build-exe \
      "$REPO_ROOT/src/main.zig" \
      -lc \
      -O Debug \
      -femit-bin="$BIN_PATH"
    ;;
esac

exec "$BIN_PATH" "$@"
