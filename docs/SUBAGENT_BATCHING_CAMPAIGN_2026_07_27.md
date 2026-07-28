# Subagent Batching Compatibility Campaign — 2026-07-27

## Status

`PARTIAL` — automated gates pass on the current dirty campaign, but the
rebased Release-app UI matrix has not run yet.

- Osaurus campaign HEAD: `887104298d04c32c36817645c231c58841067681`
  plus the dirty campaign diff recorded below.
- Current upstream target: `e294c616d3e0688d4fd5a26d0cd1c9f2e62252ab`
  (channel-presence and appcast updates; rebase and re-verification required)
- vMLX Swift pin: `d7483a88668bb3ec70e0ea7f8423a5f684084c28`
- Worktree: `/private/tmp/osaurus-subagent-batching-complete-20260727`
- Branch: `codex/subagent-batching-complete-20260727`

This document separates current-source trace evidence, historical proof tied to
older commits, current automated evidence, and current live Release-app proof.
Nothing moves to `PASS` merely because a type, setting, or test seam exists.

## Scope and non-goals

The existing `SpawnBatchTool` executor and vMLX `BatchEngine` remain the owners
of subagent fan-out and local decoding. This campaign must not add a second
scheduler, a second model cache, forced model behavior, prompt nudges, hidden
sampler overrides, or fake concurrency.

The intended product contract is:

1. A user chooses which agents, local models, and connected remote models an
   orchestrator may use.
2. The UI configures an allowed pool, not fixed "subagent 1/subagent 2" slots.
   The orchestrator sees the exact allowed target names in the tool schema and
   chooses the appropriate agent/local/cloud target independently for each job.
3. The orchestrator can submit multiple independent jobs in one `spawn_batch`
   call (for example prompt A and prompt B), gather the ordered child results,
   reason over them, and continue the parent agent loop.
4. Jobs for one local model share one model residency/handoff and the one
   resident vMLX `BatchEngine`.
5. Actual simultaneous local decoding never exceeds:
   - the launching agent's configured fan-out;
   - Server → Concurrent Sessions when Continuous Batching is enabled;
   - a defensible per-child memory-safety capacity.
6. Remote work may overlap admitted local work. A mixed request such as two
   local targets plus one remote target is supported. Same-model local jobs
   can truly batch on one engine. Different local model keys run in honest
   serialized generation waves while remote work continues: flexible residency
   can keep multiple graphs loaded, but that does not make concurrent Metal
   generation across distinct model engines safe.
7. Results retain caller order and report each child independently.
8. Stop cancels preparation, admission, prefill, decode, and remaining work;
   parent residency is restored and the chat becomes usable.
9. Child requests use the selected model bundle's own generation/template
   defaults unless the user explicitly overrides them.
10. Existing prefix/paged/L2 cache behavior is reused; spawned work does not get
   an alternate cache implementation.
11. The user-managed pool is the authorization boundary. It may contain
    discovered local models, currently connected/authenticated cloud models,
    and configured agents. The orchestrator—not a fixed UI slot—selects one
    exact target per job from that pool, so a single call can choose two local
    workers and one remote worker when those targets are allowed.
12. `Ask` means one real user decision before any model load or residency
    change. A batch asks once for the whole disclosed job set; it must not open
    one prompt per child. `Always Allow` persists to the launching default or
    custom agent's spawn policy, while `Deny` and Stop start no child.
13. Spawned workers receive only each job's standalone input plus the selected
    agent persona/tool grant. They do not inherit the parent's stale transcript.
    Results are gathered back into the parent in caller order so the
    orchestrator can reason over them and continue.
14. A read-only batch workflow may delegate independent PDF first-page
    extraction to workers, but file mutation (rename/move) remains a separately
    authorized parent action unless the user explicitly grants a tested child
    mutation surface. Batch support must never silently broaden tool authority.

The mandatory user flow is therefore:

```text
orchestrator
  -> spawn_batch([
       {id: "A", target_type: "model", target: "<allowed local>", input: "prompt A"},
       {id: "B", target_type: "agent", target: "<allowed agent>", input: "prompt B"},
       {id: "C", target_type: "model", target: "<allowed remote>", input: "prompt C"}
     ])
  -> ordered A/B/C result envelopes
  -> orchestrator reasons over the gathered results and finishes the parent turn
```

The settings surface does **not** preassign worker 1, worker 2, or worker 3.
It lets the user add/remove the exact agents, discovered local models, and
connected cloud-provider models that are legal choices, annotate when each
should be used, and set the maximum batch size. The tool schema and dynamic
Subagents prompt expose exactly that bounded pool; the orchestrator chooses
the target for each independent job. Server → Continuous Batching and
Concurrent Sessions determine the engine-side same-model local ceiling, while
the per-agent maximum and live RAM-Safety plan may clamp it further. Those
controls must share one runtime contract rather than becoming duplicate
batching knobs.

The persisted but explicitly `Planned` prefill/completion batch-size controls
remain out of scope until their runtime consumers exist.

## Current-source audit

### Source-wired behavior

- `SpawnBatchTool` parses and validates all jobs before the first residency
  change, preserves ordered results, bounds fan-out, groups one canonical local
  model per wave, overlaps remote jobs, and shares one admission/handoff for a
  same-local group.
- `AgentSubagentRunner` creates isolated child loops and uses implicit
  bundle-driven generation parameters.
- `MLXBatchAdapter` owns one shared `BatchEngine` per resident model and
  hot-resizes its maximum slots from Server settings.
- Custom agents already persist allowed agents/models, permission, worker-tool
  access, budgets, and `maxParallelSpawns`.
- Remote and local model candidates already share the model picker source.
- The mandatory picker contract is an allow-list, not numbered worker slots:
  the system prompt/tool schema must disclose exact authorized targets and the
  orchestrator selects `target_type`, `target`, and standalone `input` per job.

### Proven gaps at campaign start

