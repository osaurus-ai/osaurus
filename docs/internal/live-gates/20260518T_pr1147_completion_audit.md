# PR 1147 Completion Audit - vmlx-swift Switch

Timestamp: 2026-05-18 13:53 PDT

PR: https://github.com/osaurus-ai/osaurus/pull/1147

Head at audit: `82c763eb` plus the working-tree `/admin/cache-stats` fix.

This is a completion audit for the Osaurus switch to consolidated
`vmlx-swift`. It is intentionally not a production-clear report. The current
state is source-wired plus checklist-locked; the required real-user live matrix
is still open until artifact folders are attached for each row below.

## Objective Restated

The PR is production-ready only when Osaurus proves, through the chat app and
HTTP APIs, that consolidated `vmlx-swift` handles each local model family with:

- correct model discovery from files and weights, not names;
- correct UI defaults, visible controls, and saved-setting isolation;
- correct request construction for chat UI, `/v1/chat/completions`,
  `/v1/responses`, `/v1/messages`, `/api/chat`, and `/api/generate`;
- default cache stack behavior with prefix, paged, block L2, SSM companion,
  DSV4 native cache, ZAYA CCA, media cache, and TurboQuant KV declared active
  or N-A per topology;
- ON/OFF inverse rows for reasoning, tools, streaming, prefix cache, paged
  cache, block L2, VLM/media, MTP, sleep/wake, and diagnostic flags where
  valid;
- multi-turn visible coherency, no loops, no parser/tag leakage, and no
  hidden sampler or reasoning guard;
- no forced output-shaping behavior: sampler defaults, repetition penalties,
  reasoning rail selection, `</think>` close tokens, token/logit shaping, and
  parser repairs must come only from bundle metadata or explicit user/API
  kwargs, otherwise the row stays red until the real root cause is fixed;
- TTFT, tok/s, RSS, Activity Monitor physical footprint, cache stats, and L2
  bytes for each live row;
- old standalone inference libraries removed from active Osaurus inference
  paths.

## No-Fake-Guard Release Contract

All model families and artifact formats in scope - VL, MTP, JANG, JANGTQ, MXFP,
MLX, dense, MoE, hybrid SSM, sliding-window, DSV4-native cache, ZAYA CCA, and
omni/media paths - must be coherent through the real runtime path. A model row
cannot be marked production-clear because Osaurus or vmlx hid the symptom with a
family clamp, parser repair, forced stop token, or output rewrite.

For every model row and every fix made after a red run, the artifact folder must
contain a before/after live proof pair:

- pre-fix failure artifact: the raw incoherent, looping, leaking, cache-wrong,
  or wrong-media output plus the request payload, resolved sampler defaults,
  cache stats, TTFT, tok/s, RSS, and physical-footprint context;
- root-cause note: whether the real issue was template routing, tokenizer/BOS or
  EOS handling, native `top_k` or generation metadata resolution, attention
  architecture selection, cache restore, SSM rederive, media preprocessing,
  MTP verification/commit state, tool/reasoning parser selection, or scheduler
  lifecycle;
- post-fix passing artifact: the same live row rerun with visible coherent text,
  no loop, no hidden reasoning-only fake pass, no marker leak, normal stop
  reason, and the expected cache/memory/timing counters.

The following are release blockers unless they are explicitly user/API kwargs
or values read from `jang_config.json`, `generation_config.json`, or a validated
engine tuning file:

- forced temperature, top-p, top-k, min-p, repetition, frequency, presence, EOS,
  or length defaults used to make a broken family look coherent;
- forced `</think>` close tokens, reasoning rail rewrites, or conversion of
  reasoning deltas into visible content to manufacture a clean answer;
- parser output repair that turns raw XML, DSML, Harmony, Gemma, Mistral, GLM,
  Qwen, MiniMax, or tool sentinel leakage into an apparent structured response;
- name-based MTP, VLM, or cache enablement. MTP requires real `mtp.*` tensor
  evidence plus an unblocked `vmlx_mtp_tuning.json`; CRACK or display-name-only
  rows must stay MTP-disabled with a recorded reason;
