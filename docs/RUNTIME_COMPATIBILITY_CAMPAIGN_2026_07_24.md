# Osaurus Runtime Compatibility Campaign — 2026-07-24

Status: **PARTIAL — CURRENT-PIN LIVE UI PROOF IS NOT COMPLETE**

This is the current-source ledger for one coherent Osaurus PR covering three
ordered lanes:

1. remaining model-family tool and reasoning formats;
2. truthful context-window and KV-retention settings;
3. bounded, model-residency-aware batched subagents.

The merged SSD warmup/cancellation fix in Osaurus PR #2161 is the baseline,
not an open lane. Do not reopen it unless this campaign changes its owning
streaming, cancellation, or cache paths or a current-pin regression appears.

No screenshot, recording, model bundle, cache, database, or other binary
evidence is committed or attached to the PR. Live visual evidence remains
local; GitHub-visible evidence is text only.

## Current exact source

- Osaurus base: `b7fc8c3c7b255a46a411c2c6d0c11cab43b67681`
- merged vMLX base pin: `da2872b07c33bd138f3217eb1760385b8cda259a`
- current vMLX campaign head: `8a243bae` on
  `codex/runtime-compat-campaign-20260724`
  - `4480b4aa`: nested LFM/DSML/Pythonic arguments and LFM quantized
    auxiliary-tensor sanitization;
  - `8a243bae`: schema-aware ZAYA XML parameter resynchronization.

The Osaurus campaign package graph now pins the full
`8a243baea938c0e58bfdcb6d49dbeef7e168fd85` revision in `Package.swift` and
all three resolved-package files. This is compiled source evidence only; the
combined pin is not live-verified yet.

## Round protocol

Do not treat this as a sequence of one-off smoke tests. Each round is:

1. run multiple real-user turns in the isolated Release app;
2. inspect every item in the per-turn gate below, including the UI after the
   apparent answer or side effect;
3. record every distinct failure before editing;
4. fix the owning layer for the complete set of reproduced failures;
5. rebuild the exact source and repeat the failed rows plus their controls.

Do not repeat a row whose source pin, configuration, and current live evidence
remain unchanged. Do not infer a family, quant, or modality from a sibling row.

## Lane A — tool and reasoning formats

### Current source findings

1. LFM/Pythonic and DSML argument extraction previously split on commas with
   regexes. Nested arrays, objects, quoted commas, and streamed boundaries were
   truncated before schema validation. The campaign engine uses balanced,
   quote-aware extraction instead.
2. Quantized LFM sanitization renamed weight tensors but did not rename their
   matching scales and biases. That can make an otherwise valid bundle fail to
   load. The campaign engine applies the same key rewrite to the full quantized
   tensor family.
3. ZAYA can emit a new declared `<parameter=...>` opener before closing the
   prior parameter. The old XML parser appended the nested opener to the first
   value and contaminated the verb. The campaign engine resynchronizes only
   when the new name is another declared schema parameter; unknown tags remain
   literal.
4. The earlier family controls remain controls, not new parser targets:
   Qwen-derived Bonsai/Ornith and Gemma 4 must be rerun only because the final
   shared engine/app pin changes.
5. VibeThinker is reasoning-only in the current product contract and is not
   forced into a tool-call row.
6. MXFP4 bundles are excluded from this campaign at the user's direction.

### Required source and Release-app rows

Every available row must prove nested objects/arrays/escaping, streamed marker
boundaries, retryable tool errors, post-tool continuation, terminal final
answer, Thinking off/on when supported, and one follow-up:

- LFM2.5 MXFP8/Pythonic;
- Laguna S 2.1 and XS 2.1 JANG_2L/JANG_4M/JANG_6M with GLM tools;
- MiniMax M2.7 JANG/JANGTQ;
- Nemotron Omni/Audex formats and supported media;
- Step 3.7;
- HY-3/Hunyuan with native MTP where supported;
- ZAYA/AppleScript XML;
- available Mistral and DeepSeek/DSML rows whose production load route accepts
  the bundle;
- Qwen/Bonsai/Ornith and Gemma 4 controls.

