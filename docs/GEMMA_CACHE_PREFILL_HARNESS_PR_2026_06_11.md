# Gemma Cache Defaults, Prefill Progress, and Harness PR

This is the active Osaurus integration checklist for the paired vMLX work.

## Scope

- Default paged RAM KV cache is off. Prefix reuse must still use disk/L2 cache
  by default so single-batch users do not pay for an extra RAM tier.
- Eligible Gemma 4 QAT MXFP4 and JANG_4M models use TurboQuant KV by default
  from Chat UI and server settings. Architecture-specific exceptions must be
  recorded as runtime topology, not hidden behind UI copy.
- vMLX emits `Generation.prefillProgress`; Osaurus maps it to
  `ModelRuntimeEvent.prefillProgress`, `\u{FFFE}prefill:` stream hints, and
  `InferenceProgressManager` so Chat UI shows prefill percentage/stage before
  first token.
- Gemma 4 QAT MXFP4 and JANG_4M rows must run through the harness contract in
  `docs/HARNESS_COMPATIBILITY.md`, with scores recorded and score blockers
  fixed, before this is called merge-ready.
- Do not load, benchmark, or count non-QAT/source-looking Gemma bundles for this
  checkpoint. The active scope is only the OsaurusAI Gemma 4 QAT MXFP4 and
  JANG_4M repos listed below.
- Regression note: errors such as
  `Unhandled keys ["down_proj", "gate_up_proj"] ... TextExperts` from
  source/unquantized Gemma expert weights are not part of this checkpoint. They
  should stay documented as out-of-scope source-bundle failures, not chased as
  blockers for the QAT MXFP4/JANG_4M rows.

## Local Model Inventory

Downloaded under `~/models`:

- `OsaurusAI--gemma-4-E2B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-E4B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-12B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-26B-A4B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-31B-it-qat-MXFP4`
- `OsaurusAI--gemma-4-E2B-it-qat-JANG_4M`
- `OsaurusAI--gemma-4-E4B-it-qat-JANG_4M`
- `OsaurusAI--gemma-4-12B-it-qat-JANG_4M`
- `OsaurusAI--gemma-4-26B-A4B-it-qat-JANG_4M`
- `OsaurusAI--gemma-4-31B-it-qat-JANG_4M`

Download log directory:
`/Users/eric/models/.download-logs/gemma4-qat-screen-20260611T222059Z`.

Other local Gemma directories can exist under `/Users/eric/models`, including
Google/source-looking test folders. They are explicitly out of scope here and
must not be used for load, tool, cache, or harness proof in this checkpoint.

## Checkpoint Proof Matrix

This is the active tracking matrix for the team-testable checkpoint. Do not
mark a row `PROVEN` unless the artifact paths exist and the row proves the
production Osaurus path, not just source inspection.

Required proof columns:

- `Inventory`: local bundle exists under `/Users/eric/models`, has config,
  tokenizer, processor when multimodal, and all expected safetensor shards.
- `Load/Chat`: unsigned/dev Osaurus app or server loads the model and returns
  coherent visible text with no loops, hidden-only output, raw parser markers,
  or forced-template behavior.
- `Prefix/L2`: two long-prefix prompts prove SSD/L2 prefix cache behavior with
  `cache.pagedKV.enabled=false`, `block_disk_store.enabled=true`,
  `disk_l2_hits > 0`, `disk_l2_stores > 0`, and `paged_hits=0`.
- `TQ/SWA`: cache stats prove `effective_kv_mode="turbo(...)"`,
  TurboQuant compression count when the row generates, and Gemma SWA/rotating
  layers stay disk-backed with `requires_disk_backed_restore=true`.
- `Speed`: every generation row records token/s and, where the API exposes it,
  TTFT or enough timestamp evidence to calculate TTFT. Missing token/s means
  the row is incomplete.
- `Tools`: direct OpenAI-compatible tool-call row proves exact tool name,
  exact JSON arguments, and a tool-result continuation with visible answer.
- `Agent`: Osaurus agent/tool loop route runs without Gemma chat-template
  failures and records tool/result behavior where the branch supports it.
- `VL`: real image payload through Osaurus works for rows whose config has
  `vision_config`.
- `Audio`: real audio payload through Osaurus works for rows whose config has
  `audio_config`.
- `Prefill UI/API`: slow/long prompt emits `osaurus_prefill` chunks and the
  Chat UI surfaces percent/stage before first token.
- `Memory`: RSS and, for final checkpoint, Activity Monitor physical footprint
  are recorded during load and generation on the dev app path.

Current model capability metadata from local `config.json`:

| Model | Format | Config family | Vision | Audio | Inventory | Load/Chat | Prefix/L2 | TQ/SWA | Speed | Tools | Agent | VL | Audio | Prefill UI/API | Memory |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `osaurusai--gemma-4-e2b-it-qat-mxfp4` | MXFP4 | `gemma4` | yes | yes | PROVEN | PROVEN | PROVEN | PROVEN | PARTIAL | PROVEN | PROVEN complete / PARTIAL side-effect | TODO | TODO | PARTIAL | PARTIAL |
| `osaurusai--gemma-4-e2b-it-qat-jang_4m` | JANG_4M | `gemma4` | yes | yes | PROVEN | PROVEN | PROVEN | PROVEN | PARTIAL | PROVEN | PROVEN complete / PARTIAL side-effect | PROVEN API | BLOCKED policy | PROVEN API / TODO UI | PARTIAL |
| `osaurusai--gemma-4-e4b-it-qat-mxfp4` | MXFP4 | `gemma4` | yes | yes | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | TODO | TODO | PARTIAL |
| `osaurusai--gemma-4-e4b-it-qat-jang_4m` | JANG_4M | `gemma4` | yes | yes | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | TODO | TODO | PARTIAL |
| `osaurusai--gemma-4-12b-it-qat-mxfp4` | MXFP4 | `gemma4_unified` | yes | yes | PROVEN | PROVEN UI+agent | PROVEN UI+agent | PROVEN UI+agent | PROVEN UI+agent | TODO | PARTIAL UI status count | TODO | TODO | PROVEN API / PARTIAL UI percent | PARTIAL |
| `osaurusai--gemma-4-12b-it-qat-jang_4m` | JANG_4M | `gemma4_unified` | yes | yes | PROVEN | PARTIAL UI / PROVEN API | PROVEN UI+agent | PROVEN UI+agent | PROVEN UI+agent | TODO | PARTIAL UI status tool | TODO | TODO | PARTIAL UI / PROVEN API | PARTIAL |
| `osaurusai--gemma-4-26b-a4b-it-qat-mxfp4` | MXFP4 | `gemma4` | yes | no | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | N/A | TODO | PARTIAL |
| `osaurusai--gemma-4-26b-a4b-it-qat-jang_4m` | JANG_4M | `gemma4` | yes | no | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | N/A | TODO | PARTIAL |
| `osaurusai--gemma-4-31b-it-qat-mxfp4` | MXFP4 | `gemma4` | yes | no | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | N/A | TODO | PARTIAL |
| `osaurusai--gemma-4-31b-it-qat-jang_4m` | JANG_4M | `gemma4` | yes | no | PROVEN | PROVEN agent | PROVEN agent | PROVEN agent | PARTIAL | TODO | PROVEN forced complete | TODO | N/A | TODO | PARTIAL |

Current evidence behind non-TODO cells:

- Current PR head release-app proof on commit
  `8a0cf96576940858c2f0dcda591d55e18a15ba2c`:
  `/tmp/osaurus-gemma-proof/xcode-build-release-app-agentloop-8a0cf965.status`
  records `status=0` and the built app at
  `build/XcodeDerivedData-gemma-ui-agentloop-8a0cf965-release/Build/Products/Release/osaurus.app`.
  The app was launched keychain-free with `OSU_MODELS_DIR=/Users/eric/models`
  and is healthy on `127.0.0.1:1337`; current model inventory artifact
  `/tmp/osaurus-gemma-proof/models-agentloop-current.json` lists all ten
  OsaurusAI Gemma 4 QAT MXFP4/JANG_4M model ids. PR #1469 is open,
  mergeable, and CI checks `test-core`, `test-cli`, `swiftlint`,
  `shellcheck`, and `update_release_draft` are green as of the 2026-06-12
  refresh; `test-core` was still running during the same poll and must be
  rechecked before merge.
- Current-head runtime defaults:
  `/tmp/osaurus-gemma-proof/runtime-settings-agentloop-current.json` reports
  `pagedKV.enabled=false`, `blockDisk.enabled=true`,
  `legacyDisk.enabled=false`, `prefix.enabled=true`,
  `liveKVCodec="engine_selected"`, `storedKVCodec="auto"`,
  `maxConcurrentSequences=1`, `enableAudio=true`, `enableVideo=true`, and
  `requireMediaSaltForCache=true`. Pre-run cache artifact
  `/tmp/osaurus-gemma-proof/cache-before-agentloop-current.json` had all cache
  counters at zero with paged KV disabled.
- Current-head E2B JANG_4M default-agent tool execution:
  `/tmp/osaurus-gemma-proof/agent-required-complete-e2b-jang4m-current.sse`
  and repeat
  `/tmp/osaurus-gemma-proof/agent-required-complete-e2b-jang4m-current-repeat.sse`
  call `/agents/default/run` with no client-supplied `tools` array and
  `tool_choice="required"`. Both streams contain sanitized
  `osaurus_agent_tool` chunks for `complete`, phases `started` and
  `completed`, `is_error=false`, `end_run=true`, `HTTP_STATUS:200`, and final
  visible text `live Osaurus agent loop executed complete tool with Gemma E2B
  JANG_4M QAT and no parser leak`. Leak scan found no U+FFFE, `<tool`,
  `<think`, `<|...`, or raw `tool:/args:/done:` marker leakage beyond the
  expected sanitized trace keys. Wall time improved from `real 4.27` to
  `real 2.27` on repeat.
- Current-head E2B JANG_4M cache/prefill/token proof:
  `/tmp/osaurus-gemma-proof/cache-after-agent-required-complete-e2b-jang4m-current-repeat.json`
  reports `disk_l2_hits=1`, `disk_l2_stores=1`, `paged_hits=0`,
  `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=3`, `rotating_kv_layer_count=12`,
  `requires_disk_backed_restore=true`, and
  `turbo_quant_kv_layer_count=0`. Chat artifacts
  `/tmp/osaurus-gemma-proof/chat-prefill-e2b-jang4m-current.sse` and repeat
  `/tmp/osaurus-gemma-proof/chat-prefill-e2b-jang4m-current-repeat.sse`
  emit `osaurus_prefill` queued/running/complete chunks. The repeat row shows
  prefill progress `35/36` then `36/36`, `tokens_per_second=108.8331`, and
  `HTTP_STATUS:200` with clean visible text.
- Current-head E4B JANG_4M default-agent tool execution and cache/prefill:
  `/tmp/osaurus-gemma-proof/agent-required-complete-e4b-jang4m-current.sse`
  and repeat
  `/tmp/osaurus-gemma-proof/agent-required-complete-e4b-jang4m-current-repeat.sse`
  contain `complete` tool trace chunks with `is_error=false`, `end_run=true`,
  `finish_reason="stop"`, and no marker leakage. Chat artifacts
  `/tmp/osaurus-gemma-proof/chat-prefill-e4b-jang4m-current.sse` and repeat
  `/tmp/osaurus-gemma-proof/chat-prefill-e4b-jang4m-current-repeat.sse`
  emit queued/running/complete prefill chunks; the repeat row shows `35/36`
  then `36/36` and `tokens_per_second=36.5466`. Cache artifact
  `/tmp/osaurus-gemma-proof/cache-after-chat-prefill-e4b-jang4m-current-repeat.json`
  reports `disk_l2_hits=2`, `disk_l2_stores=6`, `paged_hits=0`,
  `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=4`, `rotating_kv_layer_count=20`, and
  `requires_disk_backed_restore=true`.
- Current-head E4B MXFP4 default-agent tool execution and cache/prefill:
  `/tmp/osaurus-gemma-proof/agent-required-complete-e4b-mxfp4-current.sse`
  and repeat
  `/tmp/osaurus-gemma-proof/agent-required-complete-e4b-mxfp4-current-repeat.sse`
  contain `complete` tool trace chunks with `is_error=false`, `end_run=true`,
  `finish_reason="stop"`, and no marker leakage. Chat artifacts
  `/tmp/osaurus-gemma-proof/chat-prefill-e4b-mxfp4-current.sse` and repeat
  `/tmp/osaurus-gemma-proof/chat-prefill-e4b-mxfp4-current-repeat.sse`
  emit queued/running/complete prefill chunks; the repeat row shows `33/34`
  then `34/34` and `tokens_per_second=43.0392`. Cache artifact
  `/tmp/osaurus-gemma-proof/cache-after-chat-prefill-e4b-mxfp4-current-repeat.json`
  reports `disk_l2_hits=2`, `disk_l2_stores=6`, `paged_hits=0`,
  `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=4`, `rotating_kv_layer_count=20`, and
  `requires_disk_backed_restore=true`.
- Current-head full QAT matrix extension on PR head `efd741f7` using the
  same live keychain-free release app:
  artifact root
  `/tmp/osaurus-gemma-proof/current-head-matrix-efd741f7-20260611T235458Z`
  contains first/repeat `/agents/default/run` rows, first/repeat
  `/v1/chat/completions` prefill rows, cache snapshots, health snapshots, and
  leak scans for the remaining QAT Gemma rows. Normalized summary artifact
  `summary.normalized.tsv` reports every listed row with
  `agent_first_status=200`, `agent_repeat_status=200`,
  `agent_trace=2`, `chat_first_status=200`, `chat_repeat_status=200`,
  `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `restore=true`, and `leak_bad=0` after excluding the expected sanitized
  `is_error=false` trace field:
  - `osaurusai--gemma-4-e2b-it-qat-mxfp4`: prefill `46/46`,
    `tokens_per_second=50.7938`, `disk_l2_hits=2`, `disk_l2_stores=6`,
    topology `3 KV / 12 rotating`.
  - `osaurusai--gemma-4-12b-it-qat-jang_4m`: prefill `46/46`,
    `tokens_per_second=18.7299`, `disk_l2_hits=2`, `disk_l2_stores=6`,
    topology `8 KV / 40 rotating`.
  - `osaurusai--gemma-4-12b-it-qat-mxfp4`: prefill `46/46`,
    `tokens_per_second=19.8534`, `disk_l2_hits=2`, `disk_l2_stores=6`,
    topology `8 KV / 40 rotating`.
  - `osaurusai--gemma-4-26b-a4b-it-qat-jang_4m`: prefill `50/50`,
    `tokens_per_second=12.5938`, `disk_l2_hits=2`, `disk_l2_stores=6`,
    topology `5 KV / 25 rotating`.
  - `osaurusai--gemma-4-26b-a4b-it-qat-mxfp4`: prefill `50/50`,
    `tokens_per_second=36.2375`, `disk_l2_hits=2`, `disk_l2_stores=6`,
    topology `5 KV / 25 rotating`.
  - `osaurusai--gemma-4-31b-it-qat-jang_4m`: prefill `46/46`,
    `tokens_per_second=14.9967`, `disk_l2_hits=2`, `disk_l2_stores=6`,
    topology `10 KV / 50 rotating`.
  - `osaurusai--gemma-4-31b-it-qat-mxfp4`: prefill `46/46`,
    `tokens_per_second=11.2934`, `disk_l2_hits=2`, `disk_l2_stores=6`,
    topology `10 KV / 50 rotating`.
  Combined with the already documented current-head E2B JANG_4M, E4B
  JANG_4M, and E4B MXFP4 rows above, this closes the current-head API/default
  agent-loop tool + prefill/cache matrix for all ten OsaurusAI Gemma 4 QAT
  MXFP4/JANG_4M models. This is still not harness scoring.
- Current-head VL re-proof:
  `/tmp/osaurus-gemma-proof/current-head-matrix-efd741f7-20260611T235458Z/vl-e2b-jang4m-red32-current.request.json`
  uses a deterministic 32x32 red PNG data URL against
  `osaurusai--gemma-4-e2b-it-qat-jang_4m`. First and repeat streams
  `vl-e2b-jang4m-red32-current.first.sse` and
  `vl-e2b-jang4m-red32-current.repeat.sse` both return visible answer `Red`,
  `HTTP_STATUS:200`, `finish_reason="stop"`, `osaurus_prefill` queued,
  running, and complete chunks at `307/307`, and token/s `28.4698` then
  `32.9218`. Cache artifact
  `vl-e2b-jang4m-red32-current.cache.after.final.json` reports
  `disk_l2_hits=2`, `disk_l2_stores=8`, `paged_hits=0`, `paged_misses=0`,
  `effective_kv_mode="turbo(3,3)"`, `kv_layer_count=3`,
  `rotating_kv_layer_count=12`, `requires_disk_backed_restore=true`, and
  `batch_diagnostics.turbo_quant_compressions=4`. Leak scan
  `vl-e2b-jang4m-red32-current.leak-scan.txt` is empty. The earlier 1x1 PNG
  attempt in `vl-e2b-jang4m-red-current.*` exercised media/cache but answered
  `Black`, so it is not counted as visual correctness proof.
- Current-head Chat UI tool proof on the PR Release app:
  artifact root `/tmp/osaurus-gemma-proof/ui-pr1469-20260612-001552` was
  produced from the PR-built app
  `build/XcodeDerivedData-gemma-ui-agentloop-8a0cf965-release/Build/Products/Release/osaurus.app`
  launched through LaunchServices with keychain disabled,
  `OSU_MODELS_DIR=/Users/eric/models`, and `OSU_PORT=1337`.
  Computer Use verified the visible model selector was switched away from the
  out-of-scope Google/source-looking folders to
  `OsaurusAI Gemma 4 12B it qat JANG_4M`.
  The first UI turn asked the model to use `osaurus_status`; the chat displayed
  an `Osaurus status` tool card, a final answer, and UI metrics
  `TTFT 5.47s`, `18.4 tok/s`, `51 tokens`. Final health
  `health.ui-turn1.final.json` reports current model
  `osaurusai--gemma-4-12b-it-qat-jang_4m`. Final cache
  `cache.ui-turn1.final.json` reports `paged_kv_enabled=false`,
  `block_disk_enabled=true`, `disk_l2_stores=2`,
  `effective_kv_mode="turbo(3,3)"`, `kv_layer_count=8`,
  `rotating_kv_layer_count=40`,
  `requires_disk_backed_restore=true`, and
  `batch_diagnostics.turbo_quant_compressions=2`.
  The second UI turn repeated `osaurus_status` after tool-result history; the
  UI displayed a second `Osaurus status` tool card, final answer, and
  `TTFT 4.15s`, `18.0 tok/s`, `40 tokens`. Cache before/after artifacts
  `cache.ui-turn2.before.json` and `cache.ui-turn2.final.json` show
  `disk_l2_hits` increased `0 -> 1`, `disk_l2_stores` increased `2 -> 4`,
  `turbo_quant_compressions` increased `2 -> 4`, and paged hits/misses stayed
  `0`. Screenshot proof is
  `ui-two-turn-tool-proof.png`. This is a regression row, not a pass: the UI
  answers have ordinary text corruption (`seleed`, `mdel`, `protctoocol`,
  `leaketod`, `curren ml IDis`, `28a`). That means the 12B JANG_4M Chat UI
  tool row is `PARTIAL` even though the tool card rendered and cache telemetry
  improved. Do not promote any Gemma QAT tool/chat proof while visible text has
  corrupted words, wrong copied numbers, mojibake, replacement/control
  characters, protocol marker residue, or spelling/character drift. The next
  trace must compare raw API events, agent-loop tool-result history,
  tokenizer/detokenizer output, cache restore state, sampling settings, and UI
  rendering before claiming this fixed.
- Current-head root cause and source fix for the UI status-tool corruption:
  strict `/v1/chat/completions` copy prompts were clean, direct
  `/agents/default/run` with `tool_choice:"none"` was clean, and manual
  structured tool-result history was clean until tool schemas were still
  advertised with `tool_choice:"auto"` on the post-tool final-answer step.
  The failing trigger was therefore narrowed to Gemma 4 QAT JANG/MXFP
  post-tool finalization with auto tools still enabled, not SwiftUI rendering
  and not a generic tokenizer/detokenizer failure. The PR now scopes
  `/agents/{id}/run` so Gemma 4 QAT JANG_4M/MXFP4 keeps auto tools for the
  first tool-call iteration, preserves required/named tool choice as
  fail-closed, but sends `tool_choice:"none"` for the model step immediately
  after a `role:"tool"` message. Regression proof:
  `/tmp/osaurus-gemma-proof/weird-text-root-20260612T073342Z/swift-test-agentrun-gemma-qat-toolchoice.log`
  passed `HTTPHandlerChatStreamingTests.agentRun_gemmaQATPostToolFinalizationDisablesAutoToolChoice`,
  proving the real HTTP agent loop now sends first-iteration auto and
  post-tool `none` for
  `osaurusai--gemma-4-12b-it-qat-jang_4m`. Source guard proof:
  `/tmp/osaurus-gemma-proof/weird-text-root-20260612T073342Z/swift-test-gemma-toolchoice.log`
  passed `RuntimePolicySourceTests.gemmaQATAgentFinalAnswerDisablesAutoToolsAfterToolResults`.
  Build proof:
  `/tmp/osaurus-gemma-proof/weird-text-root-20260612T073342Z/swift-build-osauruscore-after-toolchoice.log`
  passed `swift build --target OsaurusCore`.
- Final patched Release-app proof for the Gemma QAT post-tool fix and source
  model default-selection fix:
  `/tmp/osaurus-gemma-proof/weird-text-root-20260612T073342Z/xcodebuild-release-app-livepatched-ui.log`
  reports `** BUILD SUCCEEDED **` for the keychain-free, unsigned Release app
  at
  `build/XcodeDerivedData-gemma-livepatched-ui-20260612010944/Build/Products/Release/osaurus.app`.
  Computer Use inspected that exact app and the model picker default was
  `OsaurusAI Gemma 4 12B it qat MXFP4`, not the out-of-scope
  `google...unquantized` source row. The source fix is intentionally scoped to
  automatic Chat fallback selection: keep source rows visible in the picker,
  but rank local OsaurusAI Gemma 4 QAT JANG_4M/MXFP4 rows ahead of
  source-looking Gemma folders when no explicit model is selected. Regression
  proof:
  `/tmp/osaurus-gemma-proof/weird-text-root-20260612T073342Z/swift-test-modelpicker-gemma-default.log`
  passed
  `ModelPickerItemChatCapabilityTests.firstChatCapable_prefersOsaurusGemmaQATOverSourceGemma`.
- Final patched Release-app MXFP4 and JANG_4M tool/cache proof:
  artifact root `/tmp/osaurus-gemma-proof/final-ui-20260612T0816Z` was
  produced from the same app binary, launched with
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
  `OSAURUS_KEYCHAIN_FREE_SHOW_UI=1`,
  `OSU_MODELS_DIR=/Users/eric/models`, and isolated root
  `/tmp/osaurus-keychain-free-livepatched-ui-20260612T0118`. The first
  health snapshot reports `local_model_scan.model_count=27` from
  `/Users/eric/models`.
  `agent-run-mxfp12-status-fields-repeat.sse` and
  `agent-run-jang12-status-fields-repeat.sse` both execute
  `osaurus_status`, return visible final text
  `Status reports 28 installed model(s), 0 provider(s), and 0 plugin(s).`,
  and have zero non-ASCII/control-character leak lines in the paired
  `*.non-ascii-control.txt` artifacts. The first MXFP4 status row returned
  `1 installed model(s)` because the app's `ModelManager.availableModels`
  snapshot had not yet caught up to the local scan; the repeat row is the
  counted proof row.
- Final patched Release-app cache/RAM proof:
  `cache-after-mxfp-agent-repeat.json` reports
  `models[0].name=osaurusai--gemma-4-12b-it-qat-mxfp4`,
  `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
  `block_disk_store.enabled=true`, `disk_l2_hits=1`,
  `disk_l2_stores=4`, `kv_layer_count=8`, `rotating_kv_layer_count=40`,
  and `requires_disk_backed_restore=true`.
  `cache-after-jang-agent-repeat.json` reports the same topology for
  `osaurusai--gemma-4-12b-it-qat-jang_4m` with `disk_l2_hits=2`,
  `disk_l2_stores=4`, and paged hits/misses still zero. Both rows still
  report `turbo_quant_kv_layer_count=0`, so do not claim TurboQuant KV layer
  count proof for rotating Gemma; the honest runtime claim is
  `effective_kv_mode="turbo(3,3)"` with rotating KV plus disk-backed restore.
  `cache-files.txt` records seven `.safetensors` L2 files plus
  `cache_index.db` under the fresh `cache/kv_v2` root, totaling about
  2.37 GB. `process-footprint-final-app-only.txt` records the final app
  process at 7,611,520 KB RSS after the JANG row, and `health-final.json`
  reports current model `osaurusai--gemma-4-12b-it-qat-jang_4m` with RAM
  feasibility `verdict="ok"`.
