# Bonsai Agent DB Fitness Live Gate

Date: 2026-07-23

Status: **PARTIAL — USER EXPORT INSPECTED; FIXED RELEASE LIFECYCLE/CACHE
EVIDENCE EXISTS; END-TO-END DATABASE/SCHEDULER/EXPORT GATE OPEN**

This checkpoint tracks a user report from Osaurus after the 2026-07-23 update.
It is deliberately separate from the merged TextEdit/AppleScript PR #2151.
No screenshot, video, archive, or other binary proof belongs in Git history.
Local visual artifacts may be inspected during diagnosis, but only sanitized
text evidence may be committed or posted to GitHub.

## Reported configuration and task

- Model: `OsaurusAI/Bonsai-27b-Ternary-JANG`
- Thinking: explicitly enabled by the user
- Export:
  `/Users/eric/Downloads/Personal Fitness Trainer.zip`
- Extracted local-only transcript:
  `/private/tmp/osaurus-fitness-export-20260723.yZ6X4i/За сегодня я съел где-то 1200-1300 кКал и выпил.../chat.md`
- Prompt:

  > Как мой агент, ты можешь рассчитывать для меня потребление калорий,
  > напоминать о питье воды, напоминать считать калории без обращения к тебе
  > в чат напрямую? Ты можешь сам планировать свои запуски и вести меня как
  > тренер по сжиганию жира? Мне нужна поддержка, напоминания и постоянный
  > контроль. + расчет физической активности начиная с самых минимальных
  > занятий, иначе моя нервная система не выдержит и я перестану за всем
  > следить.

The earlier two turns in the same export were ordinary Russian-language calorie
questions and received visible text answers. The failure began only when the
user asked the agent to create persistent tracking and autonomous reminders.

## User-requested end state

The reporter clarified that the intended workflow is:

1. the agent owns a persistent, inspectable table instead of accumulating the
   tracking history inside chat context;
2. the table can be exported on demand;
3. future chats and scheduled runs continue from that database state;
4. the agent starts itself during the day and sends reminders based on the
   stored plan;
5. context growth is bounded because a scheduled run starts fresh and queries
   the database rather than replaying an indefinitely growing chat.

The current product contract can represent this only when the agent's
**Database** and **Self-scheduling** abilities are both enabled. Data Keeper
specifies `db_schema` before schema mutation, `db_upsert`/`db_insert` for
records, and `db_export` followed by `share_artifact` for a downloadable
export. Autonomous Scheduler specifies `get_current_time`, one
`schedule_next_run`, and a self-contained future-run instruction; recurring
work must schedule its own following run. These are source contracts, not live
acceptance. The live gate must still prove table creation, record reuse in a
new chat, export, scheduling, notification, cancellation, and restart.

## Artifact facts

The export contains the following sequence:

1. Bonsai emitted a `db_create_table` call missing the required `name`.
   vMLX/Chat represented it as the structured
   `_error:"invalid_tool_arguments"` argument envelope. Osaurus returned
   `kind:"invalid_args"`, `field:"name"`, `retryable:true`.
2. Bonsai corrected the arguments and successfully created `daily_log`.
3. Bonsai immediately called `db_create_table` for `daily_log` again with a
   different schema. Osaurus truthfully returned
   `kind:"invalid_args"`, `retryable:false`, and told it to call `db_schema`
   before evolving the table with `db_alter_table`.
4. Bonsai successfully created a distinct `activity_log`.
5. Bonsai attempted to create `daily_log` a third time. Osaurus returned the
   same non-retryable table-exists failure.
6. The export ends on an assistant turn recorded as `2048 tok, 25.2 tok/s`
   with no visible content and no tool call.

The two successful table creations rule out a blanket database-permission or
tool-execution failure for this transcript. They do not prove that schedules,
notifications, or later DB operations were authorized or functional because
the run never reached those steps.

## Current-source trace

Current branch base:
`25d0175d1e03f019ca26279922b50fdd702ea52e`

1. `DBCreateTableTool` exposes `name`, `purpose`, and `columns` as required
   schema fields. Its description already says to call `db_schema` first.
2. `ToolRegistry.invalidToolArgumentsEnvelope` preserves the model/parser
   error as a typed retryable `invalid_args` result. The first exported
   missing-name call therefore reached the normal truthful schema-error path.
3. `AgentTaskState` deliberately excludes `db_*` from deterministic-error
   replay because repeated database calls can legitimately succeed after state
   changes. It has no typed transition for a table-exists result and no
   logical-table-name repeat tracking. Only the generic third identical
   argument signature can produce an advisory repeat notice.
4. `StreamingStatsHint` carries `stopReason`, including `length`, alongside
   token count, rate, and the unclosed-reasoning flag.
5. `ChatView.processStreamDeltas` reads token count/rate and
   `unclosedReasoning` from the stats hint but currently discards `stopReason`.
6. Chat's agent-loop model-step classification explicitly treats a turn with
   blank visible content but nonblank thinking as `.finalResponse`. It does
   not distinguish natural stop from `max_tokens`/`length`.

