#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
VMLX_PIN="$(sed -nE 's/.*revision: "([0-9a-f]{40})".*/\1/p' "$ROOT/Packages/OsaurusCore/Package.swift" | head -1 || true)"

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
CHAT_REASONING_GUARD="$ROOT/scripts/live-proof/assert-chat-reasoning-delta-routing.sh"
CHAT_UI_REASONING_GUARD="$ROOT/scripts/live-proof/assert-chat-ui-reasoning-routing.sh"
HTTP_CANCEL_GUARD="$ROOT/scripts/live-proof/assert-http-channel-load-cancellation.sh"
TOOL_CHOICE_GUARD="$ROOT/scripts/live-proof/assert-tool-choice-required-routing.sh"
MODEL_TOOL_CAPABILITY_GUARD="$ROOT/scripts/live-proof/assert-model-tool-capability-surfaces.sh"

for file in "$KEYCHAIN_GUARD" "$VMLX_READY" "$SAMPLER_GUARD" "$RESPONSES_GUARD" "$NO_FORCED_GUARD" "$SERVER_SETTINGS_GUARD" "$CHAT_REASONING_GUARD" "$CHAT_UI_REASONING_GUARD" "$HTTP_CANCEL_GUARD" "$TOOL_CHOICE_GUARD" "$MODEL_TOOL_CAPABILITY_GUARD"; do
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

if "$CHAT_REASONING_GUARD"; then
  pass "chat reasoning delta routing"
else
  fail_msg "chat reasoning delta routing guard failed"
fi

if "$CHAT_UI_REASONING_GUARD"; then
  pass "chat UI reasoning routing"
else
  fail_msg "chat UI reasoning routing guard failed"
fi

if "$HTTP_CANCEL_GUARD"; then
  pass "HTTP channel/load cancellation"
else
  fail_msg "HTTP channel/load cancellation guard failed"
fi

if "$TOOL_CHOICE_GUARD"; then
  pass "tool_choice required routing"
else
  fail_msg "tool_choice required routing guard failed"
fi

if "$MODEL_TOOL_CAPABILITY_GUARD"; then
  pass "model tool/capability surfaces"
else
  fail_msg "model tool/capability surface guard failed"
fi

echo "--- PR artifact hygiene ---"
reject_dirty_prefix ".spm-cache" "SwiftPM artifact cache"
reject_dirty_prefix ".claude" "local Claude settings"
reject_dirty_prefix "investigation" "scratch investigation directory"
reject_status_pattern '(^|\s)(\.build|DerivedData|build/|\.DS_Store|.*\.xcuserstate|.*\.xcuserdata)' \
  "build/user-state artifact"

echo "--- required PR files ---"
if git -C "$ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
  agents_diff="$(git -C "$ROOT" diff --unified=0 origin/main...HEAD -- AGENTS.md || true)"
  if [[ -n "$agents_diff" ]]; then
    unexpected_agent_bullets="$(printf '%s\n' "$agents_diff" \
      | rg '^\+[[:space:]]*-' \
      | rg -v '^\+[[:space:]]*-[[:space:]]*(Never add fake guards|Reasoning fixes must preserve|Memory limits must apply|Server settings are part of runtime proof|Tool, memory, and cache setting proof must exercise|Do not spawn recursive local "agent" workers)' || true)"
    if [[ -n "$unexpected_agent_bullets" ]]; then
      echo "$unexpected_agent_bullets" >&2
      fail_msg "AGENTS.md contains unexpected PR-only agent rules; keep agent policy local"
    else
      pass "AGENTS.md delta is limited to explicit release proof/no-fake/no-recursive-agent rules"
    fi
  else
    pass "AGENTS.md has no PR delta"
  fi
else
  pass "origin/main unavailable; AGENTS.md PR-diff gate skipped"
fi
require_text "$ROOT/scripts/live-proof/build-keychain-free-osaurus.sh" 'CODE_SIGNING_ALLOWED=NO' \
  "keychain-free build disables Xcode signing"
require_text "$ROOT/scripts/live-proof/build-keychain-free-osaurus.sh" 'timestamp=none' \
  "keychain-free build uses timestamp-free ad-hoc seal"
require_text "$ROOT/scripts/live-proof/open-keychain-free-osaurus.sh" 'OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS' \
  "keychain-free UI launch exports disabled-keychain mode"
require_text "$ROOT/docs/RUNTIME_VALIDATION_STANDARD.md" 'generation_config' \
  "runtime validation docs preserve model generation defaults"
require_text "$ROOT/scripts/live-proof/POST1266-LIVE-FAMILY-CACHE-MATRIX.md" 'token/s' \
  "family matrix records generation throughput"
require_text "$ROOT/scripts/live-proof/POST1266-LIVE-FAMILY-CACHE-MATRIX.md" 'disk_l2_hits' \
  "family matrix records disk L2 cache evidence"
require_text "$ROOT/scripts/live-proof/family-runtime-chat-matrix.json" 'tool' \
  "family runtime matrix includes tool-call proof rows"
if [[ -n "$VMLX_PIN" ]]; then
  require_text "$ROOT/Packages/OsaurusCore/Package.swift" \
    "revision: \"$VMLX_PIN\"" \
    "Package.swift pinned to current vMLX revision $VMLX_PIN"
  require_text "$ROOT/Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift" \
    "$VMLX_PIN" \
    "RuntimePolicySourceTests guard pinned current vMLX revision"
