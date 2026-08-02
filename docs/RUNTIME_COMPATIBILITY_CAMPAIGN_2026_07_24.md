# Osaurus Runtime Compatibility Campaign — 2026-07-24

Status: **PARTIAL — REQUIRED FAMILY MATRIX REMAINS OPEN**

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

- Osaurus base: `bf3484081d2fbcef096d676eb6fa960e63e7f3e2`
- current vMLX main pin:
  `d0e1f1a9ef3115b505056b679d6b01d6861f8daa`, the squash merge of vMLX
  PR #184. A scoped diff confirms its runtime/parser/test files are
  byte-identical to the live-proven campaign head
  `7c37de3e77daf1ce1e3a212c0aaad3ba4cb471b9`:
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

The Osaurus campaign package graph now pins the merged vMLX main commit
`d0e1f1a9ef3115b505056b679d6b01d6861f8daa` in `Package.swift` and all three
resolved-package files. Its affected runtime/parser/test source is identical
to the exact campaign head exercised in the isolated Release app for LFM
database tools and disk-L2 continuity.

The rebased Osaurus head `2b8466a36f2b87632a376c49d94dabb81ba60bc9`
was rebuilt in Release and exercised through the real UI against that merged
pin. A subsequent source fix at
`12be46cf7f2bf70c05b2afad2165b864aed6690c` removed synchronous model-root
discovery from spawned-worker admission; that exact runtime source was then
rebuilt in Release and passed the normal same-model batch, follow-up, mid-batch
Stop, and post-cancel follow-up rows recorded below. The LFM family row remains
`PARTIAL` because post-error final generations reproducibly ended inside an
unclosed reasoning block; the rest of the family matrix is still unverified
at this pin.

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

### 2026-07-24 local context/KV live control

The exact-`7c37de3e` isolated Release app visibly separated the three local
limits that had previously been conflated:

- the LFM bundle maximum remained 128,000 tokens;
- the chat composer showed a 108,000-token usable budget, matching the visible
  85% compaction policy;
- Server → Cache showed a distinct inherited 65,536-token active KV retention
  cap.

Changing the explicit KV Retention Override to 32,768 displayed an unsaved
“Models reload after Save” warning. Save then reported that one loaded model
was unloaded and would reload on the next request. Before that reload, the
same screen correctly showed the saved resolved cap as 32,768 while retaining
the old active snapshot at 65,536 instead of relabeling stale coordinator
state.

Back in the real chat UI, the model selector visibly changed to cold. The next
prompt reloaded the same LFM bundle, restored 1,560 disk tokens with 4,361
remaining while paged RAM was off, streamed a closed 579 ms Thought, emitted
the exact requested `context-policy-reload-ok` in normal content, removed Stop,
and unlocked input. The UI reported TTFT 7.75 s, 186.5 tok/s, and 94 generated
tokens. Reopening Server → Cache then showed:

- saved resolved KV cap: 32,768;
- active `lfm2.5-8b-a1b-mxfp8-crack`: KV 32,768;
- RAM off; SSD 10.0 GB; codec `Engine Selected`.

The separate Chat settings surface labels its blankable output field
`Default Agent Max Output Tokens` and states that blank inherits the active
bundle's `generation_config` maximum and is neither context capacity nor KV
retention. This closes the local LFM UI wiring control only. Provider metadata,
Gemma rotating-SWA, and Qwen hybrid runtime rows remain required before the
context lane is fully verified.

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

The first rebased CI run exposed a production-path latency defect rather than
an eval timeout problem. `SubagentSession.canonicalAdmissionModelKey` called
installed-model discovery synchronously for every worker. That discovery
walks configured model roots and starved cooperative actor work, including
Stop delivery, while a batch was starting. On the exact pre-fix source, the
five focused Computer Use/subagent eval rows each took about 10.01 seconds and
the interrupt row failed its four-second contract at 10.009 seconds.

The current source derives the admission identity without I/O from the stable
resolved id, or from the final component of a repository/short bundle id.
Unknown display aliases remain separate conservative keys. It does not raise
timeouts or suppress errors. After the change, all 39 focused evals passed in
1.582 seconds: the Computer Use rows took 0.019–0.039 seconds and the interrupt
row took 0.129 seconds. The focused Xcode admission, vMLX-pin, runtime-policy,
and image-bridge contract suites also exited zero.

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

The Subagents settings UI is the owner of that allow-list. A user must be able
to add, save, and remove:

- scanned local models from the models directory selected in Settings; and
- remote models exposed by cloud providers the user has configured and
  authenticated.

Saved choices must survive leaving settings and an app relaunch. Removed,
unavailable, unauthenticated, or otherwise ineligible targets must disappear
from the request-local `spawn_model`/`spawn_batch` schema and must fail
validation before residency or provider work if referenced by stale state.
The live gate therefore includes local add/save/relaunch/remove, provider
add/save/relaunch/remove, and one mixed local-plus-remote batch selected by the
orchestrator from exactly that saved pool.

### 2026-07-24 exact-7c37 same-model batch live round

The exact-`7c37de3e` isolated Release app was configured through the real
Runtime Proof agent UI with Spawn enabled, one allowed local model
`dealign.ai/LFM2.5-8B-A1B-MXFP8-CRACK`, permission `Always Allow`,
text-only worker tools, 2,048 output tokens, two turns, 120 seconds, and a
maximum of three jobs per batch.

The first LFM orchestration attempt confused caller-stable job ids with agent
targets and emitted two nonexistent agents named `Alpha` and `Beta`. The
executor rejected the complete batch before starting either child and the
parent reached a visible Question card. Its post-error generation retained
disk-L2 continuity instead of resetting the cache.

After the user supplied the exact allowed model id through that live Question
UI, LFM emitted one structurally valid two-job `spawn_batch`. The green batch
card finished in 9.1 seconds and preserved caller order. Both child envelopes
reported:

- model `dealign.ai/LFM2.5-8B-A1B-MXFP8-CRACK`;
- `handoff: false`, proving the shared parent/child model was not
  unloaded/reloaded between jobs;
- one iteration and per-child token/s telemetry;
- successful executor status with no child runtime failure.

The full visible lifecycle nevertheless **failed semantic integrity**. The
parent reduced each requested complete child instruction to the bare strings
`alpha-child-ok` and `beta-child-ok`. The actual alpha summary said it did not
understand the phrase; beta returned a generic greeting. The parent then
falsely reported that the children returned the two requested exact strings.
The final parent UI did terminate normally (Stop disappeared, input unlocked,
the LFM selector remained warm, TTFT 2.34 seconds, 82.7 tok/s, 447 generated
tokens), but a green executor envelope is not proof that the orchestrator
faithfully transmitted or reported the work.

This live row proves same-model no-handoff execution and ordered envelopes. It
does not prove faithful task construction or result reporting for LFM as the
orchestrator. A follow-up must provide complete child inputs, compare the
actual expanded envelopes with the final answer, and then repeat with a
different capable orchestrator before classifying any remaining behavior as
model-specific.

The explicit corrective follow-up failed the same semantic gate more strongly.
The user supplied both complete worker instructions verbatim and told the
parent to report the actual returned summaries. LFM first emitted
`spawn_batch` in a single-job shape without the required `jobs` array. The
honest `invalid_args` card completed in 602 ms and the model retried without a
cache reset. Its retry again reduced the two complete inputs to bare
`alpha-child-ok` and `beta-child-ok` strings. The expanded result showed alpha
misread the token as `alice-child-ok` and beta returned
`Hey kid-ok, how can I help you today?`; the parent nevertheless fabricated
both requested exact summaries again. The turn still finalized (Stop gone,
input unlocked, 0.69-second TTFT, 108.5 tok/s, 57 final tokens), both children
remained `handoff: false`, and the short child prompts restored the 10-token
disk block with three tokens remaining. This repeat rules out an ambiguous
first instruction. LFM is not a passing orchestration model for faithful batch
task construction/result reporting at this bundle revision.

