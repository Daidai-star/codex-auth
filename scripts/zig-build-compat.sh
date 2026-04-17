#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run `zig build` with a macOS 26 compatible Zig 0.15.x build runner.

Usage:
  ./scripts/zig-build-compat.sh run -- list
  ./scripts/zig-build-compat.sh test

Environment:
  ZIG_EXECUTABLE                 Override the Zig executable path
  CODEX_AUTH_BUILD_RUNNER_DIR    Override the cached build-runner directory
  SDKROOT                        Override the macOS SDK path
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

zig_env_value() {
  local key="$1"
  "$ZIG_BIN" env | awk -v key="$key" -F'"' '$0 ~ "\\." key " = " { print $2; exit }'
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

has_target_arg() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -Dtarget=*|-Dcpu=*|-Doptimize=*)
        if [[ "$arg" == -Dtarget=* ]]; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ZIG_BIN="$(resolve_zig)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  exec "$ZIG_BIN" build "$@"
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required on macOS to resolve the active SDK." >&2
  exit 1
fi

ZIG_LIB_DIR="$(zig_env_value lib_dir)"
if [[ -z "$ZIG_LIB_DIR" ]]; then
  echo "Unable to resolve Zig lib_dir from zig env." >&2
  exit 1
fi

SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
ZIG_TARGET="$(macos_target)"
RUNNER_ROOT="${CODEX_AUTH_BUILD_RUNNER_DIR:-${TMPDIR:-/tmp}/codex-auth-zig-build-runner}"
RUNNER_BIN="$RUNNER_ROOT/build-runner"
DEPS_FILE="$RUNNER_ROOT/dependencies.zig"
LOCAL_CACHE="${ZIG_LOCAL_CACHE_DIR:-$REPO_ROOT/.zig-cache}"
GLOBAL_CACHE="${ZIG_GLOBAL_CACHE_DIR:-${HOME:-$RUNNER_ROOT}/.cache/zig}"

mkdir -p "$RUNNER_ROOT" "$RUNNER_ROOT/local-cache" "$RUNNER_ROOT/global-cache" "$LOCAL_CACHE" "$GLOBAL_CACHE"

cat > "$DEPS_FILE" <<'EOF'
pub const root_deps: []const struct { []const u8, []const u8 } = &.{};
pub const packages = struct {};
EOF

"$ZIG_BIN" build-exe \
  -target "$ZIG_TARGET" \
  --sysroot "$SDK_PATH" \
  -lc \
  --cache-dir "$RUNNER_ROOT/local-cache" \
  --global-cache-dir "$RUNNER_ROOT/global-cache" \
  --zig-lib-dir "$ZIG_LIB_DIR" \
  --dep @build --dep @dependencies \
  -Mroot="$ZIG_LIB_DIR/compiler/build_runner.zig" \
  -M@build="$REPO_ROOT/build.zig" \
  -M@dependencies="$DEPS_FILE" \
  -femit-bin="$RUNNER_BIN"

build_args=("$@")
if ! has_target_arg "${build_args[@]}"; then
  build_args=("-Dtarget=$ZIG_TARGET" "${build_args[@]}")
fi

exec "$RUNNER_BIN" \
  "$ZIG_BIN" \
  "$ZIG_LIB_DIR" \
  "$REPO_ROOT" \
  "$LOCAL_CACHE" \
  "$GLOBAL_CACHE" \
  "${build_args[@]}"