The exported final `2048 tok` reasoning-only turn is therefore consistent with
this unhandled state: a model can exhaust its output cap entirely in reasoning,
produce no answer or tool call, and Chat still classifies the task as a clean
final response. The current-source cache-off reproduction below proves this
exact state on the exact prompt and local Bonsai bundle.

## Current-source live reproduction

Live app:

- Release product:
  `/private/tmp/osaurus-bonsai-db-baseline-derived-20260723/Build/Products/Release/osaurus.app`
- Bundle identifier:
  `com.dinoki.osaurus.bonsaidbbaseline20260723`
- Executable SHA-256:
  `a52d635bdd476e7cf9d3239d0a97a8c710054f8bbafdeef4970091baa60fe166`
- Isolated root:
  `/private/tmp/osaurus-bonsai-db-baseline-root-20260723`
- Osaurus source:
  `25d0175d1e03f019ca26279922b50fdd702ea52e`
- vMLX pin:
  `7d6235316226ba9fe608018f86c463784e48b3d5`
- Model:
  `dealign.ai/Bonsai-27b-Ternary-JANG-CRACK`
- Effective UI controls:
  Thinking On, maximum output 2,048 tokens, temperature 0.7, paged GPU cache
  Off. The two runs below differ only in SSD Disk Cache On versus Off and use
  separate fresh agents/private databases.

### SSD Disk Cache On

The exact Russian prompt completed one healthy interleaved path:

1. visible Russian reasoning;
2. visible Russian plan;
3. successful `db_schema`;
4. a second visible reasoning phase;
5. a visible Russian final answer.

The UI reported `TTFT 9.68s`, `30 tok/s`, and `814 tokens`. Runtime telemetry
restored `5383/5496` prompt tokens from disk on the initial step and
`5491/5618` after the tool result. This proves that Russian input, the database
tool surface, interleaved reasoning/tool/result/final streaming, and SSD prefix
restore can all work together in the current app.

On the explicit follow-up asking it to create tables, seed rows, and schedule
reminders, Bonsai successfully created one database table. Its post-tool
completion then emitted 2,048 tokens and ended with `stop=length`; persisted
content contained 5,287 characters, including 1,776 literal newline
characters. The live bubble expanded into a large blank region while streaming.
`StreamingDeltaProcessor` appends model deltas verbatim and
`GenerationEventMapper` forwards vMLX token chunks unchanged, so the blank
region was not inserted by window sizing or the renderer. Window size only
made the upstream newline degeneration more conspicuous.

### SSD Disk Cache Off control

Computer Use visibly changed Server > Settings > Cache > SSD Disk Cache to Off
and saved it. The exact Russian prompt on a fresh agent then showed a fully cold
`0/5496` prefill with no disk hits or stores, proving that this control changed
the effective runtime path.

Bonsai emitted this persisted tool call:

```json
{"ids":"[skill/Autonomous Scheduler, skill/Data Keeper]"}
```

Osaurus returned:

```json
{"ok":false,"field":"ids","kind":"invalid_args","message":"Property 'ids' must be an array","retryable":true,"tool":"capabilities_load"}
```

The next step performed another fully cold `0/5607` prefill, produced exactly
2,048 tokens and 7,397 reasoning characters, emitted no visible content and no
tool call, and ended at `stop=length`. The UI unlocked and displayed
`TTFT 19.29s`, `26.7 tok/s`, `2,048 tokens`, plus the unclosed-thinking warning,
but the agent loop had classified the reasoning-only capped step as a final
response and abandoned the requested work.

The cold reproduction rules out SSD cache restore as a necessary cause of the
failure. The prompt manifest and `capabilities_load` schema both showed `ids`
as an array, and the enabled-capabilities block included a concrete valid-array
example. The persisted string value therefore originated in the model/tool
output path; it was not a validator rewrite of a valid array. The validator's
typed rejection was correct. The harness defect is what happens next:
`stop=length` is discarded by Chat UI state and a reasoning-only capped turn is
accepted as successful finalization.

### Current root-cause split

1. **Model/output contract failure:** Bonsai sometimes emits a stringified
   pseudo-array for a schema-declared array even when a valid example is in the
   live prompt.
2. **Correct validation:** Osaurus rejects that value as retryable
   `invalid_args`; this is not a permission failure.
3. **Model recovery failure:** Bonsai loops in reasoning instead of correcting
   the array and exhausts the explicit 2,048-token output limit.
4. **Harness finalization failure:** `StreamingStatsHint` carries
   `stop=length`, but `ChatView` does not retain it and treats the nonblank
   reasoning channel as `.finalResponse`.
5. **Separate visible degeneration:** another stochastic branch emits literal
   newline tokens until the same 2,048-token cap, causing the large blank live
   bubble.

Russian is not the cause: both earlier exported Russian turns and the healthy
cache-on current-source turn completed normally. Database permissions are not
the cause: the export and the current-source run both performed successful
table creation.

The malformed `capabilities_load` value does pass through vMLX's Qwen XML
function parser. Bonsai's bundle stamps the Qwen reasoning/tool parsers, and
its chat template renders `<function=...><parameter=...>` calls. The parser
correctly attempts JSON conversion for the schema-declared array, but invalid
JSON such as `[skill/Autonomous Scheduler, skill/Data Keeper]` previously
remained a scalar string. Osaurus then correctly rejected that scalar against
the tool schema.