### 2026-07-24 Ornith JANG_4M same-model control

The same exact-`7c37de3e` Release app was then changed through the real agent
settings UI to parent model
`JANGQ-AI/Ornith-1.0-9B-JANG_4M`. The saved spawn allow-list visibly contained
both the scanned local LFM and Ornith bundles; the isolated agent JSON persisted
that exact pair together with the 2,048-token, two-turn, 120-second, and
three-job batch limits. No remote section was present because this isolated
proof app has no authenticated cloud provider.

With Thinking visibly off, Ornith initially asked for confirmation rather than
calling the tool. After the user confirmed, it emitted one valid two-job
`spawn_batch` whose expanded arguments preserved both complete worker
instructions and targeted the exact allowed Ornith id. The executor returned
both jobs in input order with `handoff: false`, so the same resident
parent/child model was not unloaded and reloaded. Alpha returned the requested
`alpha-child-ok`; beta interpreted the word `child` as a safety-sensitive
request and refused. Unlike LFM, the parent accurately reported that mismatch
instead of fabricating success.

The green batch card finished in 10.2 seconds. The parent continuation restored
the 5,284-token disk boundary and prefilling continued for 551 tokens with 48
SSM companion states. The parent finalized at 1.58-second TTFT and 47.3 tok/s;
Stop disappeared and input unlocked. Both short child prompts were cold in
this first run (`prompt=23`, disk miss, 16-token store boundary), so this row
does not yet prove child-prefix disk reuse. A neutral repeat must remove the
ambiguous word `child`, compare both expanded result summaries verbatim, and
then repeat with Thinking on to prove that the visible setting propagates into
parent and spawned work.

This control localizes the prior instruction truncation and fabricated summary
behavior to the tested LFM orchestration output rather than the batch executor.
The required neutral repeat then used complete `alpha-result-ok` and
`beta-result-ok` instructions. Both expanded arguments were intact; both
workers returned the exact requested text; the parent reported the real
summaries verbatim; order and `handoff: false` remained correct. The batch took
8.8 seconds and the parent finalized at 0.89-second TTFT and 52.4 tok/s with
Stop gone and input unlocked.

The cache attribution is deliberately narrower than the cumulative envelope
counters. Each envelope showed the process-wide disk-hit count at one, but the
live trace showed both *new* 23-token worker prompts missed all tiers and
stored a 16-token boundary. The parent post-tool continuation, not either new
worker prompt, restored the 6,074-token disk boundary with 507 tokens
remaining. An identical-worker repeat is therefore required to prove that the
16-token worker boundary itself restores from disk.

The identical-worker repeat used the same two full worker inputs with new job
ids. Both worker streams hit disk L2 at boundary 16 with seven tokens
remaining, restored 48 SSM companion states, and skipped rewriting the already
validated disk and SSM entries. Both outputs remained exact, both jobs remained
`handoff: false`, the parent post-tool continuation hit boundary 6,725 with 507
tokens remaining, and the UI finalized at 0.97-second TTFT and 51.8 tok/s with
Stop gone and input unlocked.

This is current-pin live proof that paged RAM off plus disk L2 can restore a
valid partial worker prefix during same-model batched delegation. It is not
proof of arbitrary suffix reuse or unrelated-block concatenation. The lane
then advanced to the visible Thinking control.

With Thinking switched on through the model popover, the parent streamed 58
pre-tool `reasoning_content` deltas into a 275-character Thought card and then
emitted the valid batch envelope. The two spawned Ornith workers emitted 784
and 473 reasoning deltas respectively before returning concise, correct
summaries (`19 × 23 = 437`; `31 × 17 = 527`). After the tool result, the parent
streamed another 113 reasoning deltas into a 282-character Thought card and 77
normal-content deltas into a truthful final. No `<think>` text or tool markup
leaked into content; Stop disappeared and input unlocked at 1.44-second TTFT
and 44.0 tok/s.

The matched Thinking-off run used the same two arithmetic worker prompts. The
parent emitted zero reasoning deltas before the batch, each spawned worker
emitted zero reasoning deltas, and the post-tool parent emitted zero reasoning
deltas. No new Thought card appeared. The two workers still returned the same
correct values and the parent finalized truthfully at 1.53-second TTFT and
38.7 tok/s with Stop gone and input unlocked. The on/off template change
produced distinct cache keys: the 28-token Thinking-on and 30-token
Thinking-off child prompts each reused only their own compatible 23-token
boundary. This is current-pin live proof that the visible choice propagates
through parent generation, same-model batched workers, and the post-tool
continuation without fake inline reasoning or cross-mode KV reuse.

The source path matches the live result: `SubagentScope.current()` captures
`ChatExecutionContext.currentEnableThinking`; `SubagentSession` binds the
prepared child scope for each job; and the text, browser, Computer Use, and
AppleScript runners pass the scoped value into their nested model loop. This
is not a prompt-injected or parser-synthesized Thinking result.

During the Thinking-on row the disk quota trace also showed one real KV entry
eviction: usage moved from 10,776,939,933 bytes to 10,401,899,383 bytes against
the 10,737,418,240-byte maximum. The batch and final answer remained coherent.
That proves this quota path can evict without corrupting the active turn; it
does not yet prove the exact oldest/least-useful selection policy or a later
reissue of the evicted entry.

Cancellation/error isolation, RAM safety, allow-list removal/relaunch
persistence, and mixed local/remote execution remain live gates.

### 2026-07-24 spawn allow-list persistence and rejection

The same isolated agent was edited through Settings → Agents → Runtime Proof →
Abilities → Subagents. Removing LFM immediately persisted a one-item
`spawnableModelNames` array containing only
`JANGQ-AI/Ornith-1.0-9B-JANG_4M`; the default model and the 2,048-token,
two-turn, 120-second, three-job limits did not change. The app was quit and
relaunched from the same Release binary and test root, without rebuilding.
After relaunch the real settings UI still showed only Ornith in Allowed
models.

The user then explicitly requested the removed
`dealign.ai/LFM2.5-8B-A1B-MXFP8-CRACK` target and prohibited substitution.
Ornith emitted one `spawn_model` envelope naming that exact target. The tool
returned a visible red failed card:

`Model 'dealign.ai/LFM2.5-8B-A1B-MXFP8-CRACK' is not spawnable from this
agent. Add it in the agent's Subagents tab. Use exactly one configured id:
'JANGQ-AI/Ornith-1.0-9B-JANG_4M'.`

The rejected request did not evict or replace the resident Ornith model. The
parent continuation restored the 4,993-token disk boundary with 115 tokens
remaining, reported the failure honestly, and finalized at 5.87-second TTFT
and 45.3 tok/s. Stop disappeared and input unlocked. LFM was then added back
through the scanned Local Models picker; the UI again showed both models and
the isolated JSON persisted both exact ids with the unchanged budgets.

This is live proof of UI add/remove, process-restart persistence,
reject-before-handoff, honest error continuation, and cache continuity for
this local allow-list row. It does not substitute for the later RAM refusal,
different-local handoff, or authenticated remote-provider rows.

### 2026-07-24 RAM-safety refusal error-surface round