- Final patched Release-app prefill proof:
  `direct-chat-mxfp12.sse` emits `osaurus_prefill` queued, prefill, and
  complete chunks from `0/49` through `49/49`, then clean visible text
  `The selected model id is osaurusai--gemma-4-12b-it-qat-mxfp4.` with zero
  non-ASCII/control-character leak lines. This proves the direct chat API
  prefill signal on the final patched app. It does not close the product gap
  that `/agents/default/run` still lacks equivalent usage/prefill telemetry in
  its final stream.
- Post-tool UI corruption follow-up on PR commit `2966ea35` found the first
  fix was incomplete: `/agents/default/run` was clean, but the Chat UI path
  still sent Gemma 4 QAT post-tool finalization through local chat wiring with
  auto tools enabled. The failing screenshot is
  `/tmp/osaurus-gemma-proof/pr1469-current-2966ea35-20260612T0830Z/ui/ui-mxfp4-tool-malformed-20260612T083451Z.png`;
  visible text contained corrupted words such as `satus`, `mels`,
  `roviders`, and `todpinstalled`. The actual fix is now shared in
  `ChatToolChoicePolicy.finalizingPostToolChoice(model:messages:requested:)`,
  used by both `ChatView` and `HTTPHandler`, and preserves explicit
  `.required` or named tool choices while changing Gemma 4 QAT
  `auto`/nil post-tool final-answer turns to `.none`.
- Shared-policy source proof:
  `/tmp/osaurus-gemma-proof/pr1469-current-2966ea35-20260612T0830Z/swift-test-posttool-shared-policy.log`
  passed 14 focused tests under Xcode Swift:
  `ChatToolChoicePolicyTests`,
  `HTTPHandlerChatStreamingTests.agentRun_gemmaQATPostToolFinalizationDisablesAutoToolChoice`,
  and
  `RuntimePolicySourceTests.gemmaQATAgentFinalAnswerDisablesAutoToolsAfterToolResults`.
  The plain `/usr/bin/swift test` path failed earlier with the local toolchain
  issue `no such module 'Testing'`; the passing proof uses
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`.
- Shared-policy Release-app proof:
  `/tmp/osaurus-gemma-proof/pr1469-current-2966ea35-20260612T0830Z/xcodebuild-release-ui-policy-20260612T084231Z.log`
  reports `** BUILD SUCCEEDED **` for the unsigned Release app at
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-ui-policy-20260612T084231Z/Build/Products/Release/osaurus.app`.
  The direct executable launch exited before opening the server, so the proof
  uses LaunchServices with temporary `launchctl setenv` values:
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
  `OSAURUS_KEYCHAIN_FREE_SHOW_UI=1`,
  `OSU_MODELS_DIR=/Users/eric/models`, and `OSU_PORT=1337`. Health artifact
  `/tmp/osaurus-gemma-proof/pr1469-current-2966ea35-20260612T0830Z/ui/ui-policy-open-health.json`
  reports `status="healthy"` and `local_model_scan.model_count=27`.
- Shared-policy Chat UI tool proof for
  `osaurusai--gemma-4-12b-it-qat-mxfp4`: Computer Use verified the default
  picker as `OsaurusAI Gemma 4 12B it qat MXFP4`. Two UI turns invoked
  `osaurus_status`, displayed tool cards, and produced clean final sentences
  with no weird/control characters, no parser/tool/reasoning marker leakage,
  and no loop. The first turn reported `TTFT 3.96s`, `22.7 tok/s`,
  `26 tokens`; the second reported `TTFT 3.19s`, `23.7 tok/s`,
  `27 tokens`. Screenshot artifacts:
  `/tmp/osaurus-gemma-proof/pr1469-current-2966ea35-20260612T0830Z/ui/ui-mxfp4-tool-clean-count-mismatch-20260612T085249Z.png`
  and
  `/tmp/osaurus-gemma-proof/pr1469-current-2966ea35-20260612T0830Z/ui/ui-mxfp4-tool-second-clean-count-mismatch-20260612T085342Z.png`.
  Remaining blocker: status-count semantics are inconsistent across surfaces
  in the isolated live root. `/health` reports `local_model_scan.model_count=27`,
  the first UI status final answer reported `1 installed model(s)`, and the
  second reported `28 installed model(s)`. Treat that as a separate status-tool
  data-source issue; it is not the original corrupted-text regression.
- Shared-policy cache/RAM proof after the second UI turn:
  `/tmp/osaurus-gemma-proof/pr1469-current-2966ea35-20260612T0830Z/ui/ui-policy-after-tool-second-cache.json`
  reports `paged_cache.enabled=false`, `block_disk_store.enabled=true`,
  `disk_l2_hits=1`, `disk_l2_misses=6`, `disk_l2_stores=4`,
  `effective_kv_mode="turbo(3,3)"`, `kv_layer_count=8`,
  `rotating_kv_layer_count=40`, `requires_disk_backed_restore=true`,
  `turbo_quant_kv_layer_count=0`, and
  `batch_diagnostics.turbo_quant_compressions=4`. The honest claim remains
  rotating KV plus disk-backed restore with an engine-selected turbo mode tag;
  do not claim real TurboQuant KV layers for this Gemma row while
  `turbo_quant_kv_layer_count=0`. `ui-policy-after-tool-second-ps.txt`
  records the app at about 1,010,288 KB RSS after both UI tool turns, and the
  cache endpoint reports `current_rss=1034485760`.
- Fresh literal `/agents/default/run` proof on PR head `db2f788b`:
  artifact root
  `/tmp/osaurus-gemma-proof/pr1469-db2f788b-agent-default-jang-20260612T085813Z`
  was produced from the current PR Release app binary
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-ui-policy-20260612T084231Z/Build/Products/Release/osaurus.app`.
  The only newer PR commit after that build is documentation-only. The app was
  launched through LaunchServices with keychain disabled,
  `OSU_MODELS_DIR=/Users/eric/models`, and `OSU_PORT=1337`; initial health
  `health.initial.json` reports `status="healthy"` and
  `local_model_scan.model_count=27`.
- Literal default-agent 12B JANG_4M tool proof on `db2f788b`:
  `request.agent-default-12b-jang4m-complete.json` calls
  `/agents/default/run` with model
  `osaurusai--gemma-4-12b-it-qat-jang_4m`, no debug trace header, and named
  `tool_choice=complete`. `first.sse` and `repeat.sse` both contain two
  sanitized `osaurus_agent_tool` chunks for `complete`, phases `started` and
  `completed`, `is_error=false`, `end_run=true`, `finish_reason="stop"`,
  visible final text
  `db2f788b literal default agent 12b jang4m complete tool execution proof.`,
  and no U+FFFE/replacement/control characters, `<|tool`, `<tool_call`,
  `<tool_response`, `<think`, or raw `tool:/args:/done:` marker leakage.
  `first.validation.json` and `repeat.validation.json` both report
  `"pass": true`. `repeat.cache.summary.json` reports `disk_l2_hits=1`,
  `disk_l2_stores=1`, `paged_hits=0`, `paged_misses=0`,
  `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
  `block_disk_store.enabled=true`, `kv_layer_count=8`,
  `rotating_kv_layer_count=40`, `requires_disk_backed_restore=true`, and
  `turbo_quant_kv_layer_count=0`. Timing artifacts report first `real 7.06`
  and repeat `real 5.83`; the `/agents/default/run` stream still does not emit
  TTFT/prefill/usage chunks, so do not report those wall times as TTFT.
- Literal default-agent beyond-E2B matrix on `db2f788b`:
  `/tmp/osaurus-gemma-proof/pr1469-db2f788b-agent-default-jang-20260612T085813Z/literal-default-matrix/summary.tsv`
  proves first and repeat `/agents/default/run` named-`complete` rows for
  every remaining QAT row beyond E2B:
  E4B JANG_4M, E4B MXFP4, 12B MXFP4, 26B-A4B JANG_4M, 26B-A4B MXFP4,
  31B JANG_4M, and 31B MXFP4. Every row has `first_pass=True`,
  `repeat_pass=True`, `disk_l2_hits=1`, `paged_enabled=False`, and
  `effective_kv_mode="turbo(3,3)"`. Repeat wall times were:
  12B MXFP4 `6.98s`, 26B-A4B JANG_4M `8.14s`, 26B-A4B MXFP4 `2.88s`,
  31B JANG_4M `9.76s`, 31B MXFP4 `13.22s`, E4B JANG_4M `4.37s`, and
  E4B MXFP4 `4.24s`. RSS samples were about 0.66 GB for 12B MXFP4,
  13.60 GB for 26B-A4B JANG_4M, 1.01 GB for 26B-A4B MXFP4, 18.59 GB for
  31B JANG_4M, 0.66 GB for 31B MXFP4, 2.95 GB for E4B JANG_4M, and
  0.66 GB for E4B MXFP4. These are same-machine RSS samples, not lower-spec
  Activity Monitor physical-footprint proof.
- Fresh VL proof on `db2f788b`:
  `/tmp/osaurus-gemma-proof/pr1469-db2f788b-agent-default-jang-20260612T085813Z/vl-e2b-jang4m-red32-db2f788b.summary.json`
  repeats the 32x32 red PNG row against
  `osaurusai--gemma-4-e2b-it-qat-jang_4m`. First and repeat streams both
  mention `red`, emit three `osaurus_prefill` chunks, include usage and
  `tokens_per_second`, finish with `stop`, and have zero marker/control leaks.
  Repeat cache reports `disk_l2_hits=1`, `disk_l2_stores=4`,
  `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=3`, `rotating_kv_layer_count=12`,
  `requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
  Timing improved from `real 1.85` to `real 0.21` on repeat.
- Fresh audio row on `db2f788b` remains `BLOCKED policy`, not fixed:
  `/tmp/osaurus-gemma-proof/pr1469-db2f788b-agent-default-jang-20260612T085813Z/audio-e2b-jangm-tone-db2f788b.summary.json`
  sends a WAV tone payload to `osaurusai--gemma-4-e2b-it-qat-jang_4m` and
  returns a typed stream error:
  `Gemma4 audio input is not enabled because the pinned vMLX Gemma4 runtime does not wire audio_tower/embed_audio yet.`
  The row does not crash, but it emits no prefill, usage, token/s, or final
  audio answer. Keep Gemma4 raw audio blocked until vMLX wires and proves the
  audio tower/embed path through Osaurus.
- Current-built Release app proof on PR head `5dc82e0a`:
  `scripts/live-proof/build-keychain-free-osaurus.sh
  build/XcodeDerivedData-pr1469-5dc82e0a-nosign` completed with
  `** BUILD SUCCEEDED **` and ad-hoc sealed
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-pr1469-5dc82e0a-nosign/Build/Products/Release/osaurus.app`.
  The app was launched through LaunchServices with keychain disabled,
  `OSU_MODELS_DIR=/Users/eric/models`, `OSU_PORT=1337`, and proof root
  `/tmp/osaurus-gemma-proof/pr1469-5dc82e0a-currentbuild-20260612T091530Z`.
  `/health` reports `status="healthy"`, `local_model_scan.model_count=27`,
  and the server listener belongs to the current-built PR app process, not the
  separately running `/Applications/osaurus.app`.
- Current-built `/agents/default/run` 12B JANG_4M proof:
  `request.agent-default-12b-jang4m-complete.json`, `first.sse`, and
  `repeat.sse` prove named `complete` execution on
  `osaurusai--gemma-4-12b-it-qat-jang_4m`. Both streams include top-level
  `osaurus_agent_tool` events for phases `started` and `completed`, exact
  final text
  `5dc82e0a current-built default agent 12b jang4m complete tool execution proof.`,
  `finish_reason="stop"`, and zero replacement/control/protocol marker leaks.
  `first.validation.json` and `repeat.validation.json` both report
  `"pass": true`. Repeat cache reports `disk_l2_hits=1`,
  `disk_l2_stores=1`, `paged_cache.enabled=false`, `block_disk_store.enabled=true`,
  `effective_kv_mode="turbo(3,3)"`, `kv_layer_count=8`,
  `rotating_kv_layer_count=40`, `requires_disk_backed_restore=true`, and
  `turbo_quant_kv_layer_count=0`. Timing was first `real 17.76` and repeat
  `real 11.13`; `/agents/default/run` still does not emit TTFT/prefill/usage,
  so those wall times are not TTFT.
- Current-built full QAT default-agent matrix:
  `/tmp/osaurus-gemma-proof/pr1469-5dc82e0a-currentbuild-20260612T091530Z/full-qat-agent-matrix/summary.tsv`
  runs all ten OsaurusAI Gemma 4 QAT rows through first and repeat
  `/agents/default/run` named-`complete` calls on the same current-built app.
  Nine of ten rows pass the strict validation: E2B JANG_4M, E4B JANG_4M,
  E4B MXFP4, 12B JANG_4M, 12B MXFP4, 26B-A4B JANG_4M, 26B-A4B MXFP4,
  31B JANG_4M, and 31B MXFP4. Each passing row has started/completed
  `complete`, clean final text, `finish_reason="stop"`, no marker/control
  leakage, `disk_l2_hits=1`, `effective_kv_mode="turbo(3,3)"`, and
  `turbo_quant_kv_layer_count=0`. Same-machine repeat RSS samples include
  about 1.92 GB for E2B JANG_4M, 3.02 GB for E4B JANG_4M, 7.21 GB for
  12B JANG_4M, 13.35 GB for 26B-A4B JANG_4M, and 18.23 GB for 31B JANG_4M.
  These are process RSS samples, not lower-spec Activity Monitor physical
  footprint proof.
- Current-built E2B MXFP4 matrix row remains `PARTIAL`, not green:
  `full-qat-agent-matrix/osaurusai__gemma_4_e2b_it_qat_mxfp4.*` and the focused
  rerun in `e2b-mxfp4-exact-rerun/` both show the model calls and completes
  the `complete` tool with no marker/control leakage and repeat `disk_l2_hits=1`,
  but the visible final answer ignores the requested exact final text. The first
  row says it executed the requested matrix task; the focused rerun says it
  executed the `complete` tool, but neither emits the requested literal
  `OK_E2B_MXFP4_5dc82e0a`. Keep this row `PARTIAL` until either the model
  contract accepts non-exact finalization or the real finalization behavior is
  fixed without prompt coercion.
- Current-built direct chat prefill/TTFT proxy row:
  `/tmp/osaurus-gemma-proof/pr1469-5dc82e0a-currentbuild-20260612T091530Z/direct-chat-prefill-12b-jang4m/`
  repeats a direct `/v1/chat/completions` text row on
  `osaurusai--gemma-4-12b-it-qat-jang_4m`. Both streams answer blue, emit
  three top-level `osaurus_prefill` events, include `usage.tokens_per_second`,
  finish with `stop`, and have no marker/control leakage. Repeat cache reports
  `disk_l2_hits=1`, `disk_l2_stores=4`, `paged_cache.enabled=false`,
  `block_disk_store.enabled=true`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=8`, `rotating_kv_layer_count=40`,
  `requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
  Wall time improved from `real 1.74` to `real 0.36`; this is the current
  prefill-progress evidence surface because `/agents/default/run` still lacks
  equivalent prefill/usage events.
