# PR 1147 Model Function Compatibility Tracker

Timestamp: 2026-05-18 17:25 PDT

Scope: execution tracker for the Osaurus switch to consolidated `vmlx-swift`.
This is not a pass report. It enumerates the model/function rows that must be
proven through the Osaurus chat app and HTTP APIs before PR #1147 can be
undrafted or described as production-ready.

Status words:

- `PASS`: live Osaurus UI/API artifact exists with coherent output, timing,
  memory, and topology-correct cache evidence.
- `PARTIAL`: a source test, metadata census, or limited live row exists, but
  at least one required route, media, cache, reasoning, parser, speed, memory,
  or inverse condition is missing.
- `FAIL`: live output or wiring is red and must be root-caused without hidden
  sampler/parser/reasoning guards.
- `OPEN`: no current Osaurus live artifact closes the row.
- `N-A`: unsupported by the actual model artifact or runtime, with the checked
  path and reason recorded.

## Global Release Rules

1. Natural decode only: no hidden temperature, top-p, top-k, min-p,
   repetition, frequency, presence, EOS, length, prompt, or output guard may
   convert a red row into a pass.
2. Generation defaults resolve from `jang_config.json >
   chat.sampling_defaults`, then `generation_config.json`, then documented
   engine fallback only when metadata is absent. Native `top_k` must apply
   when present.
3. Reasoning controls are family-specific. DSV4 uses `instruct/high/max`;
   Qwen-style families use `enable_thinking`; Hy3 uses native
   `reasoning_effort`; unsupported families must send no stale reasoning
   fields.
4. MTP is tensor/tuning-gated. It requires real `mtp.*` tensors plus usable
   `vmlx_mtp_tuning.json`. CRACK/name-only MTP is a fail.
5. VLM/audio/video rows must send real media through UI, Chat Completions, and
   Responses. Text-only follow-up must have media salt nil/absent; repeated
   media must hit; different media must miss and ground correctly.
6. Cache proof requires prefix, paged, block-L2, TurboQuant KV,
   SSM companion, DSV4-native cache, ZAYA CCA, media cache, and sleep/wake as
   ON/OFF or topology-N-A with counters, TTFT, tok/s, RSS, and Activity
   Monitor physical footprint.
7. Parser proof requires tools omitted, `tools=[]`, `tool_choice=auto`, and a
   second turn with tool result where supported. Visible content must not leak
   DSML, Qwen XML, MiniMax XML, Harmony, Gemma thought, GLM/Hunyuan, Mistral,
   raw JSON, or tool sentinels.
8. Saved settings are part of the gate: reasoning, parser, media, cache, MTP,
   and coding/tool context settings must not carry across incompatible models,
   sessions, or API routes.
9. Any post-red source/template/tokenizer/parser/cache/scheduler/UI fix must be
   rerun live with the pre-fix and post-fix artifacts side by side.

## Function Axis Tracker

