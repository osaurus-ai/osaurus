#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }
warn() { echo "WARN $*" >&2; }

require_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    pass "file exists: ${file#$ROOT/}"
  else
    fail_msg "missing file: ${file#$ROOT/}"
  fi
}

require_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "missing $label in ${file#$ROOT/}"
  fi
}

require_fixed_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -Fq "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "missing $label in ${file#$ROOT/}"
  fi
}

pin_from_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  perl -0ne 'while (/vmlx-swift[\s\S]{0,1200}?(?:revision|version)\s*"?\s*:\s*"([0-9a-f]{40})"/g) { print "$1\n"; exit }' "$file" \
    || true
}

KEYCHAIN_GUARD="$ROOT/scripts/live-proof/assert-keychain-free-proof-path.sh"
GEMMA_WIRE_GUARD="$ROOT/scripts/live-proof/assert-vmlx-gemma4-parser-fix-wired.sh"
SAMPLER_GUARD="$ROOT/scripts/live-proof/assert-no-hidden-local-sampler-defaults.sh"
RESPONSES_CACHE_GUARD="$ROOT/scripts/live-proof/assert-openresponses-cache-proof-wiring.sh"
SERVER_SETTINGS_GUARD="$ROOT/scripts/live-proof/assert-server-settings-runtime-wiring.sh"

PKG="$ROOT/Packages/OsaurusCore/Package.swift"
CORE_RESOLVED="$ROOT/Packages/OsaurusCore/Package.resolved"
WORKSPACE_RESOLVED="$ROOT/osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved"
APP_RESOLVED="$ROOT/App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
CHECKOUT="$ROOT/Packages/OsaurusCore/.build/checkouts/vmlx-swift"
PARSER="$CHECKOUT/Libraries/MLXLMCommon/ReasoningParser.swift"
TOOL_PARSER="$CHECKOUT/Libraries/MLXLMCommon/Tool/Parsers/GemmaFunctionParser.swift"
DSML_PARSER="$CHECKOUT/Libraries/MLXLMCommon/Tool/Parsers/DSMLToolCallParser.swift"
TESTS="$CHECKOUT/Tests/MLXLMCommonFocusedTests/Gemma4ThoughtChannelParserFocusedTests.swift"
TOOL_TESTS="$CHECKOUT/Tests/MLXLMTests/ToolCallEdgeCasesTests.swift"
DSML_TESTS="$CHECKOUT/Tests/MLXLMCommonFocusedTests/DSMLToolCallParserFocusedTests.swift"

for file in "$KEYCHAIN_GUARD" "$GEMMA_WIRE_GUARD" "$SAMPLER_GUARD" "$RESPONSES_CACHE_GUARD" "$SERVER_SETTINGS_GUARD" \
  "$PKG" "$CORE_RESOLVED" "$WORKSPACE_RESOLVED" "$APP_RESOLVED"; do
  require_file "$file"
done

echo "--- keychain guard ---"
if "$KEYCHAIN_GUARD"; then
  pass "keychain-safe validation lane"
else
  fail_msg "keychain guard failed"
fi

echo "--- defaults/cache source guards ---"
if "$SAMPLER_GUARD"; then
  pass "no hidden local sampler defaults"
else
  fail_msg "hidden sampler default guard failed"
fi

if "$RESPONSES_CACHE_GUARD"; then
  pass "OpenResponses/cache source wiring"
else
  fail_msg "OpenResponses/cache source guard failed"
fi

if "$SERVER_SETTINGS_GUARD"; then
  pass "Server Settings runtime wiring"
else
  fail_msg "Server Settings runtime wiring guard failed"
fi

echo "--- vMLX pin surfaces ---"
require_text "$PKG" 'url: "https://github.com/osaurus-ai/vmlx-swift"' \
  "Package.swift uses osaurus-ai/vmlx-swift"

pkg_pin="$(perl -0ne 'if (/osaurus-ai\/vmlx-swift[\s\S]{0,500}?revision:\s*"([0-9a-f]{40})"/) { print $1 }' "$PKG" || true)"
core_pin="$(pin_from_file "$CORE_RESOLVED")"
workspace_pin="$(pin_from_file "$WORKSPACE_RESOLVED")"
app_pin="$(pin_from_file "$APP_RESOLVED")"

if [[ -n "$pkg_pin" ]]; then
  pass "Package.swift vMLX pin: $pkg_pin"
else
  fail_msg "Package.swift vMLX revision pin not found"
fi

if [[ -n "$core_pin" ]]; then
  pass "OsaurusCore Package.resolved vMLX pin: $core_pin"
else
  fail_msg "OsaurusCore Package.resolved vMLX pin not found"
fi

if [[ -n "$workspace_pin" ]]; then
  pass "workspace Package.resolved vMLX pin: $workspace_pin"
else
  fail_msg "workspace Package.resolved vMLX pin not found"
fi

if [[ -n "$app_pin" ]]; then
  pass "app Package.resolved vMLX pin: $app_pin"