- Current-built VL/audio re-proof:
  `/tmp/osaurus-gemma-proof/pr1469-5dc82e0a-currentbuild-20260612T091530Z/vl-e2b-jang4m-red32-5dc82e0a.*`
  repeats the 32x32 red PNG row. First and repeat streams answer `Red`, emit
  three top-level `osaurus_prefill` events, include usage and token/s, finish
  with `stop`, and have no marker/control leakage; repeat cache reports
  `disk_l2_hits=1`, `disk_l2_stores=4`, `paged_cache.enabled=false`, and
  `turbo_quant_kv_layer_count=0`. Timing improved from `real 1.91` to
  `real 0.20`. The audio row
  `audio-e2b-jang4m-tone-5dc82e0a.*` still returns the same typed policy error
  because the pinned vMLX runtime does not wire Gemma4 `audio_tower/embed_audio`;
  it is a clean no-crash block, not a working audio row.
- Current-built UI proof:
  Computer Use inspected the PR build window by exact app path
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-pr1469-5dc82e0a-nosign/Build/Products/Release/osaurus.app`.
  The visible app selected `OsaurusAI Gemma 4 12B it qat MXFP4`; a chat prompt
  asking to use Osaurus status showed a visible `Osaurus status` tool row and
  final visible text `The current PR UI proof is 5dc82e0a.` with no weird
  characters or protocol leakage. The UI displayed `TTFT 3.93s`, `5383.4 tok/s`,
  and `19 tokens`. This proves current-built UI tool execution for 12B MXFP4;
  the newer `a2694c14` row below proves the corresponding 12B JANG_4M UI
  picker/tool path.
- Current PR-head Release app proof on commit
  `a2694c1444cc3ffbf8afff507aefd3955ec99302`:
  `scripts/live-proof/build-keychain-free-osaurus.sh
  build/XcodeDerivedData-pr1469-a2694c14-nosign` completed with
  `** BUILD SUCCEEDED **` and ad-hoc sealed
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-pr1469-a2694c14-nosign/Build/Products/Release/osaurus.app`.
  The app was launched through LaunchServices with keychain disabled,
  `OSU_MODELS_DIR=/Users/eric/models`, `OSU_PORT=1337`, and proof root
  `/tmp/osaurus-gemma-proof/pr1469-a2694c14-currentbuild-20260612T095128Z`.
  Initial health reports `status="healthy"` and
  `local_model_scan.model_count=27`. At the same poll, PR #1469 checks had
  `shellcheck`, `swiftlint`, `test-cli`, and `update_release_draft` passing,
  with `test-core` still pending. Do not call this merge-ready until that CI
  job is green and the remaining runtime gates below are either proven or
  explicitly accepted as out of scope. A later `gh pr checks 1469` poll after
  the current-build proof reported all checks green, including `test-core`.
- Current PR-head `/agents/default/run` 12B JANG_4M proof on `a2694c14`:
  `request.agent-default-12b-jang4m-complete.json`,
  `agent-12b-jang4m.first.sse`, and `agent-12b-jang4m.repeat.sse` prove named
  `complete` execution on `osaurusai--gemma-4-12b-it-qat-jang_4m`. Both
  streams include top-level `osaurus_agent_tool` events for phases `started`
  and `completed`, exact final text
  `a2694c14 current-built default agent 12b jang4m complete tool execution proof.`,
  `finish_reason="stop"`, and no obvious protocol-marker or replacement
  character leakage. Repeat cache reports `disk_l2_hits=1`,
  `disk_l2_stores=1`, `paged_cache.enabled=false`,
  `block_disk_store.enabled=true`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=8`, `rotating_kv_layer_count=40`,
  `requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
  Timing was first `real 7.71` and repeat `real 6.30`; the agent route still
  does not emit TTFT/prefill/usage chunks, so these wall times are not TTFT.
- Current PR-head direct chat prefill row on `a2694c14`:
  `direct-chat-prefill-12b-jang4m/first.sse` and `repeat.sse` answer
  `A clear daytime sky is blue.`, emit `osaurus_prefill` queued, prefill, and
  complete chunks, include `usage.tokens_per_second`, finish with `stop`, and
  have no marker/control leakage. The repeat stream shows prefill progress at
  `29/30` before completion, then `30/30`; token/s is `38.5197`. Repeat cache
  reports `disk_l2_hits=2`, `disk_l2_stores=6`, `paged_cache.enabled=false`,
  `block_disk_store.enabled=true`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=8`, `rotating_kv_layer_count=40`,
  `requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
- Current PR-head VL row on `a2694c14`:
  `vl-e2b-jang4m-red32-a2694c14.request.json` repeats the deterministic 32x32
  red PNG row against `osaurusai--gemma-4-e2b-it-qat-jang_4m`. First and
  repeat streams answer `Red`, emit prefill queued/prefill/complete chunks at
  `307/307`, include usage and token/s, finish with `stop`, and have no
  marker/control leakage. Repeat timing improved from `real 5.00` to
  `real 0.36`. Repeat cache reports `disk_l2_hits=1`, `disk_l2_stores=4`,
  `paged_cache.enabled=false`, `block_disk_store.enabled=true`,
  `effective_kv_mode="turbo(3,3)"`, `kv_layer_count=3`,
  `rotating_kv_layer_count=12`, `requires_disk_backed_restore=true`, and
  `turbo_quant_kv_layer_count=0`.
- Current PR-head Chat UI tool proof for 12B JANG_4M on `a2694c14`:
  Computer Use inspected the exact PR-built app path above, switched the
  visible model picker to `OsaurusAI Gemma 4 12B it qat JANG_4M`, and sent a
  chat prompt requiring the Osaurus status tool. The UI rendered an
  `Osaurus status` tool row, then final visible text
  `UI JANG4M a2694c14 tool proof complete.` with no visible weird characters,
  protocol markers, or reasoning/tool leakage. The UI displayed
  `TTFT 4.45s`, `5602.7 tok/s`, and `21 tokens`. Post-UI health reports
  current model `osaurusai--gemma-4-12b-it-qat-jang_4m`, RAM feasibility
  `verdict="ok"`, and the app RSS sample was about 7,643,568 KB. Post-UI cache
  confirms `paged_cache.enabled=false`, `block_disk_store.enabled=true`,
  `effective_kv_mode="turbo(3,3)"`, `kv_layer_count=8`,
  `rotating_kv_layer_count=40`, and `requires_disk_backed_restore=true`; it is
  not a repeat-hit proof by itself because the visible current-model counters
  were reset by the model switch. Use the API agent/direct-chat artifacts above
  for repeat L2 hits.
- Current-head boundary after the full matrix/VL/UI rerun: lower-spec Activity
  Monitor physical-footprint proof, successful Gemma4 audio, and full
  `docs/HARNESS_COMPATIBILITY.md` harness scoring remain open gates. Do not
  count Google/source-looking Gemma bundles or BF16/source loads for this
  checkpoint unless the scope is explicitly reopened.
- Current app launch, vMLX `a4aa133` pin, keychain-disabled LaunchServices path:
  `/tmp/osaurus-keychain-free-gemma-checkpoint-a4aa-20260611-182816/models.json`.
- Current runtime settings from the isolated test root:
  `/tmp/osaurus-keychain-free-gemma-checkpoint-20260611-182534/config/server-runtime.json`
  has `pagedKV.enabled=false`, `blockDisk.enabled=true`,
  `legacyDisk.enabled=false`, `prefix.enabled=true`, and
  `liveKVCodec="engine_selected"`.
- E2B MXFP4 direct tool rows on the current app:
  `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-forced-checkpoint-a4aa-exact.json`
  and
  `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-result-continuation-checkpoint-a4aa.json`.
  The non-deterministic no-temperature probe
  `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-forced-checkpoint-a4aa.json`
  produced malformed visible text instead of `tool_calls`; keep deterministic
  tool-proof requests at `temperature=0` until the default-sampler behavior is
  separately characterized.
- E2B JANG_4M direct tool rows on the current app:
  `/tmp/osaurus-gemma-proof/chat-jang4m-tool-forced-checkpoint-a4aa.json`
  and
  `/tmp/osaurus-gemma-proof/chat-jang4m-tool-result-continuation-checkpoint-a4aa.json`.
- Agent-route tool-surface fix on current PR branch:
  - Root issue: `/agents/{id}/run` rendered the agent prompt through
    `SystemPromptComposer`, but then discarded the composer-resolved tool
    surface and sent bare `ToolRegistry.alwaysLoadedSpecs`. That let the model
    prompt and actual tool schema diverge for default-agent configure tools and
    custom-agent gated tools. Strict OpenAI `/chat/completions` remains bare and
    stateless by design.
  - Source regression:
    `/tmp/osaurus-gemma-proof/xcode-test-http-agent-tool-surface.log` reports
    `** TEST SUCCEEDED **`; `agentRun_usesComposerResolvedToolSurface` proves
    the default-agent route receives exactly
    `ToolRegistry.defaultAgentAllowedToolNames`, while custom agents do not see
    default-agent-only `osaurus_*` configure tools.
  - Unsigned patched app build:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-agenttool-surface.log`
    reports `** BUILD SUCCEEDED **`.
  - Patched app isolated root:
    `/tmp/osaurus-gemma-proof/agenttool-surface-root.txt`; health artifact
    `/tmp/osaurus-gemma-proof/agenttool-surface-health-after-status.json`
    reports `status=healthy`, `current_model=osaurusai--gemma-4-e2b-it-qat-jang_4m`,
    `local_model_scan.model_count=27`, persistence not degraded, and RAM
    feasibility `verdict="ok"`.
  - Live default-agent JANG_4M configure-read row:
    `/tmp/osaurus-gemma-proof/agenttool-surface-defaultagent-jang4m-status.sse`
    returned clean visible text through `/agents/00000000-0000-0000-0000-000000000001/run`
    with no marker/control-character leakage. It summarized the tool-visible
    installed-model count as `1`; `/health` separately reported raw local
    folder scan count `27`, so keep those counters distinct.
  - Live default-agent JANG_4M `complete` row:
    `/tmp/osaurus-gemma-proof/agenttool-surface-defaultagent-jang4m-complete.sse`
    returned `Patched default agent complete tool executed cleanly` with
    `finish_reason="stop"` and no protocol-marker leakage.
  - Live default-agent MXFP4 `complete` row:
    `/tmp/osaurus-gemma-proof/agenttool-surface-defaultagent-mxfp4-complete.sse`
    returned `Patched default agent mxfp4 complete tool executed cleanly` with
    `finish_reason="stop"` and no protocol-marker leakage. Health artifact
    `/tmp/osaurus-gemma-proof/agenttool-surface-health-after-mxfp4.json`
    reports `current_model=osaurusai--gemma-4-e2b-it-qat-mxfp4`, persistence
    not degraded, and RAM feasibility `verdict="ok"`.
  - L2 disk prefix cache artifacts were written under the isolated root:
    `cache/kv_v2` was 37 MB with three `.safetensors` files after the live
    default-agent rows.
- Follow-up forced-tool proof on patched app after the Gemma-only agent-loop
  directive fix:
  - Focused source regression:
    `/tmp/osaurus-gemma-proof/xcode-test-mlx-batch-agenttool-fix.log`
    reports `** TEST SUCCEEDED **` for `MLXBatchAdapterTests`, including
    `forcedToolChoiceAddsGemmaRequestLocalDirective` and the non-Gemma no-op
    guard.
  - Unsigned Debug app build:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-agenttool-fix.log`
    reports `** BUILD SUCCEEDED **`.
  - Runtime defaults from isolated app root
    `/tmp/osaurus-keychain-free-gemma-agenttool-fix-open-a4aa-20260611-192622/config/server-runtime.json`
    keep `pagedKV.enabled=false`, `blockDisk.enabled=true`,
    `legacyDisk.enabled=false`, `prefix.enabled=true`,
    `liveKVCodec="engine_selected"`, `memorySafety.mode="safe_auto"`, and
    `memorySafety.allowExperimentalMLXPress=false`.
  - Direct `/v1/chat/completions` streaming tool proof:
    `/tmp/osaurus-gemma-proof/v1-stream-e2b-jang4m-forced-complete-agenttool-fix.sse`
    and
    `/tmp/osaurus-gemma-proof/v1-stream-e2b-mxfp4-forced-complete-agenttool-fix.sse`
    both emit `osaurus_prefill` queued/running/complete chunks, exact
    `complete` tool names, exact JSON `summary` arguments, and
    `finish_reason="tool_calls"`.
  - Agent-loop forced `complete` proof:
    `/tmp/osaurus-gemma-proof/agenttool-custom-e2b-jang4m-forced-complete-agenttool-fix.sse`
    returns the terminal `complete` summary cleanly through the Osaurus agent
    SSE surface with no protocol-marker leakage and no loop. The route hides
    raw tool invocations by design, so this remains `PARTIAL` agent proof
    until a side-effecting built-in tool row succeeds and is externally
    queryable.
  - Agent-loop DB side-effect attempt:
    `/tmp/osaurus-gemma-proof/agenttool-custom-e2b-jang4m-db-create-auto.sse`
    reached a DB-tool result path but failed on invalid model-produced column
    arguments; no table side effect was proven. Keep this as a blocker for
    exhaustive agent tool proof, not a pass.
  - Post-run cache/RAM proof:
    `/tmp/osaurus-gemma-proof/agenttool-fix-cache-after-agent-runs.json`
    has `disk_l2_hits=1`, `block_disk_store.hits=1`, `paged_hits=0`,
    `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
    `requires_disk_backed_restore=true`, `mlx_press.enabled=false`, and
    `memory_safety.verdict`/health equivalent `ok`. RSS sample
    `/tmp/osaurus-gemma-proof/agenttool-fix-ps-after-agent-runs.txt`
    records about 1.87 GB RSS after live JANG agent/direct rows.
- Current-tree default-agent tool trace proof from the rebuilt Debug app:
  - Follow-up root issue found 2026-06-11:
    `/agents/{id}/run` tool execution was proven, but ordinary local streams
    kept the sanitized `osaurus_agent_tool` progress chunks hidden behind the
    `X-Osaurus-Debug-Agent-Tools` header. That made the Osaurus UI/API blind
    during tool execution even though the model and tool loop were working.
  - Source regression after the visibility fix:
    `/tmp/osaurus-gemma-proof/xcode-green-agent-tool-visible-default.log`
    reports `** TEST SUCCEEDED **` for
    `agent_run_executes_tool_without_streaming_internal_sentinels`. The test
    sends no `X-Osaurus-Debug-Agent-Tools` header and now requires sanitized
    `osaurus_agent_tool` chunks with `choices: []`, `started`, `completed`,
    tool name `complete`, and no U+FFFE sentinel leakage.
  - Rebuilt app proof:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-agent-tool-visible-default.log`
    reports `** BUILD SUCCEEDED **`. Older artifact
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-agenttrace.log` reports
    `** BUILD SUCCEEDED **`; the app launched with
    `OSU_MODELS_DIR=/Users/eric/models`, keychain disabled, and health artifact
    `/tmp/osaurus-gemma-proof/health-agenttool-visible.json` reporting
    `status=healthy`, `local_model_scan.model_count=27`, and persistence not
    degraded.
  - Product-gap repro before the fix:
    `/tmp/osaurus-gemma-proof/agents-default-12b-jang4m-c68c3c05-ordinary.sse`
    had no `osaurus_agent_tool` chunks, while
    `/tmp/osaurus-gemma-proof/agents-default-12b-jang4m-c68c3c05-debugtrace.sse`
    contained the same tool's started/completed chunks only because the debug
    header was present.
  - Live no-debug-header proof after the fix:
    `/tmp/osaurus-gemma-proof/agents-defaultuuid-12b-jang4m-agenttool-visible-uncommitted.sse`
    calls the built-in Default agent UUID route
    `/agents/00000000-0000-0000-0000-000000000001/run` with no debug header and
    contains two `osaurus_agent_tool` chunks for tool `complete`, phases
    `started` and `completed`, `finish_reason="stop"`, and no U+FFFE,
    `<|tool`, or `<tool_call` leakage.
  - Live no-debug-header cache/RAM proof after the fix:
    `/tmp/osaurus-gemma-proof/agents-defaultuuid-12b-jang4m-agenttool-visible-uncommitted-cache-after.json`
    reports `models[0].name=osaurusai--gemma-4-12b-it-qat-jang_4m`
    with `is_current=true`,
    `effective_kv_mode="turbo(3,3)"`, `memory_safety.cache.paged_kv_enabled=false`,
    `block_disk_store.enabled=true`, `block_disk_store.stores=1`,
    `disk_l2_stores=1`, `cache_topology.kv_layer_count=8`,
    `cache_topology.rotating_kv_layer_count=40`, and
    `cache_topology.requires_disk_backed_restore=true`. RSS sample
    `/tmp/osaurus-gemma-proof/agents-defaultuuid-12b-jang4m-agenttool-visible-uncommitted-ps-after.txt`
    records about 6.81 GB RSS for the dev app process after the row.
  - Current-head forced agent-loop proof on commit `5a885570`:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-5a885570-agentproof.log`
    reports `** BUILD SUCCEEDED **`; app health
    `/tmp/osaurus-gemma-proof/health-agentproof-5a885570.json` reports
    `status=healthy`, `local_model_scan.model_count=27`, and
    `root="/Users/eric/models"`.
  - 12B JANG_4M actual agent-loop tool execution on commit `5a885570`:
    request
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-5a885570.request.json`
    calls `/agents/00000000-0000-0000-0000-000000000001/run` with
    `tool_choice=complete` and no debug header. Stream artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-5a885570.sse`
    contains two `osaurus_agent_tool` chunks for `complete`, phases
    `started` and `completed`, `is_error=false`, `end_run=true`,
    `finish_reason="stop"`, the expected summary
    `12b jang4m agent loop tool execution proven on current PR head`, and no
    U+FFFE, `<|tool`, `<tool_call`, `<tool_response`, or chat-template marker
    leakage. Repeat artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-repeat-5a885570.sse`
    passes the same leak/tool checks.
  - 12B JANG_4M cache/RAM proof on the repeated agent-loop row:
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-repeat-5a885570.cache.json`
    reports `models[0].name=osaurusai--gemma-4-12b-it-qat-jang_4m`,
    `effective_kv_mode="turbo(3,3)"`, `paged_kv_enabled=false`,
    `block_disk_store.enabled=true`, `disk_l2_hits=1`,
    `block_disk_store.hits=1`, `cache_topology.kv_layer_count=8`,
    `cache_topology.rotating_kv_layer_count=40`, and
    `requires_disk_backed_restore=true`. Wall-clock artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-repeat-5a885570.timing.json`
    plus the parsed run recorded about 5.86 seconds for the repeated agent
    route. RSS sample
    `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-forced-complete-repeat-5a885570.ps.txt`
    records about 6.81 GB RSS.
  - 12B MXFP4 actual agent-loop tool execution on commit `5a885570`:
    request
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-5a885570.request.json`
    calls the same built-in Default agent route with `tool_choice=complete`.
    Stream artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-5a885570.sse`
    contains two `osaurus_agent_tool` chunks for `complete`, phases
    `started` and `completed`, `is_error=false`, `end_run=true`,
    `finish_reason="stop"`, the expected summary
    `12b mxfp4 agent loop tool execution proven on current PR head`, and no
    U+FFFE, `<|tool`, `<tool_call`, `<tool_response`, or chat-template marker
    leakage. Repeat artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-repeat-5a885570.sse`
    passes the same leak/tool checks.
  - 12B MXFP4 cache/RAM proof on the repeated agent-loop row:
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-repeat-5a885570.cache.json`
    reports `models[0].name=osaurusai--gemma-4-12b-it-qat-mxfp4`,
    `effective_kv_mode="turbo(3,3)"`, `paged_kv_enabled=false`,
    `block_disk_store.enabled=true`, `disk_l2_hits=1`,
    `block_disk_store.hits=1`, `cache_topology.kv_layer_count=8`,
    `cache_topology.rotating_kv_layer_count=40`, and
    `requires_disk_backed_restore=true`. Wall-clock artifact
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-repeat-5a885570.timing.json`
    plus the parsed run recorded about 5.68 seconds for the repeated agent
    route. RSS sample
    `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-forced-complete-repeat-5a885570.ps.txt`
    records about 0.56 GB RSS after switching from 12B JANG_4M to 12B MXFP4.
  - Current-head rebuilt matrix proof on commit `e9c3daed`:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-e9c3daed-matrix.log`
    reports `** BUILD SUCCEEDED **`; app health
    `/tmp/osaurus-gemma-proof/health-matrix-e9c3daed.json` reports
    `status=healthy`, `local_model_scan.model_count=27`, and
    `root="/Users/eric/models"`.
  - Remaining beyond-E2B forced agent-loop matrix:
    `/tmp/osaurus-gemma-proof/agent-matrix-e9c3daed-summary.txt` has
    `pass_ok=true` for first and repeat `/agents/{defaultUUID}/run`
    `tool_choice=complete` rows on E4B JANG_4M, E4B MXFP4, 26B-A4B JANG_4M,
    26B-A4B MXFP4, 31B JANG_4M, and 31B MXFP4. Every row has two
    `osaurus_agent_tool` chunks, phases `started` and `completed`, tool name
    `complete`, `finish_reason="stop"`, the exact expected summary, and no
    U+FFFE, `<|tool`, `<tool_call`, `<tool_response`, or chat-template marker
    leakage.
  - Remaining beyond-E2B cache/RAM matrix:
    the repeat rows in
    `/tmp/osaurus-gemma-proof/agent-matrix-e9c3daed-summary.txt` report
    `effective_kv_mode="turbo(3,3)"`, `paged=false`,
    `block_hits=1`, `block_stores=1`, `disk_l2_hits=1`, and
    `restore=true` for each model. Layer topology by row:
    E4B = `kv_layers=4`, `rotating_layers=20`; 26B-A4B =
    `kv_layers=5`, `rotating_layers=25`; 31B = `kv_layers=10`,
    `rotating_layers=50`. RSS samples in the same summary range from about
    0.58-0.95 GB for MXFP4 rows to about 2.89 GB (E4B JANG_4M),
    13.69 GB (26B-A4B JANG_4M), and 17.39 GB (31B JANG_4M). These are still
    RSS samples, not lower-spec Activity Monitor physical-footprint proof.
  - Default-agent JANG_4M end-run tool proof:
    `/tmp/osaurus-gemma-proof/agents-default-jang4m-complete-trace.sse`
    contains trace chunks for tool `complete` with phases `started` and
    `completed`, `is_error=false`, `end_run=true`, then the exact visible final
    text `Default agent JANG4M tool execution traced through Osaurus dev app.`
  - Default-agent JANG_4M cache/RAM proof:
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-jang4m-complete-trace.json`
    reports current model `osaurusai--gemma-4-e2b-it-qat-jang_4m`,
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `block_disk_store.enabled=true`, `disk_l2_stores=1`,
    `kv_layer_count=3`, `rotating_kv_layer_count=12`,
    `requires_disk_backed_restore=true`, `memory_safety.allowed=true`, and
    RSS about 2.03 GB.
  - Default-agent MXFP4 end-run tool proof:
    `/tmp/osaurus-gemma-proof/agents-default-mxfp4-complete-trace.sse`
    contains trace chunks for tool `complete` with phases `started` and
    `completed`, `is_error=false`, `end_run=true`, then the exact visible final
    text `Default agent MXFP4 tool execution traced through Osaurus dev app.`
  - Default-agent MXFP4 cache/RAM proof:
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-mxfp4-complete-trace.json`
    reports current model `osaurusai--gemma-4-e2b-it-qat-mxfp4`,
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `block_disk_store.enabled=true`, `kv_layer_count=3`,
    `rotating_kv_layer_count=12`, `requires_disk_backed_restore=true`,
    `memory_safety.allowed=true`, and RSS about 0.61 GB.
  - Exact-copy status-tool rows are not counted as a full pass:
    `/tmp/osaurus-gemma-proof/agents-default-jang4m-osaurus-status.sse` and
    `/tmp/osaurus-gemma-proof/agents-default-mxfp4-osaurus-status.sse` reached
    terminal text but the model visibly mangled copied words/numbers. Keep
    those rows `PARTIAL` and use them as a regression note for exact-copy
    quality; they do not invalidate the traced `complete` tool execution pass.
  - Expanded QAT default-agent trace matrix:
    `/tmp/osaurus-gemma-proof/agenttrace-matrix-summary-20260611T205423Z.txt`
    proves `complete` end-run tool traces for E4B JANG_4M, E4B MXFP4, 12B
    JANG_4M, 12B MXFP4, and 26B-A4B JANG_4M. Each passing row reports
    `trace=True`, `final=True`, `finish_stop=True`, matching current model,
    `effective_kv_mode="turbo(3,3)"`, `paged=false`, `disk=true`, and RSS:
    E4B JANG_4M 3.16 GB, E4B MXFP4 0.74 GB, 12B JANG_4M 7.45 GB, 12B MXFP4
    0.75 GB, and 26B-A4B JANG_4M 13.69 GB. These are agent-loop tool trace
    passes, not full harness/VL/audio passes.
  - Expanded matrix blocked rows:
    26B-A4B MXFP4 failed with `curl_failed=18`, then the dev app crashed before
    31B rows could run; both 31B JANG_4M and 31B MXFP4 have `curl_failed=7`
    because the server was already down. The zero-byte/partial SSE artifacts
    are:
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-26b-a4b-it-qat-mxfp4-complete-trace.sse`,
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-31b-it-qat-jang-4m-complete-trace.sse`,
    and
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-31b-it-qat-mxfp4-complete-trace.sse`.
  - Crash root-cause evidence:
    `/Users/eric/Library/Logs/DiagnosticReports/osaurus-2026-06-11-205528.ips`
    is an `EXC_BAD_ACCESS` / `SIGSEGV` crash on a cooperative queue. The
    stack is MLX Metal dispatch through
    `Model2VecStaticEmbeddingPipeline.embedOne`, `VMLXModel2VecEmbedder`,
    `MetalSafeEmbedder`, `HybridSearchEngine.search`, and
    `MemorySearchService.searchTranscript`. This points at resident local
    model inference plus vMLX Model2Vec memory vector search, not Gemma decode
    or the QAT bundle loader.
  - Crash prevention guard added after the IPS:
    `MemorySearchService` now skips VecturaKit/vMLX vector indexing and search
    while any local MLX model is resident, or when
    `OSAURUS_DISABLE_MEMORY_VECTOR_SEARCH=1/true`, and uses the existing SQL
    text fallback instead. This is a fail-closed Osaurus guard for the
    checkpoint, not the final vMLX Model2Vec root fix. Vector memory search can
    be restored during resident local inference only after the vMLX embedding
    crash path is fixed and live-proven.
  - Guard verification:
    `/tmp/osaurus-gemma-proof/xcode-test-memory-vector-guard.log` reports
    `** TEST SUCCEEDED **` for `MemorySearchServiceTests`, and
    `/tmp/osaurus-gemma-proof/xcode-test-runtime-policy-memory-vector-guard.log`
    reports `** TEST SUCCEEDED **` with 84 `RuntimePolicySourceTests` passing,
    including the source-policy assertion that all memory vector operations are
    guarded before VecturaKit/vMLX embedding work.
  - Guarded-app build proof:
    `/tmp/osaurus-gemma-proof/xcode-build-debug-app-memory-vector-guard.log`
    reports `** BUILD SUCCEEDED **`.
  - Guarded-app launch proof:
    `/tmp/osaurus-gemma-proof/osaurus-launch-debug-foreground.log` shows the
    Debug app launched keychain-free with the local server bound on
    `127.0.0.1:1337`. Health artifact
    `/tmp/osaurus-gemma-proof/health-memory-vector-guard-foreground.json`
    reports `status=healthy`, `local_model_scan.model_count=27`, and
    `root="/Users/eric/models"`.
  - Retried 26B-A4B MXFP4 after the memory-vector guard:
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-26b-a4b-it-qat-mxfp4-complete-trace-memoryguard.sse`
    contains `osaurus_agent_tool` `started` and `completed` chunks for
    `complete`, `is_error=false`, `end_run=true`, exact final text, and
    `finish_reason="stop"`. Cache artifact
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-osaurusai-gemma-4-26b-a4b-it-qat-mxfp4-complete-trace-memoryguard.json`
    reports current model
    `osaurusai--gemma-4-26b-a4b-it-qat-mxfp4`,
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `block_disk_store.enabled=true`, `kv_layer_count=5`,
    `rotating_kv_layer_count=25`, and
    `requires_disk_backed_restore=true`.
  - Retried 31B JANG_4M after the memory-vector guard:
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-31b-it-qat-jang-4m-complete-trace-memoryguard.sse`
    contains the same passing `complete` trace and final text. Cache artifact
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-osaurusai-gemma-4-31b-it-qat-jang-4m-complete-trace-memoryguard.json`
    reports `effective_kv_mode="turbo(3,3)"`, paged cache off, block disk
    enabled, `kv_layer_count=10`, `rotating_kv_layer_count=50`, and
    disk-backed restore required. RSS sample
    `/tmp/osaurus-gemma-proof/ps-after-agents-default-osaurusai-gemma-4-31b-it-qat-jang-4m-complete-trace-memoryguard.txt`
    records about 18.10 GB RSS after the 31B JANG_4M row.
  - Retried 31B MXFP4 after the memory-vector guard:
    `/tmp/osaurus-gemma-proof/agents-default-osaurusai-gemma-4-31b-it-qat-mxfp4-complete-trace-memoryguard.sse`
    contains the same passing `complete` trace and final text. Cache artifact
    `/tmp/osaurus-gemma-proof/cache-after-agents-default-osaurusai-gemma-4-31b-it-qat-mxfp4-complete-trace-memoryguard.json`
    reports `effective_kv_mode="turbo(3,3)"`, paged cache off, block disk
    enabled, `kv_layer_count=10`, `rotating_kv_layer_count=50`, and
    disk-backed restore required. Health artifact
    `/tmp/osaurus-gemma-proof/health-after-31b-mxfp4-memoryguard.json`
    reports the app still healthy with current model
    `osaurusai--gemma-4-31b-it-qat-mxfp4`, RAM feasibility `verdict="ok"`,
    and `mlx_last_error=null`.
