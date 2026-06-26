# Harness Compatibility

Running record of models validated against the Osaurus agent harness.
Updated as new models are tested — newest entries at the top of each table.

## How models are tested

Every model runs the same two eval suites end-to-end through the real agent
loop (real tools, real workspaces, no mocks):

- **AgentLoopFrontier** (27 cases) — complex agentic work: multi-file
  refactors, debugging from stack traces, live web fetches, database
  workflows, artifact sharing, todo discipline, compaction under load,
  byte-exact file procedures, and per-tool audits for `file_read`,
  `file_write`, `file_edit`, `file_search`, and `shell_run`.
- **AgentLoop** (17 cases) — loop mechanics: dedupe/replay, error recovery,
  budget wrap-up, clarification, rejection handling, batch isolation.
- **SandboxFrontier** (13 cases, off-CI) — the live Linux-VM sandbox lane:
  code execution (`sandbox_write_file` + `sandbox_exec`), debugging seeded
  test failures, `sandbox_install`, combined host-folder mode and path
  routing, host-secret refusal, plugin authoring + same-run invocation,
  secrets round-trip with output scrubbing, `sandbox_reduce` digestion,
  background processes, live network fetches, and sandbox-to-user artifact
  delivery. Outputs are pinned through the VirtioFS host mount, so a
  hallucinated "I ran it" cannot pass. Requires a set-up sandbox host; see
  `Packages/OsaurusEvals/Suites/SandboxFrontier/README.md` for the
  entitlement-signing run instructions.

Deterministic expectations (file equality, exit reasons, tool-usage audits)
are scored in-harness; rubric expectations are scored by a fixed judge model
(`xai/grok-4.3`) so scores are comparable across models. The eval driver
pins `temperature: 0.0` where the provider accepts it.

A failure is only meaningful with its cause attached. Scores below
distinguish **harness errors** (our bug — always fixed before a row is
published) from **model findings** (real behavior, scored honestly).

## Remote frontier models

| Model | Route | Frontier (27) | AgentLoop (17) | Sandbox (13) | Tested | Notes |
|---|---|---|---|---|---|---|
| claude-fable-5 | `anthropic/claude-fable-5` | 26 ✓ / 1 ✗* | 17 ✓ | 10 ✓ / 3 refused† | 2026-06-11 | Strongest lane overall. *Sole fail (empty first response) passed on re-run; coincided with API credit exhaustion. †All 3 sandbox misses are Anthropic's API-level cyber safeguard refusing secret/token-flavored prompts (`stop_reason: refusal`) — provider policy, not model capability. |
| gpt-5.5 | `openai/gpt-5.5` | 24 ✓ / 3 ✗ | 16 ✓ / 1 ✗ | 11 ✓ / 2 ✗ | 2026-06-11 | Flawless tool discipline; frontier fails are terse final replies and ignoring budget warnings (does the work, under-reports it). Sandbox fails: refuses to pass a secret value to `sandbox_secret_set` (model-side policy; insists on the interactive prompt flow), and the same unadvertised-plugin-tool reluctance as grok-4.3. |
| grok-4.3 | `xai/grok-4.3` | 25 ✓ / 2 ✗ | 17 ✓ | 12 ✓ / 1 ✗ | 2026-06-11 | Frontier fails: post-compaction confabulation (intermittent) and whitespace drift in a byte-exact `file_write`. Sandbox fail: won't invoke a just-registered plugin tool that isn't in the advertised schema (executes the underlying script via `sandbox_exec` instead). |
| gemini-3.1-pro-preview | `google/gemini-3.1-pro-preview` | 26 ✓ / 1 ✗ | 16 ✓ / 1 ✗* | 13 ✓ | 2026-06-11 | Fastest frontier lane; only clean sandbox sweep to date. Fail: final reply says it explained the script without including the explanation. *One-off empty first response; passed on retry. |
| deepseek-v4-pro | `deepseek/deepseek-v4-pro` | 25 ✓ / 2 ✗ | 16 ✓ / 1 ✗ | 12 ✓ / 1 ✗ | 2026-06-11 | Frontier/loop fails are budget overruns: keeps working past the iteration cap instead of wrapping up. Sandbox fail: tried a raw `sandbox_read_file` on the seeded logs before delegating to `sandbox_reduce` (discipline cap is zero raw reads). |

"—" = lane not yet run for that model.

## Local models

Gemma 4 local rows are checkpoint gates for this release lane. Every
OsaurusAI QAT MXFP4 and JANG_4M route must get a real AgentLoop harness row
before the checkpoint is promoted for broad teammate testing. A non-perfect
score can be useful when it includes real tool calls and attached failure
causes, but rows with missing tool execution, malformed tool JSON,
tool/protocol marker leakage, corrupted visible text, or unproven cache
telemetry stay partial until fixed or explicitly scoped.

This is an all-model gate, not an E2B-only smoke. The required local set is
the ten OsaurusAI Gemma 4 QAT bundles under `/Users/eric/models`: E2B, E4B,
12B, 26B-A4B, and 31B for both MXFP4 and JANG_4M. Each row needs its own
artifact path and score; source/BF16 or Google-style Gemma folders do not
count for this checkpoint.

For this Gemma QAT checkpoint, the minimum useful row is: the model loads from
the OsaurusAI QAT bundle, executes at least one real tool call through Osaurus,
continues from the tool result into visible text, and produces an AgentLoop
score with every failed case labeled as either a model finding or a scoped
runtime bug. The goal is a decent, team-testable score for each MXFP4 and
JANG_4M model, not a fake perfect score created by disabling tools, hiding
corrupt text, or skipping failing cases.

Current PR #1469 live proof also makes visible-text quality a hard gate.
Older 12B JANG_4M rows on head `f58bb924` successfully executed the real
built-in `osaurus_status` tool through `/agents/default/run`, but corrupted
ordinary text (`saurus_status toool`) in the visible answer. Current head
`5e87c496` has a clean current-built Release-app proof for the `complete` tool
on 12B JANG_4M: `/agents/default/run` emits sanitized `osaurus_agent_tool`
`started`/`completed` chunks, exact final text
`5e87c496 current-built default agent 12b jang4m complete tool execution
proof.`, and no non-ASCII/control/protocol marker leakage. Cache telemetry
reports `paged_cache.enabled=false`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=8`,
`rotating_kv_layer_count=40`, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`. A paired direct-chat prefill repeat on the same
app emits progress from `0/1470` through `1470/1470`, usage with
`tokens_per_second=4.9309`, and repeat cache with `disk_l2_hits=1`,
`disk_l2_stores=3`, and paged hits/misses both zero. E2B JANG_4M VL red-image
proof on the same app returns `Red` with prefill `0/307` through `307/307`.
This is a useful current-head tool/cache/prefill/VL checkpoint, not a full
release pass: `/agents/default/run` still does not emit usage or prefill
telemetry, Chat UI visual proof was blocked by app-bundle automation ambiguity,
the remaining QAT MXFP4/JANG_4M models still need scored AgentLoop rows, and
every failed case needs an attached cause before the checkpoint is
teammate-testable.