| ID | Finding | Start state | Owning layer |
|---|---|---:|---|
| BATCH-01 | Built-in/default chat has persisted spawn pools and budgets but no reachable UI for them. | BROKEN | Agent settings UI |
| BATCH-02 | Disabling Spawn clears a custom agent's saved targets and notes. | BROKEN | Agent settings persistence |
| BATCH-03 | `maxParallelSpawns` is presented as concurrency but does not read actual server BatchEngine capacity. | BROKEN | Spawn batch policy/schema/UI |
| BATCH-04 | Same-local fan-out launches all child tasks even when Continuous Batching is off and the engine has one slot. | PARTIAL | Spawn batch policy |
| BATCH-05 | RAM preflight charges one model estimate, not per-active-child KV/activation headroom. | BROKEN | Spawn batch RAM policy |
| BATCH-06 | Batch Stop becomes reachable only after every job finishes target preparation. | BROKEN | Spawn batch lifecycle |
| BATCH-07 | Task groups do not explicitly cancel remaining children when the parent interrupt fires. | PARTIAL | Spawn batch lifecycle |
| BATCH-08 | Dynamic request-local spawn enums/limits are narrowed before frozen session specs overwrite them. Settings changes can therefore leave stale visible targets/limits. | BROKEN | System prompt/tool schema |
| BATCH-09 | Saved remote target validation can observe a cold/stale provider model catalog. | UNVERIFIED | Target resolution/model picker |
| BATCH-10 | Result/UI telemetry does not state effective local slots or why local fan-out was limited. | BROKEN | Tool result/feed/diagnostics |
| BATCH-11 | Existing unit tests do not integrate spawn policy, server capacity, RAM capacity, settings persistence, and cancellation. | MISSING | Tests/evals |
| BATCH-12 | Existing live proof is tied to older source commits, not current `92353afe`. | MISSING | Release UI proof |
| BATCH-13 | Different local model keys must serialize generation even when flexible residency keeps both graphs loaded; that safety boundary and mixed two-local-plus-one-remote scheduling need explicit proof. | MISSING | Residency/admission policy |
| BATCH-14 | Canonical admission identity collapses different repositories that use the same bundle basename, so distinct local bundles can enter one same-model wave. | BROKEN | Model resolution/admission identity |
| BATCH-15 | Capacity and residency are resolved before a potentially long admission wait, then used without a post-wait live recheck. | BROKEN | Admission/residency lifecycle |
| BATCH-16 | Structured task-group cancellation still waits forever for a child provider/tool that ignores ordinary Swift task cancellation. | BROKEN | Tool/provider cancellation |
| BATCH-17 | Stop is visible during preparation, but a blocked target-resolution await is not itself interruptible. | BROKEN | Target resolution lifecycle |
| BATCH-18 | Aggregate result telemetry does not distinguish all-failed from partial/success, and child cache fields are process-wide absolute counters rather than attributable deltas. | BROKEN | Result/cache telemetry |
| BATCH-19 | Spawn permission `Ask` is shown in the UI but silently behaves as Allow; batch permission is not one disclosed pre-load decision and Always does not persist to the launching agent's spawn policy. | BROKEN | Permission/lifecycle |
| BATCH-20 | Remote spawn targets persist only a provider-display-name-prefixed model id. Providers with the same name/model collide, and a provider rename changes identity. | BROKEN | Provider identity/routing |
| BATCH-21 | Spawned read-only workers advertise `file_read`, but rich-document ownership rejects PDF reads, so the documented parallel PDF-metadata workflow cannot run. | BROKEN | Child tool ownership/document parsing |
| BATCH-22 | The legacy top-level Spawn model override can replace an allowed target agent's own model, but the shared pool UI does not clearly explain that precedence. | PARTIAL | Spawn model precedence/UI |
| BATCH-23 | Spawn copy implied configured workers retained all enabled/direct-chat tools, but production correctly exposes only the enabled subset with audited cooperative abort-and-drain ownership. Plugin, MCP, sandbox-process, database, and knowledge tools do not yet meet that spawned-operation contract. | PARTIAL | Child tool ownership/product copy |
| BATCH-24 | A second concurrent `TaskCoalescer.remove` can return while the first remover still owns a BatchEngine/Metal drain, allowing reentrant unload to continue before teardown completes. | BROKEN | Runtime teardown ownership |
| BATCH-25 | Laguna XS 2.1 requires bundle-driven `top_k=20`. Current local 2L/4M/6M bundles contain 20, but older/mis-shipped bundles and effective chat/spawn request plumbing still need a truthful migration and live proof. | PARTIAL | Bundle metadata/defaults |

## Historical evidence — not current-head proof

PR #2165 (`afa32e5c84191aea90b70fa44afa72ad64feee1f`) introduced the
current executor. The 2026-07-24 runtime campaign records Release-app rows for:

- same-local Ornith batching and ordered results;
- local allow-list persistence and pre-residency rejection;
- RAM refusal and different-local handoff/restore;
- timeout/Stop recovery and a usable follow-up;
- Thinking on/off and disk-L2 partial restoration.

Those rows remain useful regression cases, but subsequent AgentToolLoop and
subagent changes mean none are counted as current-head proof here.

## Implementation design

### One pure effective-capacity policy

Do not add a scheduler. Add a pure policy consumed by `SpawnBatchTool`:

- `agentSlots`: normalized `maxParallelSpawns`.
- `engineSlots`: `InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(...)`.
  Continuous Batching off resolves to one.
- `ramSlots`: same-local capacity derived from one target-model footprint plus
  one `ModelRuntime.estimatedKVHeadroomBytes(...)` charge per active child.
- `effectiveLocalSlots = min(localJobCount, agentSlots, engineSlots, ramSlots)`
  when RAM preflight is enabled.
- With RAM preflight disabled, still compute/report the estimate but do not
  clamp on `ramSlots`.
- A RAM-enabled result of zero rejects before handoff.
- A positive capacity below the job count creates local subwaves.
- Remote concurrency remains bounded by agent policy but is not reduced by a
  local engine/RAM slot of one.