Unavailable or production-rejected artifacts are `BLOCKED`, not inferred from
a sibling format or a direct parser unit test.

### Current compiled evidence

- Xcode Swift 6.3.3: 112 focused parser tests pass across Pythonic nested
  arguments, DSML inline JSON, ZAYA XML resynchronization, Qwen/Qwen 3.5,
  Gemma/Gemma 4, LFM, MiniMax, Mistral, Kimi, JSON, and XML controls.
- After clearing a stale process-wide Metal test semaphore left by an earlier
  crashed runner, both LFM quantized-tensor sanitizer tests pass against the
  actual Metal-backed tensor path.

This is source/test evidence only. No family row is live-verified by these
tests.

## Lane B — context and KV ownership

### Confirmed current-source ambiguity

- Chat settings expose a context-length value used as a metadata fallback,
  while local bundle metadata supplies the model maximum.
- the composer historically displayed the raw model maximum although runtime
  compaction uses an 85 percent effective conversation budget;
- Cache and Memory Safety exposed two editable values for the same KV
  retention cap, with legacy Memory Safety precedence;
- saved policy, newly resolved policy, and the policy captured by an already
  loaded coordinator were not clearly distinguished;
- a Memory-Safety-only save could leave an already loaded coordinator using
  its old runtime policy;
- admission estimates and the loaded coordinator could resolve different KV
  caps.
- provider model-picker rows could already carry an exact context maximum, but
  `AgentLoopBudget` skipped that metadata and used the generic fallback.

### Campaign source changes

- The consolidated Server → Cache surface distinguishes the selected model
  maximum, the 85% usable conversation budget, the unknown-metadata fallback,
  and the explicit KV-retention override.
- Both the async runtime resolver and synchronous chat UI now resolve
  Foundation → local bundle metadata → provider picker metadata → generic
  fallback. This remains `PARTIAL` until focused tests and live local/remote
  UI rows complete.

### Acceptance contract

The UI and API must distinguish:

1. bundle/provider model maximum;
2. effective conversation budget;
3. bundle `max_new_tokens`/maximum output tokens;
4. a user-explicit per-turn or subagent output-token budget;
5. unknown-metadata fallback;
6. one editable KV-retention policy;
7. active loaded policy versus saved next-load policy;
8. independent paged-RAM and disk-L2 capacities.

The Chat label is `Default Agent Max Output Tokens`, with explicit copy that
blank inherits the active bundle's generation-config maximum and that the
value is neither context capacity nor KV retention. The subagent limit is
separately labeled `Max output tokens per subagent`.

A bounded subagent token limit may cap a child below the bundle maximum, but
must not replace the model's sampling, stop/EOS, or generation defaults. A
missing user override must continue to mean "use the bundle default", not an
invented app value.

Changing a setting must visibly save, cause any required model reload, and be
proved by the effective loaded runtime—not by the control value alone.

The context work is reconciled onto current main and now has provider-metadata
coverage. It remains source-only until compiled tests and live
dense/Gemma-rotating/Qwen-hybrid rows complete.

## Lane C — bounded batched subagents

### Confirmed current-source gap

`spawn_agent(input, agent)` and `spawn_model(input, model)` each run one job.
The ordinary agent loop may execute independent tool calls concurrently, but
there is no explicit bounded heterogeneous batch contract, ordered result
envelope, or user-configured parallelism limit.

The inherited batching draft was **not mergeable** because it registered
`spawn_batch` and a UI limit without a tool schema, executor, ordered result
contract, registry integration, or execution tests. The campaign branch now
has:

- a strict job schema with stable ids and exact allowed targets;
- reject-before-load preparation of every job;
- bounded waves that overlap remote jobs, group same-local work, and serialize
  different local models;
- deterministic input-order result envelopes and one parent Stop/feed;
- request-local target enums and prompt guidance;
- one visible `Max subagents per batch` value that is both the hard job-count
  limit and the concurrency limit. The schema publishes that exact bound, and
  the executor rejects an oversized call before target resolution, admission,
  RAM preflight, model load, or parent unload.