The same Release app visibly had Local Orchestrator Handoff and RAM-Safety
Preflight on, with Keep Chat Model Loaded off. With Ornith resident, the user
requested exactly one allowed `JANGQ-AI/Laguna-S-2.1-JANG_2L` child. That local
bundle is about 41.3 GiB before the handoff safety factor and headroom, so the
preflight refused it before unloading Ornith. The mechanism made the correct
residency decision, but the generic tool envelope exposed only:

`The operation couldn't be completed.
(OsaurusCore.ChatResidencyHandoff.HandoffError error 0.)`

The parent then guessed that the session was already in a handoff state. This
is a real user-facing failure, not a passing RAM-safety row. Source tracing
showed that `HandoffError` preserved an actionable `description`, while the
generic `ToolEnvelope.fromError` boundary used `localizedDescription`.
Because the typed error did not conform to `LocalizedError`, Swift's NSError
bridge discarded the reason.

`ChatResidencyHandoff.HandoffError` now adopts `LocalizedError` and returns its
existing typed description as `errorDescription`; no threshold, residency
decision, or prompt behavior changed. The focused
`ChatResidencyHandoffRestoreTests`, `ResidencyHandoffTests`, and
`SubagentConfigurationTests` completed successfully, including an assertion
that the exact needed/available memory values survive `localizedDescription`.

The rebuilt isolated Release app then repeated the exact row. With preflight
visibly on, the tool reported that Laguna needed about 56.6 GB while only
about 55.9 GB would be available after freeing Ornith. No handoff occurred.
The parent restored 5,170 disk tokens with 208 remaining and 48 SSM states,
reported the refusal honestly, and finalized at 5.35-second TTFT and
43.3 tok/s with Ornith still warm.

With RAM-Safety Preflight then visibly off, the same exact target crossed the
gate, emitted `unloading_chat_models`, made Ornith cold, and began a real
Laguna load. It did not reach a first child token before the configured
120-second subagent time budget. The child returned an honest timeout, but the
tool UI remained in `restoring_chat_models` past three minutes until the main
Stop control was used. A subsequent direct parent turn recovered and returned
exactly `parent-restored` at 11.29-second TTFT and 44.8 tok/s, with a 5,616-token
disk restore plus 191 remaining and 48 SSM states. The visible model chip still
claimed Ornith was cold immediately after that successful generation.

Therefore the actionable refusal fix is `VERIFIED-LIVE`, while the complete
RAM-off handoff row remains `PARTIAL`: the setting was effective, but the
large child timed out before first token, restoration did not settle on its
own in the UI, and the post-recovery warm/cold indicator was stale or the
residency bookkeeping remained inconsistent. Those failures require source
attribution and a rebuilt live rerun; the successful recovery prompt does not
erase them.

### 2026-07-25 cancellation/restore source and live round

Status: **VERIFIED-LIVE FOR THE REPRODUCED TIMEOUT/RESTORE ROW**

Current source tracing found three distinct defects behind the RAM-off row:

1. `AgentSubagentRunner` could cancel its nested mapped stream at the child
   deadline without directly cancelling the exact `ModelRuntime` generation
   wrapper that owned the child model lease. The lease could therefore outlive
   the visible timeout envelope while orchestrator restoration waited in
   `strictEvict`.
2. `ChatResidencyHandoff.reloadAndVerify` performed a diagnostics-only
   `hasLoadInFlight()` probe and then called `preload()` on a later actor hop.
   That check-then-act result was stale by construction and could race with a
   cold load.
3. the composer chip displayed `ChatWarmupController` prefix state as
   “Model cold/warm.” Tool turns deliberately skip redundant hidden warmup
   because they already persist disk L2 blocks, so a successful resident model
   could still be labeled cold.

The current source makes ownership explicit:

- `GenerationEventMapper` invokes a request-local cancellation closure when
  its consumer is cancelled; `ModelRuntime` binds that closure to the exact
  generation wrapper task so its producer drains and releases its own lease;
- `ModelLoadIntent.handoffRestore` delegates the restore decision atomically to
  `ModelRuntime`; strict restore awaits an already-started different-model
  load instead of cancelling it, while the pre-existing background refusal and
  interactive cancel/drain policies remain distinct;
- the pre-slot and post-slot conflict branches now share one
  `resolveConflictingLoad` implementation so their cancellation policy cannot
  drift;
- the chip now says `Chat prefix warm` or
  `Chat prefix not pre-warmed`, which describes the state it actually reads.

The duplicate/zombie audit removed the obsolete “Model cold” and “Model warm”
localization keys and replaced the misleading load-specific helper name with a
shared non-cancelling load helper. The focused
`GenerationEventMapperTests`, `ChatResidencyHandoffRestoreTests`, and
`ResidencyIntentTests` compile against the exact package graph. The mapper
cancellation and atomic restore rows pass; after the shared resolver replaced
the duplicated loop branches, the updated residency invariants pass for both
pre-slot and post-slot calls.

The exact patched source was rebuilt in Release, ad-hoc signed as
`com.dinoki.osaurus.runtimecompat7c37de3e20260724`, and launched from
`/private/tmp/osaurus-runtimecompat-cancelrestore-proof-20260725-0037.app`
with the same isolated test root and exact vMLX pin `7c37de3e`. The real UI
then reproduced both sides of the handoff:

- a normal different-local Laguna XS child completed, reported
  `handoff: true`, unloaded the parent in 7.24 seconds, restored it in
  1.76 seconds, and returned control to an Ornith follow-up at 0.56-second
  TTFT and 52.1 tok/s;
- a deliberately overlong child exceeded the visibly configured 15-second
  worker limit. The stream trace recorded
  `[Osaurus][Stream] Consumer cancelled - stopping producer task`, the tool
  returned the structured timeout, restoration completed without pressing
  Stop, the parent emitted `AFTER-TIMEOUT`, and a direct follow-up completed at
  0.53-second TTFT and 56.3 tok/s.

In both rows the Stop control disappeared, input unlocked, and the model chip
used the truthful `Chat prefix warm/not pre-warmed` wording rather than
claiming model residency. This is current-source live proof for the reproduced
timeout/restore defect. It is not a family-wide model compatibility claim.

### 2026-07-25 spawn argument and disk-cache attribution round

A persisted pre-patch chat contained one alarming mismatch: the user requested
a new numbered-list child task while the visible `spawn_model` arguments
repeated an earlier exact-response task. The current-pin Release app therefore
ran controlled A/B rows before any parser or cache guard was considered:

1. a fresh chat with disk L2 on used unique value `NEW-ARG-729`; the visible
   arguments and child result were current;
2. with disk L2 turned off and saved through Settings, two same-chat calls used
   `CACHEOFF-A-314` and `CACHEOFF-B-2718`; both arguments were current and the
   disk counters remained exactly zero hits, zero misses, and zero stores;
3. after turning disk L2 back on, a tool/plain/tool history used
   `HIST-A-1618`, `HIST-PLAIN-42`, and `HIST-B-271828`; the second tool
   arguments were current while the parent restored the valid 6,650-token
   disk boundary with 89 tokens remaining.

The app was then relaunched from the same binary and test root with raw native
tool-envelope tracing enabled. The empty-chat warmup restored 6,294 tokens
from disk with one token remaining, proving process-restart disk reuse while
paged RAM remained off. Disk quota enforcement also evicted complete KV and
companion entries back under the configured 10 GiB limit; paged-store traces
continued to report `effectiveKVLayers=0`, `blocks=0`, and `payload=false`.

Two later same-chat traced calls establish the parser boundary:

- in the first call Ornith's raw envelope itself passed only
  `input = RAW-TRACE-909`. The executor received that exact value, and the
  bare Laguna model reasonably returned a generic clarification rather than
  the requested token;