| Axis | Required live proof | Current evidence | Status |
|---|---|---|---|
| UI model picker | Exact model path, family, VLM, MTP, reasoning, parser, cache topology, and warnings are visible and match bundle files. | Source docs and bundle census only. | OPEN |
| Chat settings visuals | DSV4 default `instruct`, DSV4 `max`; Qwen/ZAYA/Nemotron/Ling default no-thinking where valid; Hy3 native efforts; unsupported controls hidden. | Source policy docs/tests. | PARTIAL |
| Server settings and CLI preview | Prefix/paged/block-L2/sleep/wake/max-batch controls; DSV4 block size 256 fixed; invalid flags omitted; MTP status from tuning. | DSV4 renderer checklist in docs/tests. | PARTIAL |
| Startup and process lifecycle | Keychain-safe app launch, no fake `HOME`, no duplicate PR listeners, load, cancel, sleep, wake, quit, no zombie Swift engine. | Keychain-safe launch doc; current port 4242 cleanup checks. | PARTIAL |
| Chat Completions | Stream and non-stream with text/media, usage, first/last frame, `[DONE]`, cache stats, parser/no-leak review. | Some text/media probe artifacts. | PARTIAL |
| Responses | Stream and non-stream with text/media, reasoning, session continuity, cache stats, UTF preservation, parser/no-leak review. | Media bridge and UTF bridge tests; limited live rows. | PARTIAL |
| Anthropic Messages | Stream and non-stream for text, reasoning, tools where supported. | Manifest only. | OPEN |
| Ollama chat/generate | Stream and non-stream with correct terminal frames and no hidden sampler defaults. | Manifest only. | OPEN |
| Generation defaults | Omitted sampler fields use bundle metadata; explicit kwargs override exactly; native `top_k` honored. | `LocalGenerationDefaults` tests and source logs; live resolved-kwargs rows missing. | PARTIAL |
| Prefix cache | OFF repeated prompt has no hit; ON repeated/prefix-overlap prompt increments hits and lowers TTFT. | ZAYA/Gemma/Nemotron counters in limited rows. | PARTIAL |
| Paged cache | OFF/ON rows prove allocated/shared blocks or topology-N-A without stale blocks. | Some models report `is_paged_incompatible=true`; broad rows missing. | PARTIAL |
| Block-L2 cache | OFF writes no files; ON records bytes, hits, stores, max-GB enforcement. | Limited rows show 10 GiB max and hit/store counters. | PARTIAL |
| TurboQuant KV | Enabled only on compatible topologies; encode/decode counters and health state recorded; disabled rows remain coherent. | Manifest only. | OPEN |
| Hybrid SSM | Prefix hit accepted only with SSM companion hit or explicit rederive; no KV-only unsafe hit. | Nemotron/ZAYA text counters; Ling/Hy3 live Osaurus rows missing. | PARTIAL |
| DSV4 native cache | SWA+CSA+HSA, pool quant, block size 256, generic q4/q8 disabled, native stats visible. | vmlx proof and Osaurus source policy; Osaurus UI/API row missing. | PARTIAL |
| ZAYA CCA/media cache | Image+text, text-only, different-image, repeated-image, no cross-media CCA state. | ZAYA-VL artifacts are partial/red; latest-image diagnostic grounds blue. | FAIL/PARTIAL |
| VLM image | Real image through UI, Chat, Responses; text-only T2 media salt nil/absent; repeat hit and different miss. | ZAYA-VL partial/red; Qwen/Gemma/Nemotron rows missing. | PARTIAL |
| Video | Qwen/Nemotron/Gemma only where runtime supports it; unsupported ZAYA video hidden/rejected cleanly. | ZAYA image-only gate documented; other video rows missing. | OPEN |
| Audio / Parakeet | Nemotron Omni real WAV through Chat/UI, streaming, repeated-audio cache, live voice pre-encode, RADIO/vision split. | Nemotron WAV Chat smoke recovers `blue`; no stream/repeat/UI/RADIO proof. | PARTIAL |
| MTP | MXFP Qwen 27B/35B ON/OFF speed, acceptance, cache, VL, and coherency from `vmlx_mtp_tuning.json`. | Bundle census and vmlx evidence; Osaurus UI/API MTP rows missing. | PARTIAL |
| Reasoning parser | OFF/ON/max/native effort per family; no visible leakage; no forced close. | Source policy and limited vmlx evidence. | PARTIAL |
| Tool parser | Parser selected from base architecture, not display name; tools omitted/off/on/result-turn all work. | DSV4 vmlx tool proof; Osaurus broad rows missing. | PARTIAL |
| Coding/tool context | Coding prompt/tool schema injection does not leak after model/session switch and is included in cache keys only when valid. | Manifest only. | OPEN |
| Single-batch | Default B=1 path coherent with full cache stack and no unnecessary scheduler contention. | Limited live rows. | PARTIAL |
| Multi-batch | B>1 route where feasible, no cross-talk, independent sessions/ports, cache correctness preserved. | Manifest only. | OPEN |
| Memory | RSS plus Activity Monitor physical footprint before/after load, each turn, cache hit, sleep, wake. | Current rows mostly RSS-only. | PARTIAL |
| Old-library sweep | No active inference path imports old `vmlx-swift-lm`, standalone `Jinja`, standalone `swift-transformers`, or old `mlx-swift`; transitive non-inference deps documented. | Source policy tests, package docs, and `pr1147/old-library-sweep-20260518T1728/REPORT.md`; final post-live sweep still required. | PARTIAL |

## Model Family Tracker

