#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ROOT="${TASK_ROOT:-/tmp/codex-auth-validate}"

mkdir -p "$TASK_ROOT"
export HOME="$TASK_ROOT"
export USERPROFILE="$TASK_ROOT"

if [[ $# -eq 0 ]]; then
  set -- list
fi

exec "$SCRIPT_DIR/zig-build-compat.sh" run -- "$@"