- after an intervening plain turn, Ornith's raw envelope passed the complete
  `Reply exactly RAW-SECOND-2468 and nothing else.` input. The parser and
  executor preserved it exactly, Laguna returned `RAW-SECOND-2468`, and the
  parent finalized truthfully at 0.80-second TTFT and 45.5 tok/s. The child
  card completed in 5.8 seconds, Stop disappeared, and input unlocked.

The original stale-argument observation is therefore not reproducible as
systemic SSD corruption or parser substitution across cache-on, cache-off,
fresh-chat, history-shape, restart, and same-chat traced controls. The one
failed Laguna result is attributed to the parent model's raw envelope
under-specifying a context-isolated child task. Source inspection found the
related contract gap: all three spawn schemas described `input` only as a
“task/query,” even though a bare-model worker receives no parent transcript.
The current source centralizes a complete-standalone-task description across
`spawn_agent`, `spawn_model`, and `spawn_batch`: the input must include every
instruction, value, constraint, and required output format because the worker
cannot see the parent chat or interpret an opaque label. The schema test proves
all three tools consume that single contract.

The exact Release source was then rebuilt and tested through a two-turn live
chat. Turn one stored `SCHEMA-ALPHA-7391` only in the parent transcript. Turn
two asked Ornith to delegate the value to the isolated Laguna XS model. The raw
tool envelope and expanded UI card both showed:

```json
{
  "input": "Reply with exactly the secret value from the previous message and nothing else.",
  "model": "JANGQ-AI/Laguna-XS-2.1-JANG_2L"
}
```

Laguna correctly reported that it had no previous messages. The child still
completed, residency restored, the parent finalized at 0.55-second TTFT and
68.4 tok/s, Stop disappeared, and input unlocked. This is decisive live
evidence that schema description alone was insufficient; it is recorded as a
failed contract row rather than hidden behind the successful parent final.

The next source round adds one shared reject-before-load validator for explicit
parent-transcript references across `spawn_agent`, `spawn_model`, and every
`spawn_batch` job. It does not copy a transcript or invent the missing value.
It returns retryable `invalid_args` with the exact bad field and requires the
parent to retry with standalone data before model load or residency handoff.
Focused `SpawnToolTests` passed the three-surface rejection, retryability,
field attribution, reject-before-spawnability ordering, and valid standalone
input controls.

The exact Release validator build then repeated the two-turn live row with
`SCHEMA-BETA-8426`. Ornith's first raw `spawn_model` envelope again referenced
only “the previous message.” The executor rejected it as retryable
`invalid_args` before a child model load or residency handoff. Ornith visibly
explained the retry, emitted a second raw envelope containing the standalone
literal instruction `Reply with exactly the string: SCHEMA-BETA-8426`, and the
Laguna XS worker returned it. The parent finalized `PARENT-DONE-8426` at
0.76-second TTFT and 50.2 tok/s; a direct follow-up finalized
`FOLLOWUP-OK-8426` at 0.68-second TTFT and 45.2 tok/s. Both turns ended with
Stop gone and input unlocked. No tool XML leaked into visible content.

The same app also ran a database error/continuation row. Ornith created
`runtime_proof_8426`, emitted a malformed optional `todo` checklist, received a
retryable validation error, then inserted and queried `validator=passed`
without repeating the successful create. Disk L2 restored 8,835, 8,956, and
8,987-token boundaries for the post-error database steps instead of resetting
to zero. The UI finalized `DB-PROOF: validator=passed` at 0.89-second TTFT and
38.9 tok/s. Settings → Agent → Memory → Database visibly showed the active
row, then showed the same row dimmed in the Deleted filter after a real
soft-delete. This is live proof for the corrected `NSTableViewDelegate` row
path as well as malformed-tool cache continuity.

The temporary live-test settings were restored through the real UI after this
round. `Max seconds` visibly returned from 15 to 120, RAM-Safety Preflight
returned to on, Local Orchestrator Handoff remained on, Keep Chat Model Loaded
remained off, disk L2 remained on, paged RAM remained off, and no TurboQuant
setting was enabled.

### 2026-07-25 duplicate/zombie callback audit

The exact focused Xcode build exposed callback-shaped source that compiled but
was not a protocol witness:

- six `BrowserSession` WebKit policy, upload, and JavaScript-dialog methods
  lacked the Swift 6 `@MainActor @Sendable` completion-handler shape. The
  compiler reported each as “nearly matches optional requirement,” which means
  WebKit could bypass the intended scheme/download/file-upload/dialog policy;
- `AgentDataGridView.Coordinator` implemented
  `tableView(_:rowViewFor:)`, while the current `NSTableViewDelegate` witness
  is `tableView(_:rowViewForRow:)`. The custom zebra/deleted-row view path was
  therefore dead;
- `TextSubagentKind.makeToolset` bound an unused `specsOverride` value only to
  test whether it was non-nil, producing repeated warning noise around a
  security-sensitive child-tool branch.

The current source corrects the exact protocol signatures and removes the
unused binding without changing policy. The focused WebKit smoke invocation
exited 0 and the target no longer emitted those protocol-witness warnings; its
new fixture exercised alert completion, confirm rejection, prompt text, and
file-chooser rejection through the real `WKWebView` delegate.

The exact Release app then enabled Browser Use through the visible agent
setting. The already-open chat retained its original startup tool inventory,
as expected for a frozen chat context; a new chat visibly showed the larger
startup context and exposed `browser_use`. Its browser worker issued
`browser_navigate` followed by `browser_read_page`, restored a 3,923-token disk
boundary for the second browser step, and returned
`BROWSER-SESSION: Example Domain`. The parent restored its 6,719-token disk
boundary, finalized at 1.02-second TTFT and 19.3 tok/s, and unlocked input.
Settings → Browser then listed the Runtime Proof profile as an active
`example.com` session; opening it displayed the real WebKit window at
`https://example.com/` with the visible `Example Domain` heading.
The database grid live proof is recorded in the preceding section. The
JavaScript-dialog/file-chooser row remains source plus focused real-WebKit
proof because the simple navigation goal did not trigger those prompts.

Two additional observations remain separate from the callback fixes:

- clean app termination reproducibly logged `[HostAPIBridge] Stopped` twice.
  Source tracing found an intentional belt-and-suspenders second
  `HostAPIBridgeServer.stop()` call in `AppDelegate`, after
  `SandboxManager.stopContainer()` already stops the bridge. The lifecycle
  call remains intentionally idempotent; the false duplicate came from
  `HostAPIBridgeServer.stop()` logging “Stopped” even when channel, event-loop
  group, and socket path were already nil. Current source logs only when at
  least one bridge resource existed. The focused cleanup suite passed 4/4,
  including a real Unix-socket bridge start/stop and repeated idempotent
  cleanup. The final exact Release product built with exit 0, was copied to
  `/private/tmp/osaurus-runtimecompat-hostlog-proof-20260725-0232.app`,
  ad-hoc signed as
  `com.dinoki.osaurus.runtimecompat7c37de3e20260724`, and launched through the
  real UI under the same isolated root. Its Sandbox page visibly reported the
  root as not provisioned, so this run exercised the no-resource termination
  path rather than claiming a live container start. Quitting from the UI
  completed the app/server shutdown and emitted zero false
  `[HostAPIBridge] Stopped` lines, where the immediately preceding unpatched
  Release binary emitted two. This closes the duplicate no-op log regression;
  a provisioned-container lifecycle remains a separate Sandbox matrix row;
- the exact Release launch repeated
  `E5RT encountered an STL exception. msg = unordered_map::at: key not found.`
  during an Ornith cache warmup. The visible warmup and following chat turn
  completed, so this is not being called the current hang root without a
  reproducer, but it is retained for runtime source tracing.

