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
TESTS="$CHECKOUT/Tests/MLXLMCommonFocusedTests/Gemma4ThoughtChannelParserFocusedTests.swift"

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
if [[ -f "$PARSER" ]]; then
  pass "SwiftPM checkout parser exists"
  require_text "$PARSER" 'stripIdentifierOnlyAtEnd: true\)' \
    "wired checkout contains Gemma empty-thought parser fix"
else
  fail_msg "SwiftPM checkout parser missing"
fi

if [[ -f "$TESTS" ]]; then
  pass "SwiftPM checkout focused tests exist"
  require_text "$TESTS" 'empty thought channel without newline does not surface thought' \
    "wired checkout contains Gemma empty-thought regression"
else
  fail_msg "SwiftPM checkout focused tests missing"
fi

echo "--- existing Gemma wire guard ---"
if "$GEMMA_WIRE_GUARD"; then
  pass "Gemma parser fix wired through dependency checkout"
else
  warn "Gemma parser fix is not wired through the current Osaurus dependency checkout"
  fail=1
fi

active_forbidden="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -i 'CodeSigningHelper|xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
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

Required before PR promotion:
- push the vMLX parser/cache/default fixes to the vmlx-swift remote branch intended for Osaurus
- update Package.swift plus all Package.resolved surfaces to that exact revision
- refresh the SwiftPM checkout under a keychain-safe approved lane
- rerun this guard and then the live app proof lane only if explicitly approved
EOF
  exit 1
fi

echo "Osaurus vMLX PR readiness source guard passed."