The exact local bundle has no `chat.sampling_defaults` block in
`jang_config.json`. Its `generation_config.json` declares `do_sample:true`,
`temperature:1.0`, `top_p:0.95`, `top_k:20`, and EOS id `248046`; it does not
declare `max_new_tokens`. The baseline app's visible/default-agent temperature
override was `0.7` and maximum output was `2,048`, so those two user settings
superseded the corresponding bundle fallback while top-p/top-k/EOS still
belonged to the bundle/runtime. This means the observed branches are sampled
behavior under an explicit temperature override, not a deterministic model
contract. Post-fix proof must record the engine's effective values rather than
infer them from either file or UI alone.

## Fix branch under test

This section records implementation state, not acceptance:

- vMLX commit:
  `df5a4e9ba3b917eff36064f77c3ffddd72c961dd`
- vMLX PR: `osaurus-ai/vmlx-swift#179`
- vMLX changes:
  - recover a plain outer-bracketed comma list only when the declared
    parameter schema is exactly `array<string>`. Valid JSON remains on the
    existing path. Object arrays, nested collection syntax, quotes, control
    characters, and ordinary scalar parameters do not enter the recovery.
  - route Gemma's live-observed decoded `⭕thought\n...<channel|>` opener into
    the reasoning stream instead of visible content. This is a narrow parser
    alias, not a forced reasoning close/open or sampler workaround.
- vMLX source evidence: the existing XML parser selection plus the exact live
  malformed value, split-delta streaming, valid JSON unchanged, object-array
  negative control, and nested-syntax negative control passed 13 focused XML
  parser tests before this pin. The new `df5a4e9...` pin additionally passed
  `HarmonyParserFocusedTests` (18 tests), including
  `Gemma4 decoded thought-channel opener routes to reasoning` and the Gemma
  VLM guard that normalized schemas render in the template while raw schemas
  remain in `LMInput.toolSchemas`.
- Osaurus change under test: persist the authoritative terminal stop reason;
  classify a no-tool `stop=length` turn as incomplete instead of success;
  propagate that result through Chat, plugin streaming/non-streaming, HTTP
  streaming, browser/text delegation, and evaluator reporting; collapse
  terminal whitespace-only output before rendering the incomplete notice; trim
  whitespace around string boolean tool arguments before schema validation and
  execution coercion.
- Osaurus source evidence: focused agent-loop, turn-persistence, and streaming
  hint suites built and exited zero before this pin. After the `df5a4e9...`
  repin, `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening`,
  `SchemaValidatorCoercionTests`, and `AgentDatabaseTests` exited zero. This
  is not live proof.
- SQLite persistence follow-up: schema v12 adds nullable
  `turns.terminal_stop_reason`, includes it in the incremental content hash,
  upsert, select, and row decode. Focused `ChatHistoryDatabase`,
  `ChatHistoryMigrationRepair`, and `ChatTurnFinishReason` Xcode suites exit
  zero. App-restart/UI preservation is still open.

## Prior fixed-Release live evidence

These rows are useful diagnostics only after the vMLX repin. They were captured
before the current `df5a4e9...` vMLX pin and therefore cannot close the current
acceptance gate.

Isolated fixed build before the current repin:

- product:
  `/private/tmp/osaurus-bonsai-db-fix-release-derived-20260723/Build/Products/Release/osaurus.app`
- bundle id: `com.dinoki.osaurus.bonsaidbfix20260723`
- isolated root:
  `/private/tmp/osaurus-bonsai-db-fix-root-20260723`
- Osaurus base: `25d0175d1e03f019ca26279922b50fdd702ea52e`
  plus the uncommitted scoped patch
- embedded vMLX: `2dbb39a1e56bf6c5f914e0611ab0002e253fdfae`
- model: `dealign.ai/Bonsai-27b-Ternary-JANG-CRACK`
- visibly saved controls: Thinking On, Prefix Cache On, paged GPU cache Off,
  SSD Disk Cache On, SSM re-derive On

Live Computer Use rows:

1. With Max Tokens visibly saved as 32, a reasoning prompt ended with a
   distinct reasoning card, the truthful incomplete notice,
   `TTFT 1.05s`, `43.6 tok/s`, 32 tokens, and the
   `thinking didn't close` warning. Input unlocked without an automatic retry.
2. After visibly restoring Max Tokens to 2,048, a same-chat follow-up produced
   a closed reasoning card plus final answer at `TTFT 0.54s`,
   `41.3 tok/s`, 535 tokens, with no unclosed warning.
3. In a fresh chat, the exact Russian prompt restored 5,383 prompt tokens from
   SSD and prefetched only 113 remaining tokens with paged GPU cache Off. It
   produced a coherent clarification at `TTFT 0.87s`, `37.3 tok/s`,
   728 tokens.
4. The supplied-parameters follow-up emitted a `db_create_table` call whose
   vMLX parser marked `invalid_tool_arguments`, missing `name`. The next
   generation restored 5,986 tokens from SSD and prefetched 361 remaining, so
   the failed tool did not reset KV reuse to zero. That continuation then
   spent all 2,048 output tokens in unclosed reasoning and ended with the
   truthful incomplete notice at `TTFT 1.57s`, `22.7 tok/s`; input unlocked.