- generic cache fallback that ignores the owning topology, such as KV-only hits
  on hybrid SSM without companion state, media cache reuse across different
  images/videos, DSV4 through invalid generic paged/KV controls, or ZAYA CCA
  attached to the wrong media/session.

Reasoning ON/OFF must be tested by family, not assumed from one parser:

- Qwen/QwQ/MiniMax-style `enable_thinking` rows must prove OFF emits no
  reasoning leak and ON keeps reasoning in the reasoning channel;
- DSV4 must prove `instruct`, high, and `reasoning_effort=max` pass through
  unchanged;
- Hy3 must use its native `reasoning_effort` contract rather than generic
  `enable_thinking`;
- Ling defaults off but must preserve explicit opt-in and keep reasoning deltas
  separate from visible text;
- unsupported families must hide or ignore reasoning controls without adding
  stale request fields or cache-key components.

VLM and omni rows must send real media. Image/video/audio controls are valid
only when capability detection, processor files, and runtime support agree.
Every VLM row needs image+text, text-only follow-up, different-media, repeated
media, unsupported-media inverse, and cache-salt proof. Text-only T2 must show
media salt nil/absent; repeated media must show a topology-valid hit or an
explicit N-A; different media must not reuse the prior visual state.

Cache and batching rows must prove both single-batch and, where feasible,
multi-batch behavior. Prefix, paged, block-L2 disk, TurboQuant KV encode/decode,
SSM companion, DSV4 native cache/pool, ZAYA CCA, media cache, sleep/wake, and
configured L2 max-GB enforcement require ON/OFF or topology-N-A evidence. A
coherent one-turn response without cache counters, hit/miss movement, memory
context, and token/s is not enough.

The production readiness wording is therefore deliberately strict: all rows are
red or partial until live Osaurus app/API artifacts show coherent multi-turn
answers under real bundle defaults and explicit kwargs, with no fake guard and
with the correct cache/scheduler/parser/media path for that model.

## Prompt-to-Artifact Completion Map