Exact-pin checkpoint `c7613dcc` refresh on the keychain-free Release app closes
the load/tool/cache smoke for all ten OsaurusAI QAT bundles. Build log:
`/tmp/osaurus-gemma-proof/xcode-build-release-app-pin-c7613dcc-12e16b65-20260612T183001Z.log`;
proof root:
`/tmp/osaurus-gemma-proof/pr1469-c7613dcc-fresh-live-20260612T183743Z`.
Direct `/agents/default/run` first/repeat rows for E2B, E4B, 12B, 26B-A4B,
and 31B across both JANG_4M and MXFP4 are summarized in
`direct-full-qat-agent-curl-c7613dcc-20260612T184903Z/NORMALIZED.tsv`.
Every row loaded from the OsaurusAI QAT bundle, emitted real `complete`
`osaurus_agent_tool` started/completed frames on first and repeat requests,
recorded repeat `disk_l2_hits +1`, reported `paged_cache.enabled=false`,
reported rotating/disk-backed topology, and had `turbo_quant_kv_layer_count=0`
with zero marker/weird-text scan hits. 12B JANG_4M and 12B MXFP4 also have
strict OpenAI-compatible `line_count` multi-turn tool rows and direct streaming
prefill rows with progress `0/3552` through `3552/3552`, stable prefix hash,
usage token/s, and repeat L2 hits. E2B JANG_4M and E2B MXFP4 have real red-PNG
VL rows returning `Red` with repeat L2 hits. This promotes the checkpoint as a
team-testable load/tool/cache/VL smoke, not a full harness-score pass: full
AgentLoop scoring, lower-spec physical-footprint proof, and Gemma4 audio remain
separate gates. `scripts/live-proof/assert-osaurus-vmlx-pr-readiness.sh` also
passes after clearing an unrelated focused `swift-test` process from another
checkout; the guard confirms keychain-safe proof paths, no hidden sampler
defaults, cache/Responses wiring, server runtime settings wiring, matching
vMLX pin surfaces, and the wired `c7613dcc` parser checkout.

Code head `67b2070a` adds exact Chat UI proof on the built no-sign Release
app; later PR head `692da0b2` only records this documentation on top. The
proof app launched from
`build/XcodeDerivedData-pr1469-67b2070a-nosign/Build/Products/Release/osaurus.app`
with proof root
`/tmp/osaurus-gemma-proof/pr1469-67b2070a-ui-tool-20260612T143110Z`.
The visible UI row uses `OsaurusAI Gemma 4 12B it qat MXFP4`, shows the
`Osaurus status` tool card, and returns exact visible text
`UI MXFP4 67b2070a tool proof complete.` with UI metrics
`TTFT 4.07s`, `4739.7 tok/s`, and `21 tokens`. A same-chat second turn shows
a second `Osaurus status` tool card after tool history and returns exact
visible text `UI MXFP4 67b2070a second tool proof complete.` with UI metrics
`TTFT 3.40s`, `6920.7 tok/s`, and `22 tokens`. Screenshots and summaries are
`ui-mxfp4-tool-proof.png`, `ui-mxfp4-tool-proof.txt`,
`ui-mxfp4-second-tool-proof.png`, and `ui-mxfp4-second-tool-proof.txt` under
that proof root. The second-turn cache stats show
`paged_kv_enabled=false`, aggregate `paged_hits=0`, `paged_misses=0`,
`block_disk_store.enabled=true`, `disk_l2_hits=1`, `disk_l2_stores=4`,
`effective_kv_mode="turbo(3,3)"`, `turbo_quant_compressions=4`,
`kv_layer_count=8`, `rotating_kv_layer_count=40`,
`requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
This promotes the 12B MXFP4 UI tool/cache row to a current-head clean proof,
but does not promote the full Gemma QAT checkpoint: the other MXFP4/JANG_4M
models still need equivalent clean app-facing tool rows or documented
partials, and the harness text-corruption findings remain open.

The same `67b2070a` dev app also closes the previous JANG_4M agent-loop
tool gap for 12B. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-67b2070a-jang-agenttool-20260612T143245Z`.
`/agents/default/run` with
`model="osaurusai--gemma-4-12b-it-qat-jang_4m"` and
`tool_choice="auto"` emits real `osaurus_agent_tool` frames for
`osaurus_status` with `phase="started"` and `phase="completed"`,
`is_error=false`, then returns exact visible text
`JANG agent loop 67b2070a osaurus_status tool proof complete.` with no
replacement/control/non-ASCII/protocol marker leakage. The agent route still
does not emit usage or prefill telemetry, so the same proof root includes
paired direct `/v1/chat/completions` long-prefix rows for the same JANG_4M
model. Those rows emit prefill progress from `0/4034` through `4034/4034`,
return exact visible text
`JANG direct chat 67b2070a prefill cache proof complete.`, and report
`tokens_per_second=8.4939` then `8.4819`. Repeat cache stats show
`paged_kv_enabled=false`, aggregate `paged_hits=0`, `paged_misses=0`,
`disk_l2_hits=1`, `disk_l2_stores=4`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `turbo_quant_compressions=2`,
`kv_layer_count=8`, `rotating_kv_layer_count=40`,
`requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
The same exact app now also has visible Chat UI JANG_4M proof. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-67b2070a-ui-jang-tool-20260612T144811Z`.
After switching the visible selector to
`OsaurusAI Gemma 4 12B it qat JANG_4M`, the UI shows an `Osaurus status` tool
card, exact final text `UI JANG 67b2070a status tool proof complete.`, and
UI metrics `TTFT 4.81s`, `8673.1 tok/s`, and `21 tokens`, with no visible
weird/control/protocol marker leakage. Cache snapshot
`cache.after-ui-jang-tool.json` reports `paged_kv_enabled=false`,
aggregate `paged_hits=0`, `paged_misses=0`, `disk_l2_hits=1`,
`disk_l2_stores=6`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `turbo_quant_compressions=4`,
`kv_layer_count=8`, `rotating_kv_layer_count=40`,
`requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
This proves 12B JANG_4M Chat UI tool execution plus agent-loop tool execution
and direct-chat prefill/cache telemetry on the current dev app, while
preserving the remaining boundary that the broader QAT matrix is not yet
complete.

The same exact app also has a fresh 12B JANG_4M VL API proof. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-67b2070a-vl-jang-red-20260612T145209Z`.
Streamed first and repeat `/v1/chat/completions` rows use a real inline red
PNG `image_url` payload, both return exact final text `Red`, finish `stop`,
reuse prefix hash `6e340b9cffb37a989ca544e6bb780a2c`, emit prefill `0/279`
through `279/279`, and show no replacement/control/non-ASCII/protocol marker
leakage. A non-stream row returns exact `Red` with
`tokens_per_second=11.1953`. Final cache snapshot reports
`paged_kv_enabled=false`, aggregate `paged_hits=0`, `paged_misses=0`,
`disk_l2_hits=3`, `disk_l2_stores=12`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `turbo_quant_compressions=7`,
`kv_layer_count=8`, `rotating_kv_layer_count=40`,
`requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
This promotes only the 12B JANG_4M VL API cell; Chat UI attachment, audio, and
other model sizes remain unproven here.

Code head `67b2070a` now also has a current E4B JANG_4M Chat UI tool/cache
proof. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-67b2070a-ui-e4b-jang-tool-20260612T145655Z`.
The visible selector is `OsaurusAI Gemma 4 E4B it qat JANG_4M`; two same-chat
turns show `Osaurus status` tool cards and exact final text
`UI E4B JANG 67b2070a status tool proof complete.` then
`UI E4B JANG 67b2070a second status tool proof complete.`. UI metrics are
`TTFT 2.88s`, `5350.2 tok/s`, `20 tokens` and then `TTFT 2.86s`,
`83.9 tok/s`, `21 tokens`, with no visible weird/control/protocol marker
leakage. The UI cache snapshots show paged KV stayed off and disk stores
occurred, but `disk_l2_hits` stayed 0, so UI cache-hit proof remains partial.
Direct-chat cache proof for the same E4B JANG_4M model then passed on the
short stable-prefix row: streamed first and repeat outputs are exact
`E4B JANG short cache proof complete.`, prefill runs `0/984` through
`984/984`, no replacement/control/non-ASCII/protocol marker leaks appear, and
the final cache snapshot reports `paged_kv_enabled=false`,
aggregate `paged_hits=0`, `paged_misses=0`, `disk_l2_hits=3`,
`disk_l2_stores=9`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `turbo_quant_compressions=9`,
`kv_layer_count=4`, `rotating_kv_layer_count=20`,
`requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`. A
non-stream copy records `tokens_per_second=15.0615`. The earlier 4888-token
repeat diagnostic hit disk L2 but length-stopped after copying prefix text, so
it is recorded as a failed cache-quality diagnostic, not promoted proof.