For different local model keys, reuse the existing flexible multi-model
residency policy only to avoid unnecessary unload/reload when both graphs fit.
Generation remains serialized across model keys: each model owns a distinct
BatchEngine, and existing `SubagentAdmission` deliberately prevents two local
Metal producers from racing. Strict/single-model policy performs the normal
handoff; flexible/coexistence mode may retain both models but still drains and
admits one local producer at a time. No new residency cache, independent model
loader, or unsafe cross-engine concurrency is permitted.

The estimator must reuse existing model-runtime helpers and resolved memory
policy. It must not invent a new bytes-per-token formula. Target weights/load
footprint are charged once per same-model group; KV/activation headroom is
charged per simultaneously active child.

### Schema stability

Session-frozen tool payloads remain the baseline for cache stability. Current
request-local target enums and job limits must be applied after that baseline
freeze so:

- unchanged settings remain byte-identical;
- a real allow-list/budget edit changes the visible schema and prompt hash;
- the existing settings-change warmup invalidation warms the new bytes;
- execution independently revalidates the current allow-list.

### Cancellation

Create/register the parent feed and interrupt token before target preparation.
Check cancellation between prepared jobs. Propagate cancellation into active
task groups, produce honest per-job cancelled envelopes, restore the parent
model, settle the tool card, remove Stop, and unlock input.

### UI and persistence

Reuse the existing agent Subagents controls for the built-in/default chat
instead of creating an unrelated batching settings panel. The UI must show:

- allowed agents;
- allowed discovered local models;
- allowed connected provider models;
- permission and worker-tool access;
- child budgets and requested fan-out;
- effective local capacity from current server/RAM policy;
- the fact that different local models serialize and remote work may overlap.

Turning Spawn off must disable execution without erasing configured targets or
notes.

## Automated acceptance matrix

Every row needs an assertion on behavior, not only source text.

| Area | Required automated rows |
|---|---|
| Parsing | nested strings/escaping, arrays, duplicate IDs, bad target type, blank input, oversized batch |
| Policy | server batching off; server slots below/equal/above agent cap; RAM slots zero/one/many; RAM preflight disabled |
| Scheduling | same local chunking; different local serialization; remote overlap; stable result order |
| Lifecycle | Stop during preparation, admission, prefill/decode seam, and between waves; timeout; one-child failure |
| Schema | frozen baseline plus changed agent/model pools and changed batch limit |
| Persistence | default and custom pools/budgets/remote IDs; disable/re-enable preserves choices; removed target rejects |
| Generation | bundle parameters remain implicit; Thinking scope propagates; child spawn recursion stays denied |
| Cache | child cache scope remains normal runtime path; counters survive success/failure/cancel |
| Eval | model-backed `spawn_batch` rows plus agent-loop finalization and no-repeat/no-hang scoring |

### Current implementation checkpoint

This is automated/source evidence only. It does not replace the current-head
Release-app matrix below.

- `SpawnBatchToolTests`: **12/12 PASS** on the exact dirty campaign source.
  The suite is serialized because `SubagentAdmission` intentionally owns a
  process-wide local-GPU admission lane; concurrent test cases would otherwise
  contaminate their high-water observations.
- Covered rows: validation before preparation, request-local target schema and
  fan-out rejection, stable ordered/nested results, capacity diagnostics,
  two same-local jobs overlapping one remote job under one local handoff,
  one-slot local subwaves, isolated child failure, pre-interrupted cancellation,
  active Stop cancellation, and complete terminal result rows.
- The tool result now reports configured fan-out and per-wave effective engine
  slots, RAM slots, local subwave count, limiting factors, and admission
  verdict. These are execution facts, not claims inferred from a settings
  toggle.
- Separate focused suites previously passed on the same dirty source:
  effective-capacity planner **12/12**, dynamic request-local schema **44/44**,
  and shared default/custom spawn-settings UI/persistence **18/18**.
- The configured-agent tool contract is now explicit at the tool description,
  dynamic prompt, shared settings editor, configuration model, and runtime
  comments: enabled target-agent names are intersected with the registered
  tools that expose audited cooperative abort-and-drain ownership. Direct-chat
  plugin/MCP/sandbox-process/database/knowledge tools without that ownership
  remain parent-owned; no tool authority was broadened.