| Requirement | Current evidence | Missing before production-clear |
|---|---|---|
| Qwen VL / Qwen3.6 MTP VL through UI and APIs | Live matrix names Qwen3VLProcessor, MRoPE, media salt, video frame rows, native `top_k`, `chat_template_kwargs`, and `vmlx_mtp_tuning.json`. Local model census confirms Qwen3.6 MTP/VL bundles and processor files exist. | Osaurus chat-app image+text T1, text-only T2, different-image T3, repeated-media hit, video row, `/v1/chat/completions`, `/v1/responses`, saved settings, cache stats, TTFT/tok/s/RSS/footprint artifacts. |
| Gemma VL / Gemma reasoning | Live matrix separates Gemma4 VLM/Harmony from Gemma3n text-only partial evidence and requires media controls only after real detection. | Osaurus Gemma4 image/video/text rows, Harmony no-leak route rows, Gemma tool cards, cache stats, and a root cause for Gemma3n UTF drift before any production-clear text claim. |
| ZAYA / ZAYA-VL | Live matrix requires ZayaCCACache/path-dependent media state, no stale thinking carryover, no sampler clamp, and separate ZAYA-VL media rows. Local census confirms ZAYA text and VL variants plus ZAYA VL processor files. | Osaurus ZAYA-VL image/video/text-only resume rows, CCA cache proof, speed target watch, no cross-session media state reuse, and root-cause closure for current red ZAYA direct-mode rows. |
| Nemotron Omni / Parakeet / RADIO | Live matrix names Parakeet pre-encode, RADIO/vision facts, live voice chunk stability, repeated-video alias, and no reasoning-only short-budget false pass. Local census confirms Nemotron Omni variants and processor files. | Osaurus app/API audio/video/image/text-only resume rows, live voice resident pre-encode, cache stats, TTFT/tok/s/RSS/footprint, and unsupported-media error proof. |
| DSV4 Flash renderer and runtime | Source-policy tests pin native DSV4 cache copy, SWA+CSA+HSA, fixed/disabled block size 256, generic q4/q8 disabled, pool quant visible, JIT disabled, model metadata defaults, and invalid CLI flags omitted. | Final Osaurus UI screenshot/log and API artifacts proving those exact rendered settings, DSML tool rows, `reasoning_effort=max` pass-through, native cache stats, long/growing-chat behavior, TTFT/tok/s/footprint. |
| MiniMax reasoning/tools | Live matrix requires reasoning channel separation, MiniMax tool parser, no MTP from CRACK/name, cache stats, and no forced close or repetition penalty. | Osaurus UI/API multi-turn reasoning and tool-result artifacts with stream terminal usage and cache proof. |
| Ling / Hy3 / hybrid SSM | Live matrix requires Ling default-off plus explicit opt-in reasoning routing, stale Qwen thinking ignored, hybrid cache topology, SSM companion hits/misses/stores, and no KV-only unsafe hit. | Osaurus long-prompt, prefix-overlap, prefix-mismatch, API tool rows, reasoning on/off/default rows, re-derive status, cache stats, and TTFT/footprint artifacts. |
| GLM / GPT-OSS / Mistral / parser families | Live matrix requires parser from base architecture, no marker leakage, and tools only where supported. | Live local model rows when models are present; no production claim without artifacts. |
| Generation defaults and top-k | Live matrix requires UI defaults and omitted HTTP sampler fields to resolve from `generation_config.json` / `jang_config.json`, including native `top_k`. Local census confirms generation config files across target families. | Per-model resolved-kwargs logs from Osaurus UI and every API route; explicit sampler override proof; no hidden temperature/top-p/top-k/repetition floors. |
| Forced behavior audit | Live matrix now requires source/live search for forced sampler defaults, repetition penalties, reasoning rail rewrites, forced `</think>` close tokens, token/logit shaping, and parser output repair. | For every hit, artifact why it was originally added, whether it still fires, and the real template/decode/tokenizer/cache fix or a red-row status. Do not promote app-shaped output as model coherency. |
| Settings carryover and cache-key isolation | Live matrix names reasoning carryover, DSV4 `max` carryover, media carryover, cache OFF/ON restoration, tool/coding context carryover, and generation defaults. | App relaunch and cross-family switch artifacts proving stale reasoning/cache/media/tool settings do not enter another model's request or cache key. |
| Old-library and zombie-code removal | Source-policy tests assert consolidated `vmlx-swift` package pins and VMLX-prefixed imports for tokenizers/Jinja, plus no active old inference package names in current runtime source/docs. | Full final PR audit after all live rows to ensure no new old-library import or CLI path was introduced. |

## Local Model Census Snapshot

This snapshot is from `/Users/eric/models` at audit time. It is only a census,
not runtime proof.

Text / VLM / omni families found:

- DSV4: `/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K`,
  `/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ2`
- Qwen3.6 MTP/VL: `/Users/eric/models/JANGQ/Qwen3.6-27B-JANG_4M-MTP`,
  `/Users/eric/models/JANGQ/Qwen3.6-27B-MXFP4-MTP`,
  `/Users/eric/models/JANGQ/Qwen3.6-27B-MXFP8-MTP`,
  `/Users/eric/models/JANGQ/Qwen3.6-35B-A3B-MXFP4-MTP`,
  `/Users/eric/models/JANGQ/Qwen3.6-35B-A3B-MXFP8-MTP`
- Qwen3.6 non-MTP/CRACK/VL: `/Users/eric/models/dealign.ai/Qwen3.6-27B-JANG_4M-CRACK`,
  `/Users/eric/models/dealign.ai/Qwen3.6-27B-MXFP4-CRACK`,
  `/Users/eric/models/dealign.ai/Qwen3.6-35B-A3B-JANGTQ-CRACK`
- Gemma: `/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK`,
  `/Users/eric/models/mlx-community/gemma-3n-E2B-it-4bit`
- ZAYA: `/Users/eric/models/JANGQ/ZAYA1-8B-JANGTQ4`,
  `/Users/eric/models/JANGQ/ZAYA1-8B-JANGTQ_K`,
  `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ4`,
  `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ_K`,
  `/Users/eric/models/Osaurus/ZAYA1-8B-MXFP4`,
  `/Users/eric/models/Osaurus/ZAYA1-VL-8B-MXFP4`