- E2B JANG_4M API prefill progress on the current app:
  `/tmp/osaurus-gemma-proof/chat-jang4m-prefill-long-checkpoint-a4aa.sse`
  emitted 19 `osaurus_prefill` chunks from queued/running through
  `complete 8702/8702 decode_ready` before the first content token; repeat
  proof is
  `/tmp/osaurus-gemma-proof/chat-jang4m-prefill-long-repeat-checkpoint-a4aa.sse`.
- E2B JANG_4M Prefix/L2 and TQ/SWA on the current app:
  `/tmp/osaurus-gemma-proof/cache-after-prefill-repeat-checkpoint-a4aa.json`
  has `disk_l2_hits=1`, `block_disk_store.hits=1`,
  `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=3`, `rotating_kv_layer_count=12`, and
  `requires_disk_backed_restore=true`. Longer decode proof in
  `/tmp/osaurus-gemma-proof/cache-after-long-decode-tq-checkpoint-a4aa.json`
  records `batch_diagnostics.turbo_quant_compressions=3`.
- E2B JANG_4M real VL image row on commit `e9c3daed`:
  deterministic input image
  `/tmp/osaurus-gemma-proof/red-square-32.png` is a 32x32 red PNG carried in
  `/tmp/osaurus-gemma-proof/vl-e2b-jang4m-red-square-e9c3daed.request.json`
  as an OpenAI-compatible `image_url` data URL. First and repeat SSE artifacts
  `/tmp/osaurus-gemma-proof/vl-e2b-jang4m-red-square-first-e9c3daed.sse` and
  `/tmp/osaurus-gemma-proof/vl-e2b-jang4m-red-square-repeat-e9c3daed.sse`
  both return the visible answer `Red`, `finish_reason="stop"`, three
  `osaurus_prefill` chunks, and no U+FFFE/tool/template marker leakage.
  Repeat cache artifact
  `/tmp/osaurus-gemma-proof/vl-e2b-jang4m-red-square-repeat-e9c3daed.cache.json`
  reports `effective_kv_mode="turbo(3,3)"`, `paged_kv_enabled=false`,
  `block_disk_store.enabled=true`, `disk_l2_hits=1`, `kv_layer_count=3`,
  `rotating_kv_layer_count=12`, and disk-backed restore required. The repeat
  row completed in about 1.87 seconds wall clock versus about 4.75 seconds on
  the first row.
- E2B JANG_4M real audio row on commit `e9c3daed`:
  deterministic input audio
  `/tmp/osaurus-gemma-proof/tone-440hz-1s.wav` is a 1-second 440 Hz WAV carried
  in `/tmp/osaurus-gemma-proof/audio-e2b-jang4m-tone-e9c3daed.request.json`
  as OpenAI-compatible `input_audio`. Artifacts
  `/tmp/osaurus-gemma-proof/audio-e2b-jang4m-tone-first-e9c3daed.sse` and
  `/tmp/osaurus-gemma-proof/audio-e2b-jang4m-tone-repeat-e9c3daed.sse` do not
  prove audio generation; both fail closed with the typed SSE error:
  `Gemma4 audio input is not enabled because the pinned vMLX Gemma4 runtime
  does not wire audio_tower/embed_audio yet.` Keep Gemma4 audio `BLOCKED
  policy` until vMLX wires the real audio tower/embed path and the row is
  rerun successfully.