- Serial focused verification on this exact dirty source passed **44/44**:
  `SpawnGuidanceTests` 6/6, `SpawnToolTests` 20/20,
  `SubagentOperationCancellationTests` 10/10,
  `SpawnConfigurationUISourceTests` 4/4, and `SpawnedPDFReadTests` 4/4.
  A first combined parallel invocation hit the cancellation suite's
  yield-count-only startup wait once; the affected cooperative registry
  cancel-and-drain row then passed 1/1 in isolation and the full cancellation
  suite passed 10/10 serially. No production assertion failed.
- PDF support in this checkpoint is deliberately read-only: a worker can
  extract a host text-layer PDF through `file_read`; image-only PDFs and other
  unaudited rich-document paths fail honestly; cancellation drains without
  publishing success. Rename/move remains a separately authorized parent
  operation.
- `AgentLoopSpawnBatchEvalTests`: **7/7 PASS** for structured
  production-envelope observation, configured worker seeding with implicit
  bundle defaults, ordered result/count scoring, aggregate status, exact
  execution-wave facts (`remote_jobs`, effective local slots, local subwaves,
  limiting factors), cache availability, partial failure, and malformed-row
  rejection. This is model-free scorer/fixture proof only. The new
  `spawn-batch-two-configured-workers.json` fixture has not yet run against a
  real Gemma, Ornith, Bonsai, or other local model.
- Model-backed agent-selected routing and mixed local/remote provider rows
  remain pending current live model runs and authenticated provider credentials.
- A post-checkpoint adversarial lifecycle review found BATCH-14 through
  BATCH-18 above. The earlier focused passes therefore do not make this branch
  merge-ready. Exact regression tests and current-head Release proof are still
  required after those owning-layer fixes.
- Still pending before any merge-ready claim: combined related suites,
  OsaurusEvals model-backed scoring, rebase onto current `osaurus/main`, and
  every applicable live Release-app row.
- Final pre-rebase focused verification on the exact dirty campaign source
  passed **341/341** with zero failures and zero skips. It covers the twelve
  batching, permission, persistence, residency, diagnostics, runtime-policy,
  admission, feed, and cancellation suites named in the evidence ledger.
  `RuntimePolicySourceTests` also passed **99/99** independently after updating
  stale pin/source-contract expectations. These are deterministic
  source/runtime-unit gates, not Release-app proof.
- The pre-final full `OsaurusEvals` package run passed **296/296** across
  35 suites before the last source-contract and already-resident RAM reuse
  fixes. It must be rerun after the upstream rebase; it is not the final score.
- The exact pinned vMLX `BatchEngineIntegrationTests` passed **28/28** at
  `d7483a88668bb3ec70e0ea7f8423a5f684084c28`, including atomic capacity
  snapshots, hot resize, two-active/third-pending admission, cancellation,
  single-slot behavior, shutdown, and cache store/prefill behavior. The
  synthetic throughput row measured 467.2 tok/s serial versus 669.6 tok/s
  batched (1.43x). This is engine proof only.
- Adversarial RAM review found one real false refusal: cold-load Memory Safety
  was applied to a target that was already resident. The owning residency fit
  policy now bypasses only that cold-load verdict for the already-resident
  target; the regression remains within the shared bundle-aware memory
  profile. Live RAM refusal/reuse behavior is still pending.

## Current-head live Release-app matrix

Use a dedicated bundle identifier and test root. For every turn inspect the
whole lifecycle through final unlock and a follow-up.

1. Default-chat UI: add/remove/persist/relaunch local and remote targets,
   permissions, tools, budgets, and fan-out.
2. Custom-agent UI: the same rows plus disable/re-enable preservation.
3. Same parent/child local model: no unload/reload; two or more jobs; actual
   BatchEngine active high-water proves overlap when server batching is on.
4. Continuous Batching off: effective local slots visibly resolve to one and
   jobs complete in honest subwaves.
5. Server capacity below and above the agent fan-out cap.
6. Different parent/child local model: one unload/load/restore per local group;
   parent follow-up completes.
