#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 /path/to/osaurus.app com.dinoki.osaurus.uniqueproofid /absolute/models-dir [fresh-test-root]" >&2
  exit 64
fi

APP="$1"
BUNDLE_ID="$2"
MODELS_DIR="$3"
REQUESTED_TEST_ROOT="${4:-}"
BIN="$APP/Contents/MacOS/osaurus"

if [[ ! "$BUNDLE_ID" =~ ^com\.dinoki\.osaurus\.[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  echo "proof bundle id must be a unique com.dinoki.osaurus.* domain: $BUNDLE_ID" >&2
  exit 64
fi
if [[ ! -x "$BIN" ]]; then
  echo "missing executable: $BIN" >&2
  exit 66
fi
APP_BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
)"
if [[ "$APP_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "app bundle id mismatch: expected $BUNDLE_ID, got $APP_BUNDLE_ID" >&2
  exit 65
fi
if [[ "$MODELS_DIR" != /* || ! -d "$MODELS_DIR" ]]; then
  echo "models directory must be an existing absolute directory: $MODELS_DIR" >&2
  exit 64
fi
MODELS_DIR="$(cd "$MODELS_DIR" && pwd -P)"

if [[ -n "$REQUESTED_TEST_ROOT" ]]; then
  if [[ "$REQUESTED_TEST_ROOT" != /* ]]; then
    echo "test root must be absolute: $REQUESTED_TEST_ROOT" >&2
    exit 64
  fi
  if [[ -e "$REQUESTED_TEST_ROOT" ]]; then
    echo "test root must not already exist: $REQUESTED_TEST_ROOT" >&2
    exit 65
  fi
  TEST_ROOT="$REQUESTED_TEST_ROOT"
  mkdir -p "$TEST_ROOT"
else
  TEST_ROOT="$(mktemp -d "/private/tmp/osaurus-ui-proof-${BUNDLE_ID##*.}-XXXXXXXX")"
fi

# A dedicated bundle id is the UserDefaults domain. Start it empty so the
# proof cannot inherit settings from production or an earlier proof run.
/usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

process_ids_for_binary() {
  ps -axo pid=,command= | awk -v binary="$BIN" 'index($0, binary) { print $1 }'
}
BEFORE_PIDS="$(process_ids_for_binary)"

# Pass overrides in the per-launch context. Transient launchctl setenv values
# can be gone before LaunchServices starts the process and affect other launches.
STDOUT_LOG="$TEST_ROOT/osaurus.stdout.log"
STDERR_LOG="$TEST_ROOT/osaurus.stderr.log"
/usr/bin/open -n \
  --env "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1" \
  --env "OSAURUS_TEST_ROOT=$TEST_ROOT" \
  --env "OSU_MODELS_DIR=$MODELS_DIR" \
  --stdout "$STDOUT_LOG" \
  --stderr "$STDERR_LOG" \
  "$APP"

PID=""
for _ in $(seq 1 100); do
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if ! grep -qx "$candidate" <<<"$BEFORE_PIDS"; then
      PID="$candidate"
      break 2
    fi
  done < <(process_ids_for_binary)
  sleep 0.1
done
if [[ -z "$PID" ]]; then
  echo "LaunchServices did not start a new proof app process: $BIN" >&2
  exit 70
fi

echo "pid=$PID"
echo "bundle_id=$BUNDLE_ID"
echo "user_defaults_domain=$BUNDLE_ID"
echo "models_dir=$MODELS_DIR"
echo "test_root=$TEST_ROOT"
echo "app=$APP"

echo "stdout_log=$STDOUT_LOG"
echo "stderr_log=$STDERR_LOG"