- Nemotron Omni: `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK`,
  `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-JANGTQ4-CRACK`,
  `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-MXFP4-CRACK`
- MiniMax: `/Users/eric/models/dealign.ai/MiniMax-M2.7-JANGTQ_K-CRACK`,
  `/Users/eric/models/dealign.ai/MiniMax-M2.7-JANG_K-CRACK`,
  `/Users/eric/models/JANGQ/MiniMax-M2.7-Small-JANGTQ`
- Ling/Hy3: `/Users/eric/models/dealign.ai/Ling-2.6-flash-JANGTQ2-CRACK`,
  `/Users/eric/models/dealign.ai/Ling-2.6-flash-MXFP4-CRACK`,
  `/Users/eric/models/JANGQ/Hy3-preview-JANGTQ`,
  `/Users/eric/models/JANGQ/Hy3-preview-JANGTQ_K`

Processor/tuning facts found:

- Qwen3.6 MTP/VL bundles have `preprocessor_config.json`,
  `video_preprocessor_config.json`, and `vmlx_mtp_tuning.json`.
- Qwen3.6 27B MXFP4 MTP tuning selects best depth 2 and explicitly says not to
  force D3 by default.
- Qwen3.6 27B JANG_4M, 27B MXFP8, 35B MXFP4, and 35B MXFP8 MTP tuning selects
  best depth 3 from validated output-equivalent rows.
- Qwen3.6 35B JANG_2K MTP tuning is blocked and must not auto-enable.
- ZAYA-VL and Nemotron Omni variants have VLM processor files where listed
  above.

## Live Artifact Contract

For each model row, use a folder under:

`docs/internal/live-gates/pr1147/<model-slug>/`

Each folder must contain:

- `bundle_census.json`
- `ui_model_picker.log` or screenshot reference
- `ui_chat_settings.log` or screenshot reference
- `ui_server_settings_cli_preview.log`
- `chat_ui_turns.json`
- `chat_completions_stream.jsonl`
- `chat_completions_nonstream.json`
- `responses_stream.jsonl`
- `responses_nonstream.json`
- `messages_stream.jsonl` and `messages_nonstream.json` when supported
- `ollama_chat_generate.json` when supported
- `cache_stats_before_after.json`
- `health_before_after.json`
- `process_memory.csv`
- `media_sequence.json` for VLM/omni rows
- `tool_reasoning_parser.json` for tool/reasoning rows
- `carryover_inverse.json`
- `summary.md`

The first required artifact can be collected without launching a model:

```sh
python3 scripts/pr1147_collect_bundle_census.py \
  --models-root /Users/eric/models \
  --output-dir docs/internal/live-gates/pr1147/bundle-census
```

That helper only reads local metadata and safetensors index files. It fails
closed for native MTP: `auto_enable` can become true only when real `mtp.*`
tensor evidence and a validated, unblocked `vmlx_mtp_tuning.json` are both
present.

Executed for this checkpoint:

- aggregate: `docs/internal/live-gates/pr1147/bundle-census/bundle_census.json`
- table: `docs/internal/live-gates/pr1147/bundle-census/summary.md`
- per-bundle files:
  `docs/internal/live-gates/pr1147/bundle-census/<model-slug>/bundle_census.json`

This closes the file-level census artifact only. It does not close live UI,
HTTP, cache-hit, coherency, media, parser, or memory proof.

The HTTP/API artifact skeleton can be collected from a running Osaurus server
with:

```sh
python3 scripts/pr1147_http_route_probe.py \
  --base-url http://127.0.0.1:1337 \
  --output-dir docs/internal/live-gates/pr1147/http-route-probe
```

Generation route rows require an explicit model and opt-in:

```sh
python3 scripts/pr1147_http_route_probe.py \
  --base-url http://127.0.0.1:1337 \
  --output-dir docs/internal/live-gates/pr1147/<model-slug>/http-routes \
  --model <served-model-name> \
  --run-generation
```

