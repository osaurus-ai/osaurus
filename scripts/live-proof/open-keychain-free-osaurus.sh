#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /path/to/osaurus.app [test-root]" >&2
  exit 64
fi

APP="$1"
TEST_ROOT="${2:-/tmp/osaurus-keychain-free-ui-proof-$(date +%Y%m%d-%H%M%S)}"
BIN="$APP/Contents/MacOS/osaurus"

if [[ ! -x "$BIN" ]]; then
  echo "missing executable: $BIN" >&2
  exit 66
fi

mkdir -p "$TEST_ROOT"

# LaunchServices is required for a foreground SwiftUI app on current macOS.
# Set the keychain-disabled test environment in the user launchd namespace
# before open(1), so the app inherits it without touching login Keychain.
launchctl setenv OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS 1
launchctl setenv OSAURUS_TEST_ROOT "$TEST_ROOT"

/usr/bin/open -n "$APP"

echo "test_root=$TEST_ROOT"
echo "app=$APP"
