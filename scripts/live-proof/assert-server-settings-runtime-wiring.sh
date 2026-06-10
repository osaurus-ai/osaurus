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
  if rg -U -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "missing $label in ${file#$ROOT/}"
  fi
}

reject_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -n "$pattern" "$file"; then
    fail_msg "forbidden $label in ${file#$ROOT/}"
  else
    pass "no $label"
  fi
}

CACHE_UI="$ROOT/Packages/OsaurusCore/Views/Settings/ServerSettings/CacheSection.swift"
CONCURRENCY_UI="$ROOT/Packages/OsaurusCore/Views/Settings/ServerSettings/ConcurrencySection.swift"
MTP_UI="$ROOT/Packages/OsaurusCore/Views/Settings/ServerSettings/MTPSection.swift"
STORE="$ROOT/Packages/OsaurusCore/Models/Configuration/ServerRuntimeSettingsStore.swift"
RUNTIME="$ROOT/Packages/OsaurusCore/Services/ModelRuntime.swift"
CONTROLLER="$ROOT/Packages/OsaurusCore/Networking/ServerController.swift"
FLAGS="$ROOT/Packages/OsaurusCore/Services/ModelRuntime/InferenceFeatureFlags.swift"
ADAPTER="$ROOT/Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift"

for pair in \
  "$CACHE_UI:CacheSection" \
  "$CONCURRENCY_UI:ConcurrencySection" \
  "$MTP_UI:MTPSection" \
  "$STORE:ServerRuntimeSettingsStore" \
  "$RUNTIME:ModelRuntime" \
  "$CONTROLLER:ServerController" \
  "$FLAGS:InferenceFeatureFlags" \
  "$ADAPTER:MLXBatchAdapter"; do
  require_file "${pair%%:*}" "${pair#*:}"
done

echo "--- server settings UI controls ---"
require_text "$CONCURRENCY_UI" 'isOn: \$draft\.concurrency\.continuousBatching' \
  "UI exposes continuous batching toggle"
require_text "$CONCURRENCY_UI" 'draft\.concurrency\.maxConcurrentSequences = clamped' \
  "UI writes max concurrent sequence setting"
require_text "$CONCURRENCY_UI" 'pins the BatchEngine to one active slot' \
  "UI explains continuous batching off means single-slot runtime"

require_text "$CACHE_UI" 'isOn: \$draft\.cache\.prefix\.enabled' \
  "UI exposes prefix cache toggle"
require_text "$CACHE_UI" 'isOn: \$draft\.cache\.pagedKV\.enabled' \
  "UI exposes paged KV toggle"
require_text "$CACHE_UI" 'isOn: \$draft\.cache\.blockDisk\.enabled' \
  "UI exposes block L2 disk cache toggle"
require_text "$CACHE_UI" 'value: \$draft\.cache\.blockDisk\.directory' \
  "UI exposes block L2 disk directory"
require_text "$CACHE_UI" 'selection: \$draft\.cache\.liveKVCodec' \
  "UI exposes live KV codec selector"
require_text "$CACHE_UI" 'value: \$draft\.cache\.turboQuantKeyBits' \
  "UI exposes TurboQuant key bits"
require_text "$CACHE_UI" 'value: \$draft\.cache\.turboQuantValueBits' \
  "UI exposes TurboQuant value bits"
require_text "$CACHE_UI" 'value: \$draft\.cache\.defaultMaxKVSize' \
  "UI exposes per-session KV window cap"
require_text "$CACHE_UI" 'value: longPromptBinding' \
  "UI exposes long-prompt multiplier"
require_text "$CACHE_UI" 'isOn: \$draft\.cache\.enableSSMReDerive' \
  "UI exposes SSM rederive toggle"
require_text "$CACHE_UI" 'On by default so SSM companion state can be restored' \
  "UI describes SSM rederive default accurately"
reject_text "$CACHE_UI" 'Off by default' \
  "stale SSM off-by-default copy"

require_text "$MTP_UI" 'selection: \$draft\.mtp\.mode' \
  "UI exposes MTP mode"
require_text "$MTP_UI" 'Auto uses it only when the model ships a verified native MTP head' \
  "UI describes MTP auto-detect contract"