The focused Osaurus suite now exits 0 for schema/ordering, target validation,
same-local admission, bounded wave scheduling, one shared handoff, local plus
remote overlap, one-child failure isolation, pre-interrupted batches, prompt
visibility, budget persistence, and provider-context resolution. Release-app
tests are still required, so this lane remains `PARTIAL`.

After tightening the saved batch limit into a hard fan-out limit, the first
post-edit run correctly failed the stale prompt-wording assertion. The
expectation was updated to require both maximum jobs and maximum concurrency;
the rerun of `SpawnBatchToolTests` and `SpawnGuidanceTests` exits 0.

### Acceptance contract

The final contract must:

- accept caller-stable job ids and an explicit allow-listed agent or model
  target per job;
- reject every invalid target before changing local model residency;
- cap both total fan-out and parallel work at the saved user limit;
- run remote jobs concurrently;
- coalesce same-local-model jobs without unload/reload;
- serialize different local models or perform one safe grouped handoff;
- reserve RAM before local fan-out and fail honestly when insufficient;
- use one RAM projection for a shared same-model group, not one full-model
  charge per job, while checking every different local model before its
  handoff;
- return deterministic input-order results with per-job success/error state;
- propagate Stop, timeout, and one-child failure without hanging siblings;
- expose the actual allowed targets and limit in the request-local schema and
  system prompt;
- preserve each child's Thinking setting, generation defaults, tools, and
  compact context boundary.

For generation, every child must inherit the selected bundle's temperature,
top-p, top-k, min-p, repetition penalty, stop/EOS, and model maximum-output
contract unless the user/agent has an explicit supported override. The
subagent output-token limit is an explicit bounded-work cap and must be shown
as such.

Required Release-app scenarios include same-model two-job reuse, parent and
child sharing a model, different-local handoff, two local plus one remote,
backpressure, one job error, timeout, cancellation, restart persistence, and a
RAM refusal followed by a user setting change.

The request-local `spawn_batch` schema and prompt must enumerate exactly the
agents/models the user allowed and the effective maximum job/parallel count.
The orchestrator chooses the target for each job; there is no hidden model
router.

## Per-turn live gate

For every affected UI turn, inspect the entire lifecycle:

- `reasoning_content` streams into the reasoning UI; the pane opens/closes only
  when enabled and actually emitted, including child/tool-loop turns;
- no inline `<think>`, fake reasoning stream, JSON/XML envelope, close token,
  or parser debris leaks into visible content;
- every intended tool is discoverable, nested/escaped JSON/XML arguments are
  intact, and every tool/subagent card starts and finishes;
- interleaved reasoning → tool → reasoning → tool → final remains ordered;
- malformed/tool-error continuation remains live, preserves valid cache
  state, and does not fabricate success, restart prefill at zero, loop, or
  hang;
- final content is coherent, complete, free of unexplained truncation or
  repetition, and Markdown/table/code/LaTeX/KaTeX/multilingual rendering is
  visually intact;
- Stop disappears, input unlocks, status/progress animations settle, scrolling
  and resizing leave no blank/stale layout, and a follow-up completes;
- a new chat derives sampling and stop behavior from the active
  `generation_config.json`/JANG config plus only explicit user overrides;
- for media-capable rows, paperclip and drag/drop image, multi-image, video,
  and audio paths complete and preserve same-media/different-media cache
  isolation;
- cache evidence records restored and remaining tokens, TTFT, prefill rate,
  token/s, disk and RAM hits/misses/stores/evictions, physical footprint, and
  terminal stop reason. UI color alone is not evidence;
- reuse means the single longest positionally valid contiguous token prefix.
  Paged RAM may restore several consecutive blocks belonging to that prefix,
  but the runtime must not concatenate unrelated disk entries or claim an
  arbitrary suffix match as reusable KV state;
- with paged RAM off, disk L2 independently restores the best valid partial
  prefix across turns, chats, model reloads, and app restarts;
- with paged RAM explicitly on, enough distinct compatible prompts evict a
  known entry from RAM, after which reissuing it must restore from disk L2
  rather than cold-prefill;