Code head `67b2070a` now also has current E4B MXFP4 Chat UI tool/cache proof.
Proof root:
`/tmp/osaurus-gemma-proof/pr1469-67b2070a-ui-e4b-mxfp4-tool-20260612T150504Z`.
The visible selector is `OsaurusAI Gemma 4 E4B it qat MXFP4`; the UI shows an
`Osaurus status` tool card and exact final text
`UI E4B MXFP4 67b2070a status tool proof complete.` with UI metrics
`TTFT 2.96s`, `6744.2 tok/s`, and `21 tokens`. The visible row has no
weird/control/protocol marker leakage. The UI cache snapshot proves paged KV
stayed off and disk stores occurred, but `disk_l2_hits=0`, so UI cache-hit
proof is not promoted from that first visible turn. Direct-chat cache proof for
the same E4B MXFP4 model passed on a short stable-prefix row: streamed first
and repeat outputs are exact `E4B MXFP4 short cache proof complete.`, prefill
runs `0/1225` through `1225/1225`, no replacement/control/non-ASCII/protocol
marker leaks appear, and repeat cache reports `paged_kv_enabled=false`,
aggregate `paged_hits=0`, `paged_misses=0`, `disk_l2_hits=1`, and
`disk_l2_stores=4`. The non-stream copy is also exact, records
`tokens_per_second=14.7365`, and final cache reports `disk_l2_hits=2`,
`disk_l2_stores=5`, `effective_kv_mode="turbo(3,3)"`,
`turbo_quant_compressions=5`, `kv_layer_count=4`,
`rotating_kv_layer_count=20`, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`.

Current PR head `23a8cf50` adds a fresh E4B MXFP4 `/agents/default/run`
tool-execution and VL cache pass on the same running PR app. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-23a8cf50-agent-e4b-mxfp4-20260612T151426Z`.
The agent request uses `tool_choice="required"` and emits real
`osaurus_agent_tool` frames: `complete` started, `complete` completed with
`is_error=false` and `end_run=true`, then exact final text
`23a8cf50 current PR agent loop executed complete tool with Gemma E4B MXFP4 QAT and no parser leak.`.
The SSE scan has no replacement characters, U+FFFE, raw `<think>`, raw
tool/protocol markers, configured weird-word hits, or non-ASCII output. Cache
after the agent row reports paged KV off, `block_disk_store.enabled=true`,
`disk_l2_hits=2`, `disk_l2_stores=5`, `effective_kv_mode="turbo(3,3)"`,
`kv_layer_count=4`, `rotating_kv_layer_count=20`,
`requires_disk_backed_restore=true`, and `turbo_quant_kv_layer_count=0`.
Because `/agents/default/run` still does not emit usage or prefill chunks, use
the direct chat/VL rows for token-rate and prefill proof.

The same proof root also has an E4B MXFP4 VL red-image API row using a real
inline 32x32 PNG data URL. First and repeat requests both return exact `Red`,
emit prefill progress `0/307` queued, `0/307` running, and `307/307`
complete, and include usage. Token rates are `48.302 tok/s` first and
`44.5354 tok/s` repeat. The VL scans have no replacement/control/non-ASCII or
protocol marker leakage. Repeat cache reports paged KV off,
`disk_l2_hits=3`, `disk_l2_stores=10`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=4`,
`rotating_kv_layer_count=20`, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`. This promotes the E4B MXFP4 API VL/cache cell;
Chat UI image attachment and Gemma4 audio remain separate gates.

