#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HANDLER="$ROOT/Packages/OsaurusCore/Networking/HTTPHandler.swift"
ADAPTER="$ROOT/Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift"
RUNTIME="$ROOT/Packages/OsaurusCore/Services/ModelRuntime.swift"
TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_file() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then pass "$label exists"; else fail_msg "missing $label: $file"; fi
}
require_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -q "$pattern" "$file"; then pass "$label"; else fail_msg "missing $label"; fi
}
reject_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -n "$pattern" "$file"; then fail_msg "forbidden $label"; else pass "no $label"; fi
}

require_file "$HANDLER" "HTTPHandler"
require_file "$ADAPTER" "MLXBatchAdapter"
require_file "$RUNTIME" "ModelRuntime"
require_file "$TESTS" "RuntimePolicySourceTests"

if [[ -f "$HANDLER" ]]; then
  require_text "$HANDLER" 'path == "/responses" \|\| path == "/v1/responses"' "Responses and v1 Responses routes"
  require_text "$HANDLER" 'private static func applyOpenResponsesContext' "Responses previous_response_id context rehydration"
  require_text "$HANDLER" 'openResponsesContextStore\.transcript' "Responses context store read"
  require_text "$HANDLER" 'private static func storeOpenResponsesContext' "Responses context store write helper"
  require_text "$HANDLER" 'Self\.storeOpenResponsesContext' "Responses stores assistant context after output/tool rows"
  require_text "$HANDLER" 'reasoning_content: message\.reasoning_content' "Responses preserves assistant reasoning_content in context"
  require_text "$HANDLER" 'handleOpenResponsesStreaming' "Responses streaming handler"
  require_text "$HANDLER" 'handleOpenResponsesNonStreaming' "Responses non-streaming handler"
  require_text "$HANDLER" 'StreamingReasoningHint\.decode' "Responses streaming reasoning sentinel decoding"
  require_text "$HANDLER" 'StreamingStatsHint\.decode' "Responses streaming stats sentinel decoding"
  require_text "$HANDLER" 'writeReasoningDelta' "Responses emits reasoning deltas"
  require_text "$HANDLER" 'setOutputTokens' "Responses emits token usage stats"
  require_text "$HANDLER" 'writeOpenResponsesFunctionCall' "Responses emits tool-call output items"
  require_text "$HANDLER" 'ModelRuntime\.computePrefixHash' "OpenAI-compatible responses expose prefix_hash"
  require_text "$HANDLER" '"paged_cache"' "cache-stats paged_cache telemetry"
  require_text "$HANDLER" '"block_disk_store"' "cache-stats disk L2 telemetry"
  require_text "$HANDLER" '"ssm_companion_cache"' "cache-stats SSM companion telemetry"
  require_text "$HANDLER" '"cache_topology"' "cache-stats topology telemetry"
  require_text "$HANDLER" '"hybrid_pool_layer_count"' "cache-stats hybrid-pool topology telemetry"
  require_text "$HANDLER" '"requires_disk_backed_restore"' "cache-stats disk-backed topology telemetry"
  require_text "$HANDLER" '"prefix_hits"' "cache-stats prefix hit telemetry"
  require_text "$HANDLER" '"disk_l2_hits"' "cache-stats disk L2 hit telemetry"
  reject_text "$HANDLER" 'aggregate\["prefix_hits", default: 0\] \+= diskStats\.hits|aggregate\["prefix_misses", default: 0\] \+= diskStats\.misses' "folding disk L2 into prefix counters"
fi

if [[ -f "$ADAPTER" ]]; then
  require_text "$ADAPTER" 'snapshotDiagnostics\(\)' "Batch diagnostics snapshot entrypoint"
  require_text "$ADAPTER" 'prefixHits \+= pagedStats\.cacheHits' "diagnostics prefix hits from paged cache"
  require_text "$ADAPTER" 'diskL2Hits \+= diskStats\.hits' "diagnostics disk L2 hits separate"
  require_text "$ADAPTER" 'ssmReDerives \+= stats\.ssmStats\.reDerives' "diagnostics SSM rederive telemetry"
  require_text "$ADAPTER" 'turboQuantCompressions' "diagnostics TurboQuant compression telemetry"
  reject_text "$ADAPTER" 'prefixHits \+= diskStats\.hits|prefixMisses \+= diskStats\.misses' "folding disk L2 into prefix diagnostics"
fi

if [[ -f "$RUNTIME" ]]; then
  require_text "$RUNTIME" 'cacheTopology: cacheTopology' "cache coordinator model key includes loaded topology"
  require_text "$RUNTIME" 'await holder\.container\.cacheTopologySnapshot\(\)' "loaded topology snapshot before cache setup"
  require_text "$RUNTIME" 'enableCachingAsync\(config: cacheConfig\)' "async vMLX cache install"
  require_text "$RUNTIME" 'cacheCoordinatorModelKey' "cache model-key fingerprint helper"
fi

if [[ -f "$TESTS" ]]; then
  require_text "$TESTS" 'cacheTelemetryDoesNotFoldDiskL2IntoPrefixCounters' "source test keeps prefix and L2 counters separate"
  require_text "$TESTS" 'Open Responses endpoint has v1 alias' "source test covers Responses endpoint"
  require_text "$TESTS" 'HTTP channel close cancels per-request streaming tasks' "source test covers streaming cancellation cleanup"
  require_text "$TESTS" 'nativeMTPDepthSummary' "source test covers diagnostics MTP surface"
  require_text "$TESTS" 'SSM hits / misses / re-derives' "source test covers SSM diagnostics surface"
fi

active="$({ ps -axo pid,ppid,rss,etime,command || true; } | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|swift-build --package-path Packages/OsaurusCore|swift-test --package-path Packages/OsaurusCore|/Users/eric/osaurus-staging/Packages/OsaurusCore/.build' | rg -v 'rg -i|assert-openresponses-cache-proof-wiring' || true)"
if [[ -n "$active" ]]; then
  fail_msg "active Osaurus build/keychain-sensitive process detected"
  echo "$active" >&2
else
  pass "no active Osaurus build/keychain-sensitive process"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "OpenResponses/cache proof wiring guard failed." >&2
  exit 1
fi

echo "OpenResponses/cache proof wiring guard passed."
