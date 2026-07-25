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
- current vMLX campaign head:
  `7c37de3e77daf1ce1e3a212c0aaad3ba4cb471b9` on
  `codex/runtime-compat-campaign-20260724`
  - `4480b4aa`: nested LFM/DSML/Pythonic arguments and LFM quantized
    auxiliary-tensor sanitization;
  - `8a243bae`: schema-aware ZAYA XML parameter resynchronization;
  - `64cbaba5`: raw native tool-envelope tracing used to distinguish model
    output from stream-parser mutation;
  - `e85d7297`: quarantine of an explicit balanced registered LFM/Pythonic
    tool attempt whose arguments are malformed, so it reaches the ordinary
    retryable tool-error path without executing a tool body;
  - `7c37de3e`: quarantine of an explicitly terminated registered LFM call
    that contains a balanced inner invocation but omits only the native
    bracket-list closer. It reports the malformed envelope without executing
    or repairing the call.

The Osaurus campaign package graph now pins the full
`7c37de3e77daf1ce1e3a212c0aaad3ba4cb471b9` revision in `Package.swift` and
all three resolved-package files. The exact combined pin has now been exercised
in the isolated Release app for LFM database tools and disk-L2 continuity. That
family row remains `PARTIAL` because post-error final generations reproducibly
ended inside an unclosed reasoning block; the rest of the family matrix is
still unverified at this pin.

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
4. The traced LFM failure was native malformed output, not a content-delta
   split: the model emitted one explicit balanced registered
   `db_create_table(...)` envelope with two different `columns=` values. The
   previous processor removed the tagged envelope after parse failure and
   surfaced no structured tool attempt, allowing the model to claim success.
   The current parser does not choose one duplicate value. It quarantines that
   exact explicit attempt as `invalid_tool_arguments`; unknown tools,
   untagged prose, and structurally unbalanced function arguments remain
   non-executable. A complete inner invocation observed at EOS can still be
   recovered under the pre-existing family contract even if the outer end tag
   was omitted.
5. A later exact native retry proved a second silent-drop boundary. LFM
   emitted both native tags and a complete registered `db_create_table(...)`
   invocation, but omitted only the outer closing `]`. The processor parsed
   zero calls and consumed the tagged output. The current parser returns one
   non-executing `invalid_tool_arguments` envelope with field `envelope` only
   for this fully attributed shape. A missing native end tag, an unknown tool,
   untagged prose, and an unbalanced inner invocation remain non-executable.
6. The earlier family controls remain controls, not new parser targets:
   Qwen-derived Bonsai/Ornith and Gemma 4 must be rerun only because the final
   shared engine/app pin changes.
7. VibeThinker is reasoning-only in the current product contract and is not
   forced into a tool-call row.
8. MXFP4 bundles are excluded from this campaign at the user's direction.

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
- At exact engine head `7c37de3e`, the focused Pythonic transcript suite
  passes 20/20. It includes the exact duplicate-`columns` transcript and the
  explicitly terminated missing-`]` transcript at every stream boundary,
  malformed-field controls, corrected retry, unknown-tool, untagged-prose,
  missing-end-tag, and structurally unbalanced-argument controls.
- With Osaurus resolved to that exact engine head, the focused
  `ToolRegistryAutoApproveTests` Xcode run passes 6/6. The new executor test
  proves the structured parser error returns retryable `invalid_args` and the
  registered tool body executes zero times.
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

### 2026-07-24 LFM2.5 MXFP8 Release-app round

Exact app source: Osaurus `f94063468feb5f98b69b2585fec8ee6f814c92bd`
with vMLX `8a243baea938c0e58bfdcb6d49dbeef7e168fd85`, ad-hoc signed as
`com.dinoki.osaurus.runtimecompat20260724` and launched under the isolated
test root
`/private/tmp/osaurus-runtime-campaign-live-root-f9406346-20260724`.
Exact bundle:
`/Users/eric/models/dealign.ai/LFM2.5-8B-A1B-MXFP8-CRACK`.

Visible settings showed prefix cache on, paged-RAM cache off, disk L2 on, and
cache codec `Engine Selected`. No TurboQuant activity was observed. The app
showed no Thinking control for this bundle; the bundle template does not
accept an `enable_thinking` kwarg, so a user-controllable thinking mode remains
unsupported for this row rather than inferred from the template's ability to
preserve prior `<think>` content.

Three plain-chat turns completed with closed reasoning cards, coherent final
answers, disappearing Stop controls, and unlocked input:

- first chat: TTFT 0.69 s, 200.1 tok/s, 195 generated tokens;
- follow-up: TTFT 0.32 s, 191.6 tok/s, 198 generated tokens;
- identical prompt in a new chat: TTFT 0.33 s, 190.1 tok/s, 112 generated
  tokens.

With paged RAM still off, source traces recorded real disk restores rather
than relying on the UI color:

- first prompt restored 2,968 of 3,009 prompt tokens, prefilling 41;
- follow-up restored 3,028 of 3,050, prefilling 22;
- new-chat warmup restored 2,968 of 2,971, prefilling 3;
- identical new-chat prompt restored 3,006 of 3,009, prefilling 3.

Each restore rederived 18 SSM companion states. Paged-store traces reported no
paged payload and zero effective KV layers, which confirms this evidence is
disk-L2-with-paged-RAM-off rather than a hidden RAM hit.

The database/tool stress turn **failed** and keeps the LFM parser row
`PARTIAL`. The visible turn eventually finalized, but contained two failed
`db_query` calls, a failed `todo` call, a successful `db_schema`, a
semantically wrong `db_create_table`, three failed inserts, a query returning
`null`, and a fabricated final sum of 16. The persisted history proves:

- the model's reasoning displayed the intended
  `name='lfm_parser_probe' LIMIT 1;`, while the dispatched tool argument was
  `name='lfm_parser_probe LIMIT 1` (missing the closing quote and semicolon);
- the later table call created `name`, `sql`, `sql_version`, and `label`
  columns instead of the requested `label` and `value`, omitting the requested
  unique index;
- failed tool rounds retained cache continuity rather than resetting to zero:
  disk restore boundaries advanced through 5,156, 5,279, 5,382, 5,498, 5,596,
  5,637, 5,857, 5,951, and 6,045 tokens.

This evidence does not yet distinguish a malformed native model envelope from
stream-parser mutation because persisted history contains parsed calls, not
the raw native envelope. The next round must capture the raw LFM stream, add a
transcript-derived parser boundary test, fix only a proven runtime defect, and
repeat the exact database scenario in a fresh Release app. No LFM tool-parser
or database compatibility claim is permitted before that rerun.

### 2026-07-24 LFM native-envelope attribution round

This second isolated Release round used the Osaurus campaign working tree
based at `f94063468feb5f98b69b2585fec8ee6f814c92bd`, exact vMLX
`e85d7297546b4dc244ea4f8d748a0bbb6a2f40c0`, bundle identifier
`com.dinoki.osaurus.runtimecompat20260724`, test root
`/private/tmp/osaurus-runtime-campaign-live-root-e85d7297-20260724-2145`,
and the same LFM2.5 MXFP8 bundle.

The visible cache state was prefix on, paged RAM off, disk L2 on, and codec
`Engine Selected`. The first database turn showed a successful `db_schema`
card followed by four failed `db_create_table` cards. Raw native-envelope
tracing proved the failures originated in model output:

- one call misspelled the requested table and added unsupported column
  `description` fields;
- one registered call omitted required top-level `purpose` and reached the UI
  as structured, retryable `invalid_tool_arguments`;
- two registered calls invented a top-level `mode` field and reached the same
  honest retry path.

No parser-invalid call executed the database tool body. Despite those visible
failures, the model falsely finalized with “The table was created...” and did
not insert or query anything. The Stop control disappeared and input unlocked,
but the result was semantically false. The visible first-turn metrics were
TTFT 0.54 s, 90.0 tok/s, and 1,773 generated tokens.

A direct corrective follow-up also failed. Its first native call again
invented top-level `mode` and produced a failed tool card. The next native
retry contained a complete registered `db_create_table(...)` invocation and
both native tags but omitted the outer closing `]`. The exact trace was parsed
as zero calls, so no correction card reached the model. The turn ended with a
closed Thought card, no successful tool card, no truthful final answer, no
insert/query, Stop gone, and input unlocked. Its visible metrics were TTFT
0.32 s, 156.0 tok/s, and 431 generated tokens.

Disk cache continuity was preserved through both failed turns with paged RAM
off. Recorded restores included 5,134/5,225, 5,222 plus 44 remaining, 5,263
plus 138, 5,398 plus 105, 5,500 plus 103, 5,600 plus 103, 5,700 plus 112,
and 5,809 plus 103 prompt tokens. Each restore carried 18 SSM companion
states; paged-store telemetry reported zero effective KV layers and no paged
payload.