### 2026-07-25 current-main exact-pin batch rerun

The rebased Osaurus head
`2b8466a36f2b87632a376c49d94dabb81ba60bc9`, based on
`bf3484081d2fbcef096d676eb6fa960e63e7f3e2` and pinned to merged vMLX
`d0e1f1a9ef3115b505056b679d6b01d6861f8daa`, built successfully in Release.
The product was isolated as
`com.dinoki.osaurus.runtimecompat7c37de3e20260724` at
`/private/tmp/osaurus-runtimecompat-current-main-existingprefs-20260725-0323.app`
and launched with test root
`/private/tmp/osaurus-runtime-campaign-live-root-7c37de3e-20260724-2225`.

Through the real UI, the selected model was
`JANGQ-AI/Ornith-1.0-9B-JANG_4M`, Thinking was visibly off, and the composer
reported `Chat prefix warm — ready for a fast next response.` A two-job
same-model `spawn_batch` completed with a green card in 10.8 seconds. Its
expanded JSON was well formed, preserved both complete worker instructions,
reported two successes in input order and zero failures, and showed
`max_parallel=3`. Both workers returned their exact requested values,
`WORKER-ONE-7319` and `WORKER-TWO-7319`; the parent truthfully finalized
`PARENT-CURRENT-7319`.

Both workers stayed in-place with `handoff=false`. Worker one reported
48.9 tok/s with 12 prompt and 9 completion tokens, plus process counters of
one disk hit, 32 misses, and five stores. Worker two reported 50.4 tok/s with
12 prompt and 9 completion tokens, plus one disk hit, 30 misses, and four
stores. The parent restored a 6,662-token disk boundary with 92 tokens
remaining and 48 SSM states before the batch, then restored 6,747 with 533
remaining and 48 SSM states for its post-tool continuation. The final UI
reported 1.16-second TTFT, 35.9 tok/s, and nine final tokens.

The direct follow-up `FOLLOWUP-CURRENT-7319` restored the 7,273-token disk
boundary with 43 remaining and 48 SSM states, then finalized at 0.79-second
TTFT and 40.0 tok/s with ten tokens. In both turns every card settled, Stop
disappeared, input unlocked, and no reasoning or protocol markup leaked into
content. This is current-main/merged-pin proof for the tested same-model
batch and parent/worker disk paths. The later admission-startup source change
still requires the exact post-fix Release rerun recorded separately below.

### 2026-07-25 exact-12be worker-start and Stop rerun

Exact runtime source
`12be46cf7f2bf70c05b2afad2165b864aed6690c` was built in Release against
merged vMLX `d0e1f1a9ef3115b505056b679d6b01d6861f8daa`. The copied product at
`/private/tmp/osaurus-runtimecompat-final-12be46cf-20260725-0340.app`
was ad-hoc signed, verified on disk, and launched as
`com.dinoki.osaurus.runtimecompat7c37de3e20260724` with isolated root
`/private/tmp/osaurus-runtime-campaign-live-root-7c37de3e-20260724-2225`.
Computer Use confirmed that the running process came from that exact new app
path rather than the preceding proof binary.

The real UI visibly selected `JANGQ-AI/Ornith-1.0-9B-JANG_4M`, showed
Thinking off, and settled the warm status green before the test. One
two-worker `spawn_batch` then preserved both complete standalone inputs in
well-formed expanded JSON. The expanded result reported two successes, zero
failures, `max_parallel=3`, and `handoff=false` for both workers. Worker one
returned exactly `WORKER-ONE-8241` at 57.2 tok/s with 12 prompt and nine
completion tokens; worker two returned exactly `WORKER-TWO-8241` at
39.1 tok/s with the same token counts. Their process cache counters ended at
one disk hit with 28 misses/four stores and one hit with 30 misses/five stores
respectively.

The parent restored the 6,662-token disk boundary with 92 remaining and 48 SSM
states, then restored 6,747 with 535 remaining and 48 SSM states after the
tool result. It truthfully finalized `PARENT-FINAL-8241` at 1.17-second TTFT,
30.8 tok/s, and nine tokens. The direct follow-up restored 7,275 tokens with
43 remaining and 48 SSM states and finalized `FOLLOWUP-FINAL-8241` at
0.67-second TTFT, 54.3 tok/s, and ten tokens. Both turns had no reasoning
deltas with Thinking off, no protocol leakage, settled cards, disappearing
Stop controls, and unlocked input.

The Stop row used two deliberately long same-model worker instructions. The
first worker generated 893 completion tokens at 36 tok/s. The second worker
then restored the compatible 90-token disk boundary with seven remaining and
48 SSM states. Pressing the visible Stop control cancelled that worker; its
producer emitted `Consumer cancelled - stopping producer task` and terminated
in 0.50 seconds. The expanded batch result honestly reported one success and
one failure, with the failed worker message:
`Subagent 'JANGQ-AI/Ornith-1.0-9B-JANG_4M' was cancelled with the parent run.`
The card settled, Stop disappeared, and input unlocked.

A post-cancel turn remained usable. It restored the 7,387-token parent boundary
with 1,339 remaining and 48 SSM states, returned exactly
`AFTER-STOP-8241`, and finalized at 2.40-second TTFT and 29.2 tok/s. This
closes the reproduced worker-admission starvation/Stop row without increasing
timeouts or hiding a failure. It is not a claim that every model family,
remote provider, or paged-RAM configuration has completed the broader matrix.

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
- apply that disk-L2 contract independently to the main orchestrator and every
  spawned local worker. If the exact model, generation/template configuration,
  media salt, and architecture-specific companion state have compatible
  persisted blocks, each must attempt the best valid partial-prefix restore
  during handoff and return. Record parent and worker counters separately;
- malformed JSON/XML/family-specific tool calls must fail and continue without
  poisoning or silently discarding otherwise valid parent or worker cache
  state;
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
| Context | Local bundle model max, 85% chat budget, bundle output max, KV override | PARTIAL | LFM saved/active UI values and required reload are live-proven; Gemma/Qwen runtime controls remain |
| Context | Provider metadata max versus generic fallback | SOURCE-PASS | Remote-model UI row |
| Batch | Two same-local jobs and same parent/child model | VERIFIED-LIVE | Ornith returned exact ordered results with intact inputs, no handoff, truthful terminal final, repeated worker disk restore 16+7 with 48 SSM states, and matched Thinking on/off propagation through parent, workers, and continuation |
| Batch | Local allow-list add/remove, restart persistence, removed-target rejection | VERIFIED-LIVE | UI removal survived app relaunch; removed LFM rejected before handoff; Ornith stayed resident and continued from disk 4,993+115; UI add-back persisted both exact ids |
| Batch | Two local plus one remote, exact user-allowed target selection | SOURCE-PASS | Prove mixed overlap and ordered results in Release UI |
| Batch | Different-local models | VERIFIED-LIVE | Laguna XS child used a real handoff; normal and timeout rows restored Ornith and finalized without manual Stop |
| Batch | Oversized fan-out, malformed job, one-child failure, timeout, Stop | SOURCE-PASS | Release UI terminal-state and sibling-isolation trials |
| Batch | RAM refusal and user safety-setting change | PARTIAL | Refusal-before-unload and the RAM-off timeout/restore path are live-proven; restore the normal 120-second budget and RAM-safety setting, then run a fitting child through the enabled path |
| Generation | Bundle temperature/top-p/top-k/min-p/repetition/stop/max-output merge | SOURCE-PASS | Runtime telemetry for parent and each selected child |
| Cache | Paged RAM off, disk L2 partial prefix across child runs/new chats/restart | VERIFIED-LIVE | Same-model workers restored 16+7 with 48 SSM states; new-chat/history controls restored 6,650+89; app restart restored 6,294+1 with paged payload absent |
| Cache | Paged RAM on, eviction to disk, reissue from L2 | PARTIAL | RAM eviction plus later disk restore proof |
| Cache | Disk quota enforcement and coherent active turn | PARTIAL | One live KV eviction reduced 10,776,939,933 bytes to 10,401,899,383 against a 10,737,418,240-byte limit without corrupting the batch; eviction ordering and later reissue remain |

