#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="$ROOT/scripts/live-proof/launch-keychain-free-osaurus.sh"
UI_LAUNCHER="$ROOT/scripts/live-proof/open-keychain-free-osaurus.sh"
BUILDER="$ROOT/scripts/live-proof/build-keychain-free-osaurus.sh"
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

if [[ ! -f "$LAUNCHER" ]]; then
  echo "FAIL missing $LAUNCHER" >&2
  exit 1
fi
if [[ ! -f "$UI_LAUNCHER" ]]; then
  echo "FAIL missing $UI_LAUNCHER" >&2
  exit 1
fi
if [[ ! -f "$BUILDER" ]]; then
  echo "FAIL missing $BUILDER" >&2
  exit 1
fi

check_contains "$LAUNCHER" "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1" "launcher disables keychain"
check_contains "$LAUNCHER" 'OSAURUS_TEST_ROOT="$TEST_ROOT"' "launcher isolates test root"
check_absent_regex "$LAUNCHER" '(^|[^[:alnum:]_])(open|security|codesign|notarytool|xcodebuild)([[:space:]]|$)' "keychain/signing/LaunchServices command"

check_contains "$UI_LAUNCHER" "launchctl setenv OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS 1" "UI launcher disables keychain via launchd env"
check_contains "$UI_LAUNCHER" 'launchctl setenv OSAURUS_TEST_ROOT "$TEST_ROOT"' "UI launcher isolates test root via launchd env"
check_contains "$UI_LAUNCHER" "/usr/bin/open -n" "UI launcher uses LaunchServices for foreground app"
check_absent_regex "$UI_LAUNCHER" '(^|[^[:alnum:]_])(security|notarytool|xcodebuild)([[:space:]]|$)' "keychain/build command"

check_contains "$BUILDER" "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1" "builder disables keychain"
check_contains "$BUILDER" "DEVELOPER_DIR=\"\${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}\"" "builder selects full Xcode"
check_contains "$BUILDER" "CODE_SIGNING_ALLOWED=NO" "builder disables code signing"
check_contains "$BUILDER" "CODE_SIGNING_REQUIRED=NO" "builder disables required signing"
check_contains "$BUILDER" "CODE_SIGN_IDENTITY=" "builder clears signing identity"
check_contains "$BUILDER" "AD_HOC_CODE_SIGNING_ALLOWED=NO" "builder disables ad-hoc signing"
check_contains "$BUILDER" "ENABLE_USER_SCRIPT_SANDBOXING=NO" "builder disables user script sandboxing"
check_contains "$BUILDER" "/usr/bin/codesign --force --deep --sign - --timestamp=none" "builder applies keychain-free ad-hoc seal"
check_absent_regex "$BUILDER" '(^|[^[:alnum:]_])(open|security|notarytool)([[:space:]]|$)' "keychain/LaunchServices command"

"$ROOT/scripts/live-proof/assert-keychain-disabled-source-coverage.sh"

check_contains "$ROOT/Packages/OsaurusCore/Services/Keychain/KeychainQueryHelpers.swift" "disablesKeychainForProcess" "shared keychain-disabled process flag"
check_contains "$ROOT/Packages/OsaurusCore/Services/Keychain/AgentSecretsKeychain.swift" "if KeychainQueryHelpers.disablesKeychainForProcess { return nil }" "agent secret read bypass"
check_contains "$ROOT/Packages/OsaurusCore/Services/Keychain/ToolSecretsKeychain.swift" "if KeychainQueryHelpers.disablesKeychainForProcess { return nil }" "tool secret read bypass"
check_contains "$ROOT/Packages/OsaurusCore/Services/Provider/RemoteProviderKeychain.swift" "if KeychainQueryHelpers.disablesKeychainForProcess { return nil }" "remote provider read bypass"
check_contains "$ROOT/Packages/OsaurusCore/Services/MCP/MCPProviderKeychain.swift" "if KeychainQueryHelpers.disablesKeychainForProcess { return nil }" "mcp provider read bypass"
check_contains "$ROOT/Packages/OsaurusCore/Identity/StorageKeyManager.swift" "if Self.disablesKeychainForProcess { return nil }" "storage keychain read bypass"

active_forbidden="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|DerivedData-[^ ]*keychain|DerivedData-pin|launch-keychain-free-osaurus|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-keychain-free-proof-path|launch-keychain-free-osaurus\\.sh|/usr/bin/codesign --force --deep --sign - --timestamp=none|/Users/eric/\\.codex/computer-use/|SkyComputerUseClient' || true)"
if [[ -n "$active_forbidden" ]]; then
  echo "FAIL active keychain-sensitive Osaurus validation process detected:" >&2
  echo "$active_forbidden" >&2
  fail=1
else
  echo "PASS no active keychain-sensitive Osaurus build/signing/test processes"
fi

exit "$fail"
