#!/usr/bin/env bash
set -euo pipefail

# Launch/spawn gate. The bug class this guards against is "valid signature, dead
# process": 0.19.3 passed codesign/spctl/notarization yet AMFI refused to spawn
# it (a restricted entitlement with no provisioning profile -> POSIX 163), so
# every user's app became "can't be opened". A spawn that AMFI kills prints no
# sentinel and exits nonzero, so this script fails the build before notarize/
# publish instead of shipping a brick.

APP="${1:-build_output/Osaurus.app}"
APP_BIN="$APP/Contents/MacOS/osaurus"
CLI_BIN="$APP/Contents/Helpers/osaurus"
WATCHDOG_SECONDS=10

if [[ ! -x "$APP_BIN" ]]; then
  echo "❌ app binary not found or not executable at $APP_BIN" >&2
  exit 1
fi

OUT="$(mktemp -t osaurus-spawn-out)"
trap 'rm -f "$OUT"' EXIT

echo "Spawn-checking app binary: $APP_BIN"
# OSAURUS_SPAWN_CHECK makes the binary print OSAURUS_SPAWN_OK and exit(0) before
# any heavy init; OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS keeps it off the login
# Keychain so the check never raises a confidential-information prompt.
OSAURUS_SPAWN_CHECK=1 OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 "$APP_BIN" >"$OUT" 2>&1 &
SPAWN_PID=$!

# macOS has no `timeout`; arm a background killer so a hung spawn still fails.
( sleep "$WATCHDOG_SECONDS"; kill -9 "$SPAWN_PID" 2>/dev/null ) &
WATCHDOG_PID=$!

set +e
wait "$SPAWN_PID"
STATUS=$?
set -e
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

if [[ "$STATUS" -ne 0 ]]; then
  echo "❌ app spawn check exited with status $STATUS — the signed binary could not run (AMFI reject or hang)" >&2
  cat "$OUT" >&2 || true
  exit 1
fi

if ! grep -q "OSAURUS_SPAWN_OK" "$OUT"; then
  echo "❌ app spawn check did not print the OSAURUS_SPAWN_OK sentinel" >&2
  cat "$OUT" >&2 || true
  exit 1
fi
echo "✅ app binary spawns (sentinel printed, exit 0)"

# The embedded CLI helper is a separately-signed Mach-O; run it to prove it also
# spawns under the shipped signature.
if [[ -x "$CLI_BIN" ]]; then
  echo "Spawn-checking CLI helper: $CLI_BIN"
  if CLI_OUT="$("$CLI_BIN" --version 2>&1)"; then
    echo "✅ CLI helper runs: $CLI_OUT"
  else
    echo "❌ CLI helper failed to run (--version exited nonzero): $CLI_OUT" >&2
    exit 1
  fi
else
  echo "ℹ️ CLI helper not found at $CLI_BIN (skipping)"
fi

echo "✅ launch verification passed"