Locally available non-MXFP4 candidates currently include LFM2.5 MXFP8,
Laguna S/XS JANG_2L/4M/6M, MiniMax M2.7 JANG/JANGTQ, ZAYA JANGTQ, HY-3 MTP,
Step 3.7 JANG, Nemotron Audex variants, Ornith JANG/MXFP8, Qwen AgentWorld,
Qwen 3.6 MXFP8/JANG, Bonsai JANG, and Gemma 4 MXFP8/JANG dense/MoE bundles.
No result is inferred from a sibling quant or architecture.

## 2026-07-26 Gemma/Qwen post-tool completion emergency round

This round used Osaurus base `afa32e5c84191aea90b70fa44afa72ad64feee1f`,
candidate `e9173ee99412944a4c47e98b7c38bff6d4eed392`, and exact vMLX pin
`d0e1f1a9ef3115b505056b679d6b01d6861f8daa`. The Release app was ad-hoc
signed as `com.dinoki.osaurus.gemmaqwencompletionproof20260726` and launched
under isolated test root
`/private/tmp/osaurus-gemma-qwen-completion-proof-root-20260726-025205`.
The app executable SHA-256 was
`4c6397039e507a26545280ffd93e9ddf55e20c2fa297eca3332301124b736225`.

Source attribution found three separate owning contracts rather than one
global parser failure:

- model-family guidance previously routed from the display name, so Ornith
  missed Qwen 3.5 guidance even though its bundle declares
  `model_type=qwen3_5_moe`; the candidate carries bundle `modelType` through
  picker, warmup, compose, and system-prompt construction;
- a total page-extraction failure previously escaped as a thrown tool error;
  the candidate returns a structured, model-visible failure envelope while
  keeping partial extraction successful and classifying permanent 4xx errors
  as non-retryable;
- a successful, parseable Todo created during the current run now owns pending
  work. If it still has unchecked items after visible progress prose, the loop
  continues in a fresh assistant turn. Stale, failed, or malformed Todo calls
  cannot arm continuation. A reasoning-only terminal after real tool work gets
  one exact-history retry in an excluded assistant turn.

The candidate does not inject thinking tags, bias EOS, clamp sampling, match
progress prose heuristically, mask parser errors, or change cache/TurboQuant
policy. A normal visible final remains final unless the current run itself
created a valid Todo that still reports pending work.

Focused workspace tests produced 225 passes, zero failures, and zero skips in
`/private/tmp/osaurus-gemma-qwen-loop-clean-tests-derived-20260726/Logs/Test/Test-OsaurusCoreTests-2026.07.26_02-38-09--0700.xcresult`.
Those tests are source/mock evidence only; the rows below are the Release-app
acceptance evidence.

### Live Release UI rows

- Gemma 4 26B A4B JANG_4M, Thinking on: blocked Hugging Face retrieval
  continued through closed reasoning and search cards to a qualified final at
  TTFT 1.44 s, 69.3 tok/s, and 2,325 tokens. A no-tool attribution follow-up
  finalized at TTFT 5.19 s, 50.7 tok/s, and 1,367 tokens. Stop disappeared and
  input unlocked after both turns.
- Ornith 1.0 35B MXFP8, Thinking off: the full three-organization research
  prompt completed its current-run Todo, settled failed search cards, emitted
  a final, and unlocked at TTFT 0.67 s, 58.0 tok/s, and 983 tokens. Its
  follow-up finalized at TTFT 1.35 s, 65.3 tok/s, and 2,403 tokens with no
  reasoning card or inline `<think>` content.
- Ornith 1.0 35B MXFP8, Thinking on: multiple structured extraction failures
  stayed model-visible; the model eventually closed its Todo and emitted a
  qualified final at TTFT 3.89 s, 43.3 tok/s, and 411 tokens. A no-tool
  one-sentence follow-up closed its reasoning card and finalized at TTFT
  12.92 s, 51.3 tok/s, and 86 tokens. Stop disappeared and input unlocked.
- Bonsai 27B Ternary JANG, Thinking on: a real `search_and_extract` challenge
  produced a failed visible tool card and a qualified final at TTFT 0.80 s,
  44.0 tok/s, and 204 tokens. The no-tool follow-up truthfully stated that the
  page was not extracted, finalized at TTFT 16.97 s, 23.3 tok/s, and 72
  tokens, and unlocked the composer.
- Qwen AgentWorld 35B A3B MXFP8, Thinking on: the normal initially visible
  `web_search` path completed reasoning -> tool -> reasoning -> final at TTFT
  1.09 s, 52.7 tok/s, and 1,339 tokens. Its no-tool follow-up finalized at TTFT
  6.63 s, 53.3 tok/s, and 377 tokens. Both turns ended with Stop absent and
  input unlocked.

Cache traces are observations, not a cache-algorithm acceptance claim for this
PR. The live rows used disk restores at stable boundaries with hybrid companion
state, but some new-chat/follow-up prompts missed all tiers when their stable
boundary changed. No cache implementation or setting was changed here.

### Honest remaining boundary

A synthetic Qwen AgentWorld prompt that demanded `search_and_extract` before
that lazy capability was loaded did not reach a tool call. With Thinking on it
emitted 8,451 reasoning deltas over 212.94 seconds, repeatedly reconsidering
tool discovery, until manual Stop. The reasoning remained in the reasoning UI
and cancellation unlocked the composer, so this was not an inline-channel or
terminal-cleanup failure. It remains a `PARTIAL` model/tool-discovery row and
is not claimed fixed by this post-tool completion change. A producer or tool
await that literally never returns also remains outside this candidate because
Chat has no new global watchdog in this diff.

The scoped post-tool completion regression is `VERIFIED-LIVE` for the rows
above. Arbitrary lazy-capability discovery and the broader cache/family matrix
remain `PARTIAL` and must not be represented as closed by this emergency PR.

### 2026-07-26 current-main untracked multi-tool regression

Status: `OPEN` before the next fixing round.

The exact merged source `cc08980260584790484ad948aa7e064e92999a20` was
rebuilt in Release configuration as
`com.dinoki.osaurus.gemmaqwencompletionproof20260726` with exact vMLX pin
`d0e1f1a9ef3115b505056b679d6b01d6861f8daa`. In the isolated live app,
`dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK` received the three-organization
Hugging Face recommendation prompt with Thinking visibly on.

The visible lifecycle contained closed reasoning and three completed
`web_search` cards (two successful, one structured failure). The fourth model
step then emitted 2,275 reasoning characters and 258 normal content
characters promising to inspect the repositories, followed by authoritative
terminal reason `stop`. The UI treated that promise as final, removed Stop,
and unlocked input at displayed TTFT 1.63 s, 42.7 tok/s, and 716 tokens. The
persisted turn confirms `content_len=258`, `thinking_len=2275`, and
`terminal_stop_reason=stop`; it was neither an empty response, an output-token
limit, an unclosed reasoning envelope, a malformed tool call, nor a dropped
content delta.