else
  fail_msg "Package.swift does not expose a 40-hex vMLX revision"
fi
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/ModelRuntimeIsHybridTests.swift" \
  'dealignai/Qwen3\.6-35B-A3B-MXFP4-CRACK-MTP' \
  "ModelRuntime hybrid detection covers reported dealignai Qwen3.6 MXFP4 MTP slug"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/ModelRuntimeIsHybridTests.swift" \
  'DeepSeek-V4-Flash-JANGTQ2' \
  "ModelRuntime hybrid detection keeps DSV4 JANGTQ2 out of SSM-family matcher"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/IsKnownHybridModelMCDCTests.swift" \
  'dealignai/Qwen3\.6-35B-A3B-MXFP4-CRACK-MTP' \
  "MC/DC hybrid detection covers reported dealignai Qwen3.6 MXFP4 MTP slug"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/IsKnownHybridModelMCDCTests.swift" \
  'DeepSeek-V4-Flash-JANGTQ2' \
  "MC/DC hybrid detection keeps DSV4 JANGTQ2 out of SSM-family matcher"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/MLXBatchAdapterTests.swift" \
  'modelName: "DeepSeek-V4-Flash-JANGTQ2"' \
  "cache model-key test covers exact DSV4 JANGTQ2 name"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/MLXBatchAdapterTests.swift" \
  'layers=deepseekV4' \
  "cache model-key test tags DSV4 layers"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/MLXBatchAdapterTests.swift" \
  'prefix=hybrid-pool-disk' \
  "cache model-key test tags DSV4 hybrid pool disk prefix"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/MLXBatchAdapterTests.swift" \
  '!dsv4\.contains\("layers=hybrid-ssm"\)' \
  "cache model-key test rejects SSM-family tag for DSV4"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/DSV4ParserPipelineTests.swift" \
  'think_xml reasoning and DSML tool calls route to separate events' \
  "DSV4 parser pipeline separates reasoning and DSML tool calls"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/DSV4ParserPipelineTests.swift" \
  'DSML markup must not leak as visible text' \
  "DSV4 parser pipeline prevents DSML markup leak"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/DSV4ParserPipelineTests.swift" \
  'malformed live DSV4 DSML aliases route to tools without visible leakage' \
  "DSV4 parser pipeline covers live malformed DSML alias leak"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/DSV4ParserPipelineTests.swift" \
  'tool_ccalls' \
  "DSV4 parser pipeline covers tool_ccalls alias"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/DSV4ParserPipelineTests.swift" \
  'tool_cs' \
  "DSV4 parser pipeline covers tool_cs alias"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/SwiftTransformersTokenizerLoaderTests.swift" \
  'DSV4 canonical template path must use DSML tool-call blocks' \
  "DSV4 canonical tokenizer path renders DSML tool-call blocks"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/SwiftTransformersTokenizerLoaderTests.swift" \
  'DSV4 canonical template path must not use the generic tool dialect' \
  "DSV4 canonical tokenizer path rejects generic tool dialect"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/SwiftTransformersTokenizerLoaderTests.swift" \
  'DSV4 canonical template path must render assistant tool history as a DSML block' \
  "DSV4 canonical tokenizer path preserves DSML tool history"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/SwiftTransformersTokenizerLoaderTests.swift" \
  'downloadedFamilyTokenizersRenderCapabilitiesDiscoverToolSurface' \
  "downloaded model tokenizer matrix renders capability discovery surface"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/SwiftTransformersTokenizerLoaderTests.swift" \
  'Gemma 4 31B JANG_4M candidate' \
  "downloaded tokenizer matrix keeps Gemma 4 31B candidate covered"
require_text "$ROOT/Packages/OsaurusCore/Tests/Tool/ToolSearchServiceTests.swift" \
  'hybridSearchFallsBackToRegistryWhenToolDatabaseIsClosed' \
  "capability search falls back to registry when encrypted storage is closed"
require_text "$ROOT/Packages/OsaurusCore/Tests/Tool/CapabilityToolsTests.swift" \
  'capabilitiesSearchSchemaIsGemmaRenderable' \
  "capabilities_discover schema remains Gemma-renderable"
require_text "$ROOT/Packages/OsaurusCore/Models/Configuration/ModelMediaCapabilities.swift" \
  '"qwen3_6", "qwen3_6_moe"' \
  "Qwen3.6 config-based media detection preserves video-capable model types"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/MultiTurnFamilyMatrixTests.swift" \
  '"qwen3_6", "qwen3_6_moe"' \
  "multi-turn family matrix covers Qwen3.6 config-based media detection"
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
  | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-osaurus-pr-hygiene|assert-keychain-free-proof-path|assert-osaurus-vmlx-pr-readiness|assert-vmlx-gemma4-parser-fix-wired|assert-no-hidden-local-sampler-defaults|assert-openresponses-cache-proof-wiring|assert-osaurus-no-forced-behavior-pr|assert-server-settings-runtime-wiring|assert-chat-reasoning-delta-routing|assert-chat-ui-reasoning-routing|assert-http-channel-load-cancellation' || true)"
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