| Family / path | Required rows | Current evidence | Status |
|---|---|---|---|
| DSV4 Flash: `JANGQ/DeepSeek-V4-Flash-JANGTQ-K`, `JANGQ/DeepSeek-V4-Flash-JANGTQ2` | UI settings screenshot/log, CLI preview, DSML tools off/on/result, `reasoning_effort=max`, long/prefix chat, native DSV4 cache stats, TTFT/tok/s/footprint. | vmlx DSML proof and Osaurus source guards. | PARTIAL |
| Qwen3.6 MXFP MTP/VL: 27B/35B MXFP4/MXFP8 | UI MTP status from real tensors/tuning, MTP ON/OFF speed, VL image/video, text-only resume, cache hits, reasoning on/off, Qwen tools, no name-based activation. | Bundle census and tuning policy; Osaurus live rows missing. | PARTIAL |
| Qwen non-MTP controls | Prove MTP disabled with `no mtp tensor evidence`, text/VL where real processor exists, no speed claim. | Census only. | OPEN |
| Gemma4 VLM / Harmony | Image+text, text-only, image switch, Harmony/thought split, Gemma tools, cache topology, no marker leak. | vmlx/source contracts only. | OPEN |
| Gemma3n E2B text | Text multi-turn, UTF, reasoning unsupported hidden, cache on/off, physical footprint; no sampler clamp. | `gemma-3n-e2b-it-4bit/text-sequence-20260518T1652/` partial/red. | FAIL/PARTIAL |
| ZAYA1 text MXFP4 | Text math/follow-up/UTF, SSM companion, prefix/block-L2, no stale parser, no sampler/output repair. | `zaya1-8b-mxfp4/text-sequence-20260518T1705/` partial/red; UTF bridge test passes. | FAIL/PARTIAL |
| ZAYA1-VL MXFP4/JANGTQ | Image+text, text-only, different-image, repeat-image, CCA/media salt, image-only video rejection, speed target, footprint. | Multiple ZAYA-VL artifacts; original plain red-to-blue row remains partial/red. | FAIL/PARTIAL |
| Nemotron Omni MXFP4/JANGTQ | Text, audio, image, video, live voice Parakeet pre-encode, RADIO evidence, repeated media cache, sleep/wake, no reasoning-only false pass. | Text pass/family partial; WAV Chat smoke pass/family partial. | PARTIAL |
| MiniMax M2.7 | Reasoning-only behavior, MiniMax parser XML/JSON, tools off/on/result, no name-only MTP, cache stack, speed/memory. | Manifest/source policy only. | OPEN |
| Ling 2.6 flash | Default no-thinking, explicit opt-in, long prompt, prefix overlap/mismatch, SSM companion, no KV-only unsafe hit, GLM/Ling markers no leak. | vmlx no-guard proof and Osaurus source changes; Osaurus live row missing. | PARTIAL |
| Hy3 preview | Native `reasoning_effort` low/high, no generic `enable_thinking`, tools where supported, hybrid cache stats, TTFT watch. | vmlx-only proof; Osaurus UI/API/cache rows missing. | PARTIAL |
| GLM / GPT-OSS / Mistral local families | Parser/reasoning aliases, tools, marker no-leak, dense/sliding/hybrid cache stats, route parity. | Source/parser manifest only. | OPEN |
| Kimi | Excluded from PR #1147 scope unless re-added. | Explicit scope exclusion. | N-A |

## Execution Order

1. Keep the app launch clean: confirm no PR listener, launch with
   `scripts/pr1147_keychain_safe_app_launch.sh`, and record idle-residency
   mode before every cache row.
2. Run one family at a time. For each family, collect UI screenshots/logs,
   route probes, live sequence artifacts, cache stats, memory, and summary.
3. Resolve red rows by source tracing only after reproducing the live failure.
   Do not add sampler, parser, prompt, EOS, or close-tag guards.
4. Rerun the exact failed row after any fix and attach pre-fix plus post-fix
   artifacts.
5. Run the final old-library and zombie-code sweep after live rows, because
   late fixes can reintroduce old imports or invalid CLI flags.

## Current Production Call

Not production-ready. The PR is source-wired and increasingly well-gated, but
the live Osaurus app/API matrix is incomplete. Existing live rows prove some
text, audio, media, and cache movement, while Gemma3n, ZAYA text, and ZAYA-VL
still have red or partial behavior. Those rows must stay visible until the real
runtime/template/tokenizer/cache/parser cause is fixed and rerun live.