These rows prove the fixed terminal lifecycle and the failed-tool SSD suffix
continuation only for that earlier build. They do **not** prove the current
pin or the requested workflow: no table, schedule, reminder, or export was
created. Temporary raw tool-envelope tracing used during diagnosis was removed
from `ChatView.swift` before the current rebuild.

## Current fixed-Release gate still open

The required live acceptance build must embed vMLX
`df5a4e9ba3b917eff36064f77c3ffddd72c961dd` and visibly prove:

1. Bonsai with Thinking On can complete the Russian database/scheduler task
   far enough to create the expected tables or, if the model still fails, stops
   truthfully without hidden success, blank finalization, or a stuck spinner.
2. A failed tool call does not reset SSD prefix/cache reuse to a cold `0/N`
   prefill on the next step.
3. Gemma 4 12B MXFP8 with Thinking On no longer leaks `⭕thought` or
   `<channel|>` into visible content and the whitespace boolean DB arguments
   validate when emitted as `" false "`.
4. A new chat/follow-up with paged GPU cache Off and SSD Disk Cache On shows
   cross-chat disk restore/partial-prefix behavior in the live UI/cache
   telemetry.
5. Input unlocks at stream completion and no turn remains indefinitely queued
   or spinning after model output has ended.

## Adjacent context-limit UI contract

A current user screenshot shows three apparently conflicting values:

- the chat composer shows approximately `8.6k / 262k`;
- Settings > Chat shows Context Length `128000`;
- Settings > Server > Cache exposes a separate per-session window.

Current source assigns them different owners:

1. The composer denominator calls
   `AgentLoopBudget.resolveContextWindowSync`. For an installed local model it
   reads model-bundle metadata first. Bonsai's
   `config.json > text_config.max_position_embeddings` is 262,144, so the
   displayed 262K is the bundle's nominal local context window.
2. Settings > Chat labels its 128,000 field “Context window for remote
   models.” `AgentLoopBudget` uses it only when no fixed Foundation window and
   no installed-model context metadata are available. It does not override
   Bonsai's detected 262,144.
3. Settings > Server > Cache labels the other field “Per-Session Window
   (tokens)” and binds it to `cache.defaultMaxKVSize`. The live coordinator
   resolves a blank field through Memory Safety (the default Safe Auto plan
   currently resolves 65,536); an explicit user value overrides that plan.
   `longPromptMultiplier` controls when this retained-KV cap engages.

This distinction is source-traced but not yet accepted. The open correctness
question is whether a nominal 262K request can be admitted while a smaller
per-session KV window silently rotates away earlier full-attention context. The
UI must either show the actual effective retained window/threshold or prove
that the cache cap is only a storage optimization and does not reduce model
attention. Required live rows: local 262K metadata, remote/unknown 128K
fallback, Safe Auto resolved KV cap, explicit cache-cap override, and prompt
behavior below/above the multiplier threshold. Do not relabel or merge these
values until the vMLX cache implementation and live telemetry agree.

Both fixes remain **PARTIAL** until the exact fixed Release app passes the
Computer Use matrix below.

## Cross-system regression questions

These are required questions because parser output, loop state, and cache state
meet at the same model step. A pass in one layer does not imply a pass in the
others.

### Tool parser and schema boundary

1. Does the exact malformed Bonsai list become two string-array elements when
   emitted in one chunk and when its XML tags/value are split across stream
   chunks?
2. Are already-valid JSON arrays byte-for-byte equivalent in parsed value?
3. Do `array<object>`, nested arrays, quote-containing values, empty members,
   unknown functions, ordinary string parameters, and missing required
   parameters remain on their existing rejection paths?
4. Can two tool calls in one completion parse independently without the first
   call's recovery changing the second call?
5. Do reasoning deltas before and after a tool call remain in the reasoning
   card, with no XML/protocol markers leaking into visible content?
6. Is the recovery limited to Qwen XML parsing, leaving Gemma, LFM, DSML, and
   other parser families unchanged?

### Agent-loop completion and recovery

1. Are natural `stop`, tool-call termination, `length`, cancellation,
   disconnect, and provider error still distinguishable after persistence and
   chat reload?
2. Does reasoning-only `length` show a truthful incomplete state once, unlock
   input, and avoid an automatic identical retry?
3. Does visible content followed by newline degeneration trim only terminal
   whitespace while preserving the visible answer and reporting the output
   cap honestly?
4. After missing-field, malformed-array, table-exists, permission-denied, or
   tool-runtime failures, does the next step receive the exact structured tool
   result and either correct itself or stop truthfully?
5. Can a same-chat follow-up continue after each failure without a stuck
   spinner, queued lease, stale pending tool card, or false completion
   notification?
6. Do spawned text/browser agents and plugin/API agent loops return an
   incomplete/error envelope rather than silently treating the same capped
   state as success?

### SSD/prefix cache interaction

1. With paged RAM cache Off and SSD cache On, does the initial stable system,
   tool-schema, agent-memory, and user-prefix region restore from disk on a
   fresh chat and after app relaunch?