require_text "$MTP_UI" 'value: \$draft\.mtp\.draftTokenLimit' \
  "UI exposes MTP draft token limit"

echo "--- persisted automatic defaults ---"
require_text "$STORE" 'continuousBatching: true' \
  "migration defaults continuous batching on"
require_text "$STORE" 'liveKVCodec: \.engineSelected' \
  "migration defaults KV codec to engine-selected"
reject_text "$STORE" 'normalized\.cache\.liveKVCodec = \.engineSelected' \
  "legacy migration overwrites explicit existing live-KV choices"
require_text "$STORE" 'blockDisk: VMLXBlockDiskCacheSettings' \
  "migration creates block-disk cache settings"
require_text "$STORE" 'enabled: true,\n                maxSizeGB: nil,\n                directory: nil' \
  "migration defaults block-disk L2 on"
require_text "$STORE" 'enableSSMReDerive: true' \
  "migration defaults SSM rederive on"
require_text "$STORE" 'normalized\.mtp\.mode = \.auto' \
  "persisted old MTP-off defaults repair to auto"
require_text "$STORE" 'updated\.genTopP =\n            settings\.generation\.topP\.map\(Float\.init\)\n            \?\? ServerConfiguration\.default\.genTopP' \
  "blank runtime top-p clears stale legacy top-p"

echo "--- runtime consumption ---"
require_text "$CONTROLLER" 'runtimeConfigInputsRequireInvalidate' \
  "runtime settings save invalidates cached RuntimeConfig"
require_text "$CONTROLLER" 'previous\.generation != next\.generation\n            \|\| previous\.concurrency != next\.concurrency' \
  "generation and concurrency changes invalidate cached RuntimeConfig"
require_text "$FLAGS" 'guard runtime\.concurrency\.continuousBatching else \{ return 1 \}' \
  "runtime gates batch slots on continuous batching"
require_text "$FLAGS" 'runtime\.concurrency\.maxConcurrentSequences' \
  "runtime consumes max concurrent sequence setting"
require_text "$RUNTIME" 'settings\.cacheCoordinatorConfig' \
  "runtime delegates cache settings into vMLX cache coordinator"
require_text "$RUNTIME" 'shouldUseTurboQuantByDefault' \
  "runtime gates engine-selected TurboQuant by model family/topology"
require_text "$RUNTIME" 'config\.defaultKVMode = effectiveDefaultKVMode' \
  "runtime applies effective topology-gated KV mode"
require_text "$RUNTIME" 'cacheDiskDirectoryOverride' \
  "runtime resolves server settings disk cache directory"
require_text "$RUNTIME" 'cache\.blockDisk\.enabled' \
  "runtime consumes block L2 disk toggle"
require_text "$RUNTIME" 'cache\.blockDisk\.directory' \
  "runtime consumes block L2 disk directory"
require_text "$RUNTIME" 'cacheKVModeTag' \
  "runtime includes KV mode in L2 model key"
require_text "$RUNTIME" 'cacheTopology: cacheTopology' \
  "runtime includes architecture topology in cache key"
require_text "$RUNTIME" 'settings\.resolvedMTPLaunch' \
  "runtime consumes MTP launch auto-detection"
require_text "$RUNTIME" 'settings\.resolvedLoadConfiguration' \
  "runtime consumes MTP load configuration"
require_text "$RUNTIME" 'settings\.resolvedMTPDraftStrategy' \
  "runtime consumes MTP draft strategy"
require_text "$ADAPTER" 'turboQuantCompressions' \
  "runtime diagnostics report TurboQuant compression count"
require_text "$ADAPTER" 'nativeMTPDepthSummary' \
  "runtime diagnostics report native MTP depth"

active_forbidden="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-server-settings-runtime-wiring' || true)"
if [[ -n "$active_forbidden" ]]; then
  echo "$active_forbidden" >&2
  fail_msg "active Osaurus keychain-sensitive validation process detected"
else
  pass "no active Osaurus keychain-sensitive validation process"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Server settings runtime wiring guard failed." >&2
  exit 1
fi

echo "Server settings runtime wiring guard passed."