- E2B MXFP4 Prefix/L2 and TQ/SWA on the current app:
  `/tmp/osaurus-gemma-proof/cache-after-mxfp4-long-decode-repeat-checkpoint-a4aa.json`
  has `disk_l2_hits=1`, `block_disk_store.hits=1`,
  `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `kv_layer_count=3`, `rotating_kv_layer_count=12`, and
  `requires_disk_backed_restore=true`; its batch diagnostics record
  `turbo_quant_compressions=2` after the repeated long-decode row.
- Static per-model cache topology still reports
  `turbo_quant_kv_layer_count=0` because the topology snapshot records the
  base cache class layout. Use `batch_diagnostics.turbo_quant_compressions`
  plus `effective_kv_mode` for live TurboQuant activity until telemetry is
  extended to expose post-conversion layer counts.
- Current RSS samples:
  `/tmp/osaurus-gemma-proof/ps-after-tool-continuations-checkpoint-a4aa.txt`
  recorded about 1.96 GB RSS after E2B tool rows. Physical footprint still
  needs Activity Monitor/lower-spec teammate proof.
- Current-tree Agent route proof after the `a4aa133` repin is still
  `PARTIAL`, but no longer blocked on schema mismatch: focused source tests
  now prove the hidden agent route uses the composer-resolved default/custom
  tool surface, and live default-agent JANG_4M rows for `osaurus_status` and
  `complete` return clean terminal text. The route intentionally hides raw tool
  invocations from SSE; DB side-effect proof previously failed argument
  validation. Do not mark the full UI/agent-loop row complete until a real
  Chat UI run or independently queryable side-effect row is captured.
- Speed is still `PARTIAL` for proven E2B rows because token/s is present, but
  TTFT is not yet consistently recorded as a first-class metric across the
  matrix. Add timestamp-based TTFT extraction or explicit runtime TTFT before
  marking `Speed` proven.
- Memory is still `PARTIAL` because RSS samples exist, but final checkpoint
  needs Activity Monitor physical-footprint samples on lower-spec Macs.

Checkpoint execution order:

1. Keep the QAT app path buildable and live-proven first; do not widen into
   unrelated model families or non-QAT bundles.
2. Run the smallest rows first: E2B MXFP4 and E2B JANG_4M full matrix, then
   E4B, then 12B, then 26B-A4B and 31B as local RAM allows.
3. For each model, collect one artifact bundle prefix:
   `/tmp/osaurus-gemma-proof/matrix-<model>-<date>-{request,sse,response,cache,ps}.<ext>`.
4. After each model, update the table above before moving to the next model.
5. Run the QAT harness rows, record scores, and fix score blockers before
   merge-ready wording.
6. Only after the QAT matrix has app-facing proof and harness scores should the
   team checkpoint be merged/pushed for lower-spec Mac testing.

## Current Verification

- vMLX branch `codex/cache-defaults-bf16-qat` is pushed at
  `a4aa133689417b924833610db0ff2732151d74cd`.
- vMLX dependency flattening is now part of that SHA:
  `Libraries/MLXEmbedders/Model2VecStaticEmbeddingPipeline.swift` adds a
  vMLX-native Model2Vec/static embedding path for bundles such as
  `minishlab/potion-base-4M`.
- Osaurus is pinned to vMLX `a4aa133689417b924833610db0ff2732151d74cd` and
  VecturaKit `3bc52538f16a95d956c575abbc7e0423737dfd64`.
- The Osaurus embedding stack no longer imports VecturaKit's old
  `SwiftEmbedder` path. `EmbeddingService` now uses a lazy
  `VMLXModel2VecEmbedder` through `MetalSafeEmbedder`, backed by vMLX
  `MLXEmbedders`.
- Xcode and SwiftPM dependency graphs are flattened for the app path:
  `Packages/OsaurusCore/Package.resolved`,
  `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and
  `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  no longer contain `swift-embeddings`, external `swift-transformers`,
  `swift-safetensors`, or external `swift-huggingface`. They contain
  `vmlx-swift` at `a4aa133` and VecturaKit at `3bc5253`.
- Build proof after flattening:
  - vMLX full build:
    `/tmp/osaurus-gemma-proof/vmlx-build-full-model2vec.log`
    reports `Build complete!`.
  - OsaurusCore SwiftPM build:
    `/tmp/osaurus-gemma-proof/swift-build-core-vmlx-model2vec-vectura6.log`
    reports `Build complete!`.
  - Xcode workspace resolve:
    `/tmp/osaurus-gemma-proof/xcode-resolve-vmlx-a4aa-vectura6.log`
    resolves `mlx-swift @ a4aa133` and `VecturaKit @ 3bc5253`.
  - Xcode app-project resolve:
    `/tmp/osaurus-gemma-proof/xcode-resolve-app-vmlx-a4aa-vectura6.log`
    resolves `mlx-swift @ a4aa133` and `VecturaKit @ 3bc5253`.
- Current keychain-free Debug app build proof after the `a4aa133` repin:
  `/tmp/osaurus-gemma-proof/xcode-build-debug-app-vmlx-a4aa-vectura6.log`
  reports `** BUILD SUCCEEDED **`.
- Current live Gemma proof after the `a4aa133` repin is recorded in the
  checkpoint proof matrix above. Older live artifacts below remain historical
  context only.
- Focused Xcode source regression proof after the `a4aa133` repin:
  `/tmp/osaurus-gemma-proof/xcode-test-focused-cache-prefill-a4aa.log`
  reports `** TEST SUCCEEDED **`. The xcresult bundle is
  `build/XcodeDerivedData-gemma-current-tests/Logs/Test/Test-OsaurusCoreTests-2026.06.11_18-36-32--0700.xcresult`.
  This covered `GenerationEventMapperTests`, `InferenceProgressManagerTests`,
  `ServerRuntimeSettingsStoreTests`, `MLXBatchAdapterTests`, and
  `HTTPHandlerChatStreamingTests`.
- Focused Xcode source regression rerun after removing non-QAT checkpoint
  scope:
  `/tmp/osaurus-gemma-proof/xcode-test-focused-cache-prefill-a4aa-rerun.log`
  reports `** TEST SUCCEEDED **` with 128 tests passing. The xcresult bundle is
  `/tmp/osaurus-gemma-proof/xcode-test-focused-cache-prefill-a4aa-rerun.xcresult`.
  This again covered cache default migration, prefill progress, streaming
  prefill diagnostics, token/s usage chunks, and Gemma tool-surface handling.
- SwiftPM focused test attempt is locally blocked by this machine's SwiftPM
  test toolchain failing to import module `Testing`; the blocker artifact is
  `/tmp/osaurus-gemma-proof/swift-test-focused-cache-prefill-a4aa.log`.
- Local `docs/HARNESS_COMPATIBILITY.md` has been restored from upstream main
  for the required AgentLoop/AgentLoopFrontier harness contract.
- Harness branch status: this branch predates the upstream AgentLoop harness
  implementation. `origin/main` adds the documented `AgentLoop`,
  `AgentLoopFrontier`, `SandboxFrontier`, `CapabilityClaims`, and
  `SandboxDiagnostics` suites, plus matching runner code such as
  `EvalRunnerAgentLoop.swift`. That runner depends on newer OsaurusCore
  agent-loop infrastructure including `AgentLoopEvaluator` and
  `CapabilityClaimsEvaluator`, so copying only the suite JSON or only
  `Packages/OsaurusEvals` into this cache/runtime branch would produce a
  broken partial port. The harness proof gate is therefore blocked until this
  PR is rebased/merged onto the upstream eval-harness stack or a narrow
  backport of the complete agent-loop evaluator stack is intentionally made.
- Local eval CLI dependency status: the earlier temporary VecturaKit 5.2.1 /
  `swift-embeddings` pin is superseded. The real root fix is to keep
  VecturaKit's core package provider-free and supply Model2Vec embeddings from
  vMLX. This removes the resolver fight between Osaurus's mirrored
  `swift-transformers` fork and `swift-embeddings` tags that require newer
  upstream transformer tags.
- Eval CLI proof after the dependency fix:
  `/tmp/osaurus-gemma-proof/osaurus-evals-help-vecturakit-521-swiftemb-targetdep.log`
  reports `Build of product 'osaurus-evals' complete!`.
- Local eval smoke after the dependency fix:
  - `/tmp/osaurus-gemma-proof/osaurus-evals-streaminghint-smoke-20260612.log`
    and `build/eval-reports/streaminghint-smoke-20260612.json` report
    `3 total · 3 passed · 0 failed · 0 skipped · 0 errored`.
  - `/tmp/osaurus-gemma-proof/osaurus-evals-gemma4-e2b-mxfp4-preflight-smalltalk-20260612.log`
    and
    `build/eval-reports/gemma4-e2b-mxfp4-preflight-smalltalk-20260612.json`
    report `1 total · 1 passed · 0 failed · 0 skipped · 0 errored` for
    `--model osaurusai--gemma-4-e2b-it-qat-mxfp4`. This is only an
    eval-runner/config smoke; the 1ms row does not prove Gemma generation or
    quality.
- Unsigned/keychain-free Debug app build succeeded:
  `build/XcodeDerivedData-gemma-streamdiag/Build/Products/Debug/osaurus.app`.
- Runtime settings before live proof:
  - `cache.pagedKV.enabled=false`
  - `cache.liveKVCodec="engine_selected"`
  - `cache.blockDisk.enabled=true`
  - `cache.legacyDisk.enabled=false`
- vMLX root fix for Osaurus agent tools:
  `MLXVLM/Models/Gemma4.swift` now normalizes `input.tools` through
  `MLXLMCommon.normalizedToolsForChatTemplate` before Gemma 4 renders the
  native chat template. This fixes the prior `/agents/{id}/run` failure:
  `Chat template error: Runtime error: upper filter requires string`.
- Live JANG_4M proof:
  - Fresh visible generation from the unsigned dev app:
    `/tmp/osaurus-gemma-proof/chat-jang4m-visible-swa-live.json` returned
    `Seven plus five equals twelve.`
  - Fresh long streaming row:
    `/tmp/osaurus-gemma-proof/chat-jang4m-visible-long-stream-swa-live.sse`
    returned `The final word is omega.` with usage
    `prompt_tokens=119`, `completion_tokens=6`.
  - `/agents/{id}/run` no longer hits the Gemma template error:
    `/tmp/osaurus-gemma-proof/agent-run-jang4m-forced-vmlxfix-sse.txt`
  - Direct OpenAI tool-call proof returns `finish_reason="tool_calls"`, tool
    `complete`, exact JSON args
    `{"summary":"qat jang4m direct tool ok verified through osaurus"}`:
    `/tmp/osaurus-gemma-proof/chat-tool-jang4m-forced-vmlxfix.json`
  - Cache telemetry after JANG agent route:
    `/tmp/osaurus-gemma-proof/cache-after-agent-run-jang4m-forced-vmlxfix.json`
    shows `effective_kv_mode="turbo(3,3)"`,
    `paged_cache.enabled=false`, `turbo_quant_compressions=4`,
    `kv_layer_count=3`, `rotating_kv_layer_count=12`, and
    `requires_disk_backed_restore=true`.
  - Fresh direct tool proof from the unsigned dev app:
    `/tmp/osaurus-gemma-proof/chat-jang4m-tool-forced-e8b5.json`
    returned tool `complete` with exact JSON args
    `{"summary":"qat jang4m e8b5 tool ok"}`.
  - Fresh tool-result continuation proof:
    `/tmp/osaurus-gemma-proof/chat-jang4m-tool-result-continuation-e8b5.json`
    returned visible text
    `The tool returned the summary: "qat jang4m e8b5 tool ok".`
  - Fresh SWA cache telemetry after tool continuation:
    `/tmp/osaurus-gemma-proof/cache-after-jang4m-tool-continuation-swa-live.json`
    shows `effective_kv_mode="turbo(3,3)"`,
    `paged_cache.enabled=false`, `turbo_quant_compressions=3`,
    `kv_layer_count=3`, `rotating_kv_layer_count=12`,
    `requires_disk_backed_restore=true`, and block disk enabled with stores.
- Live MXFP4 proof:
  - Fresh long streaming row from the unsigned dev app:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-visible-long-stream-swa-live.sse`
    returned `The final word is gold.` with usage `prompt_tokens=95`,
    `completion_tokens=6`.
  - `/agents/{id}/run` loads and completes without the Gemma template error:
    `/tmp/osaurus-gemma-proof/agent-run-mxfp4-forced-vmlxfix-sse.txt`
  - Direct OpenAI tool-call proof returns `finish_reason="tool_calls"`, tool
    `complete`, exact JSON args
    `{"summary":"qat mxfp4 direct tool ok verified through osaurus"}`:
    `/tmp/osaurus-gemma-proof/chat-tool-mxfp4-forced-vmlxfix.json`
  - Cache telemetry after MXFP4 agent route:
    `/tmp/osaurus-gemma-proof/cache-after-mxfp4-agent-vmlxfix.json` shows
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `turbo_quant_compressions=3`, `kv_layer_count=3`,
    `rotating_kv_layer_count=12`, and `requires_disk_backed_restore=true`.
  - RAM sample after MXFP4 live proof:
    `/tmp/osaurus-gemma-proof/ps-after-mxfp4-vmlxfix.txt` recorded
    `RSS=597056 KB` for the dev app process.
  - Fresh direct tool proof from the unsigned dev app:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-forced-e8b5.json`
    returned tool `complete` with exact JSON args
    `{"summary":"qat mxfp4 e8b5 tool ok"}`.
  - Fresh tool-result continuation proof:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-tool-result-continuation-e8b5.json`
    returned visible text
    `The tool returned the summary "qat mxfp4 e8b5 tool ok".`
  - Fresh SWA cache telemetry after tool continuation:
    `/tmp/osaurus-gemma-proof/cache-after-mxfp4-tool-continuation-swa-live.json`
    shows `effective_kv_mode="turbo(3,3)"`,
    `paged_cache.enabled=false`, `turbo_quant_compressions=3`,
    `kv_layer_count=3`, `rotating_kv_layer_count=12`,
    `requires_disk_backed_restore=true`, and block disk enabled with stores.
  - RAM sample after the fresh MXFP4 proof:
    `/tmp/osaurus-gemma-proof/ps-after-tools-e8b5.txt`
    recorded `RSS=630480 KB` for the dev app process after JANG was unloaded
    and MXFP4 was current.
- vMLX added a focused Gemma SWA cache contract test: full-attention
  `KVCacheSimple` layers are TurboQuant-eligible, while sliding/SWA
  `RotatingKVCache` layers stay disk-backed.
- vMLX focused SwiftPM test attempt for that SWA contract is blocked before
  the filter runs by the existing local toolchain issue:
  `Tests/MLXPressPolicyTests/MLXPressLowRamPolicySourceTests.swift:4:8:
  error: no such module 'Testing'`.
- vMLX build proof for the final prefill-progress patch:
  `/tmp/osaurus-gemma-proof/vmlx-swift-build-solo-prefill-progress-4.log`
  reports `Build complete!` at SHA
  `e8b5ce989ff420447518a88dd1924d872fc37a35`.
- Osaurus test status:
  - `HTTPHandlerChatStreamingTests` now covers OpenAI-compatible streaming
    diagnostics. Red run before the fix:
    `/tmp/osaurus-gemma-proof/xcode-red-http-streaming-suite.log` failed
    `sse_path_uses_engine_stats_for_usage_chunk` and
    `sse_path_emits_prefill_progress_diagnostic_chunks`.
    Green run after the fix:
    `/tmp/osaurus-gemma-proof/xcode-green-http-streaming-suite.log` passed the
    full `HTTPHandlerChatStreamingTests` filter.
  - OpenAI SSE `stream_options.include_usage` now carries
    `usage.tokens_per_second` when the engine emits `StreamingStatsHint`.
  - OpenAI SSE now emits an Osaurus extension chunk with empty `choices` and
    top-level `osaurus_prefill` when the engine emits
    `StreamingPrefillProgressHint`. This lets Osaurus UI/API clients render
    determinate prefill progress without exposing the internal sentinel.
  - Focused cache/default/prefill/tool source tests are green after fixing the
    stale cache-default assertions:
    `/tmp/osaurus-gemma-proof/xcode-green-cache-prefill-focused-e8b5.log`
    reports `** TEST SUCCEEDED **` for `ServerRuntimeSettingsStoreTests`,
    `MLXBatchAdapterTests`, `StreamingHintTests`,
    `GenerationEventMapperTests`, `InferenceProgressManagerTests`,
    `RuntimePolicySourceTests`, `ToolSerializationStabilityTests`, and
    `MCPHTTPHandlerTests`. The log also verifies the workspace checkout of
    vMLX `e8b5ce989ff420447518a88dd1924d872fc37a35`.
  - The focused run caught a real paged-cache migration gap before green:
    old default-ish persisted rows with `liveKVCodec="none"` could keep
    `cache.pagedKV.enabled=true`. `ServerRuntimeSettingsStore` now repairs
    both old `none` and `engineSelected` default-ish rows to paged KV off while
    preserving the explicit live KV codec and block-disk L2 cache.
  - `xcodebuild build` for the dev app passes against the new vMLX pin.
  - The workspace `ToolSerializationStabilityTests` run initially exposed a
    bad test assertion: it treated a valid database-tool property named
    `type` as a non-string schema `type` field. The assertion is now narrowed
    to schema objects.
  - `swift test --filter ToolSerializationStabilityTests` is blocked in this
    environment by `no such module 'Testing'`, matching the known SwiftPM
    toolchain issue for packages using Apple's Testing module.
- Live app/API diagnostics proof from the freshly built Debug app:
  - Launched app:
    `build/XcodeDerivedData-gemma-streamdiag/Build/Products/Debug/osaurus.app`.
  - LaunchServices proof needed `OSU_MODELS_DIR=/Users/eric/models`; without
    it, the app stayed healthy but `/v1/models` was empty because the effective
    model directory resolved elsewhere.
  - `/tmp/osaurus-gemma-proof/models-streamdiag-modeldir-1337.json` advertised
    all ten requested OsaurusAI Gemma 4 QAT MXFP4/JANG_4M repos.
  - Token/s live API proof:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-l2-repeat-first-streamdiag.sse`
    includes `usage.tokens_per_second=2.9493`, and
    `/tmp/osaurus-gemma-proof/chat-mxfp4-l2-repeat-second-streamdiag.sse`
    includes `usage.tokens_per_second=18.098`.
  - Prefill progress and L2 disk prefix/cache proof with paged RAM cache off:
    `/tmp/osaurus-gemma-proof/chat-mxfp4-l2-long-first-streamdiag.sse` and
    `/tmp/osaurus-gemma-proof/chat-mxfp4-l2-long-second-streamdiag.sse` used an
    exact long-prefix repeat on `osaurusai--gemma-4-e2b-it-qat-mxfp4`.
    `/tmp/osaurus-gemma-proof/cache-after-l2-long-repeat-streamdiag.json`
    reports `disk_l2_hits=1`, `disk_l2_stores=4`, `disk_l2_misses=6`,
    `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
    `turbo_quant_compressions=3`, `kv_layer_count=3`,
    `rotating_kv_layer_count=12`, and `requires_disk_backed_restore=true`.
  - Final e8b5 live prefill proof:
    `/tmp/osaurus-gemma-proof/chat-jang4m-prefill-long-e8b5.sse` emitted 13
    OpenAI-compatible `osaurus_prefill` chunks on the default single-batch
    solo path before the answer `done.`. The progress sequence included
    `queued`, `prefill/running`, 512-token chunk increments through 5120 /
    5423 units, and `complete/decode_ready`. The final usage chunk recorded
    `prompt_tokens=6496`, `completion_tokens=2`, and
    `tokens_per_second=0.5986`.
  - Final e8b5 cache telemetry for the same prefill row:
    `/tmp/osaurus-gemma-proof/cache-after-prefill-long-jang4m-e8b5.json`
    reports `disk_l2_hits=1`, `disk_l2_stores=1`, `paged_hits=0`,
    `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
    `turbo_quant_compressions=1`, `kv_layer_count=3`,
    `rotating_kv_layer_count=12`, and `requires_disk_backed_restore=true`.
    The current model row is
    `osaurusai--gemma-4-e2b-it-qat-jang_4m` with
    `paged_cache.enabled=false` and `block_disk_store.enabled=true` with
    `hits=1`, `misses=1`, and `stores=1`.
  - Earlier repeated-prefix MXFP4 L2 proof:
    `/tmp/osaurus-gemma-proof/cache-after-l2-long-repeat-streamdiag.json`
    reports aggregate `disk_l2_hits=1`, `disk_l2_misses=6`,
    `disk_l2_stores=4`, `paged_hits=0`, and `paged_misses=0`.
    The current model row is `osaurusai--gemma-4-e2b-it-qat-mxfp4` with
    `effective_kv_mode="turbo(3,3)"`, `paged_cache.enabled=false`,
    `block_disk_store.enabled=true`, `block_disk_store.hits=1`, and
    `requires_disk_backed_restore=true`. This is the concrete proof that L2
    disk prefix caching still works with paged RAM cache off.
  - Final e8b5 tool cache telemetry:
    `/tmp/osaurus-gemma-proof/cache-after-tools-e8b5.json` reports MXFP4
    current with `effective_kv_mode="turbo(3,3)"`,
    `paged_cache.enabled=false`, `disk_l2_stores=2`, `paged_hits=0`,
    `paged_misses=0`, `kv_layer_count=3`, `rotating_kv_layer_count=12`, and
    `requires_disk_backed_restore=true`.
  - Short repeated prompts only produced L2 stores/misses with `disk_l2_hits=0`;
    the proven hit row requires a long enough shared prefix to cross the block
    reuse threshold.

## Prefill Progress Contract

- Progress units are prompt-processing work units. For text-only rows this is
  prompt tokens; cache restore counts restored prompt tokens, and prefill counts
  remaining prompt tokens consumed before first decode token.
- Osaurus stages:
  - `queued`: request admitted, total prompt-token count known when available.
  - `cacheLookup`: prefix/L2 lookup is running.
  - `cacheRestore`: cache hit restored prompt tokens from paged/L2/disk tiers.
  - `prefill`: uncached prompt work is running.
  - `complete`: prefill has seeded decode and the first token path can start.
- Calculation:
  `percent = min(100, max(0, completedUnitCount / totalUnitCount * 100))`.
  If `totalUnitCount == 0`, UI must render the stage as indeterminate rather
  than inventing a fake percent.
- Current proven wiring:
  vMLX `Generation.prefillProgress` -> Osaurus `ModelRuntimeEvent` ->
  `StreamingPrefillProgressHint` -> Chat UI `InferenceProgressManager` and
  OpenAI-compatible SSE `osaurus_prefill` chunks.
- Current proven status:
  vMLX BatchEngine emits stage-boundary progress and cache-restore counts, the
  common `LLMModel.prepare` chunk loop reports completed prompt units, VLM
  embedding chunk helpers report completed units, Gemma 4 reports chunked
  prefill progress from its token-plus-embedding prepare path, and the B=1 solo
  fast path now forwards `TokenIterator` prefill progress into the returned
  `Generation` stream. The e8b5 live Osaurus API row proves
  `osaurus_prefill` chunks before first token for a long Gemma QAT prompt.

Open prefill/TTFT work before checkpoint:

- Add or verify a first-class TTFT metric. Token/s is already in final SSE
  usage, but users feel the prefill wait before first token. For the matrix,
  record either engine-emitted TTFT or timestamp-derived TTFT from:
  request start, first `osaurus_prefill`, `complete/decode_ready`, first text
  delta, and final usage.
- Percent calculation must stay honest for every model type:
  - Text-only or text path: denominator is prompt token count after template
    rendering. Completed units are restored cache tokens plus prefilled prompt
    tokens.
  - Gemma VL image path: denominator must include the text tokens plus image
    embedding/prompt units known to the runtime. If exact image units are not
    known, render determinate text-token progress plus a labeled
    indeterminate media-embedding stage rather than faking 100%.
  - Gemma audio path: same rule as VL. If the runtime knows audio feature
    chunks, use them as units; otherwise show an indeterminate audio-embedding
    stage followed by determinate text-token prefill.
  - L2 cache restore: completed units should jump by restored prompt units so
    repeated-prefix rows visibly move faster instead of showing a long blind
    wait.
  - Multi-batch path: each request needs its own progress state keyed by
    request/conversation stream, not one global percent.
- UI must clear progress on first visible delta, cancellation, error, and final
  completion. Stale `Prefill 100%` state after generation is a UI bug.
- API clients get top-level `osaurus_prefill` chunks with empty `choices` so
  OpenAI-compatible stream parsers can ignore them, while Osaurus UI can render
  them. Do not hide progress inside text deltas.
- Final visual proof still needs a screenshot or log-backed UI observation
  during a deliberately slow/long prompt, not only SSE parsing.

## Remaining Proof Gates

## Clean-Main Checkpoint Proof - 2026-06-11 19:05 PT

Branch under test: `codex/gemma-cache-prefill-checkpoint-main`.

vMLX pin under test:
`a4aa133689417b924833610db0ff2732151d74cd`.

Clean-main app build:

- Unsigned Debug app build passed from the workspace:
  `/tmp/osaurus-gemma-proof/xcode-build-debug-app-main-a4aa-rerun1.log`
  ends with `** BUILD SUCCEEDED **`.
- Unsigned Debug app rebuild after restoring QAT-only scope also passed:
  `/tmp/osaurus-gemma-proof/xcode-build-debug-app-main-a4aa-rerun2.log`
  ends with `** BUILD SUCCEEDED **` and resolves `mlx-swift @ a4aa133`.
- Local gitignored unblocker for the build:
  `App/osaurus/Secrets.xcconfig` with empty telemetry/Sentry values. This file
  is intentionally not part of the PR.

Clean-main launch:

- App path:
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-main-app/Build/Products/Debug/osaurus.app`.
- Launched with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
  `OSAURUS_TEST_ROOT=/tmp/osaurus-keychain-free-gemma-main-a4aa-20260611-190223`,
  `OSU_MODELS_DIR=/Users/eric/models`, and `OSU_PORT=1337`.
- `/health` artifact:
  `/tmp/osaurus-gemma-proof/clean-main-health.json`.
  It reports `status="healthy"`, model root `/Users/eric/models`,
  `model_count=27`, and no loaded model before the smoke rows.
- `/v1/models` artifact:
  `/tmp/osaurus-gemma-proof/clean-main-models.json`.
  It advertises the requested Gemma QAT MXFP4/JANG_4M bundles. Extra local
  folders in the model root are ignored for this checkpoint.