Current PR head `bfff6e27` adds the matching fresh E4B JANG_4M
`/agents/default/run` and VL cache pass. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-bfff6e27-agent-e4b-jang-20260612T151808Z`.
The agent request uses `tool_choice="required"` and emits real
`osaurus_agent_tool` frames: `complete` started, `complete` completed with
`is_error=false` and `end_run=true`, then exact final text
`bfff6e27 current PR agent loop executed complete tool with Gemma E4B JANG_4M QAT and no parser leak.`.
The agent SSE scan has no replacement characters, U+FFFE, raw `<think>`, raw
tool/protocol markers, configured weird-word hits, or non-ASCII output. The
agent-only cache snapshot shows paged KV off and disk-backed restore, but only
misses and no disk L2 hit/store on that short tool row; use the VL repeat below
for E4B JANG_4M token-rate, prefill, and L2-hit proof.

The same proof root has an E4B JANG_4M VL red-image API row using the same real
inline 32x32 PNG data URL. First and repeat requests both return exact `Red`,
emit prefill progress `0/307` queued, `0/307` running, and `307/307`
complete, and include usage. Token rates are `44.3992 tok/s` first and
`42.9683 tok/s` repeat. The VL scans have no replacement/control/non-ASCII or
protocol marker leakage. Repeat cache reports paged KV off,
`disk_l2_hits=1`, `disk_l2_stores=5`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=4`,
`rotating_kv_layer_count=20`, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`. This promotes the E4B JANG_4M API VL/cache
cell; Chat UI image attachment and Gemma4 audio remain separate gates.

Current PR head `81813403` adds a fresh 26B A4B MXFP4 live
`/agents/default/run` and VL cache pass, specifically to narrow the earlier
26B A4B MXFP4 full-harness Metal-abort row. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-81813403-agent-26b-a4b-mxfp4-20260612T152129Z`.
The agent request uses `tool_choice="required"` and emits real
`osaurus_agent_tool` frames: `complete` started, `complete` completed with
`is_error=false` and `end_run=true`, then exact final text
`81813403 current PR agent loop executed complete tool with Gemma 26B A4B MXFP4 QAT and no parser leak.`.
The agent SSE scan has no replacement characters, U+FFFE, raw `<think>`, raw
tool/protocol markers, configured weird-word hits, or non-ASCII output. The
agent-only cache snapshot shows paged KV off, disk-backed restore,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=5`,
`rotating_kv_layer_count=25`, and `turbo_quant_kv_layer_count=0`, but only
misses and no disk L2 hit/store on that short tool row.

The same proof root has a 26B A4B MXFP4 VL red-image API row using a real
inline 32x32 PNG data URL. First and repeat requests both return exact `Red`,
emit prefill progress `0/307` queued, `0/307` running, and `307/307`
complete, and include usage. Token rates are `28.8095 tok/s` first and
`29.8502 tok/s` repeat. The VL scans have no replacement/control/non-ASCII or
protocol marker leakage. Repeat cache reports paged KV off,
`disk_l2_hits=1`, `disk_l2_stores=5`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=5`,
`rotating_kv_layer_count=25`, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`. This proves the live app can load the 26B A4B
MXFP4 QAT bundle, execute a real tool, and run VL/cache cleanly; it does not
erase the earlier full AgentLoop Metal abort or the visible-corruption failures
from long harness cases.

Current PR head `a9a6e4fc` adds the matching 26B A4B JANG_4M live
`/agents/default/run` and VL cache pass. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-a9a6e4fc-agent-26b-a4b-jang-20260612T152503Z`.
The agent request uses `tool_choice="required"` and emits real
`osaurus_agent_tool` frames: `complete` started, `complete` completed with
`is_error=false` and `end_run=true`, then exact final text
`a9a6e4fc current PR agent loop executed complete tool with Gemma 26B A4B JANG_4M QAT and no parser leak.`.
The agent SSE scan has no replacement characters, U+FFFE, raw `<think>`, raw
tool/protocol markers, configured weird-word hits, or non-ASCII output. The
agent-only cache snapshot shows paged KV off, disk-backed restore,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=5`,
`rotating_kv_layer_count=25`, and `turbo_quant_kv_layer_count=0`, but only
misses and no disk L2 hit/store on that short tool row.

The same proof root has a 26B A4B JANG_4M VL red-image API row using a real
inline 32x32 PNG data URL. First and repeat requests both return exact `Red`,
emit prefill progress `0/307` queued, `0/307` running, and `307/307`
complete, and include usage. Token rates are `13.0881 tok/s` first and
`12.8728 tok/s` repeat. The VL scans have no replacement/control/non-ASCII or
protocol marker leakage. Repeat cache reports paged KV off,
`disk_l2_hits=1`, `disk_l2_stores=5`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=5`,
`rotating_kv_layer_count=25`, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`. Health reports RAM feasibility `ok`, but the
post-agent process RSS sample is `13338640 KB`, so this is live proof on the
M5 Max MacBook, not lower-spec physical-footprint proof.

Current PR head `563ee034` adds fresh 31B MXFP4 live `/agents/default/run` and
VL cache proof. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-563ee034-agent-31b-mxfp4-20260612T152853Z`.
The agent request uses `tool_choice="required"` and emits real
`osaurus_agent_tool` frames: `complete` started, `complete` completed with
`is_error=false` and `end_run=true`, then exact final text
`563ee034 current PR agent loop executed complete tool with Gemma 31B MXFP4 QAT and no parser leak.`.
The agent SSE scan has no replacement characters, U+FFFE, raw `<think>`, raw
tool/protocol markers, configured weird-word hits, or non-ASCII output. The
agent-only cache snapshot shows paged KV off, disk-backed restore,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=10`,
`rotating_kv_layer_count=50`, and `turbo_quant_kv_layer_count=0`, but only
misses and no disk L2 hit/store on that short tool row.

The same proof root has a 31B MXFP4 VL red-image API row using a real inline
32x32 PNG data URL. First and repeat requests both return exact `Red`, emit
prefill progress `0/307` queued, `0/307` running, and `307/307` complete, and
include usage. Token rates are `7.7439 tok/s` first and `7.7445 tok/s`
repeat. The VL scans have no replacement/control/non-ASCII or protocol marker
leakage. Repeat cache reports paged KV off, `disk_l2_hits=1`,
`disk_l2_stores=5`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=10`,
`rotating_kv_layer_count=50`, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`. Health reports RAM feasibility `ok` with
projected memory `23437801305` bytes; this is live proof on the M5 Max
MacBook, not lower-spec physical-footprint proof.

Current PR head `777736b2` adds the matching fresh 31B JANG_4M live
`/agents/default/run` and VL cache proof. Proof root:
`/tmp/osaurus-gemma-proof/pr1469-777736b2-agent-31b-jang-20260612T153239Z`.
The agent request uses `tool_choice="required"` and emits real
`osaurus_agent_tool` frames: `complete` started, `complete` completed with
`is_error=false` and `end_run=true`, then exact final text
`777736b2 current PR agent loop executed complete tool with Gemma 31B JANG_4M QAT and no parser leak.`.
The agent SSE scan has no replacement characters, U+FFFE, raw `<think>`, raw
tool/protocol markers, configured weird-word hits, or non-ASCII output. The
agent-only cache snapshot shows paged KV off, disk-backed restore,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=10`,
`rotating_kv_layer_count=50`, and `turbo_quant_kv_layer_count=0`, but only
misses and no disk L2 hit/store on that short tool row.

