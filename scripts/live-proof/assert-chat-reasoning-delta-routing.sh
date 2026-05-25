#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHAT_ENGINE="$ROOT/Packages/OsaurusCore/Services/Chat/ChatEngine.swift"
CHAT_TESTS="$ROOT/Packages/OsaurusCore/Tests/Chat/ChatEngineTests.swift"

fail=0
pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

require_file() {
  local file="$1"
  local label="$2"
  if [[ -f "$file" ]]; then
    pass "$label exists"
  else
    fail_msg "$label missing: $file"
  fi
}

require_order() {
  local file="$1"
  local first="$2"
  local second="$3"
  local label="$4"
  local first_line second_line
  first_line="$(rg -n "$first" "$file" | head -1 | cut -d: -f1 || true)"
  second_line="$(rg -n "$second" "$file" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

require_file "$CHAT_ENGINE" "ChatEngine"
require_file "$CHAT_TESTS" "ChatEngineTests"

require_text "$CHAT_ENGINE" 'guard let requestOptions else \{' \
  "bare API requests do not synthesize profile defaults from nil options"
require_text "$CHAT_ENGINE" 'return \[:\]' \
  "nil request options remain empty"
require_text "$CHAT_ENGINE" 'if let reasoning = StreamingReasoningHint\.decode\(delta\)' \
  "ChatEngine decodes reasoning sentinel before visible text"
require_text "$CHAT_ENGINE" 'TokenEstimator\.estimate\(reasoning\)' \
  "reasoning token accounting uses decoded reasoning text"
require_text "$CHAT_ENGINE" 'continuation\.yield\(delta\)' \
  "reasoning sentinel is preserved for UI/API endpoint routing"
require_text "$CHAT_TESTS" 'streamChat_preserves_reasoning_sentinel_for_endpoint_routing' \
  "reasoning sentinel regression exists"
require_text "$CHAT_TESTS" 'completeChat_keepsBareAPIRequestsFreeOfHiddenThinkingDefaults' \
  "bare API no-hidden-thinking regression exists"
require_text "$CHAT_TESTS" 'modelOptions\["disableThinking"\] == nil' \
  "regression rejects hidden disableThinking defaults"

require_order "$CHAT_ENGINE" 'StreamingReasoningHint\.decode\(delta\)' \
  'StreamingToolHint\.isSentinel\(delta\)' \
  "reasoning sentinel handled before tool sentinel branch"
require_order "$CHAT_ENGINE" 'StreamingReasoningHint\.decode\(delta\)' \
  'responseAccumulator\.append\(delta\)' \
  "reasoning sentinel handled before visible response accumulation"
require_order "$CHAT_ENGINE" 'StreamingReasoningHint\.decode\(delta\)' \
  'TokenEstimator\.estimate\(delta\)' \
  "reasoning sentinel handled before visible delta token estimate"

active="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -i 'CodeSigningHelper|xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-chat-reasoning-delta-routing' || true)"
if [[ -n "$active" ]]; then
  echo "$active" >&2
  fail_msg "active keychain/build process detected; source assertions above are still useful but do not promote live readiness"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Chat reasoning delta routing guard failed." >&2
  exit 1
fi

echo "Chat reasoning delta routing guard passed."