7. Two same-local jobs plus one authenticated remote job.
8. Two different local targets plus one authenticated remote target: prove
   the remote job overlaps local work, each local target completes in a safe
   serialized generation wave, Flexible mode avoids needless reloads when both
   fit, and Strict/insufficient-RAM paths hand off or refuse honestly.
9. Removed/disconnected remote target rejects before local handoff.
10. One child tool/parser failure while siblings finish.
11. Stop during preparation, prefill, decode, and finalization; no queued/hung
    card; follow-up completes.
12. Thinking on/off and interleaved reasoning → tool → reasoning → tool → final.
13. Exact bundle generation defaults and user overrides.
14. Disk-L2 partial prefix restore with paged RAM off across child jobs, a new
    chat, model reload, and app restart; record restored/remaining tokens,
    TTFT, prefill rate, and hit/miss/store counters.
15. Paged RAM on: create entry, evict with distinct work, then prove disk-L2
    restores the valid block.
16. RAM refusal and RAM-clamped local subwaves without OOM.
17. Representative available families: Qwen/Ornith/Bonsai, Gemma, Laguna,
    Nanbeige. Do not infer unavailable family/quant rows.
18. Permission: one visible batch-level Ask approval before target preparation;
    Deny/Stop causes zero model loads; Always persists across relaunch for the
    correct default/custom agent.
19. Cloud identity: two connected providers with the same display name and
    model slug remain independently selectable/routable; rename,
    disconnect/reconnect, removal, and relaunch preserve or reject the exact
    intended provider honestly.
20. PDF fan-out: at least two text-layer PDFs are read concurrently by
    read-only children, ordered metadata returns to the parent, and the parent
    performs approved rename/move operations without granting child shell or
    write access. Image-only PDFs fail honestly or use an explicitly enabled
    OCR path.
21. Configured-agent tool truth: UI, tool descriptions, and the dynamic prompt
    disclose the cancellation-audited subset actually present in the child
    schema. A direct-chat plugin/MCP/sandbox/database/knowledge tool without
    cooperative abort-and-drain remains parent-owned; Stop must never be made
    unsafe merely to claim direct-chat parity.
22. Concurrent teardown ownership: two unload/removal callers join the same
    in-flight BatchEngine/Metal drain. Only the first owns disposal, but neither
    caller may proceed until the drain completes.
23. Laguna XS 2.1 defaults: inspect installed 2L/4M/6M
    `generation_config.json`, migrate only recognized Laguna XS bundles whose
    `top_k` is missing or carries the known bad shipped value, and prove chat
    plus spawned-child effective requests use 20. Do not add a global runtime
    sampler override or overwrite an explicit per-request user override.

## Evidence ledger