The same proof root has a 31B JANG_4M VL red-image API row using a real inline
32x32 PNG data URL. First and repeat requests both return exact `Red`, emit
prefill progress `0/307` queued, `0/307` running, and `307/307` complete, and
include usage. Token rates are `8.2956 tok/s` first and `7.9948 tok/s`
repeat. The VL scans have no replacement/control/non-ASCII or protocol marker
leakage. Repeat cache reports paged KV off, `disk_l2_hits=1`,
`disk_l2_stores=5`, `block_disk_store.enabled=true`,
`effective_kv_mode="turbo(3,3)"`, `kv_layer_count=10`,
`rotating_kv_layer_count=50`, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`. Health reports RAM feasibility `ok` with
projected memory `31819264141` bytes, while the post-agent process RSS sample
is `18208768 KB`, so this remains live proof on the M5 Max MacBook, not
lower-spec physical-footprint proof.

The Gemma QAT harness target is deliberately practical: each MXFP4 and JANG_4M
bundle must score decently enough to prove real Osaurus tool use and teammate
testability, even if the score is not perfect. A row is not acceptable if it
gets that score by disabling tools, skipping hard cases, hiding corrupted text,
or counting source/BF16 Gemma folders instead of the OsaurusAI QAT bundles.

| Model | Route | AgentLoop (17) | Tested | Notes |
|---|---|---|---|---|
| Gemma 4 31B QAT MXFP4 | `osaurusai--gemma-4-31b-it-qat-mxfp4` | 14 ✓ / 3 ✗ | 2026-06-12 | First full 31B MXFP4 AgentLoop row on PR #1469 head `84752a8a`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-84752a8a-harness-31b-mxfp4-20260612T135746Z/31b-mxfp4-agentloop.json`; summary artifact `31b-mxfp4-agentloop.summary.json`. The row proves real tool use across `capabilities_load`, `clarify`, `complete`, `file_edit`, `file_read`, `file_search`, `file_write`, `shell_run`, and `todo`, and completed without Metal abort or fatal marker. It fails `compaction-stress` because it reaches `iterationCapReached`, expected compaction watermark never records, and final text is empty/misses `log4`; it fails `parallel-batch-reads` because the correct `combined.txt` is written but the run reaches `iterationCapReached` with empty final text instead of finalizing; it fails `search-then-multi-file-edit` because the model first uses wrong paths, then shell `sed` commands that do not remove all `fetchDataV1` occurrences, and finalizes with `grep -rq fetchDataV1 src/` still exiting 0. Protocol marker scan found no replacement characters, U+FFFE, raw `<think>`, raw tool/protocol, `tool:`, `args:`, or `done:` leakage. The visible corruption scan found no configured weird-character hits in final text. Cache artifacts show 11 disk KV safetensor files, about `9.7G`, and 11 `cache_entries`; this is cache-material evidence, not standalone TTFT/L2-hit proof. Runtime was `real 1361.82`, `user 461.94`, `sys 679.79`; sampled RSS varied from about `0.43G` to `1.98G`, but this is process RSS only and still does not satisfy lower-spec Activity Monitor physical-footprint proof. |
| Gemma 4 31B QAT JANG_4M | `osaurusai--gemma-4-31b-it-qat-jang_4m` | 15 ✓ / 2 ✗ | 2026-06-12 | First full 31B JANG_4M AgentLoop row on PR #1469 head `c21b9988`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-c21b9988-harness-31b-jang4m-20260612T133706Z/31b-jang4m-agentloop.json`; summary artifact `31b-jang4m-agentloop.summary.json`. The row proves real tool use across `capabilities_load`, `clarify`, `complete`, `file_edit`, `file_read`, `file_search`, `file_write`, `shell_run`, and `todo`, and completed without Metal abort or fatal marker. It fails `compaction-stress` because it reaches `iterationCapReached` with compaction occurred but no final text and missing final mention of `log4`; it fails `wrap-up-on-budget` because it reaches `iterationCapReached` with empty final text after reading `main.py` and `converter.py`. Protocol marker scan found no replacement characters, U+FFFE, raw `<think>`, raw tool/protocol, `tool:`, `args:`, or `done:` leakage. Keep this row partial because visible ordinary text corruption remains in a passing final: `The um of the number on the first line (41) and t number on the lashest line (9) is 50.` Cache artifacts show 11 disk KV safetensor files, about `9.7G`, and 11 `cache_entries`; this is cache-material evidence, not standalone TTFT/L2-hit proof. Runtime was `real 1010.63`, `user 443.20`, `sys 144.43`; peak sampled RSS during the run was about `17.9G`, so lower-spec physical-footprint proof is still not satisfied. |
| Gemma 4 26B A4B QAT MXFP4 | `osaurusai--gemma-4-26b-a4b-it-qat-mxfp4` | 13 pass / 4 fail + abort | 2026-06-12 | First 26B A4B MXFP4 AgentLoop attempt on PR #1469 head `c7892240`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-c7892240-harness-26b-a4b-mxfp4-20260612T123831Z/26b-a4b-mxfp4-agentloop.json`; summary artifact `26b-a4b-mxfp4-agentloop.summary.json`. The row proves real tool use across `capabilities_load`, `clarify`, `complete`, `file_edit`, `file_read`, `file_write`, `shell_run`, and `todo`, but the command terminated abnormally with `MLX/ErrorHandler.swift:343: Fatal error: [METAL] Command buffer execution failed ... stream.cpp:78`, so this is blocked/failed proof, not a promoted partial. Failed cases are `capabilities-load-midrun`, `compaction-stress`, `duplicate-call-avoidance`, and `search-then-multi-file-edit`. The compaction output looped with visible corruption such as `log2.xt`, `tlog4.xt`, `havte heckecd`, `shofuld hek`, and repeated `I'lll hekcc og4.txt`; `duplicate-call-avoidance` answered `10` instead of `50`; `search-then-multi-file-edit` exited with no tool calls. Marker scan found no replacement characters or raw protocol/tool marker leakage. The harness root wrote 36 disk KV safetensor cache entries, about `9.9G`; this is cache-material evidence only and does not prove TTFT/L2-hit quality. |
| Gemma 4 26B A4B QAT JANG_4M | `osaurusai--gemma-4-26b-a4b-it-qat-jang_4m` | 15 ✓ / 2 ✗ | 2026-06-12 | First 26B A4B JANG_4M AgentLoop row on PR #1469 head `eb54672e`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-eb54672e-harness-26b-a4b-jang4m-20260612T130918Z/26b-a4b-jang4m-agentloop.json`; summary artifact `26b-a4b-jang4m-agentloop.summary.json`. The row proves real tool use across `capabilities_load`, `clarify`, `complete`, `file_edit`, `file_read`, `file_search`, `file_write`, `shell_run`, and `todo`, and unlike the 26B MXFP4 row it completed without a Metal abort. It fails `capabilities-load-midrun` because `capabilities_load({"ids":["tool/file_write"]})` is rejected as disabled/already-loaded and `loaded.txt` is missing, and `duplicate-call-avoidance` because the model reads `data.txt` once but reports `1 + 9 = 10` instead of the expected `50`. Protocol marker scan found no replacement characters, U+FFFE, raw `<think>`, raw tool/protocol, `tool:`, `args:`, or `done:` leakage. Keep this row partial because visible ordinary text corruption remains in passing finals, including `log1.xt`, `tlog2.xt`, `contens`, `emperature`, `functiotns`, `whcoich`, `nvecorsion`, `directoory`, and `convertetr`. The harness root wrote 35 disk KV safetensor cache entries, about `9.9G`, with 35 cache index rows; this is cache-material evidence, not standalone TTFT/L2-hit proof. |
| Gemma 4 12B QAT MXFP4 | `osaurusai--gemma-4-12b-it-qat-mxfp4` | 16 ✓ / 1 ✗ | 2026-06-12 | First 12B MXFP4 AgentLoop row on PR #1469 head `5c29f17d`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-5c29f17d-harness-12b-mxfp4-20260612T122047Z/12b-mxfp4-agentloop.json`; summary artifact `12b-mxfp4-agentloop.summary.json`. The row proves real tool use across `capabilities_load`, `clarify`, `complete`, `file_edit`, `file_read`, `file_search`, `file_write`, `shell_run`, and `todo`. It fails only `compaction-stress`: expected compaction watermark never recorded, final text missed `log4`, and the failed case ended with empty final text after only `todo`, `file_read`, and `todo`. Marker scan found no replacement characters or raw protocol/tool marker leakage. The harness root wrote 25 disk KV safetensor cache entries, about `9.7G`. Keep this row partial because visible text corruption remains in a passing final (`I have reated`, `recquested checklist`), and harness cache artifacts are not standalone TTFT/L2-hit proof. |
| Gemma 4 12B QAT JANG_4M | `osaurusai--gemma-4-12b-it-qat-jang_4m` | 16 ✓ / 1 ✗ | 2026-06-12 | First 12B JANG_4M AgentLoop row on PR #1469 head `923f7edb`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-923f7edb-harness-12b-jang4m-20260612T120129Z/12b-jang4m-agentloop.json`; summary artifact `12b-jang4m-agentloop.summary.json`. The first attempt hit the known local SwiftPM/MLX `default.metallib` bootstrap issue after build; the pinned vMLX `prepare-mlx-metal.sh` prep installed `default.metallib` and `mlx.metallib` beside `osaurus-evals`, then the rerun completed. The row proves real tool use across `capabilities_load`, `clarify`, `complete`, `file_edit`, `file_read`, `file_search`, `file_write`, `share_artifact`, `shell_run`, and `todo`. It fails only `compaction-stress`: expected compaction watermark never recorded, final text missed `log4`, and visible text is corrupted (`taskcompleted`, `heckingc het`, `Summfary`, `Nonel`, `fivet og files containl`). Marker scan found no replacement characters or raw protocol/tool marker leakage. The harness root wrote 25 disk KV safetensor cache entries, about `9.7G`; keep this row partial until visible text corruption and compaction behavior are fixed. The earlier live `/agents/default/run` checkpoint remains useful API proof for real `osaurus_status` execution, but this harness score is the current compatibility row. |
| Gemma 4 E4B QAT MXFP4 | `osaurusai--gemma-4-e4b-it-qat-mxfp4` | 15 ✓ / 2 ✗ | 2026-06-12 | First E4B MXFP4 AgentLoop row on PR #1469 head `343ca2f2`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-343ca2f2-harness-e4b-mxfp4-20260612T114705Z/e4b-mxfp4-agentloop.json`; summary artifact `e4b-mxfp4-agentloop.summary.json`. The row proves real tool use across `capabilities_load`, `clarify`, `complete`, `file_edit`, `file_read`, `file_search`, `file_write`, `share_artifact`, `shell_run`, and `todo`. It fails `duplicate-call-avoidance` and `write-new-file`; `write-new-file` ultimately created the correct file but first emitted malformed `file_write` JSON, so it remains a real tool-call quality failure. The JSON text scan found no replacement characters or protocol/tool marker leakage, but visible word/character corruption remains in finals such as `north outh`, `EcoRROR`, `VERScION`, `exeuted cthe`, and `directocsry`; keep this partial. |
| Gemma 4 E4B QAT JANG_4M | `osaurusai--gemma-4-e4b-it-qat-jang_4m` | 14 ✓ / 3 ✗ | 2026-06-12 | First E4B JANG_4M AgentLoop row on PR #1469 head `8d16e648`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-8d16e648-harness-e4b-jang4m-20260612T113615Z/e4b-jang4m-agentloop.json`; summary artifact `e4b-jang4m-agentloop.summary.json`. The row proves real tool use across `capabilities_load`, `clarify`, `complete`, `file_edit`, `file_read`, `file_search`, `file_write`, `share_artifact`, `shell_run`, and `todo`. It fails `duplicate-call-avoidance`, `search-then-multi-file-edit`, and `wrap-up-on-budget`. The JSON text scan found no replacement characters or protocol/tool marker leakage, but multiple finals have visible word/character corruption such as `reaal-2.xt`, `contaitns`, `daota.txt`, and `exshellactly`, so this is a useful partial score, not a clean promotion. |
| Gemma 4 E2B QAT MXFP4 | `osaurusai--gemma-4-e2b-it-qat-mxfp4` | 11 ✓ / 6 ✗ | 2026-06-12 | First full MXFP4 AgentLoop row on PR #1469 head `eb9fe17f`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-eb9fe17f-harness-20260612T102258Z/e2b-mxfp4-agentloop.json`; smoke artifact `e2b-mxfp4-write-new-file-agentloop.json` passed `write-new-file` with `file_write` and correct `TODO.md` contents. Full row proves real tool use across `capabilities_load`, `clarify`, `file_edit`, `file_read`, `file_search`, `file_write`, `shell_run`, and `todo`, but stays partial. Fails `clarify-on-ambiguity`, `compaction-stress`, `duplicate-call-avoidance`, `recover-from-failing-command`, `search-then-multi-file-edit`, and `todo-discipline-multistep`; multiple finals show visible character/spelling corruption, so this is decent tool capability evidence but not a clean promotion. |
| Gemma 4 E2B QAT JANG_4M | `osaurusai--gemma-4-e2b-it-qat-jang_4m` | 13 ✓ / 4 ✗ | 2026-06-12 | First full QAT Gemma local AgentLoop row on PR #1469 head `e03cecf9`. Artifact: `/tmp/osaurus-gemma-proof/pr1469-e03cecf9-harness-20260612T095729Z/e2b-jang4m-agentloop.json`. Fails `compaction-stress`, `duplicate-call-avoidance`, `search-then-multi-file-edit`, and `todo-discipline-multistep`; several finals show visible character/spelling drift, so do not promote this row beyond partial. A rejected follow-up experiment forcing post-tool `tool_choice:none` inside `AgentLoopEvaluator` kept `duplicate-call-avoidance` failed and made `search-then-multi-file-edit` stop after only `file_search` with fake edit prose, so the harness loop must preserve auto tools until a proven finalization signal exists. |
| Qwen3.5-4B-OptiQ-4bit | `mlx-community/Qwen3.5-4B-OptiQ-4bit` | 16 ✓ / 1 flaky (passed on retry) | 2026-06-11 | Small-model regression lane; re-confirmed after the sandbox-eval harness changes (same documented `search-then-multi-file-edit` path-thrashing flake, passes on retry). |