The current owning-layer contradiction is structural: the loop can continue
ordinary progress prose only after a successful current-run Todo, while the
agent-loop guidance tells a model to skip Todo for a “direct question.” This
prompt is phrased as a direct question but requires multiple source-retrieval
steps, so Gemma performed multi-tool work without arming the only structured
completion contract. No phrase matcher, forced reasoning marker, sampler/EOS
override, parser masking, or cache change is acceptable as a fix. The next
round must make the multi-step tracking contract unambiguous, then re-run this
exact prompt plus Ornith/Qwen controls in a fresh isolated Release app.

### 2026-07-26 candidate structural contract

Status: **SOURCE-PASS / FINAL RELEASE-UI PROOF OPEN**.

A prompt-only correction was not sufficient. One fresh Release-app attempt
completed, but an identical new-chat repeat reproduced the current-main
failure after multiple ordinary tool actions. The candidate therefore makes
the existing Todo state machine an explicit precondition before the third
ordinary action, but only for local bundles whose authoritative
`config.json:model_type` contains `gemma` or `qwen`. This includes renamed
Qwen-backbone bundles such as Ornith and Bonsai without matching their display
names. It excludes remote models, GLM, Laguna, LFM, DeepSeek, missing metadata,
and every headless/API policy unless that surface explicitly opts in later.

The rejected third action does not execute. It returns one structured,
retryable `task_tracking_required` envelope telling the model to create a
current-run Todo and retry the exact call, or to answer completely if no more
tools are needed. Control tools do not consume the action count; stale session
Todos and malformed Todo arguments cannot unlock it. The serial and batch
paths share this contract, and ordinary tool rejection semantics remain
unchanged. Focused tests cover the third-action boundary, successful retry,
same-batch Todo, stale-Todo rejection, headless preservation, and the exact
positive/negative bundle-type scope.

The first candidate live round found a second independent instruction defect:
the successful checked-Todo path told models to emit a normal final answer and
also call `complete` “in the same message.” Gemma rendered literal
`complete(summary: ...)` protocol text in visible content. The candidate now
reserves structured `complete` for honestly blocked tracked work. A successful
checked Todo ends with a normal answer and no `complete` call; both prompt and
tool schema explicitly prohibit printing tool-call syntax. This is an owning
schema correction, not a content scrubber or parser repair.

The final isolated Release binary must still prove, for both Gemma and Ornith:
closed reasoning, the third-action precondition, Todo creation and retry,
finished tool cards, a coherent protocol-free final, Stop disappearance,
input unlock, a completing follow-up, and compatible disk-L2 partial restore.
No merge or `VERIFIED-LIVE` classification is allowed before those rows.

### 2026-07-26 external-bundle and schema/cache live finding

Status: **SOURCE FIX / REBUILT RELEASE-UI PROOF OPEN**.

The first Release candidate was launched as the isolated app
`com.dinoki.osaurus.gemmaqwenschemafreezeproof20260726` against vMLX
`d0e1f1a9ef3115b505056b679d6b01d6861f8daa`. Through Settings, the custom
model folder was set to `/Users/eric/models`; Server → Cache visibly showed
prefix and disk L2 on, paged RAM off, and the engine-selected codec. The exact
external bundle
`/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK` was selected
with Thinking on.

The long Hugging Face research turn completed several closed reasoning/tool
cycles, recovered from structured search and capability-load failures, emitted
a qualified final, removed Stop, and unlocked input. The UI reported TTFT
2.07 s, 87.3 tok/s, and 964 generated tokens. However, the third-action Todo
precondition did not fire. Source trace found the exact metadata loss:
`ExternalModelLocator.models()` reconstructed persisted external entries with
their id/path/provenance but omitted the authoritative bundle `model_type`.
The bundle itself declares `gemma4`; the picker therefore handed the chat
policy `nil` and selected threshold zero. The candidate now rehydrates
`model_type` from the registered bundle's `config.json` and uses the catalog's
local-model resolution rather than requiring a momentarily populated picker
row. A focused test invalidates the in-memory registry before asserting the
rehydrated `gemma4` value, exercising the app-relaunch path.

This live round also distinguishes a valid cache invalidation from the
reported persistent cold-prefill defect. Explicitly loading
`search_and_extract` changed the callable schema from eight to nine tools;
the token LCP with the previous request fell to 996 and the immediately
following turn correctly missed disk because the configured prompt inventory
had changed. After that nine-tool schema stabilized, the next visible
follow-up restored 7,267 of 7,295 prompt tokens from disk with paged RAM still
off, prefilling only 28. It closed its reasoning, answered “Three plus three
is six,” removed Stop, and unlocked input at UI TTFT 0.49 s (41.3 tok/s,
81 generated tokens). This is current-source evidence for same-session Gemma
rotating-cache disk reuse; new chat, app restart, the patched Todo contract,
and the Ornith hybrid row remain required before release classification.

### 2026-07-26 Todo continuation history and disk-L2 A/B

Status: **VERIFIED-LIVE FOR THE REPRODUCED ORNITH/GEMMA TODO CONTINUATION ROW**.

The stale Release candidate
`com.dinoki.osaurus.gemmaqwentodoproof20260726` reproduced a narrower
continuation defect with the exact Ornith 1.0 35B MXFP8 bundle. With prefix
and disk L2 on and paged RAM off, session
`DCB5997B-8BCE-4135-961B-167F57BF0EA2` rejected an unchanged duplicate Todo,
visibly reached Todo 1/1, and then emitted unrelated answer text from the
preceding user turn. Its persisted sequence was user -> assistant Todo call ->
tool result -> assistant duplicate Todo call -> structured
`todo_no_progress` result -> assistant premature final -> assistant checked
Todo call -> tool result -> stale final. The live trace contained Ornith disk
restores with all 60 hybrid SSM companion states.

The same stale binary was changed through Settings to disk L2 off while
leaving prefix on and paged RAM off. A fresh new-chat repetition in session
`1E7B9BDD-47A8-45BC-8748-5092D96D73E3` reached Todo 1/1 and the correct final,
`Task complete — the duplicate todo call was rejected as expected.`, at TTFT
3.33 s, 62.7 tok/s, and 124 generated tokens. Stop disappeared and the
composer unlocked. Cache tracing reported misses at every tier and no disk
stores. This A/B is diagnostic only: turning disk off is not a fix and the
successful row still persisted an invalid adjacent-assistant history before
the checked Todo call.

Source trace found the owning contradiction in the chat surface. When
`AgentToolLoop` rejected a premature final because a current-run Todo remained
pending, `prepareTrackedTaskContinuation` appended a fresh assistant turn but
left the abandoned final model-visible. After its transient notice was
removed, Qwen/Ornith received assistant(final) -> assistant(tool call) -> tool
history. The bundle template's `last_query_index` handling makes that history
structurally different from the intended tool-result continuation; restoring
hybrid state from the earlier valid boundary exposed the stale continuation.

The candidate keeps the premature response visible in chat but marks that
turn `modelContextExcluded` before appending the fresh assistant buffer. The
preceding tool result remains the model-visible continuation anchor. This does
not inject reasoning tags, alter EOS, change sampling, disable cache, rewrite
model content, or apply a family-wide output guard. Tests now require the
model-visible continuation roles to end user -> assistant(tool call) -> tool.

The checkout was fast-forwarded without overlap to Osaurus main
`c820eb1d7c6c0ff183198c236b4efb5657580196` with exact vMLX pin
`d0e1f1a9ef3115b505056b679d6b01d6861f8daa`. The focused current-head result
`/private/tmp/osaurus-gemma-qwen-schema-freeze-release-derived-20260726/Logs/Test/Test-OsaurusCoreTests-2026.07.26_17-41-48--0700.xcresult`
contains 42 passes, zero failures, and zero skips. A separate serial stress
result at
`/private/tmp/osaurus-gemma-qwen-schema-freeze-release-derived-20260726/Logs/Test/Test-OsaurusCoreTests-2026.07.26_17-37-19--0700.xcresult`
contains 95 successful runs of the 19 stop/session tests. The stress round
also exposed and corrected a test-only defect: raw `JSONEncoder` bytes were
compared without sorted keys, so semantically identical message arrays could
fail on object-key order. Production encoding and requests were not changed.

