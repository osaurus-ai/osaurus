#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
    fail_msg "missing $label in ${file#$ROOT/}"
  fi
}

COMPOSER_TESTS="$ROOT/Packages/OsaurusCore/Tests/Chat/SystemPromptComposerToolResolutionTests.swift"
PREVIEW_TESTS="$ROOT/Packages/OsaurusCore/Tests/Chat/ContextBudgetPreviewTests.swift"
CAPABILITY_TESTS="$ROOT/Packages/OsaurusCore/Tests/Tool/CapabilityToolsTests.swift"
SEARCH_TESTS="$ROOT/Packages/OsaurusCore/Tests/Tool/ToolSearchServiceTests.swift"
TOKENIZER_TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/SwiftTransformersTokenizerLoaderTests.swift"
GUIDANCE="$ROOT/Packages/OsaurusCore/Services/Chat/ModelFamilyGuidance.swift"
TOOL_INDEX="$ROOT/Packages/OsaurusCore/Services/Tool/ToolIndexService.swift"
TOOL_SEARCH="$ROOT/Packages/OsaurusCore/Services/Tool/ToolSearchService.swift"

for entry in \
  "$COMPOSER_TESTS:SystemPromptComposerToolResolutionTests" \
  "$PREVIEW_TESTS:ContextBudgetPreviewTests" \
  "$CAPABILITY_TESTS:CapabilityToolsTests" \
  "$SEARCH_TESTS:ToolSearchServiceTests" \
  "$TOKENIZER_TESTS:SwiftTransformersTokenizerLoaderTests" \
  "$GUIDANCE:ModelFamilyGuidance" \
  "$TOOL_INDEX:ToolIndexService" \
  "$TOOL_SEARCH:ToolSearchService"; do
  require_file "${entry%%:*}" "${entry##*:}"
done

echo "--- first-turn tool surface ---"
require_text "$COMPOSER_TESTS" 'autoMode_includesAlwaysLoadedAndPreflightAdditions' \
  "auto mode keeps capability discovery in first-turn tools"
require_text "$COMPOSER_TESTS" 'manualMode_includesAlwaysLoadedBuiltinsAndUserPicks' \
  "manual mode keeps capability discovery alongside user picks"
require_text "$COMPOSER_TESTS" 'manualMode_emptyManualNames_stillIncludesAlwaysLoaded' \
  "empty manual mode still keeps bootstrap tools"
require_text "$COMPOSER_TESTS" 'canonicalToolOrder_isStableAcrossInvocations' \
  "tool order is stable for tokenizer prompt caching"
require_text "$PREVIEW_TESTS" 'toolsOn_auto_includesCapabilityNudgeOnly' \
  "context preview exposes capability nudge when tools are on"
require_text "$PREVIEW_TESTS" 'realTaskAfterGreeting_restoresBootstrapTools' \
  "real task after greeting restores bootstrap discovery tools"
require_text "$PREVIEW_TESTS" 'toolsOn_dsv4Model_includesModelFamilyGuidance' \
  "DSV4 first-turn preview includes model-family tool-use guidance"

echo "--- capability search and load compatibility ---"
require_text "$CAPABILITY_TESTS" 'capabilitiesSearchSchemaIsGemmaRenderable' \
  "capabilities_discover schema is Gemma-renderable"
require_text "$CAPABILITY_TESTS" 'registryAcceptsLegacySingularQueryAlias' \
  "capabilities_discover accepts singular query alias"
require_text "$CAPABILITY_TESTS" 'registryAcceptsStringifiedQueriesFromSmallModels' \
  "capabilities_discover accepts stringified query arrays"
require_text "$CAPABILITY_TESTS" 'searchFiltersDynamicToolsOutsideAgentGrant' \
  "capabilities_discover enforces agent grants for dynamic tools"
require_text "$CAPABILITY_TESTS" 'toolLoadBuffersSpec' \
  "capabilities_load buffers loaded tool specs"
require_text "$SEARCH_TESTS" 'capabilitySearchAcceptsGrantedBM25OnlyToolWhenEmbeddingIndexUnavailable' \
  "capability search exposes BM25-only tools when embeddings are unavailable"
require_text "$SEARCH_TESTS" 'hybridSearchFallsBackToRegistryWhenToolDatabaseIsClosed' \
  "capability search falls back to live registry when encrypted storage is closed"
require_text "$TOOL_INDEX" 'ToolRegistry\.capabilityToolNames' \
  "capability infrastructure tools are excluded from searchable target catalog"
