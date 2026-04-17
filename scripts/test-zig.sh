#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

resolve_zig() {
  if [[ -n "${ZIG_EXECUTABLE:-}" && -x "${ZIG_EXECUTABLE}" && "${ZIG_EXECUTABLE}" != "$SCRIPT_DIR/zig" ]]; then
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

macos_target() {
  case "$(uname -m)" in
    arm64|aarch64)
      printf '%s\n' "aarch64-macos"
      ;;
    x86_64|amd64)
      printf '%s\n' "x86_64-macos"
      ;;
    *)
      echo "Unsupported macOS architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

ZIG_BIN="$(resolve_zig)"

if [[ "$(uname -s)" == "Darwin" ]]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required on macOS to resolve the active SDK." >&2
    exit 1
  fi

  SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
  exec "$ZIG_BIN" test "$REPO_ROOT/src/main.zig" -lc -target "$(macos_target)" --sysroot "$SDK_PATH" "$@"
fi

exec "$ZIG_BIN" test "$REPO_ROOT/src/main.zig" -lc "$@"
