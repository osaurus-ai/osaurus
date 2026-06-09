#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

reject_regex() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  local matches
  matches="$(rg -n -g '!**/Tests/**' "$pattern" "$path" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    echo "$matches" >&2
    fail_msg "forbidden $label"
  else
    pass "no $label"
  fi
}

require_regex() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if rg -q "$pattern" "$path"; then
    pass "$label"
  else
    fail_msg "missing $label"
  fi
}

SOURCE_ROOT="$ROOT/Packages/OsaurusCore"

echo "--- forbidden forced-behavior scan ---"
reject_regex "$SOURCE_ROOT" 'forced thinking|force thinking|forced think|forceThink|force_think|forced reasoning|forceReasoning|inject(ed)? thinking|synthetic thinking|fake thinking' \
  "forced thinking/reasoning behavior"
reject_regex "$SOURCE_ROOT" 'close-token bias|close token bias|bias.*</think>|</think>.*bias|forced closer|force.*closer|forced opener|force.*opener' \
  "decode close-token/open-token bias"
reject_regex "$SOURCE_ROOT" 'parser repair|repair parser|parser fallback repair|strip visible output|hide parser bug|coerce.*template|template coercion' \
  "parser repair/template coercion"
reject_regex "$SOURCE_ROOT" 'rep-penalty rescue|repetition-penalty rescue|hidden repetition|runtimeRepetitionPenalty \?\? 1\.[0-9]|repetitionPenalty \?\? 1\.[0-9]' \
  "hidden repetition-penalty rescue"
reject_regex "$SOURCE_ROOT" 'runtimeTemperature \?\? 0\.[0-9]|temperature \?\? 0\.[0-9]|runtimeTopP \?\? 1\.0|runtimeTopK \?\? 0|runtimeMinP \?\? 0' \
  "hardcoded hidden sampler defaults"
reject_regex "$SOURCE_ROOT" 'useNativeMTPGreedyDefaults|native.*MTP.*greedy|topK.*=.*1.*MTP|temperature.*=.*0.*MTP' \
  "native-MTP sampler rewrite"

echo "--- required positive source contracts ---"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'let engineDefaults = MLXLMCommon\.GenerateParameters\(\)' \
  "MLXBatchAdapter starts from vMLX GenerateParameters defaults"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'engineDefaults\.temperature' \
  "temperature fallback is vMLX engine default"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'engineDefaults\.topP' \
  "topP fallback is vMLX engine default"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'engineDefaults\.topK' \
  "topK fallback is vMLX engine default"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'engineDefaults\.minP' \
  "minP fallback is vMLX engine default"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'requestSamplingIsExplicitGreedy' \
  "native MTP eligibility requires explicit greedy sampling"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'generation\.samplingParametersAreImplicit' \
  "native MTP checks implicit sampling marker"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'return false' \
  "implicit sampling does not authorize native-MTP sampler rewrite"
require_regex "$SOURCE_ROOT/Services/ModelRuntime/MLXBatchAdapter.swift" \
  'normalizedReasoningEffort != nil \|\| disableThinking != nil' \
  "reasoning template kwargs require explicit request controls"

echo "--- keychain/build process boundary ---"
active_forbidden="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -v '/Users/eric/.codex/computer-use/.*/SkyComputerUseClient' \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-osaurus-no-forced-behavior-pr' || true)"
if [[ -n "$active_forbidden" ]]; then
  echo "$active_forbidden" >&2
  fail_msg "active Osaurus keychain-sensitive validation process detected"
else
  pass "no active Osaurus keychain-sensitive validation process"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Osaurus no-forced-behavior PR guard failed." >&2
  exit 1
fi

echo "Osaurus no-forced-behavior PR guard passed."
