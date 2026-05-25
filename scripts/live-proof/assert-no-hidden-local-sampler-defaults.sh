#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTER="$ROOT/Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift"
TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_file() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    pass "$label exists"
  else
    fail_msg "missing $label: $file"
  fi
}

require_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "missing $label"
  fi
}

reject_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -n "$pattern" "$file"; then
    fail_msg "forbidden $label"
  else
    pass "no $label"
  fi
}

require_file "$ADAPTER" "MLXBatchAdapter"
require_file "$TESTS" "RuntimePolicySourceTests"

if [[ -f "$ADAPTER" ]]; then
  require_text "$ADAPTER" 'let engineDefaults = MLXLMCommon\.GenerateParameters\(\)' "vMLX engine defaults object"
  require_text "$ADAPTER" 'engineDefaults\.temperature' "temperature falls back to vMLX engine default"
  require_text "$ADAPTER" 'engineDefaults\.topP' "topP falls back to vMLX engine default"
  require_text "$ADAPTER" 'engineDefaults\.topK' "topK falls back to vMLX engine default"
  require_text "$ADAPTER" 'engineDefaults\.minP' "minP falls back to vMLX engine default"
  require_text "$ADAPTER" 'modelDefaults\.repetitionPenalty' "repetition penalty can come from model defaults"
  reject_text "$ADAPTER" 'runtimeTemperature \?\? 0\.7|temperature: useNativeMTPGreedyDefaults|topP: useNativeMTPGreedyDefaults|topK: useNativeMTPGreedyDefaults' "hidden temperature/native-MTP sampler rewrite"
  reject_text "$ADAPTER" 'runtimeTopP \?\? 1\.0|runtimeTopK \?\? 0|runtimeMinP \?\? 0' "hardcoded topP/topK/minP fallback literals"
  reject_text "$ADAPTER" 'dsv4MaxReasoningRepetitionPenalty|rep-penalty rescue|repeated "thinking" token loop' "forced repetition-penalty rescue"
fi

if [[ -f "$TESTS" ]]; then
  require_text "$TESTS" 'engineDefaults\.temperature' "source test guards temperature engine default"
  require_text "$TESTS" 'engineDefaults\.topP' "source test guards topP engine default"
  require_text "$TESTS" 'engineDefaults\.topK' "source test guards topK engine default"
  require_text "$TESTS" 'engineDefaults\.minP' "source test guards minP engine default"
  require_text "$TESTS" 'must use vmlx GenerateParameters defaults for topP/topK/minP' "source test explains no hidden sampler literals"
fi

active="$({ ps -axo pid,ppid,rss,etime,command || true; } | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|swift-build --package-path Packages/OsaurusCore|swift-test --package-path Packages/OsaurusCore|/Users/eric/osaurus-staging/Packages/OsaurusCore/.build' | rg -v 'rg -i|assert-no-hidden-local-sampler-defaults' || true)"
if [[ -n "$active" ]]; then
  fail_msg "active Osaurus build/keychain-sensitive process detected"
  echo "$active" >&2
else
  pass "no active Osaurus build/keychain-sensitive process"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Hidden local sampler default guard failed." >&2
  exit 1
fi

echo "Hidden local sampler default guard passed."