2. When a failed tool result changes only the suffix, does longest-prefix
   lookup reuse the earlier matching SSD blocks and prefill only the divergent
   result/continuation suffix instead of returning to `0/N`?
3. If several partial candidates exist, does selection use the longest safe
   match rather than the newest, shortest, or incompatible entry?
4. Do cache telemetry and visible prefill agree on restored/remaining token
   counts, TTFT, disk hit/miss/store counters, and queued/prefill/decode/drain
   transitions?
5. Does cancellation during prefill/decode drain the lease without storing a
   poisoned partial suffix, while preserving earlier safe SSD blocks for the
   next chat?
6. Do model, tokenizer, template, tool schema, Thinking state, media salt,
   cache codec, and architecture changes produce intentional misses rather
   than unsafe cross-configuration hits?
7. For Bonsai/Ornith/Qwen 3.5 hybrid GDN/SSM models, does a partial SSD KV hit
   restore or asynchronously re-derive companion recurrent state at the exact
   matched boundary before decode?
8. Does the same sequence remain coherent with SSD Off, proving cache is an
   optimization and not required for correct parser/loop behavior?

### Cross-family and UI controls

1. Does the exact task remain coherent on Bonsai plus one other Qwen-XML model,
   while a non-Qwen parser control shows no behavior change?
2. Does explicit Thinking On/Off reach every model step after tool results and
   every delegated step, rather than only the first manual chat request?
3. Does resizing the chat during generation change only layout, not persisted
   deltas, tool cards, stop reason, or terminal whitespace cleanup?
4. Do the input, Stop button, model picker, Thinking control, and new-chat
   action return to the correct enabled state after success, tool error,
   output-cap exhaustion, and cancellation?

### Generation-config ownership and stochastic behavior

1. At model load, are temperature, top-p, top-k, min-p/top-min-p, repetition
   controls, stop ids/strings, and other supported defaults read from the
   active bundle's `generation_config.json`/JANG metadata rather than inferred
   from a display name?
2. Do user-explicit chat/API overrides win only for that request, while an
   untouched control uses the exact bundle defaults?
3. Are the effective values preserved on every post-tool generation, spawned
   model run, delegated agent step, and automatic follow-up, including the
   explicit Thinking choice?
4. Does changing model/config invalidate or salt incompatible cache entries
   rather than restoring a prefix produced under different template or
   generation ownership?
5. Under a deterministic control, do repeated runs produce the same parsed
   tool structure and terminal state? Under matched bundle-default stochastic
   sampling, what is the failure rate across repeated fresh runs?
6. If malformed arrays, duplicate DB creation, newline degeneration, or
   reasoning-only exhaustion are stochastic, do all failures still recover or
   terminate truthfully without depending on a lucky sample?
7. Do logs/telemetry expose the effective request values used by the engine so
   the UI setting, request DTO, and runtime cannot disagree silently?

No acceptance fix may introduce a hidden sampler override, forced reasoning
tag, synthetic stop token, or family-name-based clamp. A behavioral difference
must be traced either to the bundle contract, a user-visible override, or a
runtime/parser bug.

## Remaining questions and post-fix gates

1. Does retaining `stop=length` prevent a reasoning-only capped turn from
   finalizing the agent run as success, across Chat UI and the other agent-loop
   surfaces?
2. Does one bounded, truthful length continuation recover, or does the model
   repeat the same reasoning loop? Do not add forced tags, sampler overrides,
   or family-specific prompt coercion.
3. Does the model emit a valid visible answer if Thinking is explicitly Off?
   This is a diagnostic control, not permission to force Thinking Off.
4. After a successful `db_create_table`, does a structured table-exists result
   plus `db_schema` preserve tool-result grounding and lead to
   `db_alter_table`, or does Bonsai repeat creation under matched sampling?
5. Do a missing-field error, a table-exists error, and a permission denial
   have distinct continuation behavior?
6. Does the run terminate, unlock input, and accept a same-chat follow-up after
   each outcome?
7. Do scheduler/reminder steps ask for the correct user confirmation and
   respect the agent's actual schedule mode?
8. Do the same task and error controls preserve SSD-prefix reuse across
   post-tool turns without resetting to a cold prompt?

## Acceptance matrix

All rows require a fresh Release-config Osaurus app with a unique bundle id,
isolated `OSAURUS_TEST_ROOT`, keychain-disabled test profile, exact local model
bundle under `/Users/eric/models`, and visible Computer Use operation.