require_text "$TOOL_INDEX" 'runtimeManagedToolNames' \
  "runtime-managed tools are excluded from searchable target catalog"
require_text "$TOOL_SEARCH" 'searchRegistryFallbackWithDiagnostic' \
  "registry fallback path exists for keychain-free capability discovery"
require_text "$TOOL_SEARCH" 'registryLexicalScore' \
  "registry fallback uses lexical scoring when database/index is unavailable"

echo "--- model-family tool guidance ---"
require_text "$GUIDANCE" 'case googleGemma' "Gemma/Gemini guidance family exists"
require_text "$GUIDANCE" 'case glmQwen' "GLM/Qwen guidance family exists"
require_text "$GUIDANCE" 'case deepSeek' "DeepSeek/DSV4 guidance family exists"
require_text "$GUIDANCE" 'Only call tools that exist in your schema' \
  "Gemma guidance forbids hallucinated tool names"
require_text "$GUIDANCE" 'Only call tools that exist in your schema' \
  "DeepSeek guidance keeps DSML tool use schema-bound"
require_text "$GUIDANCE" 'capabilities_discover' \
  "DeepSeek guidance points missing capabilities at discovery path"
require_text "$GUIDANCE" 'qwen' "Qwen markers are present"
require_text "$GUIDANCE" 'dsv4' "DSV4 markers are present"
require_text "$GUIDANCE" 'gemma' "Gemma markers are present"

echo "--- downloaded tokenizer family tool surface ---"
require_text "$TOKENIZER_TESTS" 'downloadedFamilyTokenizersRenderCapabilitiesDiscoverToolSurface' \
  "downloaded tokenizer matrix renders capabilities_discover"
require_text "$TOKENIZER_TESTS" 'Gemma 4 26B JANG_4M CRACK' "Gemma 4 26B primary row"
require_text "$TOKENIZER_TESTS" 'Gemma 4 26B finished 4bit' "Gemma 4 26B finished row"
require_text "$TOKENIZER_TESTS" 'Gemma 4 31B JANG_4M candidate' "Gemma 4 31B candidate row"
require_text "$TOKENIZER_TESTS" 'Gemma 4 31B finished 4bit candidate' "Gemma 4 31B finished candidate row"
require_text "$TOKENIZER_TESTS" 'Gemma 4 E2B finished 4bit' "Gemma 4 E2B row"
require_text "$TOKENIZER_TESTS" 'Gemma 4 E4B finished 4bit' "Gemma 4 E4B row"
require_text "$TOKENIZER_TESTS" 'Qwen3\.6 27B source' "Qwen3.6 27B source row"
require_text "$TOKENIZER_TESTS" 'Qwen3\.6 35B JANGTQ CRACK' "Qwen3.6 35B JANGTQ row"
require_text "$TOKENIZER_TESTS" 'Qwen3\.6 35B MXFP4 CRACK MTP' "Qwen3.6 35B MXFP4 MTP row"
require_text "$TOKENIZER_TESTS" 'MiniMax M2\.7 JANGTQ_K CRACK' "MiniMax JANGTQ_K row"
require_text "$TOKENIZER_TESTS" 'DeepSeek V4 Flash JANG' "DSV4 JANG row"
require_text "$TOKENIZER_TESTS" 'DeepSeek V4 Flash JANGTQ-K' "DSV4 JANGTQ-K row"
require_text "$TOKENIZER_TESTS" 'DeepSeek V4 Flash JANGTQ2' "DSV4 JANGTQ2 row"
require_text "$TOKENIZER_TESTS" 'upper filter' \
  "tokenizer matrix rejects Gemma upper-filter template regressions"
require_text "$TOKENIZER_TESTS" 'capabilities_discover' \
  "tokenizer matrix checks capabilities_discover renders in prompts"

active="$({ ps -axo pid,ppid,rss,etime,command || true; } | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' | rg -i 'codesign( |$)|notarytool|/usr/bin/security( |$)' | rg -v 'rg -i|assert-model-tool-capability-surfaces' || true)"
if [[ -n "$active" ]]; then
  fail_msg "active keychain/signing helper detected; source assertions above are still useful but do not promote live readiness"
  echo "$active" >&2
else
  pass "no active keychain/signing helper"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Model tool/capability surface guard failed." >&2
  exit 1
fi

echo "Model tool/capability surface guard passed."
