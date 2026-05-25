#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_file() {
  local file="$1"
  local label="$2"
  if [[ -f "$file" ]]; then
    pass "$label exists"
  else
    fail_msg "missing $label: $file"
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

reject_dirty_prefix() {
  local prefix="$1"
  local label="$2"
  local matches
  matches="$(git -C "$ROOT" status --short -- "$prefix" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    echo "$matches" >&2
    fail_msg "$label must not be present in PR dirty state"
  else
    pass "no dirty $label"
  fi
}

reject_status_pattern() {
  local pattern="$1"
  local label="$2"
  local matches
  matches="$(git -C "$ROOT" status --short | rg "$pattern" || true)"
  if [[ -n "$matches" ]]; then
    echo "$matches" >&2
    fail_msg "$label must not be present in PR dirty state"
  else
    pass "no $label in PR dirty state"
  fi
}

KEYCHAIN_GUARD="$ROOT/scripts/live-proof/assert-keychain-free-proof-path.sh"
VMLX_READY="$ROOT/scripts/live-proof/assert-osaurus-vmlx-pr-readiness.sh"
SAMPLER_GUARD="$ROOT/scripts/live-proof/assert-no-hidden-local-sampler-defaults.sh"
RESPONSES_GUARD="$ROOT/scripts/live-proof/assert-openresponses-cache-proof-wiring.sh"
NO_FORCED_GUARD="$ROOT/scripts/live-proof/assert-osaurus-no-forced-behavior-pr.sh"
SERVER_SETTINGS_GUARD="$ROOT/scripts/live-proof/assert-server-settings-runtime-wiring.sh"

for file in "$KEYCHAIN_GUARD" "$VMLX_READY" "$SAMPLER_GUARD" "$RESPONSES_GUARD" "$NO_FORCED_GUARD" "$SERVER_SETTINGS_GUARD"; do
  require_file "$file" "${file#$ROOT/}"
done

echo "--- process/keychain gates ---"
if "$KEYCHAIN_GUARD"; then
  pass "keychain-free lane"
else
  fail_msg "keychain-free guard failed"
fi

echo "--- source readiness gates ---"
if "$VMLX_READY"; then
  pass "vMLX pin/checkout readiness"
else
  fail_msg "vMLX pin/checkout readiness failed"
fi

if "$SAMPLER_GUARD"; then
  pass "no hidden sampler defaults"
else
  fail_msg "hidden sampler defaults guard failed"
fi

if "$RESPONSES_GUARD"; then
  pass "OpenResponses/cache wiring"
else
  fail_msg "OpenResponses/cache guard failed"
fi

if "$NO_FORCED_GUARD"; then
  pass "no forced behavior / hidden sampler repairs"
else
  fail_msg "no-forced-behavior PR guard failed"
fi

if "$SERVER_SETTINGS_GUARD"; then
  pass "server settings runtime wiring"
else
  fail_msg "server settings runtime wiring guard failed"
fi

echo "--- PR artifact hygiene ---"
reject_dirty_prefix ".spm-cache" "SwiftPM artifact cache"
reject_dirty_prefix ".claude" "local Claude settings"
reject_dirty_prefix "investigation" "scratch investigation directory"
reject_status_pattern '(^|\s)(\.build|DerivedData|build/|\.DS_Store|.*\.xcuserstate|.*\.xcuserdata)' \
  "build/user-state artifact"

echo "--- required PR files ---"
require_file "$ROOT/AGENTS.md" "Osaurus AGENTS keychain rules"
require_text "$ROOT/AGENTS.md" 'Do not run Osaurus SwiftPM/Xcode validation lanes' \
  "Osaurus no SwiftPM/Xcode validation rule"
require_text "$ROOT/Packages/OsaurusCore/Package.swift" \
  'revision: "52af37d5d4d5b7279ef627b505ca1f186b383cc8"' \
  "Package.swift pinned to vMLX Gemma parser fix"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift" \
  '52af37d5d4d5b7279ef627b505ca1f186b383cc8' \
  "RuntimePolicySourceTests guard pinned vMLX revision"
require_text "$ROOT/Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'let engineDefaults = MLXLMCommon\.GenerateParameters\(\)' \
  "MLXBatchAdapter uses vMLX engine defaults"
require_text "$ROOT/Packages/OsaurusCore/Networking/HTTPHandler.swift" \
  'ChannelEvent\.inputClosed|requestTasks\.cancelAll|Task\.checkCancellation' \
  "HTTP cancellation source path present"
require_text "$ROOT/Packages/OsaurusCore/Views/Settings/ServerSettings/CacheSection.swift" \
  'isOn: \$draft\.cache\.enableSSMReDerive' \
  "Server settings expose SSM rederive toggle"
require_text "$ROOT/Packages/OsaurusCore/Views/Settings/ServerSettings/CacheSection.swift" \
  'selection: \$draft\.cache\.liveKVCodec' \
  "Server settings expose live KV codec selector"
require_text "$ROOT/Packages/OsaurusCore/Views/Settings/ServerSettings/ConcurrencySection.swift" \
  'isOn: \$draft\.concurrency\.continuousBatching' \
  "Server settings expose continuous batching toggle"

active_forbidden="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -i 'CodeSigningHelper|xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-osaurus-pr-hygiene|assert-keychain-free-proof-path|assert-osaurus-vmlx-pr-readiness|assert-vmlx-gemma4-parser-fix-wired|assert-no-hidden-local-sampler-defaults|assert-openresponses-cache-proof-wiring|assert-osaurus-no-forced-behavior-pr|assert-server-settings-runtime-wiring' || true)"
if [[ -n "$active_forbidden" ]]; then
  echo "$active_forbidden" >&2
  fail_msg "active Osaurus keychain-sensitive validation process detected"
else
  pass "no active Osaurus keychain-sensitive validation process"
fi

if [[ "$fail" -ne 0 ]]; then
  cat >&2 <<'EOF'
Osaurus PR hygiene is BLOCKED.

Remove or intentionally ignore local-only artifacts before PR publication.
Do not run SwiftPM/Xcode validation while the keychain-free gate is active.
EOF
  exit 1
fi

echo "Osaurus PR hygiene guard passed."