| Row | Required evidence | Status |
| --- | --- | --- |
| Exact Russian prompt, Thinking On | Visible tool rows, exact args/results, reasoning card, final visible answer, finish reason, TTFT, token/s, input unlocked | PARTIAL — one healthy run; one cache-on newline/length failure; one cache-off malformed-array/length failure |
| Thinking Off control | Same prompt, explicit picker state, no hidden reasoning, truthful final/tool behavior | OPEN |
| Malformed `capabilities_load.ids` recovery | Typed invalid-args result followed by corrected array call or truthful incomplete state; never clean-finalize a capped reasoning-only turn | FAILED CURRENT LIVE |
| Missing `name` recovery | One typed invalid-args result, corrected call, no parser-marker leak | EXPORT-OBSERVED; CURRENT LIVE OPEN |
| Existing table recovery | `db_schema`/`db_alter_table` or truthful stop; no repeated create loop | FAILED IN EXPORT; CURRENT LIVE OPEN |
| Schedule/reminder continuation | Correct schedule tools, confirmation, bounded recurrence, final summary | OPEN |
| Tool error then same-chat follow-up | No hang; history grounded; partial SSD cache restore; input unlocked | PARTIAL — 5,986-token SSD restore and clean unlock proven; task correction failed at output cap |
| New chat and app restart | Disk L2 partial restore with paged RAM off; coherent answer/tool use | OPEN |
| Cross-model control | At least one non-Bonsai local family under the same tool schema | OPEN |

### Cross-model reporter-workflow matrix

The reporter's exact usage—not a load-only or single-call prompt—is the
acceptance workload. Run it first on Bonsai, then with matched UI settings on
one additional Qwen-XML bundle and one non-Qwen parser family:

1. Russian intake prompt and supplied body parameters;
2. inspect existing schema before mutation;
3. create the tracking schema once and seed/query a row;
4. start a fresh chat and query the same persisted row without replaying the
   old conversation;
5. export CSV/JSON and surface the downloadable artifact;
6. read current time and schedule one approved next run whose instruction is
   self-contained and reschedules itself for recurrence;
7. inspect/cancel that run;
8. inject one malformed/missing argument and prove the typed result is
   grounded, the next prefill reuses SSD prefix state, and the model either
   corrects it or stops truthfully;
9. repeat after app restart with paged RAM cache Off and SSD cache On;
10. record visible Thinking state, reasoning/content separation, tool rows,
    terminal reason, TTFT, token/s, restored/remaining prompt tokens, and input
    unlock.

No family is inferred from another. Bonsai, the Qwen control, and the
non-Qwen control each remain `OPEN` until their own live rows exist.

No implementation is accepted from source/tests alone. No model-family blame is
accepted unless matched live controls show the same current harness succeeds
while the exact Bonsai bundle repeatedly fails under the same effective
configuration.

## 2026-07-23 late emergency: stable system-prefix SSD restore

Status: **VERIFIED LIVE FOR THE SCOPED QWEN/GEMMA EMERGENCY PR — FINAL-PIN
RELEASE TOOL, FINISH-REASON, REASONING, AND SSD-SUFFIX ROWS RECORDED**

The user-reported cache symptom is that fresh chats and post-tool continuations
can show `0/N` prefill even though SSD cache is enabled and previous chats
already warmed the same Osaurus/tool prompt rail. The current source diagnosis
is not arbitrary suffix-cache failure. vMLX restores one validated contiguous
prefix boundary from the candidate set; it does not stitch unrelated SSD
fragments. The missed reuse occurs because Osaurus renders static system
instructions plus mutable DB/sandbox/tool state into one system message. When
the mutable suffix changes after a database or tool event, the full-system
boundary becomes unsafe even though the leading static bytes remain identical.

The fix under test adds a runtime-only cache hint:

- Osaurus computes the already-existing `SystemPromptComposer.staticPrefix` and
  attaches it to local MLX requests as `cacheStableSystemPrefix`.
- The field is local-only: it is not in `ChatCompletionRequest.CodingKeys`, is
  not exposed to OpenAI JSON, is not forwarded to remote providers, and is not
  rendered as additional model-visible text.
- vMLX accepts `UserInput.cacheStableSystemPrefix` and derives an earlier
  tokenizer boundary by rendering two probe system messages with divergent
  suffixes, then LCP-validating both probes against the real prompt tokens.
  This prevents BPE split-point mistakes and avoids trusting raw byte length.
- LLM, Gemma 4, and Qwen3VL processors pass the hint into
  `canonicalChatCacheBoundaries`, covering the text path and the main local
  Gemma/Qwen/VL paths affected by Osaurus chat.

Important non-change: **TurboQuant KV remains opt-in only.** This cache-boundary
fix must not turn on TurboQuant for any family. Source policy still says
`engineSelected` resolves to native/fp16 KV and `shouldUseTurboQuantByDefault`
returns `false`. The only path to TurboQuant KV is a user-visible Settings
change to `cache.liveKVCodec = turboQuant` with explicit key/value bit widths.
The live Release proof must inspect the isolated app config and UI state before
any PR comment claims this is verified.

Current source/test evidence:

- Final Osaurus vMLX pin:
  `f50853514ee00365837be3301c91850ca7ed5877`
- Pre-squash vMLX proof commit:
  `91933aef193cab180b821bad1f4b4cc8ad753107`
  (`git diff 91933aef..vmlx-origin/main` was empty after PR #179 merged, so
  the final main pin has the same vMLX source tree as the proof commit)
- vMLX focused test:
  `/tmp/vmlx-static-prefix-boundary-tests-20260723.log`
  (`CanonicalChatCacheBoundariesTests`, including
  `staticSystemHintAddsEarlierBoundaryInsideMutableSystemMessage`)