- disk/RAM size limits evict old entries without stale state, OOM, or
  unbounded growth; TurboQuant remains off unless explicitly enabled;
- when TurboQuant is enabled, the effective encoded topology and
  architecture-specific rederive state are recorded rather than inferred from
  the toggle;
- native-MTP Qwen 3.6/HY-3 rows show actual activation/depth in Server
  activity, not config metadata alone;
- RAM-safety refusal occurs before unload/load, leaves the parent usable, and
  changing the visible safety setting produces the corresponding effective
  runtime decision.

Until the exact combined Osaurus build passes these rows, the campaign remains
`PARTIAL`.

## Current live-validation matrix

`SOURCE-PASS` below means compiled source/tests only. It is not a live model or
UI pass. Every row must be updated with the exact bundle, settings state,
trial count, cache counters, TTFT/token rate, final stop state, and any local
text/log artifact before its status can become `VERIFIED-LIVE`.

| Lane | Required current-pin row | Current status | Missing gate |
| --- | --- | --- | --- |
| Tool parser | LFM2.5 MXFP8 Pythonic nested object/array, tool error, continuation | SOURCE-PASS | Release UI load and full-turn trials |
| Tool parser | ZAYA XML declared-parameter resync and AppleScript continuation | SOURCE-PASS | Release UI tool-card and side-effect/finalization trials |
| Tool parser | Laguna S 2.1 JANG_2L/4M/6M GLM tools and reasoning | PARTIAL | Each quant needs independent Release UI proof |
| Tool parser | Laguna XS 2.1 JANG_2L/4M/6M GLM tools and reasoning | PARTIAL | Each quant needs independent Release UI proof |
| Tool parser | MiniMax M2.7 JANG/JANGTQ | SOURCE-PASS | Release UI parser, reasoning, generation-default, and cache proof |
| Tool parser | Step 3.7, HY-3 MTP, Nemotron, available Mistral/DSML | SOURCE-PASS | Available-bundle Release UI rows and modality/MTP telemetry |
| Controls | Bonsai/Ornith Qwen and Gemma 4 dense/MoE | SOURCE-PASS | Exact-pin regression rows for tools, reasoning, cache, and final unlock |
| Context | Local bundle model max, 85% chat budget, bundle output max, KV override | SOURCE-PASS | Saved/active UI values and required reload behavior |
| Context | Provider metadata max versus generic fallback | SOURCE-PASS | Remote-model UI row |
| Batch | Two same-local jobs and same parent/child model | SOURCE-PASS | Prove one resident load, concurrent execution, one final unlock |
| Batch | Two local plus one remote, exact user-allowed target selection | SOURCE-PASS | Prove mixed overlap and ordered results in Release UI |
| Batch | Different-local models | SOURCE-PASS | Prove serialized handoff and parent restoration |
| Batch | Oversized fan-out, malformed job, one-child failure, timeout, Stop | SOURCE-PASS | Release UI terminal-state and sibling-isolation trials |
| Batch | RAM refusal and user safety-setting change | SOURCE-PASS | Visible refusal-before-unload and effective retry |
| Generation | Bundle temperature/top-p/top-k/min-p/repetition/stop/max-output merge | SOURCE-PASS | Runtime telemetry for parent and each selected child |
| Cache | Paged RAM off, disk L2 partial prefix across child runs/new chats/restart | PARTIAL | Exact disk restored/remaining counters and coherent outputs |
| Cache | Paged RAM on, eviction to disk, reissue from L2 | PARTIAL | RAM eviction plus later disk restore proof |

Locally available non-MXFP4 candidates currently include LFM2.5 MXFP8,
Laguna S/XS JANG_2L/4M/6M, MiniMax M2.7 JANG/JANGTQ, ZAYA JANGTQ, HY-3 MTP,
Step 3.7 JANG, Nemotron Audex variants, Ornith JANG/MXFP8, Qwen AgentWorld,
Qwen 3.6 MXFP8/JANG, Bonsai JANG, and Gemma 4 MXFP8/JANG dense/MoE bundles.
No result is inferred from a sibling quant or architecture.