- Runtime defaults artifact:
  `/tmp/osaurus-keychain-free-gemma-main-a4aa-20260611-190223/config/server-runtime.json`.
  It has `cache.pagedKV.enabled=false`, `cache.blockDisk.enabled=true`,
  `cache.legacyDisk.enabled=false`, `cache.prefix.enabled=true`, and
  `cache.liveKVCodec="engine_selected"`.

Clean-main direct tool-call proof:

- E2B MXFP4 forced OpenAI-compatible tool row passed:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-mxfp4-tool-forced.json`.
  It returned `finish_reason="tool_calls"`, tool name `complete`, and exact
  arguments `{"summary":"clean main mxfp4 tool ok"}`.
- E2B MXFP4 tool-result continuation passed:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-mxfp4-tool-continuation.json`.
  It returned visible text and `tokens_per_second=6.9944`.
- E2B JANG_4M forced OpenAI-compatible tool row passed:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-jang4m-tool-forced.json`.
  It returned `finish_reason="tool_calls"`, tool name `complete`, and exact
  arguments `{"summary":"clean main jang4m tool ok"}`.
- E2B JANG_4M tool-result continuation passed:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-jang4m-tool-continuation.json`.
  It returned visible text and `tokens_per_second=8.0922`.

Clean-main prefill/cache proof:

- Long JANG_4M streaming prompt:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-jang4m-prefill-long.sse`.
  It emitted `osaurus_prefill` chunks from `queued` through
  `complete 12622/12622 decode_ready` before the first content token
  `checkpoint`.
- Repeated long JANG_4M prompt:
  `/tmp/osaurus-gemma-proof/clean-main-chat-e2b-jang4m-prefill-long-repeat.sse`.
- Cache after repeated long prompt:
  `/tmp/osaurus-gemma-proof/clean-main-cache-after-prefill-repeat.json`.
  It reports `disk_l2_hits=1`, `block_disk_store.hits=1`,
  `paged_hits=0`, `paged_misses=0`, `effective_kv_mode="turbo(3,3)"`,
  `turbo_quant_compressions=4`, `kv_layer_count=3`,
  `rotating_kv_layer_count=12`, and `requires_disk_backed_restore=true`.
- RSS sample after the direct tool rows:
  `/tmp/osaurus-gemma-proof/clean-main-ps-after-tools.txt`.
  It records the clean-main app process at about 1.85 GB RSS after the E2B
  tool rows.

Clean-main agent-loop status:

- Built-in default-agent route accepted the clean-main JANG_4M model and
  streamed a response:
  `/tmp/osaurus-gemma-proof/clean-main-agent-run-e2b-jang4m.sse`.
- Status is `PARTIAL`: the route did not emit a tool call for the
  `complete` instruction and answered directly. Direct OpenAI-compatible tool
  calling is proven for MXFP4 and JANG_4M above, but final UI/agent-loop proof
  still needs either a chat UI run or an agent-loop request that actually emits
  and executes a tool call.
- Superseded status update: commit `5a885570` now has forced
  `/agents/{defaultUUID}/run` agent-loop execution proof for 12B JANG_4M and
  12B MXFP4 in the current-tree proof section above. The older clean-main E2B
  row remains useful as the historical failure artifact, not the current
  checkpoint state.

Exact rebuilt-app proof after QAT-only scope correction:

- Discarded artifact warning: live `rerun2` API artifacts were not counted
  because port `1337` was still served by an older Debug app path. The counted
  live proof below uses process `5718` from:
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-main-app/Build/Products/Debug/osaurus.app/Contents/MacOS/osaurus`.
- Health artifact:
  `/tmp/osaurus-gemma-proof/health-main-a4aa-rerun3.json`.
  It reports `status="healthy"`, model root `/Users/eric/models`, and no
  loaded model before the rerun3 rows.
- Process/path proof:
  `/tmp/osaurus-gemma-proof/pgrep-before-live-main-a4aa-rerun3.txt`.
- E2B JANG_4M forced OpenAI-compatible tool row passed:
  `/tmp/osaurus-gemma-proof/chat-tool-jang4m-main-a4aa-rerun3.json`.
  It returned `finish_reason="tool_calls"`, tool name `complete`, and exact
  arguments `{"summary":"qat jang4m main a4aa rerun3 tool ok"}`.
- E2B MXFP4 forced OpenAI-compatible tool row passed:
  `/tmp/osaurus-gemma-proof/chat-tool-mxfp4-main-a4aa-rerun3.json`.
  It returned `finish_reason="tool_calls"`, tool name `complete`, and exact
  arguments `{"summary":"qat mxfp4 main a4aa rerun3 tool ok"}`.
- E2B JANG_4M tool-result continuation passed:
  `/tmp/osaurus-gemma-proof/chat-tool-result-jang4m-main-a4aa-rerun3.json`.
  It returned visible text
  `The tool returned the summary: "qat jang4m main a4aa rerun3 tool ok".`
  with `tokens_per_second=18.5051`.
- E2B MXFP4 tool-result continuation passed:
  `/tmp/osaurus-gemma-proof/chat-tool-result-mxfp4-main-a4aa-rerun3.json`.
  It returned visible text
  `The tool returned the summary "qat mxfp4 main a4aa rerun3 tool ok".`
  with `tokens_per_second=17.0711`.
- E2B JANG_4M long-prefix prefill/L2 proof:
  `/tmp/osaurus-gemma-proof/chat-prefill-jang4m-main-a4aa-rerun3-first.sse`,
  `/tmp/osaurus-gemma-proof/chat-prefill-jang4m-main-a4aa-rerun3-repeat.sse`,
  and
  `/tmp/osaurus-gemma-proof/cache-after-prefill-jang4m-main-a4aa-rerun3.json`.
  The stream emitted 26 `osaurus_prefill` chunks per run before the visible
  answer `checkpoint`; cache telemetry reports `effective_kv_mode="turbo(3,3)"`,
  `paged_cache.enabled=false`, `block_disk_store.hits=1`,
  `block_disk_store.stores=2`, and `turbo_quant_compressions=2`.
- E2B MXFP4 long-prefix prefill/L2 proof:
  `/tmp/osaurus-gemma-proof/chat-prefill-mxfp4-main-a4aa-rerun3-first.sse`,
  `/tmp/osaurus-gemma-proof/chat-prefill-mxfp4-main-a4aa-rerun3-repeat.sse`,
  and
  `/tmp/osaurus-gemma-proof/cache-after-prefill-mxfp4-main-a4aa-rerun3.json`.
  The stream emitted 26 `osaurus_prefill` chunks per run before the visible
  answer `checkpoint`; cache telemetry reports `effective_kv_mode="turbo(3,3)"`,
  `paged_cache.enabled=false`, `block_disk_store.hits=1`,
  `block_disk_store.stores=2`, and `turbo_quant_compressions=2`.
- RSS/health after rerun3 E2B live rows:
  `/tmp/osaurus-gemma-proof/ps-after-e2b-live-main-a4aa-rerun3.txt` records
  `RSS=711072 KB`, and
  `/tmp/osaurus-gemma-proof/health-after-e2b-live-main-a4aa-rerun3.json`
  reports current model `osaurusai--gemma-4-e2b-it-qat-mxfp4` with RAM
  verdict `ok`.

QAT-only harness smoke after source-model scope correction:

- The non-QAT/source Gemma lane is explicitly out of scope for this checkpoint.
  Do not run BF16/source bundles or treat source expert-key failures such as
  `Unhandled keys ["down_proj", "gate_up_proj"] ... TextExperts` as blockers
  for QAT MXFP4/JANG_4M proof.
- First filtered `AgentLoop` smoke for
  `osaurusai--gemma-4-e2b-it-qat-jang_4m` built `osaurus-evals` but failed
  before model execution because MLX could not find `default.metallib`:
  `/tmp/osaurus-gemma-proof/evals-agentloop-e2b-jang4m-write-new-file-3efacd1f.log`.
  This is a local SwiftPM/MLX bootstrap issue, not a source-model load issue.
- Metal bootstrap was repaired for the eval binary by running the pinned vMLX
  prep script and installing `default.metallib` / `mlx.metallib` beside
  `Packages/OsaurusEvals/.build/arm64-apple-macosx/debug/osaurus-evals`:
  `/tmp/osaurus-gemma-proof/prepare-mlx-metal-evals-checkout-3efacd1f.log`
  and
  `/tmp/osaurus-gemma-proof/prepare-mlx-metal-evals-binarydir-3efacd1f.log`.
- Rerun command:

```sh
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-evals-gemma-e2b-jang-rerun-1781239515 \
OSU_MODELS_DIR=/Users/eric/models \
OSAURUS_DISABLE_MEMORY_VECTOR_SEARCH=1 \
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentLoop \
  --model osaurusai--gemma-4-e2b-it-qat-jang_4m \
  --filter write-new-file \
  --startup-timeout 180 \
  --out /tmp/osaurus-gemma-proof/evals-agentloop-e2b-jang4m-write-new-file-3efacd1f-rerun.json \
  -v
```

- Result:
  `/tmp/osaurus-gemma-proof/evals-agentloop-e2b-jang4m-write-new-file-3efacd1f-rerun.json`
  passed 1/1. The model called `file_write` once, produced no tool errors,
  and created `TODO.md` with the required unchecked items `write tests`,
  `update docs`, and `tag release`.
- Paired E2B MXFP4 rerun after the same eval bootstrap repair:

```sh
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-evals-gemma-e2b-mxfp4-rerun-1781239642 \
OSU_MODELS_DIR=/Users/eric/models \
OSAURUS_DISABLE_MEMORY_VECTOR_SEARCH=1 \
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentLoop \
  --model osaurusai--gemma-4-e2b-it-qat-mxfp4 \
  --filter write-new-file \
  --startup-timeout 180 \
  --out /tmp/osaurus-gemma-proof/evals-agentloop-e2b-mxfp4-write-new-file-915cdab1.json \
  -v
```

- MXFP4 result:
  `/tmp/osaurus-gemma-proof/evals-agentloop-e2b-mxfp4-write-new-file-915cdab1.json`
  passed 1/1. The model called `file_write` once, produced no tool errors,
  and created `TODO.md` with the required unchecked items. The eval final text
  was blank, so count this as a harness tool/outcome pass only; do not use it
  as visible-chat quality proof.
- This proves the QAT E2B JANG_4M and MXFP4 models can run at least one real
  `docs/HARNESS_COMPATIBILITY.md` AgentLoop case through the in-process
  OsaurusEvals harness. It does not complete full AgentLoop/AgentLoopFrontier
  scoring for all ten QAT bundles.

- Expand the required harness suites from the one-case smoke to the full QAT
  matrix. Do not mark QAT harness scoring complete until the commands below run
  successfully for the QAT MXFP4/JANG_4M target set and the reports are
  recorded.
- Run the required harness suites for each QAT target model:

```sh
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentLoopFrontier \
  --model <prefix>/<model-id> \
  --out build/eval-reports/<model>-frontier.json

swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentLoop \
  --model <prefix>/<model-id> \
  --out build/eval-reports/<model>-agentloop.json
```

- Treat `SandboxFrontier` as an off-CI/extra lane unless the sandbox host and
  entitlement-signed CLI are available.
- Run Chat UI and server/API rows for Gemma MXFP4/JANG_4M with cache telemetry
  proving paged RAM off, disk/L2 on, and TurboQuant KV on where valid.
- Run QAT MXFP4 and JANG_4M harness rows and record scores, token/s, cache
  topology, memory footprint, and multi-turn visible behavior. Improve model
  or runtime behavior only where the harness score/logs show a real failure.
- Current full AgentLoop score for
  `osaurusai--gemma-4-e2b-it-qat-jang_4m` on PR head `e03cecf9`:
  `/tmp/osaurus-gemma-proof/pr1469-e03cecf9-harness-20260612T095729Z/e2b-jang4m-agentloop.json`
  completed all 17 `Packages/OsaurusEvals/Suites/AgentLoop` cases with
  `13 passed`, `4 failed`, `0 skipped`, and `0 errored`. The run used
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
  `OSU_MODELS_DIR=/Users/eric/models`,
  `OSAURUS_DISABLE_MEMORY_VECTOR_SEARCH=1`, and isolated test root
  `/tmp/osaurus-gemma-proof/pr1469-e03cecf9-harness-20260612T095729Z/test-root-e2b-jang4m-agentloop`.
  It executed real tool traffic across `file_read`, `file_write`,
  `file_edit`, `file_search`, `shell_run`, `todo`, `clarify`, `complete`, and
  `capabilities_load`. Suite-wide tool usage was:
  `capabilities_load=1`, `clarify=1`, `complete=5`, `file_edit=4`,
  `file_read=19`, `file_search=1`, `file_write=5`, `shell_run=5`, and
  `todo=1`. The isolated `cache/kv_v2` directory contained 53 `.safetensors`
  L2 blocks totaling about 1.5 GB by the end of the run.
- Current AgentLoop failures for E2B JANG_4M are real model/runtime findings,
  not harness bootstrap failures:
  `agent_loop.compaction-stress` did not record compaction and missed `log4`;
  `agent_loop.duplicate-call-avoidance` read the file once but answered the
  wrong sum and had visible character drift; `agent_loop.search-then-multi-file-edit`
  stopped after `file_search` and left `fetchDataV1`; and
  `agent_loop.todo-discipline-multistep` completed file edits but never updated
  the todo list with a checked item before completion. Multiple passing and
  failing finals also show visible spelling/character corruption such as
  `tlog2.xt`, `thfie`, `numbler`, `Efxtrat`, `Tlhe`, `fethDataV1`,
  `prjeoct`, and `recquested`. This keeps full harness scoring and visible
  text integrity `PARTIAL`; do not promote the QAT harness lane until these
  failures are understood and fixed without prompt coercion or hidden sampler
  changes.
- Token/s is now exposed through OpenAI-compatible SSE usage chunks when
  `stream_options.include_usage=true`. Add normal visible-generation token/s
  rows for every model family before merge-ready wording.
- Prefill progress is wired through vMLX single-batch and scheduler paths,
  Osaurus runtime events, the Chat UI manager, and OpenAI-compatible SSE
  diagnostic chunks. The e8b5 API row proves determinate progress chunks before
  first token; final visual proof still needs a Chat UI observation showing the
  same percentage during a slow/long prompt.
- Final completion gate is app-facing, not source-only:
  - Build the unsigned/dev Osaurus app without keychain/signing prompts.
  - Load a Gemma 4 QAT model from `~/models`.
  - Chat with it and verify coherent visible output.
  - Exercise a real tool call inside Osaurus and verify exact tool
    name/arguments plus tool-result continuation.
  - Capture token/s, cache topology, prefill progress visibility, and RAM /
    physical-footprint observations during load and generation.

## Inventory Status

- `~/models` currently contains the 10 requested QAT MXFP4/JANG_4M repos.
- Only these ten QAT bundles count for this checkpoint.

## 2026-06-11 Release-App Crash Checkpoint

This checkpoint remains QAT-only. Do not load BF16/source Gemma bundles, and do
not treat the source expert-key failure
`Unhandled keys ["down_proj", "gate_up_proj"] ... TextExperts` as part of this
workstream. That error belongs to the removed source-model lane and should stay
out of the merge gate for Gemma 4 QAT MXFP4/JANG_4M.

The first keychain-free Release app build at Osaurus `d34f5ffa` and vMLX
`a4aa133689417b924833610db0ff2732151d74cd` launched successfully with
`OSU_MODELS_DIR=/Users/eric/models`, advertised all ten requested QAT bundles,
and reported the desired cache policy before model load:

- `/tmp/osaurus-gemma-proof/health-release-goal-d34f5ffa.json`
- `/tmp/osaurus-gemma-proof/models-release-goal-d34f5ffa.json`
- `/tmp/osaurus-gemma-proof/cache-before-release-goal-d34f5ffa.json`
- runtime config:
  `/tmp/osaurus-keychain-free-gemma-goal-d34f5ffa-direct-20260611-220034/config/server-runtime.json`

Those artifacts showed `paged_kv_enabled=false`, `block_disk_enabled=true`,
`legacy_disk_enabled=false`, `prefix_enabled=true`, and
`live_kv_codec="engine_selected"`.

The first real 12B JANG_4M forced tool-call request then crashed the Release app
before a complete agent/tool answer:

- request:
  `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-release-goal-d34f5ffa.request.json`
- partial SSE:
  `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-release-goal-d34f5ffa.sse`
- crash report:
  `~/Library/Logs/DiagnosticReports/osaurus-2026-06-11-220201.ips`

Root cause from the crash stack: vMLX prefill progress used
`TaskLocal.withValue` in the optimized generation path and faulted in
`swift_task_localValuePushImpl` before `TokenIterator` could safely run the
Gemma QAT request. This is a real Release-app regression in the prefill progress
wiring, not a source-model loader issue.

vMLX fix under test:

- reachable remote commit:
  `dc52096743215a153522c9b260c8191f133d7288`
- branch:
  `osaurus-ai/vmlx-swift codex/gemma-prefill-tasklocal-crash`
- change:
  replace the prefill progress `@TaskLocal` reporter with a scoped
  thread-dictionary handler in `PrefillProgressReporter.withHandler(...)`, and
  call that helper from `Evaluate.swift` and `BatchEngine.swift`.
- source proof:
  `/tmp/osaurus-gemma-proof/vmlx-release-build-MLXLMCommon-prefill-reporter-fix.log`
  ends with `Build of target: 'MLXLMCommon' complete!`.
- blocked source test:
  the narrow vMLX Swift test was blocked by the unrelated test-target import
  error `no such module 'Testing'`; do not count that as passed.

Osaurus now pins the reachable vMLX fix revision in:

- `Packages/OsaurusCore/Package.swift`
- `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift`

Current Release app rebuild proof:

- status:
  `/tmp/osaurus-gemma-proof/xcode-build-release-app-goal-dc520967.status`
- build log:
  `/tmp/osaurus-gemma-proof/xcode-build-release-app-goal-dc520967.log`
- app:
  `/private/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-goal-dc520967-release/Build/Products/Release/osaurus.app`
- built vMLX checkout:
  `/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-goal-dc520967-release/SourcePackages/checkouts/vmlx-swift`
  at `dc52096743215a153522c9b260c8191f133d7288`.

The built checkout was inspected after build. `PrefillProgressReporter.swift`
uses `PrefillProgressReporter.withHandler(...)`, and `Evaluate.swift` /
`BatchEngine.swift` call that helper. The old prefill
`PrefillProgressReporter.$current.withValue(...)` TaskLocal path is absent from
the inspected files.

Focused source-policy proof:

- status:
  `/tmp/osaurus-gemma-proof/swift-test-runtime-policy-source-dc520967.status`
- log:
  `/tmp/osaurus-gemma-proof/swift-test-runtime-policy-source-dc520967.log`
- command:
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/OsaurusCore --filter RuntimePolicySourceTests`
- result:
  `Suite "Runtime source policy" passed`; `Test run with 84 tests in 1 suite passed`.

The rebuilt Release app launched keychain-free with isolated state:

- launch log:
  `/tmp/osaurus-gemma-proof/osaurus-release-goal-dc520967-direct.log`
- root:
  `/tmp/osaurus-gemma-proof/osaurus-release-goal-dc520967-root.txt`
- health:
  `/tmp/osaurus-gemma-proof/health-release-goal-dc520967.json`
- models:
  `/tmp/osaurus-gemma-proof/models-release-goal-dc520967.json`
- cache before load:
  `/tmp/osaurus-gemma-proof/cache-before-release-goal-dc520967.json`
- runtime config:
  `/tmp/osaurus-keychain-free-gemma-goal-dc520967-direct-20260611-222213/config/server-runtime.json`

Runtime config and `/admin/cache-stats` prove the current default cache policy:
`pagedKV.enabled=false`, `blockDisk.enabled=true`,
`legacyDisk.enabled=false`, `prefix.enabled=true`, and
`liveKVCodec="engine_selected"`.

Release app QAT tool/caching proof:

- 12B JANG_4M first run:
  `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-release-goal-dc520967.sse`
  completed the `complete` tool and emitted exactly
  `release app 12b jang4m default agent tool proven.`. The old Release crash
  did not reproduce.
- 12B JANG_4M repeat:
  `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-release-goal-dc520967-repeat.sse`
  completed the same tool row. Cache telemetry
  `/tmp/osaurus-gemma-proof/agent-run-12b-jang4m-release-goal-dc520967-repeat.cache.json`
  reports `disk_l2_hits=1`, `disk_l2_stores=1`, and
  `paged_hits=0` / `paged_misses=0`.
- 12B JANG_4M RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-run-12b-jang4m-release-goal-dc520967-repeat.txt`
  reports `RSS=7095696 KB` after the repeated row.