else
  fail_msg "app Package.resolved vMLX pin not found"
fi

if [[ -n "$pkg_pin" && -n "$core_pin" && -n "$workspace_pin" && -n "$app_pin" ]]; then
  if [[ "$pkg_pin" == "$core_pin" && "$pkg_pin" == "$workspace_pin" && "$pkg_pin" == "$app_pin" ]]; then
    pass "all Osaurus vMLX pin surfaces agree"
  else
    fail_msg "Osaurus vMLX pin surfaces disagree: package=$pkg_pin core=$core_pin workspace=$workspace_pin app=$app_pin"
  fi
fi

echo "--- wired vMLX checkout parser proof ---"
if checkout_head="$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)"; then
  if [[ -n "$pkg_pin" && "$checkout_head" == "$pkg_pin" ]]; then
    pass "SwiftPM checkout HEAD matches Package.swift vMLX pin"
  else
    fail_msg "SwiftPM checkout HEAD $checkout_head does not match Package.swift vMLX pin $pkg_pin"
  fi
else
  fail_msg "SwiftPM checkout HEAD not readable"
fi

if [[ -f "$PARSER" ]]; then
  pass "SwiftPM checkout parser exists"
  require_fixed_text "$PARSER" 'channelName == "thought" || channelName == "thinking"' \
    "wired checkout handles Gemma bare thought channel name"
  require_fixed_text "$PARSER" 'harmonyChannelShouldStripName = false' \
    "wired checkout contains Gemma empty-thought parser fix"
else
  fail_msg "SwiftPM checkout parser missing"
fi

if [[ -f "$DSML_PARSER" ]]; then
  pass "SwiftPM checkout DSML parser exists"
  require_text "$DSML_PARSER" 'tool_ccalls' \
    "wired checkout accepts DSV4 tool_ccalls DSML alias"
  require_text "$DSML_PARSER" 'tool_cs' \
    "wired checkout accepts DSV4 tool_cs DSML alias"
else
  fail_msg "SwiftPM checkout DSML parser missing"
fi

if [[ -f "$TOOL_PARSER" ]]; then
  pass "SwiftPM checkout Gemma tool parser exists"
  require_text "$TOOL_PARSER" 'trimmingCharacters\(in: \.whitespacesAndNewlines\)' \
    "wired checkout contains Gemma tool whitespace parser fix"
else
  fail_msg "SwiftPM checkout Gemma tool parser missing"
fi

if [[ -f "$TESTS" ]]; then
  pass "SwiftPM checkout focused tests exist"
  require_text "$TESTS" 'empty thought channel without newline does not surface thought' \
    "wired checkout contains Gemma empty-thought regression"
else
  fail_msg "SwiftPM checkout focused tests missing"
fi

if [[ -f "$TOOL_TESTS" ]]; then
  pass "SwiftPM checkout Gemma tool tests exist"
  require_text "$TOOL_TESTS" 'Gemma-4 tool-call parser trims whitespace around function names and keys' \
    "wired checkout contains Gemma tool whitespace regression"
else
  fail_msg "SwiftPM checkout Gemma tool tests missing"
fi

if [[ -f "$DSML_TESTS" ]]; then
  pass "SwiftPM checkout DSML focused tests exist"
  require_text "$DSML_TESTS" 'processorAcceptsLiveToolCCallsToolCSAlias' \
    "wired checkout contains DSV4 DSML alias regression"
  require_text "$DSML_TESTS" 'visible\.trimmingCharacters\(in: \.whitespacesAndNewlines\)\.isEmpty' \
    "wired checkout rejects visible DSML alias leakage"
else
  fail_msg "SwiftPM checkout DSML focused tests missing"
fi

echo "--- existing Gemma wire guard ---"
if "$GEMMA_WIRE_GUARD"; then
  pass "Gemma parser fix wired through dependency checkout"
else
  warn "Gemma parser wire guard failed or was process-blocked; inspect the guard output above before classifying this as a pin/checkout mismatch"
  fail=1
fi

active_forbidden="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-osaurus-vmlx-pr-readiness|assert-keychain-free-proof-path|assert-vmlx-gemma4-parser-fix-wired|assert-no-hidden-local-sampler-defaults|assert-openresponses-cache-proof-wiring|assert-server-settings-runtime-wiring' || true)"
if [[ -n "$active_forbidden" ]]; then
  echo "$active_forbidden" >&2
  fail_msg "active Osaurus keychain-sensitive validation process detected"
else
  pass "no active Osaurus keychain-sensitive validation process"
fi

if [[ "$fail" -ne 0 ]]; then
  cat >&2 <<'EOF'
Osaurus vMLX PR readiness is BLOCKED.

If the source/pin assertions above failed, fix the named vMLX pin/checkout/source mismatch.
If the source/pin assertions above passed and only the process gate failed, clear the
keychain/signing helper before rerunning this guard and any live app proof lane.
EOF
  exit 1
fi

echo "Osaurus vMLX PR readiness source guard passed."
