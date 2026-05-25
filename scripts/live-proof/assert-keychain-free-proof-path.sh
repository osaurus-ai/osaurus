#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENTS="$ROOT/AGENTS.md"
LAUNCHER="$ROOT/scripts/live-proof/launch-keychain-free-osaurus.sh"
fail=0

check_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! rg -q --fixed-strings "$pattern" "$file"; then
    echo "FAIL missing $label in $file" >&2
    fail=1
  else
    echo "PASS $label"
  fi
}

check_absent_regex() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -n "$pattern" "$file"; then
    echo "FAIL forbidden $label in $file" >&2
    fail=1
  else
    echo "PASS no $label"
  fi
}

if [[ ! -f "$AGENTS" ]]; then
  echo "FAIL missing $AGENTS" >&2
  exit 1
fi
if [[ ! -f "$LAUNCHER" ]]; then
  echo "FAIL missing $LAUNCHER" >&2
  exit 1
fi

check_contains "$AGENTS" "Keychain-Free Validation Gate" "keychain-free validation gate"
check_contains "$AGENTS" "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1" "keychain-disabled env rule"
check_contains "$AGENTS" "OSAURUS_TEST_ROOT=/tmp/..." "isolated test root rule"
check_contains "$AGENTS" "If Xcode, codesign, CodeSigningHelper, or Keychain UI" "stop-on-keychain rule"
check_contains "$AGENTS" "Do not run Osaurus SwiftPM/Xcode validation lanes" "no Osaurus SwiftPM/Xcode validation lane rule"
check_contains "$AGENTS" "Shell-only guards, \`rg\` audits, direct script checks" "shell-only default validation rule"

check_contains "$LAUNCHER" "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1" "launcher disables keychain"
check_contains "$LAUNCHER" 'OSAURUS_TEST_ROOT="$TEST_ROOT"' "launcher isolates test root"
check_absent_regex "$LAUNCHER" '(^|[^[:alnum:]_])(open|security|codesign|notarytool|xcodebuild)([[:space:]]|$)' "keychain/signing/LaunchServices command"

active_forbidden="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|DerivedData-[^ ]*keychain|DerivedData-pin|launch-keychain-free-osaurus|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-keychain-free-proof-path|launch-keychain-free-osaurus\.sh' || true)"
if [[ -n "$active_forbidden" ]]; then
  echo "FAIL active keychain-sensitive Osaurus validation process detected:" >&2
  echo "$active_forbidden" >&2
  fail=1
else
  echo "PASS no active keychain-sensitive Osaurus build/signing/test processes"
fi

exit "$fail"