Do not count a route-probe artifact as model proof unless the same folder also
has cache stats, visible output review, parser/no-leak review, timing, and
memory artifacts for the model row.

In generation mode, the route helper now uses unique stream/non-stream output
filenames and captures before/after `/health`, `/admin/cache-stats`, and
process-memory snapshots. That makes the generated `api_routes/` artifact
diagnosable for route status, terminal frames, cache counter movement, and RSS
context, but it still needs human output-tail review before any model row can
pass.

VLM/Omni multi-turn rows should use:

```sh
python3 scripts/pr1147_live_sequence_probe.py \
  --base-url http://127.0.0.1:4242 \
  --model <served-model-name> \
  --output-dir docs/internal/live-gates/pr1147/<model-slug>/vlm-sequence \
  --image <image-a> \
  --different-image <image-b> \
  --video <optional-video> \
  --audio <optional-audio>
```

That helper records image+text, text-only, different-image, repeat-image, video,
and audio turns when the corresponding media inputs are supplied. It writes raw
Chat Completions and Responses request/response bodies, per-turn snapshots, and
output tails. It is still an artifact collector; the row needs explicit human
review for grounding, parser leaks, stop reason, cache hit correctness, TTFT,
tok/s, RSS, and physical footprint.

For model-cache proof, verify the app/server idle-residency setting first.
Osaurus defaults to immediate unload after the final generation lease drops;
with that policy, non-streaming post-request `/health` and `/admin/cache-stats`
can correctly return empty `loaded` / `models` arrays even though generation
just succeeded. Cache-hit rows must either set a non-immediate residency policy
or capture snapshots during a streaming request before the lease is released.

ZAYA-VL live sequence checkpoint:

- pre-fix artifact:
  `docs/internal/live-gates/pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1458/`
  showed the probe helper was carrying Chat Completions media history into
  Responses follow-up requests. The first Responses turn returned 200, but
  later Responses turns returned 400 because prior media used the wrong route
  shape.
- probe fix: `scripts/pr1147_live_sequence_probe.py` now stores prior user
  history in route-native shape. Chat uses `text` / `image_url`; Responses uses
  `input_text` / `input_image`.
- post-fix artifact:
  `docs/internal/live-gates/pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1504/`
  completed 10 route rows and wrote per-turn request, response, health,
  cache-stats, and process-memory artifacts.
- Responses source fix:
  the `vlm-sequence-20260518T1504/` Responses rows returned generic
  "media" text because `OpenResponsesRequest.toChatCompletionRequest()`
  flattened content through `OpenResponsesMessageContent.plainText`, which
  drops `input_image`. The PR now preserves Responses `input_image` as
  Chat Completions `MessageContentPart.image_url` and pins it with
  `ChatEngineTests.openResponsesRequest_preservesInputImageIntoChatRequest`.
  This is source/test proof only; a fresh keychain-safe live rerun is required
  before Responses image grounding can be marked passing.
- review:
  `docs/internal/live-gates/pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1504/review.md`
  marks the row FAIL/PARTIAL. Chat grounds the first red image and text-only
  follow-up, but the different blue image is answered as red, Responses returns
  generic "media" text instead of grounded image answers, ZAYA1-VL video returns
  HTTP 500 `ZAYA1-VL video input is not implemented`, and `/health` plus
  `/admin/cache-stats` still report no loaded model/cache counters. Source
  trace shows the empty post-request snapshots are consistent with the default
  `.immediately` idle-residency policy, so the next cache-proof rerun must set
  non-immediate residency through the app/settings path or capture stream-time
  snapshots while the lease is held. This is a real live gap, not a pass.
- source capability fix:
  ZAYA1-VL is now classified as `.imageOnly` from both model-id and
  directory/`model_type` capability paths. This matches current vmlx-swift
  engine support: image/text is implemented, while video throws
  `ZAYA1-VL video input is not implemented` until a real ZAYA video processor
  exists. Focused tests now pin picker/composer gating so image is accepted and
  video/audio are rejected for ZAYA1-VL. This prevents the UI from advertising
  a fake video path; it does not make the red different-image grounding row or
  live cache proof pass.