The exact current-head source was then rebuilt in Release, copied to
`/private/tmp/osaurus-gemma-qwen-todo-history-fix-proof-20260726-1749.app`,
ad-hoc signed under isolated bundle id
`com.dinoki.osaurus.gemmaqwentodohistoryfixproof20260726`, and launched with a
fresh isolated test root. Its executable SHA-256 is
`200ace6064e0d3d930f228aec174ef6f43b6db258c77ea28bf20b6f4e070d1d7`.
Through the real Settings UI, the external model root was set to
`/Users/eric/models` and rescanned, prefix and disk L2 were enabled, paged RAM
was disabled, the on-the-fly cache codec was explicitly set to `None`, and
SSM re-derivation remained enabled. The UI confirmed that the saved runtime
policy unloaded the resident model for reload; no TurboQuant cache mode was
enabled.

Two fresh-chat Ornith 1.0 35B MXFP8 trials then ran the exact duplicate-Todo
contract with Thinking visibly on. Both rejected the unchanged call as
`todo_no_progress`, reached Todo 1/1, emitted a coherent short final, removed
Stop, unlocked the composer, and completed a subsequent arithmetic turn.
Trial one finalized at 0.62-second TTFT and 65.3 tok/s; its follow-up finalized
at 0.80-second TTFT and 62.1 tok/s. Trial two finalized at 0.41-second TTFT and
64.7 tok/s; its follow-up finalized at 0.83-second TTFT and 48.7 tok/s. The
Thinking UI opened and closed separately from content, and no protocol debris
or inline `<think>` text appeared.

The corresponding persisted sessions are
`35ABAFFE-AA0D-4758-9327-ADCA812052EB` and
`F477E925-B702-4E61-A534-FCAA04FB483E`. In the first, both premature assistant
finals at sequence 5 and 6 have `model_context_excluded=1`; in the second, the
single premature final at sequence 5 has `model_context_excluded=1`. The next
model-visible turn in each case is the checked Todo call, followed by its tool
result and the terminal final. The UI intentionally preserves the abandoned
text for auditability, but it cannot contaminate a later model request.

Disk L2 remained active with paged RAM disabled throughout both trials. The
second new-chat request restored 3,226 of 3,231 prompt tokens from disk, and
the subsequent tool continuations restored the best compatible 3,336, 3,516,
3,501, and 3,629-token boundaries with only five tokens remaining at each
matching boundary. Every restore included all 60 Ornith SSM companion states.
Paged-store telemetry reported zero effective KV layers, zero blocks, and no
RAM payload, so these were disk-backed hybrid restores rather than hidden
paged-RAM hits.

The same binary and cache policy then loaded
`/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK`, with Thinking
visibly enabled, in a fresh chat. Gemma called Todo pending, received the
structured duplicate rejection, called Todo complete, reached Todo 1/1, and
finalized `The duplicate call was rejected.` at 0.42-second TTFT and
80.2 tok/s. A direct follow-up finalized `Two plus two is four.` at
0.59-second TTFT and 77.1 tok/s. Stop disappeared and input unlocked after
both turns. Session `6F2A5AC5-6403-4A90-A164-9697D76270C9` contains the exact
user -> assistant(tool) -> tool sequence for all three calls with no abandoned
final. Gemma's disk restores carried the required rotating-SWA companion state:
the new-chat path restored 1,107 prompt tokens with four remaining, followed by
valid partial boundaries of 1,111, 1,201, 1,323, and 1,605 tokens while paged
RAM remained empty.

This verifies the reproduced malformed-history root cause and its current-head
fix for the tested Ornith hybrid-Qwen and Gemma rotating-SWA rows. It does not
claim family-wide compatibility for every Qwen/Gemma bundle, parser,
quantization, modality, cache codec, or task; those broader matrix rows remain
separately open below.

## Follow-on live issue ledger after the emergency merge

These are deliberately not bundled into the Gemma/Qwen completion patch. Each
remains open until its owning source and fresh Release-app UI lifecycle are
proved.

1. **PDF content-based batch rename — OPEN.** Reproduce Ornith 9B on a copied
   folder: inspect first pages, handle text PDFs and OCR fallback, derive exact
   author/title names, perform reversible rename/move into the configured
   folder only, continue after a missing `pdftotext`/OCR command, and report
   every per-file result. Prove repeated files, name collisions, Unicode,
   encrypted/image-only PDFs, cancellation, and a follow-up turn. Evaluate
   same-model bounded subagent batching only after the single-file contract is
   correct.
2. **Todo terminal UI — OPEN.** A pinned checklist must not remain “in
   progress” after final answer, Stop, cancellation, failure, session change,
   or app restart. Stale Todos must not arm later turns. Prove normal success,
   blocked closure, malformed Todo, cancellation, and chat deletion.
3. **Computer Use / AppleScript exact-scope handoff — OPEN.** Re-run the 16B
   rows for open-only, new blank document, replace existing text once, no
   unsolicited save, no placeholder text, wrong-dialog recovery, malformed
   `verb`, repeated-action detection, success recognition, and terminal UI.
   The orchestrator must pass only the user's literal requested content and
   current task; the worker must not inherit stale job history.
4. **Batched delegation and residency — PARTIAL.** Existing same-model
   `handoff:false` evidence remains current, but PDF fan-out still needs
   bounded same-local batching, failure isolation, cancellation, RAM
   accounting once per resident model, and cache reuse per child. Different
   local parent/child work must unload and restore once per grouped handoff;
   mixed local/remote jobs must honor the saved allow-list and ordered result
   envelope. Generation defaults, Thinking, max-output limits, context budget,
   and RAM-safety settings must propagate to every child.
5. **Context and cache truthfulness — PARTIAL.** Continue separating model
   maximum context, 85% conversation budget, bundle maximum output, active KV
   retention, paged-RAM capacity, and disk-L2 quota. Prove paged RAM off plus
   disk partial-prefix restore across new chats/reloads/restarts, then paged
   RAM eviction followed by disk restore. UI warm/prefill counters and TTFT/
   token-rate telemetry must agree with exact restored and remaining token
   counts; no arbitrary suffix or unrelated block concatenation is allowed.
6. **Large local-model root picker refresh — REPRODUCED 2026-08-02.** The
   isolated Release app's local server discovered and loaded
   `/Users/eric/models/DeepSeek-V4-Flash-0731-JANG` as
   `deepseek-v4-flash-0731-jang`, while the live Chat picker remained on its
   launch-time partial snapshot and exposed only the unrelated remote
   `deepseek-v4-flash` alias. Sending through that alias failed visibly with
   `HTTP 503: Managed TP2 model switch is already in progress`; sending the
   exact local ID to the same app server returned HTTP 200 and populated the
   DSV4 cache topology. Source trace: `discoverLocalModels()` bounds a cold
   scan wait, while `startLocalModelsScanLocked()` previously filled
   `cachedLocalModels` after that timeout without posting
   `.localModelsChanged`, so `ModelPickerItemCache` never rebuilt. The owning
   fix is to publish local-scan completion after the finished snapshot is
   installed, followed by a fresh Release UI rerun selecting the exact local
   row. Until that rerun, this row is PARTIAL and not release proof.