- Osaurus focused source/pin test:
  `/tmp/osaurus-static-prefix-source-tests-91933aef-rerun-20260723.log`
  (`RuntimePolicySourceTests/chatComposedStaticPromptPrefixReachesLocalMLXCacheHint`
  and `vmlxPinIncludesRuntimeHardening`)
- Osaurus focused DB/tool-loop regression test:
  `/tmp/osaurus-db-toolloop-static-prefix-91933aef-20260723.log`
  (`SchemaValidatorCoercionTests`, `AgentDatabaseTests`,
  `AgentToolLoopTests`, `ChatTurnFinishReasonTests`)
- Osaurus focused TurboQuant policy regression test:
  `/tmp/osaurus-tq-default-policy-tests-91933aef-20260723.log`
  (`MLXBatchAdapterTests/cacheKVModeTagTracksEffectiveCoordinatorPolicy`,
  `ServerRuntimeSettingsStoreTests/load_repairsLegacyCacheDefaultsWithoutEnablingTurboQuant`,
  and `ServerRuntimeSettingsStoreTests/loadOrMigrate_buildsFromLegacyOnFirstRun`)
- Post-merge vMLX main repin source/TQ test:
  `/tmp/osaurus-source-tq-pin-tests-f5085351-20260723.log`
  (reran `RuntimePolicySourceTests`, including
  `vmlxPinIncludesRuntimeHardening` and
  `chatComposedStaticPromptPrefixReachesLocalMLXCacheHint`, plus the focused
  TurboQuant default/opt-in rows at final pin
  `f50853514ee00365837be3301c91850ca7ed5877`)

Release UI evidence recorded:

- Proof app:
  `/tmp/osaurus-static-prefix-release-derived-91933aef-20260723/Build/Products/Release/osaurus.app`
- Bundle id:
  `com.dinoki.osaurus.staticprefixproof20260723`
- Executable SHA-256:
  `f110b825de75dfae41e288a6215080e5f1e3ba468f1f25ea1203434e8fc6d9ce`
- Isolated root:
  `/private/tmp/osaurus-static-prefix-proof-root-20260723-91933aef-live2`
- Runtime log:
  `/tmp/osaurus-static-prefix-live-91933aef-20260723.log`
- This Release app was built before the vMLX PR #179 squash merge, against
  `91933aef193cab180b821bad1f4b4cc8ad753107`. The final Osaurus source is
  pinned to `f50853514ee00365837be3301c91850ca7ed5877`, and the vMLX tree diff
  between those two revisions is empty. The final pin has source/test proof in
  `/tmp/osaurus-source-tq-pin-tests-f5085351-20260723.log`; a rebuilt final-pin
  Release app row would still be required before claiming binary-identical live
  proof.
- Live Settings > Server > Cache state:
  prefix cache On, SSD/block-disk cache On, paged RAM KV cache Off,
  `liveKVCodec = engine_selected`, `storedKVCodec = auto`, no
  `turboQuantKeyBits`/`turboQuantValueBits` fields.
- Live Settings > Server > Live Activity state after the Gemma cache rows:
  `TurboQuant compressions 0`, `Loaded models 1`, `Cache-enabled models 1`,
  `Disk L2 hits / misses / stores 3 / 6 / 4`.
- Gemma 4 12B MXFP8 visible chat rows, with paged RAM KV Off and SSD On:
  - fresh prompt `Say exactly: cache proof one.` produced
    `cache proof one.`, TTFT `1.17s`, `26.4 tok/s`, and unlocked input.
  - new chat prompt `Say exactly: cache proof two.` produced
    `cache proof two.`, TTFT `0.46s`, `31.9 tok/s`, and unlocked input.
  - after quitting and relaunching the same isolated app/root, prompt
    `Say exactly: cache proof after restart.` produced
    `cache proof after restart.`, TTFT `0.48s`, `32.0 tok/s`, and unlocked
    input.
- Log evidence for cross-chat/restart SSD restore includes:
  - `HIT disk boundary=1725 remaining=4 ... tokens=1729`
  - `HIT disk boundary=1729 remaining=12 ... tokens=1741`
  - `HIT disk boundary=1741 remaining=9 ... tokens=1750`
  - restart row `HIT disk boundary=1725 remaining=4 ... tokens=1729`
    followed by `HIT disk boundary=1729 remaining=13 ... tokens=1742`
    and `HIT disk boundary=1742 remaining=10 ... tokens=1752`.
- Bonsai 27B Ternary JANG CRACK visible chat rows, with the same isolated root,
  paged RAM KV Off, SSD On, and model-picker Thinking Off:
  - new chat prompt `Say exactly: bonsai cache proof one.` produced
    `bonsai cache proof one.`, TTFT `0.62s`, `32.2 tok/s`, and unlocked input.
  - second new chat prompt `Say exactly: bonsai cache proof two.` produced
    `bonsai cache proof two.`, TTFT `0.60s`, `32.3 tok/s`, and unlocked input.
  - log evidence shows hybrid companion-state SSD restores on this Qwen-family
    route, including `HIT disk boundary=3007 remaining=1 ssm=96 ...`,
    `HIT disk boundary=3007 remaining=19 ssm=96 ...`, and
    `HIT disk boundary=3019 remaining=14 ssm=96 ...`.
  - post-Bonsai Live Activity showed `TurboQuant compressions 0`,
    `Hybrid caches 1`, `Disk L2 hits / misses / stores 5 / 31 / 8`,
    and `SSM hits / misses / re-derives 5 / 0 / 0`.