Metadata route probe checkpoint:

- pre-fix artifact:
  `docs/internal/live-gates/pr1147/http-route-probe-metadata-20260518T1425/`
  shows `/admin/cache-stats` returned HTTP 404 with body `Not Found`.
- fix: `HTTPHandler` now exposes a read-only `/admin/cache-stats` endpoint
  backed by `ModelRuntime.cachedModelSummaries()` and
  `CacheCoordinator.snapshotStats()` when a model is loaded. The route does not
  load a model by itself.
- post-fix artifact:
  `docs/internal/live-gates/pr1147/http-route-probe-metadata-20260518Tpost-cache-stats/`
  shows `/admin/cache-stats` returned HTTP 200 with an empty cold-start
  `models` array and zero aggregate counters for prefix, paged, block-L2, and
  SSM companion cache fields.

This closes only the metadata/admin-route existence row. It does not prove any
model-specific cache hit, L2 write, SSM rederive, coherency, speed, or memory
row.

Keychain-safe app launch is required for live app/API gates:
`docs/internal/live-gates/20260518T_pr1147_keychain_safe_launch.md`. Do not run
the app binary with a fake `HOME`; that can break macOS Keychain access for the
database encryption key and produces invalid live-gate evidence.
The helper `scripts/pr1147_keychain_safe_app_launch.sh` launches the debug app
through LaunchServices, refuses fake `HOME`, sets `OSU_MODELS_DIR` through
`launchctl`, and restores the prior launchctl environment.

The per-family execution manifest for the remaining real-user rows is:
`docs/internal/live-gates/20260518T_pr1147_live_user_api_execution_manifest.md`.
It names the source anchors, artifact file contract, UI/API/cache/parser
inverses, saved-setting carryover rows, and model-family sequences that must
exist before this PR can be undrafted.

The component-level edge-case matrix is:
`docs/internal/live-gates/20260518T_pr1147_component_edge_case_matrix.md`. It
breaks the manifest into source-to-artifact wiring, per-family UI defaults,
media turn sequences, cache/scheduler proof, parser and reasoning leak checks,
saved-setting/cache-key inverses, and artifact acceptance rules. It is still a
checklist, not a pass report.

The forced-behavior source audit is:
`docs/internal/live-gates/pr1147/forced-behavior-audit-20260518T1545/REPORT.md`.
It currently marks source hits for background `no_think`, explicit
`frequency_penalty` mapping, family reasoning-template bridges, MiniMax template
fallback, the now-fixed Ling force-off/reasoning-merge path, and
metadata/fallback sampler resolution. This audit is a triage artifact only. It
must be paired with live model rows before release. The Ling fake-merge source
hit has a fresh vmlx no-guard proof plus Osaurus focused tests, but the family
still needs app/API long-output, cache, SSM, memory, and saved-setting carryover
artifacts before production-clear.

Hy3 has fresh vmlx-only proof at
`/Users/eric/vmlx-swift/docs/internal/live-gates/20260518T_hy3_jangtq_no_guard_refresh/`.
That proof confirms generic `enable_thinking=true` is not the Hy3 reasoning
control, while native `reasoning_effort=low/high` routes reasoning cleanly. It
supports Osaurus's native Hy3 effort bridge but does not close the Osaurus
app/API Hy3 row.

## Current Audit Outcome

Not complete.

The PR currently has strong source-policy gates, documented model-family
contracts, startup/server binding proof, and a cold-start
`/admin/cache-stats` route proof. It now also has one real ZAYA-VL app/API
artifact set, and that artifact is explicitly red: media switch grounding,
live Responses media grounding after the source fix, ZAYA-VL video capability,
and loaded-model/cache reporting are not production-ready. It does not yet have
passing live Osaurus
app/API artifact sets for Qwen VL, Gemma VLM, ZAYA-VL, Nemotron Omni, DSV4,
MiniMax, Ling, Hy3, and other parser families. Do not undraft or call the
switch production-ready until those artifact folders exist and pass with real
visible output, cache stats, timing, memory, and no parser/tag leakage.
