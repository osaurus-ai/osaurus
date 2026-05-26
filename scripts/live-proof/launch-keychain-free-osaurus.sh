#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /path/to/osaurus.app [test-root]" >&2
  exit 64
fi

APP="$1"
TEST_ROOT="${2:-/tmp/osaurus-keychain-free-live-proof-$(date +%Y%m%d-%H%M%S)}"
BIN="$APP/Contents/MacOS/osaurus"

if [[ ! -x "$BIN" ]]; then
  echo "missing executable: $BIN" >&2
  exit 66
fi

mkdir -p "$TEST_ROOT"
LOG="$TEST_ROOT/osaurus.log"
PIDFILE="$TEST_ROOT/osaurus.pid"

# This live-proof launcher intentionally bypasses LaunchServices/open(1) so
# the keychain-disabled environment is inherited by the app process.
# Do not add signing, notarization, security(1), or Keychain calls here.
nohup env \
  OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
  OSAURUS_TEST_ROOT="$TEST_ROOT" \
  "$BIN" >"$LOG" 2>&1 &
PID=$!
printf '%s\n' "$PID" > "$PIDFILE"

echo "pid=$PID"
echo "test_root=$TEST_ROOT"
echo "log=$LOG"