- 12B MXFP4 exact forced-tool row:
  `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-release-goal-dc520967-exact.sse`
  completed the `complete` tool and emitted exactly
  `release app 12b mxfp4 default agent tool proven`.
- 12B MXFP4 repeat:
  `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-release-goal-dc520967-exact-repeat.sse`
  completed the same tool row. Cache telemetry
  `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-release-goal-dc520967-exact-repeat.cache.json`
  reports `disk_l2_hits=1`, `disk_l2_stores=2`, and
  `paged_hits=0` / `paged_misses=0`.
- 12B MXFP4 RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-run-12b-mxfp4-release-goal-dc520967-exact-repeat.txt`
  reports `RSS=550080 KB` after the repeated row while the model remains
  health-current.

Prefill progress proof:

- request:
  `/tmp/osaurus-gemma-proof/chat-prefill-12b-mxfp4-release-goal-dc520967.request.json`
- SSE:
  `/tmp/osaurus-gemma-proof/chat-prefill-12b-mxfp4-release-goal-dc520967.sse`
- timing:
  `/tmp/osaurus-gemma-proof/chat-prefill-12b-mxfp4-release-goal-dc520967.timing.json`
- cache:
  `/tmp/osaurus-gemma-proof/chat-prefill-12b-mxfp4-release-goal-dc520967.cache.json`

The SSE emitted `osaurus_prefill` before first token with determinate progress:
`queued 0/3224`, `prefill 0/3224`, chunk updates at `512`, `1024`,
`1536`, `2048`, `2560`, `3072`, then `complete 3224/3224`. It then generated
`prefill visible` and emitted usage with `prompt_tokens=4816`,
`completion_tokens=7`, `total_tokens=4823`, and
`tokens_per_second=5.8165`.

Current boundary:

- This checkpoint now has Release-app QAT proof for 12B JANG_4M and 12B MXFP4
  tool-call execution, disk L2 restore/hit telemetry, paged RAM KV disabled,
  and visible SSE prefill progress.
- It is still not a full merge gate for all ten QAT bundles. E2B/E4B/26B/31B
  live app rows, VL rows, full harness scoring, and Chat UI visual confirmation
  still need to be run before final release wording.
- The period-bearing MXFP4 forced-tool row
  `/tmp/osaurus-gemma-proof/agent-run-12b-mxfp4-release-goal-dc520967.sse`
  completed the tool but emitted the final text without the period, so keep
  strict punctuation fidelity for that exact prompt marked partial.

## 2026-06-11 Agent-Loop E4B QAT Checkpoint

This checkpoint is still QAT-only and still excludes BF16/source Gemma bundles.
It extends the Release-app proof from the 12B rows to E4B JANG_4M and E4B
MXFP4, and it specifically closes the gap where a `/agents/{id}/run` row could
stream final text without proving that the server-side agent loop actually
executed a tool.

Fresh PR build:

- Osaurus commit:
  `f8f02857e87d96dbb08f238c2c4f1fc7f75a5bb3`
- build status:
  `/tmp/osaurus-gemma-proof/xcode-build-release-app-agent-loop-f8f02857.status`
- build log:
  `/tmp/osaurus-gemma-proof/xcode-build-release-app-agent-loop-f8f02857.log`
- built app:
  `/private/tmp/osaurus-gemma-checkpoint-main/build/XcodeDerivedData-gemma-agent-loop-f8f02857-release/Build/Products/Release/osaurus.app`
- built vMLX checkout:
  `dc52096743215a153522c9b260c8191f133d7288`

The build completed through `MLXLMCommon`, `MLXLLM`, `MLXVLM`, and
`OsaurusCore`, then ad-hoc sealed the app without a signing identity or
Keychain-backed certificate.

Fresh app launch:

- launch log:
  `/tmp/osaurus-gemma-proof/osaurus-agent-loop-f8f02857-direct.log`
- root:
  `/tmp/osaurus-gemma-proof/osaurus-agent-loop-f8f02857-root.txt`
- health:
  `/tmp/osaurus-gemma-proof/health-agent-loop-f8f02857.json`
- models:
  `/tmp/osaurus-gemma-proof/models-agent-loop-f8f02857.json`
- cache before load:
  `/tmp/osaurus-gemma-proof/cache-before-agent-loop-f8f02857.json`
- runtime config:
  `/tmp/osaurus-keychain-free-gemma-agent-loop-f8f02857-20260611-224053/config/server-runtime.json`

The fresh runtime config proves the intended defaults: `pagedKV.enabled=false`,
`blockDisk.enabled=true`, `legacyDisk.enabled=false`, `prefix.enabled=true`,
`enableSSMReDerive=true`, `liveKVCodec="engine_selected"`,
`storedKVCodec="auto"`, and multimodal `requireMediaSaltForCache=true`.
`/v1/models` advertised all ten requested QAT Gemma bundles.

E4B JANG_4M agent-loop tool proof:

- request:
  `/tmp/osaurus-gemma-proof/agent-loop-e4b-jang4m-f8f02857.request.json`
- first SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-e4b-jang4m-f8f02857.sse`
- repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-e4b-jang4m-f8f02857-repeat.sse`
- repeat cache:
  `/tmp/osaurus-gemma-proof/agent-loop-e4b-jang4m-f8f02857-repeat.cache.json`
- repeat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-loop-e4b-jang4m-f8f02857-repeat.txt`

Both SSE files include `osaurus_agent_tool` frames for `complete` with
`phase="started"` and `phase="completed"`, `is_error=false`,
`end_run=true`, then final visible content exactly
`agent loop e4b jang4m tool execution proven.`. The SSE files do not contain
internal U+FFFE tool sentinels, raw `tool:` / `args:` / `done:` sentinels,
`<think>` tags, or tool/reasoning marker leakage.

The E4B JANG_4M repeat cache reports `disk_l2_hits=1`,
`disk_l2_stores=1`, `paged_hits=0`, and `paged_misses=0`. The topology is 24
layers: 4 full KV layers and 20 rotating KV layers, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=false`, and `turbo_quant_kv_layer_count=0`.
The model's `effective_kv_mode` reports `turbo(3,3)` while the concrete
topology remains rotating KV plus disk-backed restore. The app `ps` row after
repeat reports `RSS=2908112 KB`.

E4B MXFP4 agent-loop tool proof:

- request:
  `/tmp/osaurus-gemma-proof/agent-loop-e4b-mxfp4-f8f02857.request.json`
- first SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-e4b-mxfp4-f8f02857.sse`
- repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-e4b-mxfp4-f8f02857-repeat.sse`
- repeat cache:
  `/tmp/osaurus-gemma-proof/agent-loop-e4b-mxfp4-f8f02857-repeat.cache.json`
- repeat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-loop-e4b-mxfp4-f8f02857-repeat.txt`

Both SSE files include `osaurus_agent_tool` frames for `complete` with
`phase="started"` and `phase="completed"`, `is_error=false`,
`end_run=true`, then final visible content exactly
`agent loop e4b mxfp4 tool execution proven.`. The SSE files do not contain
internal U+FFFE tool sentinels, raw `tool:` / `args:` / `done:` sentinels,
`<think>` tags, or tool/reasoning marker leakage.

The E4B MXFP4 repeat cache reports `disk_l2_hits=1`,
`disk_l2_stores=1`, `paged_hits=0`, and `paged_misses=0`. The topology is 24
layers: 4 full KV layers and 20 rotating KV layers, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=false`, and `turbo_quant_kv_layer_count=0`.
The model's `effective_kv_mode` reports `turbo(3,3)` while the concrete
topology remains rotating KV plus disk-backed restore. The app `ps` row after
repeat reports `RSS=543360 KB`.

Token/s and prefill progress proof for the same E4B checkpoint:

- E4B JANG_4M request:
  `/tmp/osaurus-gemma-proof/chat-e4b-jang4m-token-rate-f8f02857.request.json`
- E4B JANG_4M SSE:
  `/tmp/osaurus-gemma-proof/chat-e4b-jang4m-token-rate-f8f02857.sse`
- E4B JANG_4M cache:
  `/tmp/osaurus-gemma-proof/chat-e4b-jang4m-token-rate-f8f02857.cache.json`
- E4B MXFP4 request:
  `/tmp/osaurus-gemma-proof/chat-e4b-mxfp4-token-rate-f8f02857.request.json`
- E4B MXFP4 SSE:
  `/tmp/osaurus-gemma-proof/chat-e4b-mxfp4-token-rate-f8f02857.sse`
- E4B MXFP4 cache:
  `/tmp/osaurus-gemma-proof/chat-e4b-mxfp4-token-rate-f8f02857.cache.json`

The JANG_4M chat SSE emits `osaurus_prefill` queued/prefill/complete progress
from `0/29` to `29/29`, then visible content
`e4b jang4m token rate visible.`, and usage with `prompt_tokens=20`,
`completion_tokens=10`, `total_tokens=30`, `tokens_per_second=75.3915`.

The MXFP4 chat SSE emits `osaurus_prefill` queued/prefill/complete progress
from `0/30` to `30/30`, then visible content
`e4b mxfp4 token rate visible.`, and usage with `prompt_tokens=20`,
`completion_tokens=11`, `total_tokens=31`, `tokens_per_second=82.7628`.

Boundary after this checkpoint:

- E4B JANG_4M and E4B MXFP4 now have fresh PR-build agent-loop proof with
  actual `complete` tool execution, no sentinel/reasoning/tool leakage, disk L2
  hit on repeat, paged KV disabled, prefill progress on chat, and token/s from
  ordinary chat generation.
- `/agents/{id}/run` tool-intercept SSE currently does not emit a usage chunk.
  Token/s for the E4B rows is therefore recorded from `/v1/chat/completions`
  on the same model/runtime checkpoint, not from the tool-intercept agent SSE.
- This is still not the full ten-model matrix. E2B, 26B A4B, and 31B QAT rows,
  plus VL/audio rows, Chat UI visual proof, lower-spec physical-footprint proof,
  and full harness scoring remain open.

## 2026-06-11 Agent-Loop 26B A4B QAT Checkpoint

This checkpoint keeps the same QAT-only scope as the 12B and E4B rows. It does
not load BF16/source Gemma bundles. It extends the fresh Release-app
agent-loop proof to the 26B A4B JANG_4M and 26B A4B MXFP4 QAT bundles using
the same app build and keychain-free runtime listed in the E4B checkpoint.

26B A4B JANG_4M agent-loop tool proof:

- request:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-jang4m-f8f02857.request.json`
- first SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-jang4m-f8f02857.sse`
- first timing:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-jang4m-f8f02857.time.txt`
- repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-jang4m-f8f02857-repeat.sse`
- repeat timing:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-jang4m-f8f02857-repeat.time.txt`
- repeat cache:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-jang4m-f8f02857-repeat.cache.json`
- repeat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-loop-26b-a4b-jang4m-f8f02857-repeat.txt`

Both SSE files include `osaurus_agent_tool` frames for `complete` with
`phase="started"` and `phase="completed"`, `is_error=false`, and
`end_run=true`, then final visible content exactly
`agent loop 26b a4b jang4m tool execution proven.`. The leak scan found only
the expected tool trace and final text: no internal U+FFFE tool sentinels, raw
`tool:` / `args:` / `done:` sentinels, `<think>` tags, or tool/reasoning marker
leakage.

The repeat cache reports `disk_l2_hits=1`, `disk_l2_misses=7`,
`disk_l2_stores=1`, `paged_hits=0`, `paged_misses=0`, and
`companion_misses=1`. The topology is 30 layers: 5 full KV layers and 25
rotating KV layers, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=false`, and `turbo_quant_kv_layer_count=0`.
The model's `effective_kv_mode` reports `turbo(3,3)` while the concrete
topology remains rotating KV plus disk-backed restore. The first agent-loop row
took `6.31 real`; the repeat row took `4.10 real`. The app `ps` row after the
repeat reports `RSS=13287344 KB`.

26B A4B MXFP4 agent-loop tool proof:

- request:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-mxfp4-f8f02857.request.json`
- first SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-mxfp4-f8f02857.sse`
- first timing:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-mxfp4-f8f02857.time.txt`
- repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-mxfp4-f8f02857-repeat.sse`
- repeat timing:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-mxfp4-f8f02857-repeat.time.txt`
- repeat cache:
  `/tmp/osaurus-gemma-proof/agent-loop-26b-a4b-mxfp4-f8f02857-repeat.cache.json`
- repeat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-loop-26b-a4b-mxfp4-f8f02857-repeat.txt`

Both SSE files include `osaurus_agent_tool` frames for `complete` with
`phase="started"` and `phase="completed"`, `is_error=false`, and
`end_run=true`, then final visible content exactly
`agent loop 26b a4b mxfp4 tool execution proven.`. The leak scan found only
the expected tool trace and final text: no internal U+FFFE tool sentinels, raw
`tool:` / `args:` / `done:` sentinels, `<think>` tags, or tool/reasoning marker
leakage.

The repeat cache reports `disk_l2_hits=1`, `disk_l2_misses=7`,
`disk_l2_stores=1`, `paged_hits=0`, `paged_misses=0`, and
`companion_misses=1`. The topology is 30 layers: 5 full KV layers and 25
rotating KV layers, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=false`, and `turbo_quant_kv_layer_count=0`.
The model's `effective_kv_mode` reports `turbo(3,3)` while the concrete
topology remains rotating KV plus disk-backed restore. The first agent-loop row
took `4.40 real`; the repeat row took `2.16 real`. The app `ps` row after the
repeat reports `RSS=744912 KB`.

Token/s and prefill progress proof for the same 26B A4B checkpoint:

- 26B A4B JANG_4M request:
  `/tmp/osaurus-gemma-proof/chat-26b-a4b-jang4m-token-rate-f8f02857.request.json`
- 26B A4B JANG_4M SSE:
  `/tmp/osaurus-gemma-proof/chat-26b-a4b-jang4m-token-rate-f8f02857.sse`
- 26B A4B JANG_4M cache:
  `/tmp/osaurus-gemma-proof/chat-26b-a4b-jang4m-token-rate-f8f02857.cache.json`
- 26B A4B JANG_4M timing:
  `/tmp/osaurus-gemma-proof/chat-26b-a4b-jang4m-token-rate-f8f02857.time.txt`
- 26B A4B JANG_4M post-chat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-chat-26b-a4b-jang4m-token-rate-f8f02857.txt`
- 26B A4B MXFP4 request:
  `/tmp/osaurus-gemma-proof/chat-26b-a4b-mxfp4-token-rate-f8f02857.request.json`
- 26B A4B MXFP4 SSE:
  `/tmp/osaurus-gemma-proof/chat-26b-a4b-mxfp4-token-rate-f8f02857.sse`
- 26B A4B MXFP4 cache:
  `/tmp/osaurus-gemma-proof/chat-26b-a4b-mxfp4-token-rate-f8f02857.cache.json`
- 26B A4B MXFP4 timing:
  `/tmp/osaurus-gemma-proof/chat-26b-a4b-mxfp4-token-rate-f8f02857.time.txt`

The JANG_4M chat SSE emits `osaurus_prefill` queued/prefill/complete progress
from `0/33` to `33/33`, then visible content
`26b a4b jang4m token rate visible.`, and usage with `prompt_tokens=21`,
`completion_tokens=17`, `total_tokens=38`, and `tokens_per_second=87.3053`.
The post-chat app `ps` row reports `RSS=13300928 KB`.

The MXFP4 chat SSE emits `osaurus_prefill` queued/prefill/complete progress
from `0/34` to `34/34`, then visible content
`26b a4b mxfp4 token rate visible.`, and usage with `prompt_tokens=21`,
`completion_tokens=18`, `total_tokens=39`, and `tokens_per_second=97.2085`.

Boundary after this checkpoint:

- 26B A4B JANG_4M and 26B A4B MXFP4 now have fresh PR-build agent-loop proof
  with actual `complete` tool execution, no sentinel/reasoning/tool leakage,
  disk L2 hit on repeat, paged KV disabled, prefill progress on chat, and
  token/s from ordinary chat generation.
- `/agents/{id}/run` tool-intercept SSE still does not emit a usage chunk.
  Token/s for the 26B A4B rows is therefore recorded from
  `/v1/chat/completions` on the same model/runtime checkpoint, not from the
  tool-intercept agent SSE.
- The JANG_4M 26B A4B physical footprint is still heavy on this Mac
  (`RSS=13287344 KB` after repeat, `RSS=13300928 KB` after token-rate chat).
  Lower-spec RAM safety is not proven by this row.
- This is still not the full ten-model matrix. E2B and 31B QAT rows, plus
  VL/audio rows, Chat UI visual proof, lower-spec physical-footprint proof, and
  full harness scoring remain open.

## 2026-06-11 Agent-Loop E2B QAT Checkpoint

This checkpoint keeps the same QAT-only scope and same keychain-free
Release-app runtime as the E4B and 26B A4B rows. It does not load BF16/source
Gemma bundles. It extends the server-side agent-loop proof to the E2B JANG_4M
and E2B MXFP4 QAT bundles.

E2B JANG_4M agent-loop tool proof:

- request:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-jang4m-f8f02857.request.json`
- first SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-jang4m-f8f02857.sse`
- first timing:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-jang4m-f8f02857.time.txt`
- repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-jang4m-f8f02857-repeat.sse`
- repeat timing:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-jang4m-f8f02857-repeat.time.txt`
- repeat cache:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-jang4m-f8f02857-repeat.cache.json`
- repeat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-loop-e2b-jang4m-f8f02857-repeat.txt`

Both SSE files include `osaurus_agent_tool` frames for `complete` with
`phase="started"` and `phase="completed"`, `is_error=false`, and
`end_run=true`, then final visible content exactly
`agent loop e2b jang4m tool execution proven.`. The SSE files do not contain
internal U+FFFE tool sentinels, raw `tool:` / `args:` / `done:` sentinels,
`<think>` tags, or tool/reasoning marker leakage.

The repeat cache reports `disk_l2_hits=1`, `disk_l2_misses=9`,
`disk_l2_stores=1`, `paged_hits=0`, `paged_misses=0`, and
`companion_misses=1`. The topology is 15 layers: 3 full KV layers and 12
rotating KV layers, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=false`, and `turbo_quant_kv_layer_count=0`.
The model's `effective_kv_mode` reports `turbo(3,3)` while the concrete
topology remains rotating KV plus disk-backed restore. The first agent-loop row
took `3.06 real`; the repeat row took `1.66 real`. The app `ps` row after the
repeat reports `RSS=2026864 KB`.

E2B MXFP4 agent-loop tool proof:

- request:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-mxfp4-f8f02857.request.json`
- first SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-mxfp4-f8f02857.sse`
- first timing:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-mxfp4-f8f02857.time.txt`
- repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-mxfp4-f8f02857-repeat.sse`
- repeat timing:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-mxfp4-f8f02857-repeat.time.txt`
- repeat cache:
  `/tmp/osaurus-gemma-proof/agent-loop-e2b-mxfp4-f8f02857-repeat.cache.json`