- The isolated SSD cache directory grew from `4.0G` after Gemma to `7.2G`
  after Bonsai under
  `/private/tmp/osaurus-static-prefix-proof-root-20260723-91933aef-live2/cache/kv_v2`.

This live row proves the default path does not enable TurboQuant and that
Gemma's local Release app path can reuse SSD L2 blocks across new chats and app
restart. The Bonsai row proves the same app build can complete simple fresh-chat
Qwen-family generations with hybrid/SSM disk restores and no post-output hang.
It does **not** prove Ornith, Qwen3.5/VL, Laguna, DB-tool dynamic suffix
recovery, or AppleScript behavior.

### Final-pin Release UI closeout

Final app and runtime:

- Release product:
  `/tmp/osaurus-static-prefix-release-derived-f5085351-20260723/Build/Products/Release/osaurus.app`
- bundle id: `com.dinoki.osaurus.staticprefixprooff50820260723`
- isolated root:
  `/private/tmp/osaurus-static-prefix-proof-root-20260723-f5085351-live2`
- final vMLX pin:
  `f50853514ee00365837be3301c91850ca7ed5877`
- vMLX PR #179 is merged at that exact revision. Its current source contains
  the schema-bound Qwen XML `array<string>` recovery, Gemma thought-channel
  reasoning routing, and tokenizer-validated static system-prefix boundary.
- Osaurus PR #2153 carries the hint only through local runtime request
  plumbing, persists the authoritative terminal stop reason, constrains
  database column types in the public schema, and does not expose the cache
  hint through OpenAI JSON or remote requests.

The Release app was operated through the real model picker, chat composer,
tool cards, and Server Settings UI. No screenshot or binary was added to the
repository.

Visible effective settings:

- Prefix Cache: On
- GPU/Paged KV Cache: Off
- SSD Disk Cache: On
- cache codec: Engine Selected
- TurboQuant compressions: `0`

Live tool rows:

| Model and control | Visible result | Persisted/runtime result |
| --- | --- | --- |
| `dealign.ai/Bonsai-27b-Ternary-JANG-CRACK`, Thinking Off | one create, one insert, one query; exact row `(21, bonsai-finalpin-twenty-one)`; TTFT `1.12s`; `41.3 tok/s`; input unlocked | nested `columns` and `rows` arguments persisted; terminal reason `stop`; isolated SQLite row matches |
| `JANGQ-AI/Ornith-1.0-9B-MXFP8`, Thinking Off | one create, one insert, one query; exact row `(31, ornith-finalpin-thirty-one)`; TTFT `0.68s`; `65.3 tok/s`; input unlocked | nested `columns` and `row` arguments persisted; terminal reason `stop`; isolated SQLite row matches |
| `OsaurusAI/gemma-4-12B-it-MXFP8`, Thinking Off | one create, one insert, one query; exact row `(41, gemma-finalpin-forty-one)`; TTFT `1.25s`; `30.0 tok/s`; input unlocked | typed boolean/number strings were coerced against schema; terminal reason `stop`; isolated SQLite row matches |
| same Gemma model, fresh chat, Thinking Off | queried the newly created table without mutation; exact row returned; TTFT `8.29s`; `39.8 tok/s`; input unlocked | Disk L2 hits increased `3 -> 4`; terminal reason `stop` |
| same Gemma model, fresh chat, Thinking On | model-picker control visibly On; separate `Thought for 5.3s` / 294-character reasoning block; one query; exact row; TTFT `8.75s`; `27.1 tok/s`; input unlocked | first assistant step persisted 294 reasoning characters, tool result remained grounded, final terminal reason `stop`; Disk L2 hits increased `4 -> 5` |

Final Server > Settings > Live Activity readout:

- active slots `0`
- queued `0`
- engine accepting requests
- cache-enabled models `1`
- paged evictions `0`
- Disk L2 hits / misses / stores `5 / 110 / 22`
- TurboQuant compressions `0`

The fresh-chat restore is a functional cache pass, not a claimed latency win:
the second Gemma TTFT was slower despite the hit. The evidence proves that the
SSD tier is consulted and restores a validated prefix while the DB/tool suffix
changes, with paged RAM cache disabled. It does not prove every SSD or every
model will have lower wall-clock TTFT.

The scoped emergency PR is therefore **VERIFIED LIVE** for:

1. Qwen-derived Bonsai and Ornith nested database tool arguments;
2. Gemma nested tool arguments and schema-bound scalar coercion;
3. Thinking Off and Gemma Thinking On reasoning/content separation;
4. post-tool final answer, persisted `stop`, and UI unlock;
5. SSD stable-prefix reuse across a changed DB suffix with paged RAM off;
6. TurboQuant remaining off without an explicit user setting.

The broader Russian fitness workflow remains partial at the top of this
document because scheduler, notification, export, and every other parser family
were deliberately excluded from this emergency merge. LFM/DSML and the full
cross-family parser matrix are tracked separately and are not included in PR
#2153.