Apple Foundation Models are classified `tiny` with tools disabled and are
not run against the agent suites.

## Gemma QAT PR Checkpoint

Post-main merge checkpoint for Osaurus PR #1469, 2026-06-12:

- Current Osaurus pin target is
  `020ec0d5f96cc158dd82ea1973cae66c0b70face` from
  merged `osaurus-ai/vmlx-swift` PR #44. This is the vMLX main commit containing
  the Gemma 4 QAT loader fix plus main's paged-cache default, prefill progress,
  and Model2Vec static embedding APIs. The earlier live app proof on
  `c7613dcc7c3a94432230f684d7a2619a5fdcec4e` remains valid as live evidence
  for the Gemma QAT loader/parser/cache behavior, but the shipping PR pin is
  now the vMLX main `020ec0d5` revision.
- Focused post-vMLX-main source proof passed with full Xcode:
  `/tmp/osaurus-gemma-proof/pr1469-vmlx-main-pin-20260612T202611Z/focused-tests.log`.
  The run executed 94 selected tests across `RuntimePolicySourceTests`,
  `AgentToolLoopParallelBatchTests`, and
  `ModelManagerTests/discoverLocalModels_timeoutDoesNotCacheEmptyResult`.
- Pre-main-merge Release app build proof passed on the combined PR-head
  `834498a8`:
  `/tmp/osaurus-gemma-proof/xcode-build-release-app-pin-834498a8-direct-20260612T192605Z.log`
  reports `** BUILD SUCCEEDED **`, and the ad-hoc signed app verifies with
  `codesign --verify --deep --strict` at
  `build/XcodeDerivedData-gemma-834498a8-direct-nosign-20260612T192605Z/Build/Products/Release/osaurus.app`.