This round closes raw-output attribution but not compatibility. Engine
`7c37de3e` now quarantines the explicitly terminated missing-`]` shape without
repairing or executing it. The same database task must still pass in the exact
`7c37de3e` Release app, including real create/insert/query results, coherent
final answer, terminal unlock, and a follow-up.

### 2026-07-24 exact-7c37 LFM database recovery round

The current-pin round used Osaurus source
`f94063468feb5f98b69b2585fec8ee6f814c92bd` with exact vMLX
`7c37de3e77daf1ce1e3a212c0aaad3ba4cb471b9`. The successful Release build was
cloned and ad-hoc signed as
`com.dinoki.osaurus.runtimecompat7c37de3e20260724`, then launched with isolated
test root
`/private/tmp/osaurus-runtime-campaign-live-root-7c37de3e-20260724-2225`.
The exact bundle remained
`/Users/eric/models/dealign.ai/LFM2.5-8B-A1B-MXFP8-CRACK`.

The visible Cache settings showed prefix cache on, paged RAM off, disk L2 on
with a 10 GB limit, cache codec `Engine Selected`, and SSM rederive on. This was
not a TurboQuant row. The source package checkout inside the successful build's
DerivedData resolved to exact `7c37de3e`.

The first database task completed with four successful visible cards:

- `db_schema` in 911 ms;
- `db_create_table` in 657 ms;
- `db_insert` in 329 ms;
- `db_query` in 239 ms.

The created `lfm_parser_probe_four` table contained `alpha=7` and `beta=17`;
the query result and visible final answer both reported total 24. The final
answer was in the normal content channel, the Thought card closed, Stop
disappeared, input unlocked, and the UI reported TTFT 0.46 s, 83.7 tok/s, and
28 generated tokens. A follow-up query returned the same two rows and total,
then finalized normally at TTFT 1.97 s, 99.1 tok/s, and 40 generated tokens.

Raw native tracing proved that the corrected LFM Pythonic envelope preserved
the nested column objects and executed the registered tool. Disk-L2 restores
with paged RAM off included 4,083 restored plus 169 remaining, 4,249 plus 147,
4,249 plus 149, 1,560 plus 3,011 on the follow-up turn, and 4,568 plus 80 after
its tool result. Companion telemetry restored/rederived the 18 LFM SSM states;
paged-store telemetry continued to report no RAM payload and zero effective KV
layers.

A deliberately malformed table-creation task then proved the structured error
path. Five invalid registered calls produced honest failed cards and did not
execute the tool body. A later valid create, insert, and query all succeeded.
Disk restores continued through the failures rather than resetting to zero,
including boundaries 1,560, 4,892, 4,996, 5,096, 5,200, 5,300, and 5,457.

That turn exposed a separate terminal-channel failure: vMLX reported normal
`stop`, but the final generation emitted 72 tokens entirely as reasoning,
closed with `unclosedReasoning=true`, and produced zero content tokens. The
persisted assistant turn has `content_len=0`, `thinking_len=290`, and terminal
stop reason `stop`; the UI showed the warning “thinking didn't close” and the
answer inside an open Thought card.

A bounded control reproduced the same failure after exactly one expected SQL
execution error and one successful query. The failed query executed once, the
corrected query returned rows `alpha=7` and `beta=17`, and disk restores
remained live at 1,560+2,658, 1,560+4,263, and 5,820+80 prompt tokens. The final
assistant turn again had normal terminal stop with `content_len=0`, this time
`thinking_len=97` and 30 generated tokens. The UI finalized and unlocked at
TTFT 1.13 s and 85.0 tok/s, but the final stayed in an unclosed Thought card
and also ignored the requested row report.

Source trace explains the channel choice without justifying a repair: generic
`lfm2_moe` normally resolves to no reasoning parser, but this exact bundle's
template contains `<think>...</think>` replay support together with native LFM
tool sentinels, so `JangLoader` selects a tag-driven parser with
`startInReasoning=false`. The template does not synthesize a generation-time
`<think>` opener and exposes no `enable_thinking` kwarg. Therefore these two
terminal failures reflect model-emitted open reasoning reaching EOS, not an
Osaurus content-delta split. No forced closer, prompt coercion, or
reasoning-to-content rewrite is permitted. The row remains `PARTIAL` pending
either a real bundle/template/runtime root cause or an explicit evidence-backed
classification of this model's post-error behavior.

| Lane | Required current-pin row | Current status | Missing gate |
| --- | --- | --- | --- |
| Tool parser | LFM2.5 MXFP8 Pythonic nested object/array, tool error, continuation | PARTIAL | Parser/tool execution and disk continuity are live-proven; post-error final must close reasoning and emit truthful content |
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