| Date/time | Source SHA | Row | Result | Evidence |
|---|---|---|---|---|
| 2026-07-27 start | `92353afe` | Current-source audit | PARTIAL | This document; exact file-level findings above |
| 2026-07-27 21:36 PDT | `92353afe` + campaign diff | `SpawnBatchToolTests` | PASS (automated only) | Swift Testing: 12 tests, 1 serialized suite, 0 failures, 0.362 s |
| 2026-07-27 checkpoint | `92353afe` + campaign diff | Capacity planner | PASS (automated only) | Swift Testing: 12/12 focused rows |
| 2026-07-27 checkpoint | `92353afe` + campaign diff | Dynamic schema refresh | PASS (automated only) | Swift Testing: 44/44 focused rows |
| 2026-07-27 checkpoint | `92353afe` + campaign diff | Shared default/custom UI and persistence | PASS (automated only) | Swift Testing: 18/18 focused rows; no live UI proof yet |
| 2026-07-27 checkpoint | `92353afe` + campaign diff | Spawn-batch eval observation/scoring | PASS (automated only) | `AgentLoopSpawnBatchEvalTests`: 7/7; aggregate/wave/cache facts scored; real model fixture unrun |
| 2026-07-27 adversarial review | `92353afe` + campaign diff | Stable identity, post-wait replan, non-cooperative Stop, aggregate/cache telemetry | BROKEN | BATCH-14 through BATCH-18; no merge claim |
| 2026-07-27 21:37 PDT | upstream audit | Mainline drift | PENDING REBASE | `osaurus/main` advanced from `92353afe` to `c8be96cc`, including PR #2203 app-hang fixes that overlap the campaign diff |
| 2026-07-27 contract audit | `92353afe` + campaign diff | Permission, provider identity, PDF worker ownership, legacy override | BROKEN/PARTIAL | BATCH-19 through BATCH-22; source-only audit, no live proof |
| 2026-07-28 spawned-tool contract audit | `92353afe` + campaign diff | Configured-agent tool exposure | PARTIAL | BATCH-23: product/model-facing copy aligned to the audited cancellation gate; broad plugin/MCP/sandbox/database/knowledge parity still requires tool-by-tool abort-and-drain ownership; no live proof |
| 2026-07-28 focused spawned-tool verification | `92353afe` + campaign diff | Guidance, tool description, UI source, cancellation ownership, PDF reads | PASS (automated only) | Serial focused suites 44/44; one combined-parallel startup-wait flake reproduced as PASS 1/1 isolated and 10/10 full suite; no Release-app proof |
| 2026-07-28 strict same-model eval | `92353afe` + campaign diff | Nanbeige JANG 4M, two configured same-model workers | PASS (model-backed, stale-base until rebase) | Report `/private/tmp/osaurus-subagent-batching-evals-20260728/nanbeige-same-model-exact-wave-configured.json`, SHA-256 `eddab4a10365223222efd469084b278f64612879e86a8353ad6d831a056b31f7`; Continuous Batching on, sessions 2, effective slots 2, one local subwave `[2]`, both child streams overlap at first delta, 2/2 ordered, one parent final, 47.3 tok/s, TTFT 2.151 s, peak physical footprint 3,481 MB, L2 +1 hit/+17 misses/+12 stores |
| 2026-07-28 Laguna XS config audit | local bundles | 2L/4M/6M `generation_config.json` | PARTIAL | All three local `/Users/eric/models/dealign.ai/Laguna-XS-2.1-JANG_*-CRACK` bundles currently contain `top_k: 20`; migration behavior and effective chat/spawn requests are not yet proven |
| 2026-07-28 teardown audit | `92353afe` + campaign diff | Concurrent unload/drain ownership | BROKEN | BATCH-24: `TaskCoalescer.remove` does not join an existing tombstoned drain; deterministic regression and owning-layer fix required |
| 2026-07-28 pinned vMLX verification | `d7483a88668bb3ec70e0ea7f8423a5f684084c28` | Atomic BatchEngine capacity, resize, admission, cancellation, shutdown, cache | PASS (engine automated only) | `BatchEngineIntegrationTests` 28/28; synthetic serial 467.2 tok/s, batch 669.6 tok/s (1.43x); no Osaurus UI claim |
| 2026-07-28 pre-final eval run | `88710429` + campaign diff | Full OsaurusEvals package | PASS (stale pre-rebase automated only) | 296/296 tests across 35 suites; rerun required after final rebase/source freeze |
| 2026-07-28 RuntimePolicy source contracts | `88710429` + campaign diff | Runtime-policy contracts and exact vMLX pin | PASS (automated only) | xcresult `Test-OsaurusCoreTests-2026.07.28_11-02-09--0700.xcresult`: 99/99, zero failures/skips |
| 2026-07-28 final focused pre-rebase matrix | `88710429` + campaign diff | Permission, config, UI source, residency, health, runtime policy, batch, adapter, server settings, admission, feed, cancellation | PASS (automated only) | xcresult `Test-OsaurusCoreTests-2026.07.28_11-03-21--0700.xcresult`: 341/341, zero failures/skips |
| 2026-07-28 RAM adversarial review | `88710429` + campaign diff | Already-resident target under tightened Memory Safety | FIXED IN SOURCE / LIVE PENDING | Cold-load denial no longer rejects an already-resident target; focused regression is included in the 341-test matrix; Release-app RAM rows remain unrun |