- `scripts/live-proof/assert-osaurus-vmlx-pr-readiness.sh` passes on the
  merged tree with all four vMLX pin surfaces set to `020ec0d5`, the SwiftPM
  checkout HEAD matching that pin, keychain-free proof paths intact, no hidden
  local sampler defaults, OpenResponses/cache wiring intact, server settings
  runtime wiring intact, and Gemma parser/tool regressions present in the wired
  checkout.
- Audio is deferred for this PR. It is not part of the correctness merge gate.
  Speed benchmarking is also deferred; the current merge gate is Gemma QAT
  correctness: MXFP4/JANG_4M loads, real tool calls, parser/no-leak behavior,
  paged cache off by default, disk L2/prefix telemetry, prefill events on the
  direct chat surface, and repeat cache hits.

## Gemma Speed + Audio Checkpoint (vMLX main 1ab081eb)

Follow-up checkpoint, 2026-06-12, after merged `osaurus-ai/vmlx-swift`
PR #46 (vMLX main `1ab081eb1d51568ae636f64b9ac76cd3ab4d2534`):

- The audio and raw-speed deferrals from the previous checkpoint are
  resolved at the engine level. vMLX main now carries:
  - the TaskLocal prefill reporter crash fix (`dc52096`), which the
    previous `020ec0d5` pin was missing — raw Gemma 4 QAT generation on
    that pin segfaults at generation start (`RunBench` repro,
    `/tmp/gemma4-speed-proof/e2b-mxfp4-perf.log`);
  - Gemma 4 audio for every checkpoint that ships audio tensors: 12B
    unified raw-waveform chunking (Gemma4UnifiedAudioFeatureExtractor
    parity) and the E-series conformer `audio_tower` port (proof: E2B
    transcribed synthesized speech verbatim,
    `/tmp/gemma4-audio-proof/PROOF-SUMMARY.txt`). 26B-A4B/31B ship no
    audio tensors; Osaurus now reports audio per-bundle from the weight
    map instead of a blanket "runtime unwired" refusal;
  - decode-speed levers vs the documented llama.cpp E2B GGUF baseline
    (7384.7 prefill / 173.7 decode tok/s): TaskLocal fix 120.1 →
    tied-head q6 132.5 → compiled decode 165.3 tok/s (MXFP4; JANG_4M
    165.1), and prefill measured at 10,068 tok/s on a 1,957-token
    prompt — above the GGUF prefill baseline. Bench artifacts under
    `/tmp/gemma4-speed-proof/`.