- repeat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-loop-e2b-mxfp4-f8f02857-repeat.txt`

Both SSE files include `osaurus_agent_tool` frames for `complete` with
`phase="started"` and `phase="completed"`, `is_error=false`, and
`end_run=true`. The SSE files do not contain internal U+FFFE tool sentinels,
raw `tool:` / `args:` / `done:` sentinels, `<think>` tags, or tool/reasoning
marker leakage. The final visible content is
`agent loop e2b mxfp4 tool execution proven` without the requested trailing
period, so strict punctuation fidelity for this exact MXFP4 agent prompt is
partial even though tool execution completed cleanly.

The repeat cache reports `disk_l2_hits=1`, `disk_l2_misses=9`,
`disk_l2_stores=1`, `paged_hits=0`, `paged_misses=0`, and
`companion_misses=1`. The topology is 15 layers: 3 full KV layers and 12
rotating KV layers, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=false`, and `turbo_quant_kv_layer_count=0`.
The model's `effective_kv_mode` reports `turbo(3,3)` while the concrete
topology remains rotating KV plus disk-backed restore. The first agent-loop row
took `2.90 real`; the repeat row took `1.62 real`. The app `ps` row after the
repeat reports `RSS=658592 KB`.

Token/s and prefill progress proof for the same E2B checkpoint:

- E2B JANG_4M request:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-token-rate-f8f02857.request.json`
- E2B JANG_4M SSE:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-token-rate-f8f02857.sse`
- E2B JANG_4M cache:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-token-rate-f8f02857.cache.json`
- E2B JANG_4M timing:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-token-rate-f8f02857.time.txt`
- E2B JANG_4M post-chat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-chat-e2b-jang4m-token-rate-f8f02857.txt`
- E2B MXFP4 request:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-token-rate-f8f02857.request.json`
- E2B MXFP4 SSE:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-token-rate-f8f02857.sse`
- E2B MXFP4 cache:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-token-rate-f8f02857.cache.json`
- E2B MXFP4 timing:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-token-rate-f8f02857.time.txt`
- E2B MXFP4 post-chat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-chat-e2b-mxfp4-token-rate-f8f02857.txt`

The JANG_4M chat SSE emits `osaurus_prefill` queued/prefill/complete progress
from `0/29` to `29/29`, then visible content
`e2b jang4m token rate visible.`, and usage with `prompt_tokens=20`,
`completion_tokens=10`, `total_tokens=30`, and `tokens_per_second=117.0439`.
The post-chat app `ps` row reports `RSS=2026816 KB`.

The MXFP4 chat SSE emits `osaurus_prefill` queued/prefill/complete progress
from `0/30` to `30/30`, then visible content
`e2b mxfp4 token rate visible.`, and usage with `prompt_tokens=20`,
`completion_tokens=11`, `total_tokens=31`, and `tokens_per_second=124.343`.
The post-chat app `ps` row reports `RSS=660704 KB`.

Boundary after this checkpoint:

- E2B JANG_4M now has fresh PR-build agent-loop proof with actual `complete`
  tool execution, exact final text, no sentinel/reasoning/tool leakage, disk L2
  hit on repeat, paged KV disabled, prefill progress on chat, and token/s from
  ordinary chat generation.
- E2B MXFP4 now has the same proof for tool execution, cache, paged-off
  behavior, prefill, and token/s, but strict punctuation fidelity is partial
  for the agent-loop final text because the model omitted the requested final
  period.
- `/agents/{id}/run` tool-intercept SSE still does not emit a usage chunk.
  Token/s for the E2B rows is therefore recorded from `/v1/chat/completions`
  on the same model/runtime checkpoint, not from the tool-intercept agent SSE.
- This is still not the full ten-model matrix. 31B QAT rows, plus VL/audio
  rows, Chat UI visual proof, lower-spec physical-footprint proof, and full
  harness scoring remain open.

## 2026-06-11 Agent-Loop 31B QAT Checkpoint

This checkpoint keeps the same QAT-only scope and same keychain-free
Release-app runtime as the earlier rows. It does not load BF16/source Gemma
bundles. It closes the first-pass API/tool/cache matrix for the 31B JANG_4M
and 31B MXFP4 QAT bundles.

31B JANG_4M agent-loop tool proof:

- request:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-jang4m-f8f02857.request.json`
- first SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-jang4m-f8f02857.sse`
- first timing:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-jang4m-f8f02857.time.txt`
- repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-jang4m-f8f02857-repeat.sse`
- repeat timing:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-jang4m-f8f02857-repeat.time.txt`
- repeat cache:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-jang4m-f8f02857-repeat.cache.json`
- repeat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-loop-31b-jang4m-f8f02857-repeat.txt`

Both SSE files include `osaurus_agent_tool` frames for `complete` with
`phase="started"` and `phase="completed"`, `is_error=false`, and
`end_run=true`, then final visible content exactly
`agent loop 31b jang4m tool execution proven.`. The SSE files do not contain
internal U+FFFE tool sentinels, raw `tool:` / `args:` / `done:` sentinels,
`<think>` tags, or tool/reasoning marker leakage.

The repeat cache reports `disk_l2_hits=1`, `disk_l2_misses=9`,
`disk_l2_stores=1`, `paged_hits=0`, `paged_misses=0`, and
`companion_misses=1`. The topology is 60 layers: 10 full KV layers and 50
rotating KV layers, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=false`, and `turbo_quant_kv_layer_count=0`.
The model's `effective_kv_mode` reports `turbo(3,3)` while the concrete
topology remains rotating KV plus disk-backed restore. The first agent-loop row
took `12.13 real`; the repeat row took `8.07 real`. The app `ps` row after the
repeat reports `RSS=18172640 KB`.

31B MXFP4 agent-loop tool proof:

- request:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-mxfp4-f8f02857.request.json`
- first SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-mxfp4-f8f02857.sse`
- first timing:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-mxfp4-f8f02857.time.txt`
- repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-mxfp4-f8f02857-repeat.sse`
- repeat timing:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-mxfp4-f8f02857-repeat.time.txt`
- repeat cache:
  `/tmp/osaurus-gemma-proof/agent-loop-31b-mxfp4-f8f02857-repeat.cache.json`
- repeat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-agent-loop-31b-mxfp4-f8f02857-repeat.txt`

Both SSE files include `osaurus_agent_tool` frames for `complete` with
`phase="started"` and `phase="completed"`, `is_error=false`, and
`end_run=true`, then final visible content exactly
`agent loop 31b mxfp4 tool execution proven.`. The SSE files do not contain
internal U+FFFE tool sentinels, raw `tool:` / `args:` / `done:` sentinels,
`<think>` tags, or tool/reasoning marker leakage.

The repeat cache reports `disk_l2_hits=1`, `disk_l2_misses=9`,
`disk_l2_stores=1`, `paged_hits=0`, `paged_misses=0`, and
`companion_misses=1`. The topology is 60 layers: 10 full KV layers and 50
rotating KV layers, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=false`, and `turbo_quant_kv_layer_count=0`.
The model's `effective_kv_mode` reports `turbo(3,3)` while the concrete
topology remains rotating KV plus disk-backed restore. The first agent-loop row
took `19.36 real`; the repeat row took `13.15 real`. The app `ps` row after
the repeat reports `RSS=665824 KB`.

Token/s and prefill progress proof for the same 31B checkpoint:

- 31B JANG_4M request:
  `/tmp/osaurus-gemma-proof/chat-31b-jang4m-token-rate-f8f02857.request.json`
- 31B JANG_4M SSE:
  `/tmp/osaurus-gemma-proof/chat-31b-jang4m-token-rate-f8f02857.sse`
- 31B JANG_4M cache:
  `/tmp/osaurus-gemma-proof/chat-31b-jang4m-token-rate-f8f02857.cache.json`
- 31B JANG_4M timing:
  `/tmp/osaurus-gemma-proof/chat-31b-jang4m-token-rate-f8f02857.time.txt`
- 31B JANG_4M post-chat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-chat-31b-jang4m-token-rate-f8f02857.txt`
- 31B MXFP4 request:
  `/tmp/osaurus-gemma-proof/chat-31b-mxfp4-token-rate-f8f02857.request.json`
- 31B MXFP4 SSE:
  `/tmp/osaurus-gemma-proof/chat-31b-mxfp4-token-rate-f8f02857.sse`
- 31B MXFP4 cache:
  `/tmp/osaurus-gemma-proof/chat-31b-mxfp4-token-rate-f8f02857.cache.json`
- 31B MXFP4 timing:
  `/tmp/osaurus-gemma-proof/chat-31b-mxfp4-token-rate-f8f02857.time.txt`
- 31B MXFP4 post-chat RAM:
  `/tmp/osaurus-gemma-proof/ps-after-chat-31b-mxfp4-token-rate-f8f02857.txt`

The JANG_4M chat SSE emits `osaurus_prefill` queued/prefill/complete progress
from `0/30` to `30/30`, then visible content
`31b jang4m token rate visible.`, and usage with `prompt_tokens=20`,
`completion_tokens=14`, `total_tokens=34`, and `tokens_per_second=17.9033`.
The post-chat app `ps` row reports `RSS=18246256 KB`.

The MXFP4 chat SSE emits `osaurus_prefill` queued/prefill/complete progress
from `0/31` to `31/31`, then visible content
`31b mxfp4 token rate visible.`, and usage with `prompt_tokens=20`,
`completion_tokens=15`, `total_tokens=35`, and `tokens_per_second=22.9764`.
The post-chat app `ps` row reports `RSS=740704 KB`.

Boundary after this checkpoint:

- 31B JANG_4M and 31B MXFP4 now have fresh PR-build agent-loop proof with
  actual `complete` tool execution, exact final text, no sentinel/reasoning/tool
  leakage, disk L2 hit on repeat, paged KV disabled, prefill progress on chat,
  and token/s from ordinary chat generation.
- `/agents/{id}/run` tool-intercept SSE still does not emit a usage chunk.
  Token/s for the 31B rows is therefore recorded from `/v1/chat/completions`
  on the same model/runtime checkpoint, not from the tool-intercept agent SSE.
- The 31B JANG_4M physical footprint is heavy on this Mac
  (`RSS=18172640 KB` after repeat, `RSS=18246256 KB` after token-rate chat).
  Lower-spec RAM safety is not proven by this row.
- The QAT API/tool/cache matrix now has first-pass Release-app proof for E2B,
  E4B, 12B, 26B A4B, and 31B in both JANG_4M and MXFP4 forms. Remaining
  release gates are Chat UI visual proof, VL/audio rows, lower-spec
  physical-footprint proof, vMLX main update verification, and full harness
  scoring.

## Default Agent Alias and BatchEngine Status - 2026-06-12

Root issue found after the first matrix pass:

- The QAT agent-loop matrix used the built-in Default agent UUID route:
  `/agents/00000000-0000-0000-0000-000000000001/run`.
- The literal route `/agents/default/run` still failed before the local fix
  with `HTTP_STATUS:400` and body
  `{"error":"invalid_agent_id","message":"Invalid agent UUID in path"}`.
- That was a route/parser gap, not a Gemma runtime, cache, or tool-calling
  failure. The route parser now maps path id `default` to `Agent.defaultId`
  before the built-in-agent remote guard runs.
- Security boundary: loopback/plain local requests now reach the built-in
  Default agent through the alias; remote encrypted requests still normalize to
  the same built-in UUID and are rejected by the existing remote built-in-agent
  guard. Remote plaintext requests still fail earlier on Secure Channel policy.

Focused source regression added:

- `Packages/OsaurusCore/Tests/Networking/HTTPHandlerChatStreamingTests.swift`
  adds `builtInAgentRun_defaultAlias_overLoopback_bypassesGuard`.
- Local SwiftPM test attempt from `Packages/OsaurusCore` is blocked by the
  existing local toolchain/repo issue `error: no such module 'Testing'`:
  `/tmp/osaurus-gemma-proof/swift-test-default-agent-alias-package-de097cb2-plus.log`.
  Do not report this source test as passed until that toolchain issue is fixed.

Rebuilt app proof after the alias fix:

- Release app build:
  `/tmp/osaurus-gemma-proof/xcode-build-release-app-default-alias.log`
  reports `** BUILD SUCCEEDED **`; status file
  `/tmp/osaurus-gemma-proof/xcode-build-release-app-default-alias.status`
  records `status=0`.
- App launch root:
  `/tmp/osaurus-gemma-proof/osaurus-ui-proof-default-alias-root.txt`.
- Health:
  `/tmp/osaurus-gemma-proof/health-default-alias.json`.
- Runtime config:
  `/tmp/osaurus-gemma-proof/server-runtime-default-alias.json` keeps
  `cache.pagedKV.enabled=false`, `cache.blockDisk.enabled=true`,
  `cache.prefix.enabled=true`, `cache.liveKVCodec="engine_selected"`,
  `cache.storedKVCodec="auto"`, `concurrency.maxConcurrentSequences=1`,
  `memorySafety.allowExperimentalMLXPress=false`,
  `multimodal.enableAudio=true`, `multimodal.enableVideo=true`, and
  `multimodal.requireMediaSaltForCache=true`.

E2B JANG_4M literal `/agents/default/run` proof:

- Request:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-jang4m-default-alias.request.json`
- First SSE:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-jang4m-default-alias.sse`
- First timing:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-jang4m-default-alias.time.txt`
- Repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-jang4m-default-alias-repeat.sse`
- Repeat timing:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-jang4m-default-alias-repeat.time.txt`
- Repeat cache:
  `/tmp/osaurus-gemma-proof/cache-after-agent-default-e2b-jang4m-default-alias-repeat.json`

Both SSE files return `HTTP_STATUS:200`, emit sanitized `osaurus_agent_tool`
frames for `complete` with `phase="started"` and `phase="completed"`,
`is_error=false`, `end_run=true`, and visible final text exactly
`default alias e2b jang4m tool execution proven.`. The first row took
`3.81 real`; repeat took `1.78 real`. The repeat cache has `disk_l2_hits=1`,
`disk_l2_stores=1`, `paged_hits=0`, and `paged_misses=0`. Topology is 15
layers: 3 full KV layers, 12 rotating KV layers,
`requires_disk_backed_restore=true`, `effective_kv_mode="turbo(3,3)"`, and
`turbo_quant_kv_layer_count=0`.

E2B JANG_4M chat prefill/token-rate proof on the same rebuilt app:

- Request:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-cache-ttft-default-alias.request.json`
- First SSE:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-cache-ttft-default-alias.sse`
- First timing:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-cache-ttft-default-alias.time.txt`
- Repeat SSE:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-cache-ttft-default-alias-repeat.sse`
- Repeat timing:
  `/tmp/osaurus-gemma-proof/chat-e2b-jang4m-cache-ttft-default-alias-repeat.time.txt`
- Repeat cache:
  `/tmp/osaurus-gemma-proof/cache-after-chat-e2b-jang4m-cache-ttft-default-alias-repeat.json`

The chat SSE emits `osaurus_prefill` queued/prefill/complete progress from
`0/27` to `27/27`; the repeat emits `0/27`, `26/27`, `27/27`. Usage reports
`prompt_tokens=14`, `completion_tokens=21`, `total_tokens=35`, and
`tokens_per_second=107.598` first pass / `110.253` repeat. Repeat cache reports
`disk_l2_hits=2`, `disk_l2_stores=6`, `paged_hits=0`, and `paged_misses=0`.

E2B MXFP4 literal `/agents/default/run` proof:

- Request:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-mxfp4-default-alias.request.json`
- First SSE:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-mxfp4-default-alias.sse`
- First timing:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-mxfp4-default-alias.time.txt`
- Repeat SSE:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-mxfp4-default-alias-repeat.sse`
- Repeat timing:
  `/tmp/osaurus-gemma-proof/agent-default-e2b-mxfp4-default-alias-repeat.time.txt`
- Repeat cache:
  `/tmp/osaurus-gemma-proof/cache-after-agent-default-e2b-mxfp4-default-alias-repeat.json`

Both SSE files return `HTTP_STATUS:200`, emit sanitized `osaurus_agent_tool`
frames for `complete` with `phase="started"` and `phase="completed"`,
`is_error=false`, `end_run=true`, and visible final text exactly
`default alias e2b mxfp4 tool execution proven.`. The first row took
`3.14 real`; repeat took `1.73 real`. The repeat cache has `disk_l2_hits=1`,
`disk_l2_stores=1`, `paged_hits=0`, and `paged_misses=0`. Topology is 15
layers: 3 full KV layers, 12 rotating KV layers,
`requires_disk_backed_restore=true`, `effective_kv_mode="turbo(3,3)"`, and
`turbo_quant_kv_layer_count=0`.

E2B MXFP4 chat prefill/token-rate proof on the same rebuilt app:

- Request:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-cache-ttft-default-alias.request.json`
- First SSE:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-cache-ttft-default-alias.sse`
- First timing:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-cache-ttft-default-alias.time.txt`
- Repeat SSE:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-cache-ttft-default-alias-repeat.sse`
- Repeat timing:
  `/tmp/osaurus-gemma-proof/chat-e2b-mxfp4-cache-ttft-default-alias-repeat.time.txt`
- Repeat cache:
  `/tmp/osaurus-gemma-proof/cache-after-chat-e2b-mxfp4-cache-ttft-default-alias-repeat.json`

The chat SSE emits `osaurus_prefill` queued/prefill/complete progress from
`0/28` to `28/28`; the repeat emits `0/28`, `27/28`, `28/28`. Usage reports
`prompt_tokens=14`, `completion_tokens=21`, `total_tokens=35`, and
`tokens_per_second=118.2153` first pass / `120.814` repeat. Repeat cache
reports `disk_l2_hits=2`, `disk_l2_stores=6`, `paged_hits=0`, and
`paged_misses=0`.

BatchEngine compile status:

- The Osaurus Release app build above compiled the pinned vMLX checkout's
  `Libraries/MLXLMCommon/BatchEngine/BatchEngine.swift` with no compiler
  error. The only matching build-log line is the normal `SwiftCompile` command.
- The separate local checkout `/Users/eric/vmlx-swift` is dirty in
  `BatchEngine.swift`, `BatchScheduler.swift`, and `BatchTypes.swift`, but a
  direct current build of that target also succeeds:
  `/tmp/vmlx-swift-mlxcommon-build-batchengine.latest` points to the log for
  `swift build --target MLXLMCommon`, which reports
  `Build of target: 'MLXLMCommon' complete!`.
- Therefore no current `BatchEngine.swift` compiler error is reproduced from
  either the PR-pinned app build or the local vMLX `MLXLMCommon` target. If a
  later command reports BatchEngine errors, keep the exact command, checkout,
  commit, and full log with this doc before fixing; do not infer it from the
  filename alone.

Updated boundary:

- Pushed Osaurus PR checkpoint: PR #1469 branch
  `codex/gemma-cache-prefill-checkpoint-main` is at commit `cf4bbd09`
  (`Share Gemma QAT post-tool finalization policy`). GitHub CI restarted for
  that commit on 2026-06-12; at the time of this note `test-core`, `test-cli`,
  and `swiftlint` were still in progress, while `shellcheck` and
  `update_release_draft` had passed. Do not merge until CI is green and the
  remaining proof gaps below are either fixed or explicitly accepted.
- vMLX main/pin reconciliation remains open. Osaurus currently pins
  `Packages/OsaurusCore/Package.swift` to vMLX
  `dc52096743215a153522c9b260c8191f133d7288`, while remote
  `osaurus-ai/vmlx-swift main` is
  `76047f3b4492d4fae316267a30fba55163b1c5cd`. The local
  `/Users/eric/vmlx-swift` checkout is dirty on
  `codex/mimo-v25-cache-contract` and must not be treated as merge-ready by
  this Osaurus checkpoint. The final release path still needs the required
  Gemma/cache runtime changes landed on vMLX main and Osaurus repinned to the
  exact proven main SHA.
- Source/unquantized Gemma bundles remain excluded. Do not load them for this
  checkpoint and do not treat their expert-weight key failures as QAT blockers.
- The concrete Gemma QAT cache topology still reports rotating KV plus
  disk-backed restore with `turbo_quant_kv_layer_count=0`; keep saying that
  exactly until runtime stats prove a nonzero TurboQuant KV layer count.
- Literal `/agents/default/run` is now proven for E2B JANG_4M and E2B MXFP4.
  The larger-model matrix is already proven through the built-in Default agent
  UUID route and should be re-smoked through the alias only if release review
  requires identical path coverage for every size.