- Osaurus wires the levers as the Decode Performance settings section
  (`performance.tiedHeadCodec`, default fp16 passthrough;
  `performance.compiledDecode`, default off — experimental pending the
  PR #1173 model-switch corruption root cause). Defaults change no
  behavior; both levers act on the next model load via
  `ModelRuntime.applyPerformancePolicy`.
- The E2B JANG_4M ~7 GB load footprint is the bundle's own on-disk size
  (7.3 GB, mixed-precision profile) mapped via mmap — not a runtime
  leak. MXFP4 E2B is 3.8 GB on disk / ~1.7 GB footprint.

## Provider wire-format requirements

Quirks discovered live, handled automatically by Osaurus. Useful if you
connect these providers through a custom endpoint.

| Provider | Requirement | Osaurus handling |
|---|---|---|
| OpenAI (api.openai.com), Azure OpenAI | Rejects `oneOf`/`anyOf`/`allOf`/`enum`/`const`/`not` at the **top level** of function `parameters` (HTTP 400 `invalid_function_parameters`); nested uses are fine. | Top-level offenders stripped on the wire for enforcing providers only; tool arguments are still validated locally against the full schema. |
| Anthropic | Same restriction on `input_schema` (`oneOf`/`allOf`/`anyOf`). | Same sanitizer. |
| Anthropic (claude-fable family) | Rejects `temperature` outright: HTTP 400 "`temperature` is deprecated for this model." | `temperature`/`top_p` omitted for the family; the model runs on its native defaults. |
| Anthropic | Real-time cyber safeguard can block a turn at the API level: `stop_reason: "refusal"` with **zero content blocks** (observed on secret/token-relay prompts). | Surfaced as an explicit stream error carrying the provider's `stop_details.explanation` instead of a silent empty reply. |
| Google Gemini (3.x) | Function calls carry **thought signatures** that must be echoed back when the call is re-sent in history; missing signatures are an HTTP 400. | Signatures captured per tool call and re-emitted on every surface (chat, HTTP, eval driver). |
| DeepSeek (thinking mode) | `reasoning_content` must be echoed back on assistant turns in multi-round tool conversations; omitting it is an HTTP 400. | Reasoning content preserved on assistant history turns and stripped automatically for providers that reject the field. |
| Google Gemini | OpenAPI-3.0-subset schema validator (rejects `$ref`, `additionalProperties`, top-level combinators, type unions, …). | Dedicated recursive schema sanitizer (`geminiCompatibleSchema`). |
| OpenAI reasoning models (o-series, gpt-5+) | Require `max_completion_tokens` (reject `max_tokens`); forbid `temperature`/`top_p`. | Detected by model-id profile; parameters switched/omitted automatically. |
| Mistral, Groq, OpenRouter, DeepSeek, … (strict OpenAI-compat) | Reject `max_completion_tokens` (HTTP 422). | `max_tokens` emitted by default for non-reasoning models. |
| xAI, Groq, OpenRouter | Accept full JSON Schema in tool parameters. | No sanitization — full schemas sent as-is. |
| OpenAI-compatible streaming (xAI/Grok, Azure OpenAI) | Per-request token `usage` is only returned mid-stream when `stream_options.include_usage` is set, and the final usage chunk arrives **after** `finish_reason` (including on tool-call turns). Without it, streamed remote runs report 0 completion tokens. | Osaurus sets `stream_options.include_usage` on streaming requests to these upstreams, briefly defers the tool-call dispatch so the trailing usage chunk lands first, then surfaces the real `completion_tokens` as the same in-band stats hint the local runtime emits. Throughput (`tok/s`) is the provider's value when present, else left nil — never fabricated. Other providers and the non-streaming path are byte-identical on the wire. |

## Known model findings

Model-behavior observations from failed or notable eval rows. These are not
harness bugs; they're scored honestly and tracked across model versions.

- **gpt-5.5 — terse finalization.** Completes deliverables correctly but
  under-narrates: final replies may omit a summary of what was done, and it
  can keep verifying past the iteration budget instead of finishing. If you
  use gpt-5.5 for agent work, ask for an explicit summary in your prompt.
- **grok-4.3 — post-compaction recall.** After long-context compaction it
  may state details from memory instead of re-reading; the harness marks
  compacted content "no longer visible — re-fetch" but compliance is
  intermittent.
- **grok-4.3 — `file_write` fidelity.** Occasionally introduces leading
  whitespace when re-writing file content verbatim. Byte-exact copy tasks
  are safer via `shell_run` (`cp`).
- **gemini-3.1-pro-preview — meta-narration.** May finish with "I provided
  an explanation" instead of the explanation itself when the deliverable is
  the reply text (deliverable files are unaffected).
- **deepseek-v4-pro — budget overruns.** Tends to keep working past tight
  iteration budgets instead of heeding wrap-up warnings; on open-ended
  tasks give it room or expect a cut-off rather than a summary.
- **claude-fable-5 — provider safety refusals on secret-shaped prompts.**
  Anthropic's API-level cyber safeguard blocks turns that look like
  secret/token relays (`stop_reason: "refusal"`, zero content) before the
  model can act — even legitimate workflows like storing a secret with
  `sandbox_secret_set` and reading it back. Rewording helps only partially;
  Anthropic offers a policy-exemption request flow. No model-behavior
  negative findings to date.
- **grok-4.3, gpt-5.5 — unadvertised-tool reluctance.** Will not call a
  freshly registered plugin tool (`{pluginId}_{toolId}`) that is absent from
  the request's tool schema, even when told it is callable; both route
  around it by executing the plugin's script via `sandbox_exec` instead
  (gpt-5.5 even discovers and loads the tool via `capabilities_load` but
  still never invokes it). claude-fable-5 and gemini-3.1-pro-preview call
  the unadvertised tool correctly. (Osaurus intentionally freezes the tool
  schema for the run — deferred-schema policy — and resolves registered
  tools by name at execution time.)
- **gpt-5.5 — model-side secret-handling policy.** Refuses to call
  `sandbox_secret_set` with an inline `value`, citing its own
  secret-handling rules, and insists on the interactive no-value prompt
  flow — which only exists in the chat UI. Unlike claude-fable-5's
  API-level safeguard this is the model's own choice (the request is never
  blocked by the provider). Headless/automated secret seeding with gpt-5.5
  is unreliable; store secrets via the UI prompt flow instead.

## Testing a new model

```bash
# 1. Export the provider's API key (see prefixes below)
export OPENAI_API_KEY=...   # openai/<model>
export ANTHROPIC_API_KEY=.. # anthropic/<model>
export XAI_API_KEY=...      # xai/<model>
export GEMINI_API_KEY=...   # google/<model>
export DEEPSEEK_API_KEY=... # deepseek/<model>
export GROQ_API_KEY=...     # groq/<model>
export OPENROUTER_API_KEY=. # openrouter/<model>

# 2. Optional: fixed judge for cross-model comparability
export JUDGE_MODEL=xai/grok-4.3   # needs XAI_API_KEY

# 3. Run the regression lab against a saved baseline
scripts/evals/agent-loop-regression-lab.sh \
  --baseline build/eval-baselines/<model>/agent-loop \
  --model <prefix>/<model-id> \
  --out-dir build/eval-reports/<model>-agent-loop-lab
```

The lab runs `AgentLoop` and `AgentLoopFrontier` by default, captures raw
per-suite JSON under `reports/`, and writes `regression-summary.json` plus
`regression-summary.md`. Use the Markdown summary as the short proof block for
new rows; keep the JSON paths for failure attribution and later comparisons. To
compare already-captured reports without rerunning a model, pass `--current
<path>` alongside `--baseline <path>`.

Keys ride in ephemeral in-memory providers — never written to disk or
Keychain. New providers need a preset in
`Packages/OsaurusEvals/Sources/OsaurusEvalsKit/RemoteProviderBootstrap.swift`.

The SandboxFrontier lane additionally needs a set-up sandbox host and an
entitlement-signed CLI binary (VM boot requires
`com.apple.security.virtualization`); follow the run instructions in
`Packages/OsaurusEvals/Suites/SandboxFrontier/README.md`.

When adding a row: record pass/fail counts, the date, and attribute every
failure (harness error vs. model finding). Harness errors must be fixed and
the lane re-run before the row is published.
