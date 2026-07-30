# Subagent Batching Compatibility Campaign — 2026-07-27

## Status

`PARTIAL — AFFECTED FOLLOW-UP PROVEN; BROAD MODEL EVAL SETUP-BLOCKED` — the
original batching campaign merged in PR #2221. The post-merge shared-concurrency
follow-up was tested at behavioral source/test SHA
`cf97ceddfc5250c28fe6ee5d78e34df3f45f5662`; its patch-identical current
behavioral commit is `f08d660fc49f96f1d87125190f4c2818bcbd2640` after rebasing over an
appcast-only upstream commit. It has fresh focused, full-Core,
deterministic-eval, exact-pin vMLX, and isolated Release-app evidence. The
affected live scope covers bidirectional Settings synchronization
and relaunch persistence, Always Allow persistence, same-model concurrency,
different-local handoff/restore, mixed local/OpenAI-compatible-provider work,
active remote cancellation, strict RAM refusal, terminal unlock, and exact
follow-up turns.

The final full model-backed AgentLoop/AgentLoopFrontier invocation did not see
the local Nanbeige registration and therefore produced setup errors before
model execution. Those rows are recorded as `BLOCKED`, not as product failures
or passes, and this document does not describe the follow-up as release-ready
or regression-free. Earlier model-backed rows remain historical evidence only.
The provider proof uses a deterministic no-auth localhost emulator; it does not
claim an authenticated public-cloud account test and did not read or copy Codex
credentials.

- Tested behavioral source/test SHA: `cf97ceddfc5250c28fe6ee5d78e34df3f45f5662`.
- Patch-identical current behavioral commit: `f08d660fc49f96f1d87125190f4c2818bcbd2640`.
- Rebased upstream base: `a83f667f944fcea918141b743348f5d27aa6c4d0`.
- vMLX Swift pin: `439f53694f3d630663e97612c264ae73e499121a`.
- Worktree: `/private/tmp/osaurus-subagent-postmerge-cleanup-20260729`.
- Branch: `codex/subagent-postmerge-cleanup-20260729`.
- A later documentation-only commit may advance the PR head; the tested
  behavioral tree remains the SHA above.

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

The serialized prefill/completion batch-size and SMELT contract fields remain
available to the server/API compatibility layer, but their Settings controls
were removed on 2026-07-29. They must not return to the visible UI until real
runtime consumers and end-to-end proof exist.

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
| BATCH-26 | Custom-agent launcher and target authority used final-value equality only, so an edit followed by a value-identical restore during approval or post-admission validation could escape ABA detection. | BROKEN | Per-agent Spawn authority |
| BATCH-27 | The PR #2216 rebase split idle-decision ownership from the exact handoff unload claim and initially omitted post-drain identity/ownership rechecks on the combined path. | FIXED IN SOURCE / LIVE PENDING | Runtime teardown ownership |

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
- Still pending before any merge-ready claim: post-rebase automated reruns,
  OsaurusEvals model-backed scoring, and every applicable live Release-app
  row. The prior automated evidence remains historical until it is repeated on
  final rebased HEAD `a283c8a8`.
- Final focused verification on clean rebased HEAD `69485fd0` passed
  **341/341** with zero failures and zero skips. It covers the twelve
  batching, permission, persistence, residency, diagnostics, runtime-policy,
  admission, feed, and cancellation suites named in the evidence ledger.
  The earlier independent `RuntimePolicySourceTests` **99/99** result was
  pre-rebase; all runtime-policy rows are included in the rebased 341-test
  result. These are deterministic source/runtime-unit gates, not Release-app
  proof.
- The pre-final full `OsaurusEvals` package run passed **296/296** across
  35 suites before the last source-contract and already-resident RAM reuse
  fixes. That historical score was not used as the final gate; the package was
  rerun after the authority and fixture fixes described below.
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

### Post-rebase authority and eval stabilization

The first full post-rebase `OsaurusEvals` run did **not** pass: it ran all
**296 tests across 35 suites** but reported **3 failed tests / 15 recorded
issues** in subagent authority rows. Running the complete
`SubagentEvalTests` suite as a focused reproducer amplified the same problem to
**6 failed tests / 23 recorded issues**. The failures were not accepted as
model randomness or hidden with test serialization.

The production root cause was a torn cold authority read.
`SubagentConfigurationStore.snapshot()` released its state lock before disk
materialization, so concurrent first readers could decode identical bytes but
each advance `snapshotRevision`. Callers that obtained configuration and
revision separately could therefore observe a configuration from one
materialization and a revision from another, making an unchanged batch look
mutated during validation/authorization.

The owning-layer correction is:

- single-flight cold disk materialization without holding the state lock
  across I/O;
- a post-read generation/cache recheck so an old disk read cannot overwrite a
  concurrent save or override-directory change;
- one atomic `snapshotWithRevision()` configuration/revision pair consumed by
  both text-subagent authority snapshots and batch authority fingerprints;
- a 32-reader cold-start regression proving one materialization and one
  revision increment.

After that correction, focused `SubagentEvalTests` passed **33/33**. The
configuration-store, permission-gate, and batch-tool Core matrix passed
**65/65**, zero failures/skips, in
`/private/tmp/osaurus-subagent-store-authority-20260728-1140.xcresult`.

A second failure was isolated to the scripted eval fixture rather than the
production Stop contract. Its fixed wall-clock interrupt could fire before the
scripted child had entered its run under full-suite contention. The original
case passed **1/1** in isolation, showing the intended production path; the
fixture now uses a bounded run-entry rendezvous before starting the Stop delay,
while retaining a fallback deadline so a real failure to enter still gets
interrupted rather than hanging.

With both corrections on the current dirty source:

- full `OsaurusEvals`: **296/296 across 35 suites**;
- broad affected `OsaurusCoreTests`: **489/489**, zero failures/skips, result
  bundle
  `/private/tmp/osaurus-subagent-batching-broad-core-20260728-1201.xcresult`;
- combined Agent Channels + Spawn prompt/tool surface:
  `PromptSurfaceMatrixTests/promptAndToolSurfaceMatrix()` **1/1**, result bundle
  `/private/tmp/osaurus-prompt-surface-cross-feature-20260728.xcresult`.

The combined prompt result preserves both `spawn_agent` and `spawn_batch`,
retains the `agent_channel_*` manifest, and asserts that the Spawn schemas are
byte-identical to the Spawn-only row with no duplicate tool names. Its
xcresult also contains a non-failing Thread Performance Checker warning at
`ModelManager.swift:1856`; that diagnostic is not represented as resolved by
the passing assertion.

The pinned vMLX `BatchEngineIntegrationTests` were also rerun at
`d7483a88668bb3ec70e0ea7f8423a5f684084c28`: **28/28**, zero failures, 4.768 s.
The synthetic throughput row measured 425.4 total tok/s serial versus
640.3 tok/s batched (**1.51x**). This is engine/test-only evidence, not live
Osaurus/model proof.

Cleanup removed **18.9 GB** of obsolete DerivedData; the Data volume reported
approximately **1.2 TiB free** afterward. The model assets reserved for the
live matrix were not removed. This is storage housekeeping only, not runtime
proof.

The post-handoff adversarial audit found BATCH-26. The owning fix adds separate
monotonic launcher, permission, and target generations per custom-agent UUID;
presentation-only edits do not move them, while edit-and-restore changes still
invalidate prepared direct and batch work. The exact changed-source
`SpawnPermissionGateTests` gate passed **20/20**, zero failures/skips, in
`/private/tmp/osaurus-subagent-authority-aba-20260729.xcresult`. This is
focused automated evidence only; the full frozen-source matrix and live app
remain pending.

The fresh combined focused lifecycle gate then passed **115/115**, zero
failures/skips, across `SubagentAdmissionTests`,
`SubagentSessionAdmissionTests`, `SubagentResidencyTests`,
`SpawnPermissionGateTests`, `ServerRuntimeSettingsStoreTests`, and
`SubagentOperationCancellationTests`. Result bundle:
`/private/tmp/osaurus-subagent-focused-20260729-0112.xcresult`.

After rebasing onto merged PR #2216, the fresh focused gate passed **115/115**
again in
`/private/tmp/osaurus-subagent-focused-20260729-postrebase-1.xcresult`.
The first combined #2216/handoff source-contract run then correctly found
BATCH-27. The owning teardown now preserves the exact idle-decision commit
gate, generation/child-ownership claims, bounded fail-closed drains, and
identity/ownership rechecks after each suspension boundary. The corrected
focused source-contract rerun passed **107/107** in
`/private/tmp/osaurus-subagent-pr2216-fix-20260729.xcresult`.

The current broad affected Core matrix passed **597/597**, zero failures and
zero skips, in
`/private/tmp/osaurus-subagent-broad-current-20260729.xcresult`. It contains
the previous 489 batching/channel/prompt/lifecycle cases plus the merged
selected-chat warmup, idle-residency, runtime-policy, and exact handoff rows.
The full fresh-scratch `OsaurusEvals` package passed **299/299 across 36
suites**; raw log:
`/private/tmp/osaurus-subagent-evals-current-20260729.log`. This adds the
selected-chat idle-eviction lifecycle suite to the previous 296/35 baseline.

### Final frozen-candidate verification

The final full local Core/Evals gates ran on behavioral source
`886319c35fe7e102d2c25a0c39a50e72f16452f2` with vMLX pin
`84612e143d2e51da865316dbc49167530a1717ad`:

- full `OsaurusCoreTests`: **7,311 passed, 21 skipped, 0 failed, 7,332
  total** in
  `/private/tmp/osaurus-subagent-broad-final-886319c3.xcresult`; raw log
  SHA-256
  `cbdacbc5ea3076969e9ed7a079164b36926816381ba2e947b4f12d96c0900c86`;
- full `OsaurusEvals`: **299/299 across 36 suites**, zero failures; raw log
  `/private/tmp/osaurus-subagent-evals-final-886319c3-xcode.log`, SHA-256
  `c4eba58b13534416e94074992a126bcbab9c6ae875839798c9f5fadaa02050b7`;
- deterministic live-contract eval scenarios: **101/101** across Schema,
  ToolEnvelope, PrefixHash, ArgumentCoercion, ToolResultGrounding,
  AgentChannels, ComputerUse, and ScreenContext; raw log SHA-256
  `6ddd8c2394c40f39bbfe1f8df4cf774576832ee60694c3df09147d2d51cd649d`;
- focused isolation regressions: **7/7** AppleScript/image bridge and **33/33**
  tokenizer/personas, zero failures; logs SHA-256
  `784518ede238a1a7033921468e9e8876f87da72ef17763cbd3aee3b4bd2d0c01`
  and
  `7408ce6c81348414bc7b21061a8426f206942fc870f9f5004da4de712b8b6194`;
- exact-frozen-source Release app bundle ID
  `com.dinoki.osaurus.subagentbatchproof.c317e0f0`; executable SHA-256
  `183780eb9d8b7c27b02fe9ae8b4b66645fd3f9ddb242a214bc4d2f0b86f7298e`;
  strict deep code-sign verification passed and the build log SHA-256 is
  `0ddb4be4eaae13045e699d68c71690e333d40c7c0f979a504c46337728d277af`;
- full live-matrix Release app bundle ID from the immediately preceding,
  patch-identical campaign commit
  `com.dinoki.osaurus.subagentbatchproof.23219920`; executable SHA-256
  `74b5828910186c71903cf424a2f5524551df562b87112251569a56352f5bcf52`;
  strict deep code-sign verification passed and the build log SHA-256 is
  `7a9ece798d1c6e6b0420d953c5e69c22ff4c2d78c19ed418e81f10b356d5f7a0`.

Frozen runtime source `c317e0f094e4b35593e39d9d2d2e492871574e0a`
differs from behavioral source `886319c3` only by the localized panel-title
catalog entry required for `L("Tool Permission")`. The exact-source i18n gate
passed with 6,305 catalog keys, all 3,072 Swift localization references
resolved, and zero suspect literals. The fresh exact-source Release build and
strict deep code-sign verification also passed.

The late upstream rebase added only PR #2219's OsaurusAI catalog fetch-limit
change from 100 to 200. `git range-diff` classified all 13 campaign commits as
patch-identical. The exact rebased Release app was then opened with a new
keychain-free test root and the affected model-discovery/settings surface was
rechecked through Computer Use: the picker exposed 61 local bundles, Nanbeige
JANG_4M was assigned with note `Post-rebase discovery proof`, the main-chat
maximum was changed from three to two, and a full app relaunch preserved the
target, note, Ask policy, worker-tool mode, two-per-batch limit, local handoff,
and RAM-Safety preflight. The persisted delegation JSON SHA-256 is
`f363c8167814e4204f51179e0c1cacbe8f36921d8a259319197d8a8c6e0fbcb4`;
the target-assignment and post-relaunch screenshot SHA-256 values are
`1b4df1b74e816fe6b369056559087c13ca208bbea251c293aef6b78987e3aeea`
and
`9a0b7389a771ccf7568d1f3a4ba42e37fca443a469fc96a155356926c59b7a88`.
The isolated app was quit; the production `com.dinoki.osaurus` instance was
left running and untouched.

### Final upstream rebase and Settings lifecycle fix

Upstream advanced once more through PR #2220, which changed only
`ClaudePluginCard.swift` and `PluginsView.swift`. The campaign rebased
conflict-free onto `af68b064167300d255ab1a1e37b5b5c2dd2943fc`. Exact rebased
source `033eb49815b4fd3c7920fcf1b9ae49942fb3feef` passed full Core
(**7,311 passed, 21 skipped, 0 failed**) and full Evals (**299/299 across 36
suites**), and its fresh Release app built and passed strict deep code-sign
verification. The executable SHA-256 was
`60f586f0a1f81e396573441491f1329379262f6ec326b3ab97eecf468f88683b`.

That exact app nevertheless failed the required visible Settings lifecycle:
after changing the main-chat maximum from three to two and enabling RAM-Safety,
General -> Server stopped responding. The sampled main thread was blocked in
`SecItemCopyMatching` from `RelaysSectionView.body` at `ServerView.swift:718`
while a concurrent router signer also accessed the Keychain. The raw sample is
`/private/tmp/osaurus-subagent-postrebase-033eb498-ui-timeout.sample`, SHA-256
`5997d856076637dd93118276eac5bd820000de7f98cc728179136e1fca293c0e`.
This was recorded as a live failure and fixed rather than masked by an app
restart.

Runtime source `315f1f63b4eef7b8c966ceaa1c7601f18c9568a9` routes both automatic
relay-identity call sites through the existing race-safe background helper,
which reserves identity state on the main actor but performs Keychain reads and
address derivation in a detached task. The new focused source contract passed
**101/101**; full Core passed **7,312 passed, 21 skipped, 0 failed, 7,333
total**; and full Evals passed **299/299 across 36 suites**. Evidence SHA-256
values are, respectively,
`156e62c80fb7468a91c0a26a1fd1bf0146c89a473ac74f587a30fb693dee201e`,
`647c17033b9d937f3ffbe24191f2e90c3a3bdbd68798085720a496e33070193b`,
and `c07221ed8e587a6cc140d5043e6650f490986b573c4825b1700fbe2763e2794e`.

The exact fixed Release bundle
`com.dinoki.osaurus.subagentbatchproof.315f1f63` passed strict deep code-sign
verification; its executable SHA-256 is
`4d95e983b592c7ac5268c5f6fdb29997f18a2910a3b7d06c6b46925dd2e14971`
and build-log SHA-256 is
`aba3fca4ae0036f8a4a9ec62af183df8da10d96de277e450c6a38f4d97e75a35`.
Computer Use then proved General -> Server -> General navigation, successful
quit, relaunch persistence of two-per-batch plus RAM-Safety enabled, and a
responsive Server surface. The proof used the shared Osaurus configuration
root despite the dedicated bundle identifier, so the measured pre-test values
were explicitly restored through the UI to three-per-batch and RAM-Safety off.
The restored JSON SHA-256 is
`e017dff20893795b4b8607321bdc4ff8e1223f91668ebbec2c6cd5fb035a1464`.
General-restored and Server-responsive screenshot SHA-256 values are
`2cfdf8230831d7f9f8d5c5fedfb5e12095270d7c5d8504260ef3e71871886b1e`
and
`a29b7faca4befe1c01d70ed4ebe9b79af7affc6c9ee64212ac6f8d0bbdc4c200`.
The proof app was quit and the already-running production
`com.dinoki.osaurus` app remained running.

### Final PR #2222 base move

Before push, upstream advanced again through PR #2222's chat-import guide. Its
only source changes were `ChatSessionImportCoordinator.swift`,
`ChatSessionSidebar.swift`, the new `ImportGuideSheet.swift`, and localization
catalog additions. All 17 campaign commits remained patch-identical after a
conflict-free rebase onto `f013ccc7ac109aa5fba7c22c1174cfb9022e3150`.
The runtime commit became `ebdd229381d6ed12abcfced407bc75e00c2b4543`.

The final-base full Core suite passed **7,312 passed, 21 skipped, 0 failed,
7,333 total** in
`/private/tmp/osaurus-subagent-broad-final-ebdd2293.xcresult`; raw log SHA-256
`aaf63c0051476ea931376ee5eb7e1771a40c215aa56408052710d6798881b7d1`.
Full Evals passed **299/299 across 36 suites** from a clean Xcode-toolchain
scratch tree; raw log SHA-256
`384c7ab03980849e1b83a7b28f09ad825cbe162d9b38dde3667466766fcf3fe9`.
The i18n gate passed with 6,315 catalog keys, all 3,072 Swift references
resolved, and zero suspect literals.

Exact build source `8a70d427144d6059ee5b77a79c1c98ca041160ef`, a documentation-only child
of the runtime commit, produced Release bundle
`com.dinoki.osaurus.subagentbatchproof.8a70d427`. Strict deep code-sign
verification passed; executable SHA-256 is
`1e0b7062a4b132747e5494c2dd7b20bcb0b4ee2e83fbd37f2fadaddbc3df6a5f`
and build-log SHA-256 is
`273f4581fdc9610d027953be6f9589e9de1a9dcebccd9f2f4e5af468e8bfb4eb`.

Computer Use changed the visible main-chat limit from three to two and
RAM-Safety from off to on, proved General -> Server -> General stayed
responsive, quit the app, relaunched the exact bundle, and confirmed both
changes persisted. It then restored the shared configuration through the UI to
three-per-batch and RAM-Safety off. The restored JSON retained SHA-256
`e017dff20893795b4b8607321bdc4ff8e1223f91668ebbec2c6cd5fb035a1464`.
Server-responsive and General-restored screenshot SHA-256 values are
`d77c6fa1838716974925626af77b476701c9172397a29d9f58e3d42ce9aec802`
and
`2e73491354cbfd857badf8b11138d0d7f9d167d2d6cca3a1c9c1145588acfd78`.
An initial accessibility capture immediately after dismissing onboarding timed
out, but an exact-process sample showed the main thread idle in the AppKit event
loop rather than blocked; the next capture returned the full chat UI and every
subsequent action completed. The isolated app quit cleanly, and production
Osaurus PID 90191 remained running.

### Exact-pin Nanbeige, cache, prefill, and parser gate

The final Release dependency checkout was independently verified at exact vMLX
SHA `84612e143d2e51da865316dbc49167530a1717ad`. Its
`LLMModelFactory.swift` explicitly registers model type `nanbeige`, so that
bundle type does not fall through to the unsupported-model error. The Nanbeige
runtime allocates `num_hidden_layers * totalLoops` independent cache slots,
indexes every loop-layer pair without aliasing, and fails closed on unsupported
future architecture flags. Osaurus RAM admission applies the same physical
loop-layer multiplier. The exact-pin Nanbeige suite passed **6/6**, including a
two-layer, two-loop forward assertion that all four cache offsets advance and
the registry/model-cache construction row. Raw log SHA-256:
`ff8da47d765aeea6223dfc015cabeacdd4032b3b1ba2e111ef46e950ba971bf8`.

The exact-pin chunked-prefill suite passed **9/9**. It proves that a 600-token
prompt with step 256 evaluates two largest full 256-token chunks and returns
the 88-token remainder, while an exact 256-token boundary remains one complete
final forward; 1D/2D input, mask flattening, progress, and cancellation rows
also passed. Raw log SHA-256:
`fa2ebcc68857fa325bceba138b1b692438034b08a8229d6809cea6f08d23f186`.

Exact-pin reasoning and tool-parser suites passed **139/139**. Coverage includes
Qwen reasoning start/close behavior, interleaved and split-stream boundaries,
no-reasoning behavior, XML function calls, nested and multiline arguments,
arrays, invalid/missing arguments, and the other supported parser families.
Raw log SHA-256:
`dcea39a7cc12a416ec5160cb84d67a3c00d11c1571a595236ba32eb753164067`.
Together with the live Nanbeige thinking-on/off and tool/delegation rows, this
closes the source, focused-test, and visible-lifecycle sides of the pin gate.

The first combined terminal attempt did not reach these assertions because
SwiftPM does not emit MLX's `default.metallib`. A second attempt initially used
the app-root custom metallib instead of the packaged
`mlx-swift_Cmlx.bundle` metallib and crashed on missing kernel `rbitsc`; that
crash left the test-only named semaphore held. The final isolated reruns used
the exact Release bundle's 3.6 MB Cmlx metallib, reset only that stale test
semaphore, ran each test framework separately, and produced the passing logs
above. These were runner-resource failures, not hidden product assertion
failures.

The full-matrix Release app was launched with a dedicated keychain-free test root
and clicked through the real Chat and Settings UI. The final-candidate rerun
visibly proved persisted target notes, Ask permission, worker-tool mode,
2,048-token/2-turn/120-second child budgets, per-agent maximum two, Concurrent
Sessions three, Continuous Batching on, Memory Safety effective concurrency
two, same-model `[2]` execution, mixed local/remote execution, active remote
cancellation with provider socket closure, thinking on/off, terminal unlock,
and strict 10% RAM refusal followed by restoration to the normal Strict 60%
plan. The deterministic OpenAI-compatible emulator script SHA-256 is
`df4f509abd1091092a38917715a9cdc1e1891f539ad118ceb6ef3df3c0c4e80c`.
No credential or `auth.json` was used.

Final-candidate visible rows and raw evidence:

- Settings relaunch preserved Batch Worker, Ornith 9B, Thinking Off, allowed
  local/remote targets and notes, Ask, worker tools, child budgets, maximum
  two, Continuous Batching on, and the Strict concurrency clamp. Screenshot
  SHA-256
  `fb94c0b19f32f523c69585e7e47fe2f43c7425390feaa4408ee253024e090417`.
- Same-model Nanbeige `spawn_batch` reported configured/effective two,
  `engine_slots: 2`, `ram_slots: 21`, subwaves `[2]`, ordered exact child
  summaries, 2/2 success, exact parent final, and exact follow-up. Child rates
  were 21.5 and 18.8 tok/s; parent/follow-up were 56.3/54.4 tok/s. Result and
  follow-up screenshot SHA-256 values are
  `e33572bf2b7bc8174a4bd5d7e60866a8d8b1c999f636dcfea187c8a63b2a1e95`
  and
  `34649da9f81fb668314110b007be849b008fb65f5b934cfcf959aa28de158e92`.
- Mixed Nanbeige/local plus stable provider target returned ordered 2/2
  success with `local_jobs: 1`, `remote_jobs: 1`, effective local slots one,
  and parent/follow-up finalization. The emulator returned its deterministic
  fallback because the child used `Return` rather than its `Reply exactly`
  pattern; this is recorded as an emulator-content expectation miss, not a
  routing failure. Screenshot SHA-256
  `0ccf287ebb0172817becddedca758254d5e6584f69ced72699eddd97fa04f114`.
- Stop during a delayed active provider child returned the explicit cancelled
  envelope, removed Stop, unlocked input, and closed the client socket (the
  emulator observed a broken pipe). Screenshot SHA-256
  `c76fb303281d6f9eb4bde631658c60bca48233e3ff080b7de71a7b94658fa4b3`.
- Thinking On showed closed reasoning around two settled tool cards and a
  coherent final with no raw thinking tags or protocol debris. The parent also
  emitted a false intermediate "still running" line after the first settled
  child; lifecycle is PASS and model content is MISS. Thinking Off persisted
  across relaunch and produced no reasoning card. Screenshot SHA-256 values:
  `85dd4745831f8cd94158af3da01ac79e46bc5f28d006486bebfb8bf7650a2624`,
  `4fdedce4f8d20776acd7c1ccfa12e29eb92ad1499bd9f0123bd6d2be9ad38fda`,
  and
  `94555d61cda74ab963023b237bd0200d42c30adaef4d2bb6b1d26be9726e5ca2`.
- Strict was changed live to custom 10% and saved. The dense Ornith 35B MXFP8
  request was refused before load because its estimated 42.7 GB working set
  exceeded the 12.8 GB budget. The parent then wrongly attempted a second 9B
  spawn, which was denied; the card settled and later turns unlocked but
  repeated the stale parent token, recorded as a model-content miss. Strict
  60% was restored and the temporary target was removed through the UI. The
  app ended at 2,660 MB physical footprint (4,603 MB peak), with system memory
  92% free. Setting/refusal/restore screenshot SHA-256 values are
  `8639af742dfdcc2f5cd00df0561dd17d07afd2b6a39f81531c3de29d1222b741`,
  `37e4ed0da5076cee9cee8b1288de93b47b6a26d2df1d03439f7ce7a8284f5a2c`,
  and
  `50c7baef3b16b2caaf4682caac40956392c97ad5fe572da32de90f41cfae38f6`.
  The temporary clone is recoverable at
  `/Users/eric/.Trash/Osaurus-proof-Ornith-35B-MXFP8-20260729T0625`; the
  original bundle was never modified and both config hashes were
  `33b6cb6d3fb9e265486b6e9fd018f48b6d94172becc22805f51dd140e9400246`.

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
| 2026-07-28 upstream rebase | `69485fd0` on `e294c616` | Four campaign commits rebased over the then-current Osaurus main | PASS (historical source ancestry only) | Conflict-free rebase; upstream later advanced to `d6216d23`, so a final rebase and rerun remain pending; all four vMLX pins resolve to `d7483a88668bb3ec70e0ea7f8423a5f684084c28` |
| 2026-07-28 focused post-rebase matrix | `69485fd0` | Permission, config, UI source, residency, health, runtime policy, batch, adapter, server settings, admission, feed, cancellation | PASS (automated only) | xcresult `Test-OsaurusCoreTests-2026.07.28_11-08-59--0700.xcresult`: 341/341, zero failures/skips |
| 2026-07-28 first full post-rebase eval | `69485fd0` + campaign diff | Full OsaurusEvals package | FAIL | 296 tests across 35 suites; 3 failed tests / 15 issues in subagent authority rows; not counted as a pass |
| 2026-07-28 focused authority reproduction | `69485fd0` + campaign diff | Full `SubagentEvalTests` before authority fix | FAIL | 6 failed tests / 23 issues; unchanged config was rejected while validating/authorizing batches |
| 2026-07-28 cold authority fix | `69485fd0` + campaign diff | Single-flight configuration materialization and atomic config/revision snapshot | PASS (automated only) | `SubagentEvalTests` 33/33; Core store/permission/batch 65/65 in `/private/tmp/osaurus-subagent-store-authority-20260728-1140.xcresult`; live app pending |
| 2026-07-28 scripted Stop fixture audit | `69485fd0` + campaign diff | Wall-clock Stop under full-suite contention | FIXED IN EVAL FIXTURE | Old case passed 1/1 isolated; new bounded run-entry barrier prevents a nominal mid-run Stop from landing before child run entry |
| 2026-07-28 final token-free eval package | `69485fd0` + campaign diff | Full OsaurusEvals package | PASS (automated only) | 296/296 tests across 35 suites; model-backed and live Release-app rows remain pending |
| 2026-07-28 broad affected Core matrix | `69485fd0` + campaign diff | Authority, permission, batching, residency, lifecycle, channels, prompts, settings | PASS (automated only) | 489/489, zero failures/skips; `/private/tmp/osaurus-subagent-batching-broad-core-20260728-1201.xcresult` |
| 2026-07-28 channels + spawn prompt surface | `69485fd0` + campaign diff | Combined prompt/tool schema composition | PASS WITH NON-FAILING DIAGNOSTIC (automated only) | 1/1; `/private/tmp/osaurus-prompt-surface-cross-feature-20260728.xcresult`; bundle also records a Thread Performance Checker warning at `ModelManager.swift:1856` |
| 2026-07-28 pinned vMLX rerun | `d7483a88668bb3ec70e0ea7f8423a5f684084c28` | `BatchEngineIntegrationTests` | PASS (engine automated only) | 28/28, zero failures, 4.768 s; serial 425.4 total tok/s, batched 640.3, 1.51x; not live Osaurus/model proof |
| 2026-07-28 storage cleanup | local machine | Obsolete build data | COMPLETE (housekeeping only) | 18.9 GB obsolete DerivedData removed; Data volume approximately 1.2 TiB free; reserved live-test model assets preserved |
| 2026-07-28 final upstream rebase | `a283c8a8` on `d6216d23` | Five campaign commits rebased over current Osaurus main | PASS (source ancestry only) | Conflict-free rebase; all four vMLX pins resolve to `d7483a88668bb3ec70e0ea7f8423a5f684084c28`; post-rebase automated and live rows remain pending |
| 2026-07-29 per-agent Spawn authority audit | `a283c8a8` + campaign diff | Custom launcher/permission/target ABA generations | FIXED IN SOURCE / LIVE PENDING | `SpawnPermissionGateTests` 20/20, zero failures/skips; `/private/tmp/osaurus-subagent-authority-aba-20260729.xcresult`; full frozen-source and Release-app reruns remain pending |
| 2026-07-29 fresh focused lifecycle gate | `a283c8a8` + campaign diff | Admission, post-wait residency, permission/authority, server migration, cancellation | PASS (automated only) | 115/115, zero failures/skips; `/private/tmp/osaurus-subagent-focused-20260729-0112.xcresult`; broad/eval/live rows remain pending |
| 2026-07-29 PR #2216 rebase | `1cef485d` on `33f455e4` | Six campaign commits rebased over merged selected-chat idle warmup recovery | PASS (source ancestry only) | One semantic ModelRuntime conflict required combined idle-decision plus exact-claim teardown; automated proof follows |
| 2026-07-29 post-rebase focused gate | `1cef485d` | Admission, session admission, residency, authority, server migration, cancellation | PASS (automated only) | 115/115, zero failures/skips; `/private/tmp/osaurus-subagent-focused-20260729-postrebase-1.xcresult` |
| 2026-07-29 merged teardown audit | `1cef485d` + fix | PR #2216 idle-decision ownership plus handoff identity/ownership claims | FAIL THEN FIXED IN SOURCE | Initial 138/140 source-contract run found BATCH-27; no pass claimed for that run |
| 2026-07-29 merged teardown focused rerun | `de0ac40e` | Runtime policy and exact handoff ABA guards | PASS (automated only) | 107/107, zero failures/skips; `/private/tmp/osaurus-subagent-pr2216-fix-20260729.xcresult` |
| 2026-07-29 broad affected Core matrix | `de0ac40e` | Batching, channels, prompts, settings, warmup, idle residency, exact handoff, cancellation | PASS (automated only) | 597/597, zero failures/skips; `/private/tmp/osaurus-subagent-broad-current-20260729.xcresult` |
| 2026-07-29 full token-free eval package | `de0ac40e` | All deterministic OsaurusEvals including AgentLoop spawn batch, parent continuation, Stop, and selected-chat warmup lifecycle | PASS (automated only) | 299/299 across 36 suites; `/private/tmp/osaurus-subagent-evals-current-20260729.log`; model-backed/live rows remain pending |
| 2026-07-29 02:12 PDT fresh Release UI | `ff01bcd4` + vMLX `84612e14` | Main-chat `Ask`, one same-model `spawn_batch` with two Nanbeige workers | FAIL | The model emitted one valid two-job call and the expanded card reached `validating targets` then `authorizing batch`, but no approval panel was visible or exposed in the app accessibility tree after more than four minutes. The card and parent Stop remained active and input stayed locked; no child began loading. Exact isolated app: `com.dinoki.osaurus.subagentbatchproof.ff01bcd4`; stdout `/private/tmp/osaurus-subagent-batch-live-ff01bcd4.stdout.log`; test root `/private/tmp/osaurus-subagent-batch-ui-root-ff01bcd4-20260729T0152`. This is a live lifecycle failure, not a pass from valid tool arguments or pre-load rejection safety. |
| 2026-07-29 02:17 PDT same Release UI continuation | `ff01bcd4` + vMLX `84612e14` | Hidden-prompt keyboard path and same-model batch execution | BATCH PASS / PERMISSION UI FAIL | Sending Return to the app resumed the otherwise invisible permission continuation. The two Nanbeige children then overlapped in one local subwave `[2]` with engine slots/configured max `2`, returned ordered `ALPHA`, `BETA`, and the parent produced exact `BATCH DONE: ALPHA \| BETA.` at 55.7 tok/s. The aggregate card settled, Stop disappeared, and input unlocked. This proves the batch execution path but also proves the security defect: an app-wide Return was able to approve a prompt that was not visible or focused. |
| 2026-07-29 02:38 PDT fixed Release UI | `e76fcb6a` + vMLX `84612e14` | Visible `Ask` permission, Allow Once, two same-model Nanbeige workers, parent continuation, terminal unlock, follow-up | PASS LIFECYCLE / FOLLOW-UP CONTENT MISS | The titled `Tool Permission` dialog was visible, centered on the launching app, exposed in accessibility as a dialog, and showed the exact two-job arguments plus Deny/Allow/Always Allow. Clicking visible Allow ran both workers concurrently in one `[2]` subwave (`engine_configured_max=2`, `effective_local_slots=2`, process active high-watermark 1→2); ordered `GAMMA`, `DELTA` succeeded at 8.0 and 10.6 tok/s. Parent exact `FIXED BATCH: GAMMA \| DELTA.` completed at 56.5 tok/s, Stop disappeared, input unlocked, and follow-up completed at 53.4 tok/s. Nanbeige rendered `FLLOW-UP UNLOCKED` instead of the requested `FOLLOW-UP UNLOCKED`, recorded as a model instruction-fidelity miss rather than hidden. Warm process footprint was 1,581 MB (`ps` RSS 1,222,528 KB); L2 restored 4,306/5,409 parent-continuation tokens and 5,405/5,535 follow-up tokens. Permission screenshot SHA-256 `97fd697d884da24f7f3cfd8bfcb23b1abc2e4be91853d7965c9d9ac00283ff71`; settled-result screenshot SHA-256 `c3ae457637f4a04273fa6950b40d365abb0a2e717840a907fd0b6c185b11d5dd`; local-only paths `/private/tmp/osaurus-subagent-batch-e76fcb6a-permission-visible.jpeg` and `/private/tmp/osaurus-subagent-batch-e76fcb6a-fixed-result.jpeg`. |
| 2026-07-29 03:04 PDT fixed Release UI | `e76fcb6a` + vMLX `84612e14` | Main-chat maximum reduced live from four to one; valid two-job array reaches the configured cap | PASS | The visible Limits stepper was changed `4 → 3 → 2 → 1`, and the collapsed summary read `1 per batch`. A clean Nanbeige chat then emitted one real two-item `jobs` array. The expanded `Failed: Spawn batch` card returned `expected: "1-1 jobs"` and `jobs contains 2 items, but this agent allows at most 1 subagents per batch`; neither child loaded. Parent `MAX ONE LIVE VERIFIED.` completed at 56.8 tok/s, Stop disappeared, and input unlocked. The cap was then restored through the same UI `1 → 2 → 3 → 4`, with the collapsed summary reading `4 per batch`. Screenshot `/private/tmp/osaurus-subagent-batch-e76fcb6a-max-one-live.jpeg`, SHA-256 `b65f602b15c711f2c06cdef4f13a37bd086e7764adb080d2ea2e0d5c552f25eb`. |
| 2026-07-29 03:08 PDT fixed Release UI | `e76fcb6a` + vMLX `84612e14` | Server Continuous Batching saved Off with two same-model local jobs | PASS | Server → Settings → Concurrency & Batching visibly resolved `Effective BatchEngine limit: 1 — Continuous Batching is off`, was saved, and remained Off on the live page. One real two-item Nanbeige batch then reported `configured_max_subagents: 4`, `engine_configured_max: 1`, `effective_local_slots: 1`, `limited_by: ["continuousBatchingDisabled", "engineCapacity"]`, and `local_subwaves: [1, 1]`. Ordered `SERIAL-A` and `SERIAL-B` completed at 80.4 and 81.6 tok/s; parent exact `BATCHING OFF: SERIAL-A \| SERIAL-B` completed at 67.7 tok/s and unlocked. Continuous Batching was restored On and saved; the UI returned to effective limit 2 under Memory Safety. Screenshot `/private/tmp/osaurus-subagent-batch-e76fcb6a-batching-off.jpeg`, SHA-256 `f24a56b1cd31ddd304d9516cf6ca69ec1b327244e62ea99ef29ab9b6113b088d`. |
| 2026-07-29 03:11 PDT fixed Release UI | `e76fcb6a` + vMLX `84612e14` | `Batch Worker` with main-chat agent-target override | PASS | With the visible main-chat override still set to Nanbeige, a real `target_type: agent` job resolved `Batch Worker` to UUID `62EE9E42-F2B5-4972-A17B-295EADC2890B` and ran `JANGQ-AI/Nanbeige4.2-3B-JANG_4M` in place (`handoff: false`, `residency_mode: in_place`). The child returned exact `AGENT-OVERRIDE-NANBEIGE` at 67.2 tok/s and the parent completed at 56.7 tok/s. Screenshot `/private/tmp/osaurus-subagent-batch-e76fcb6a-agent-override-nanbeige.jpeg`, SHA-256 `c0a9fbd628a5d55acb5ed12d425c3c7d61d37193fbbd4c3a9e7a4bea17cf83fe`. |
| 2026-07-29 03:20 PDT persistence relaunch | `e76fcb6a` + vMLX `84612e14` | Clear main override to `Use each target agent's model`; different-local agent handoff and parent restore | PASS RUNTIME / PARENT FORMAT MISS | The visible override picker was changed to `Use each target agent's model`. After a graceful same-root relaunch with the exact isolated model directory, the same `Batch Worker` target ran its own configured `JANGQ-AI/Ornith-1.0-9B-JANG_4M`, reported `handoff: true`, `residency_mode: unload_restore`, and one local subwave `[1]`; the child returned exact `AGENT-OWN-MODEL-ORNITH` at 43.9 tok/s. The restored Nanbeige parent remained active and completed a separate exact follow-up `PARENT RESTORED.` at 54.5 tok/s with Stop gone and input unlocked. The immediate parent continuation was coherent but added a verbose success preamble before the requested exact line, recorded as an instruction-format miss rather than hidden. Screenshots `/private/tmp/osaurus-subagent-batch-e76fcb6a-agent-own-model-ornith.jpeg` (SHA-256 `24ce384b2b1d821b6bf1fceb32eba4456c02ed02048adba16a406d2e0dfc92d9`) and `/private/tmp/osaurus-subagent-batch-e76fcb6a-parent-restored-followup.jpeg` (SHA-256 `fe6070534af84fe6f077dad45be3fd6d183790b593818e4363853fb29c3ef16e`). |
| 2026-07-29 03:13–03:23 PDT fixed Release UI | `e76fcb6a` + vMLX `84612e14` | Repeated Settings navigation CPU/lifecycle failure | FAIL — SOURCE FIX REQUIRED | Twice, navigating the real Settings UI left the app permanently at 100% CPU and made its accessibility tree time out: first while returning from Server toward General, then reproducibly after selecting Agents to edit `Batch Worker`. In both cases the main thread remained in a SwiftUI `AttributeGraph` update rooted in `SidebarNavigation.body` / `SidebarItemView.body`; the second process did not recover after more than two minutes. This blocks live editing of the custom agent's own model and is not masked by restarting. Samples: `/private/tmp/osaurus-subagent-batch-e76fcb6a-settings-hang.sample` (SHA-256 `eab06aa7cf3c12c69175b500dac8bc3b574c89c0baae8c3de346c9f343d9c6bc`) and `/private/tmp/osaurus-subagent-batch-e76fcb6a-agents-page-hang.sample` (SHA-256 `6c23e65b397adbde8deb8c72913dd87b54356008137b729176137fb85927382e`). |
| 2026-07-29 03:51 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Settings sidebar accessibility/CPU regression fix | PASS | A fresh isolated Release app exposed every settings sidebar row with valid accessibility frames. General remained at 0.0% CPU at 0/5/15 s; Agents rendered immediately and settled 1.4% → 0.3% → 0.0% at 0/5/15 s. Repeated Agents → Batch Worker → Abilities → Subagents navigation stayed responsive with no accessibility timeout or AttributeGraph loop. The owning fix changes the bounded sidebar row container from lazy to eager construction; focused RuntimePolicy source suite passed 100/100 in `/private/tmp/osaurus-subagent-sidebar-fix-3.xcresult`. |
| 2026-07-29 03:52–03:54 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Custom-agent own-model edit, navigation persistence, relaunch persistence, agent-target execution | PASS ROUTING/LIFECYCLE / CONTENT MISS | `Batch Worker` was changed in the real editor from Ornith to `Laguna-XS-2.1-JANG_4M-CRACK`, showed Saved, survived Chat navigation and a full same-root app relaunch, then executed through its UUID with Laguna, `handoff: true`, `residency_mode: unload_restore`, one local subwave `[1]`, 50.2 tok/s, settled parent UI, and an exact unlocked follow-up at 49.1 tok/s. Nanbeige corrupted the child tool input and the parent missed the requested exact format, so content fidelity is FAIL even though routing/lifecycle pass. Screenshots `/private/tmp/osaurus-subagent-batch-6d621e26-laguna-agent-result.jpeg` (SHA-256 `b763f23200046d41a172b9f36b21a50d1631066058c13a1f5d459906ada955c9`) and `/private/tmp/osaurus-subagent-batch-6d621e26-laguna-followup.jpeg` (SHA-256 `1e2e46504ef9d9d2438b3e95f43e9732adfbfae70cc0a9d1bba0c444332db7a9`). The agent model was restored visibly to Ornith afterward. |
| 2026-07-29 04:01 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Custom-agent own maximum set live to one and enforced by real tool execution | PASS CAP / MODEL BEHAVIOR MISS | `Batch Worker` Abilities → Subagents showed its own allowed Nanbeige/Ornith pool, notes, Ask policy, worker tools, budgets, and `2 per batch`; expanding Limits and changing the maximum `2 → 1` immediately changed the summary and effective local ceiling to one. A fresh Batch Worker chat emitted one valid two-item `spawn_batch`; execution rejected it before child load with `expected: "1-1 jobs"` and `this agent allows at most 1 subagents per batch`. The model then disobeyed the one-call instruction and retried other spawn tools, so the cap is PASS while parent model behavior is FAIL. Screenshot `/private/tmp/osaurus-subagent-batch-6d621e26-custom-agent-cap-one.jpeg`, SHA-256 `5f600fc31ae8500aa49cfcbfbd8a18b9674eeb4deb767b27be821954ceff6f74`. |
| 2026-07-29 04:01–04:13 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Custom-agent direct Spawn Ask/Deny/Allow Once/repeat-prompt ownership | PASS | The earlier exploratory turn persisted `always_allow` at 04:02:14 through the prompt's confirmed Always Allow path; its later direct spawns were therefore authorized and are not a permission bypass. The policy was reset visibly to Ask and the persisted JSON read `ask`. A direct `spawn_model` exposed a titled/focused dialog with the exact target/input; Escape returned `user_denied`, started no child output, settled the failed card, removed Stop, and unlocked input. A second call prompted again; Return allowed exactly one Nanbeige child (`ASK-ALLOW-ONCE-PASS`, 66.6 tok/s), restored the Ornith parent, and completed exact `ALLOW-ONCE-PARENT-DONE`. Persisted policy remained `ask`; a third call exposed the same dialog again and Escape denied it. Evidence: `/private/tmp/osaurus-subagent-batch-6d621e26-ask-allow-once.jpeg` (SHA-256 `2feb07fb3ca91d15c43294a0ee7796f3b3760e7683444fdf34e8268c1264eef4`), `/private/tmp/osaurus-subagent-batch-6d621e26-ask-prompts-again.jpeg` (`d8e66c158ec87a10889a514b574b487895c9025fb9f88ff65501ea249466ce9e`), and `/private/tmp/osaurus-subagent-batch-6d621e26-ask-deny-repeat-final.jpeg` (`eb4ee770665709934b63c34ea5a62e53125e6f600f129e35a8d0d5656db43ac6`). |
| 2026-07-29 04:15–04:16 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Custom-agent Spawn disable/re-enable preservation and maximum restore/relaunch | PASS | Turning Batch Worker Spawn off hid the controls and persisted only `spawnDelegationEnabled: false`; both allowed model IDs, both target notes, Ask policy, worker tools, budgets, and cap one remained in the isolated agent JSON. Re-enabling Spawn immediately restored the same visible rows and notes. Limits was changed live `1 → 2`, the summary and configured same-model ceiling both showed two, and a full app relaunch reopened Batch Worker with Spawn on, Ask selected, the Nanbeige/Ornith pool and notes intact, and `2 per batch`. Screenshots `/private/tmp/osaurus-subagent-batch-6d621e26-toggle-preserve-cap-restored.jpeg` (SHA-256 `b7487a07506b1278a23d686d827d4d5360d797bfea71c322fd3ef7a0acb782c0`) and `/private/tmp/osaurus-subagent-batch-6d621e26-toggle-preserve-relaunch.jpeg` (`8e9e4465a68c4936011a7c5415397ac093ea96b29a24226f8aa6cb67aa19d4ed`). Relaunched app PID 77793 was idle at 0.0% CPU with RSS 1,323,792 KB and ample free memory. |
| 2026-07-29 04:17–04:18 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Restored custom-agent cap two drives a real same-model batch | PASS | From the relaunched Batch Worker, Ornith emitted exactly one disclosed two-job `spawn_batch`; the visible Ask dialog named both Nanbeige jobs and Return granted Allow Once. The expanded terminal result reported `configured_max_subagents: 2`, `max_parallel: 2`, `effective_local_slots: 2`, `engine_slots: 2`, `ram_slots: 21`, one local subwave `[2]`, `residency_mode: unload_restore`, ordered exact `RESTORED-CAP-A`/`RESTORED-CAP-B`, 2/2 success, and parent exact `RESTORED-CAP-TWO-DONE` at 54.7 tok/s. Stop disappeared and input unlocked. Child rates were 26.0 and 21.8 tok/s. Post-row process physical footprint was 2,619 MB with 4,327 MB peak. Permission screenshot `/private/tmp/osaurus-subagent-batch-6d621e26-custom-cap-two-permission.jpeg` (SHA-256 `8dad72f1915fce2eaf3998585b7d8a93dc1388d8e0c30a82590b65d6f33fe862`); settled-result screenshot `/private/tmp/osaurus-subagent-batch-6d621e26-custom-cap-two-result.jpeg` (`a1e11efc433d158f55dcd1ca762e0fb03adb4767398e21c650380c1558c39be6`). |
| 2026-07-29 04:19–04:20 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Different-local bare-model waves, ordered gather, parent restore/follow-up | PASS | One Batch Worker `spawn_batch` disclosed Nanbeige then Ornith model jobs. The scheduler safely ran two one-job model waves (resident Ornith first as `in_place`, then Nanbeige as `unload_restore`) instead of overlapping distinct Metal engines, while the returned results preserved caller order. Exact child summaries were `DIFFERENT-A-NANBEIGE` at 65.9 tok/s and `DIFFERENT-B-ORNITH` at 48.3 tok/s; aggregate 2/2 succeeded, parent exact `DIFFERENT-MODELS-DONE` completed at 54.5 tok/s, and a separate exact parent follow-up `DIFFERENT-MODELS-FOLLOWUP` completed at 54.0 tok/s with terminal controls unlocked. Post-row physical footprint was 2,622 MB with 4,329 MB peak. Screenshots: permission `/private/tmp/osaurus-subagent-batch-6d621e26-different-models-permission.jpeg` (SHA-256 `3ed3cc5946988070743c2d86d2871844f45fd6095430e3a80475b8491a8e5a04`), expanded result `/private/tmp/osaurus-subagent-batch-6d621e26-different-models-result.jpeg` (`ba7d543c17f5cbadc757739e7fba4156f4246227c91782ab2aa9c8313424776b`), and follow-up `/private/tmp/osaurus-subagent-batch-6d621e26-different-models-followup.jpeg` (`21cb6fe9b48c620a6646a000be295662f26f71dc7fd96717b41db81d69d62c74`). |
| 2026-07-29 04:27–04:32 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | OpenAI-compatible provider add/test/discovery, allowed-model assignment, notes, and relaunch persistence | PASS WITH KEYCHAIN-FREE RECONNECT CAVEAT | Through Settings → Providers, a no-auth custom provider named `Proof Remote Emulator` was configured as `http://127.0.0.1:18081/v1`; the visible Test Connection found one model and the Providers page reported it Connected. The Batch Worker model picker exposed `proof-remote-echo` under the provider, it was added with note `Deterministic remote provider proof`, and the stable persisted target was `remote-provider:25e2d6b6-9a8e-47cb-9f8a-e5665bcfe5e4/proof-remote-echo`. A full same-root relaunch preserved the provider, target, note, Ask policy, and cap two. Because this isolated app was deliberately launched with keychain disabled, providers began disconnected; visibly clicking the emulator's Reconnect restored one discovered model and changed the saved target from `Unavailable` back to `proof-remote-echo Proof Remote Emulator`. No Codex auth file or credential was read or copied. Screenshots: provider connected `/private/tmp/osaurus-subagent-batch-6d621e26-provider-emulator-connected.jpeg` (SHA-256 `dd403be0b81ebec73d6c0270d46f3511fcee432b95cd3eb4c94b16afd31fd478`), assignment `/private/tmp/osaurus-subagent-batch-6d621e26-remote-model-assigned.jpeg` (`c103189e2bd48b3bda24f5562a4f88cc57537d65a6e52be36e7ca3118d201ad6`), and relaunch restore `/private/tmp/osaurus-subagent-batch-6d621e26-remote-model-relaunch-restored.jpeg` (`5e1bba9eb8d32c7c9613ab3aaf5bef44edd633e5e7b84a789c32a8e3b8f7608c`). |
| 2026-07-29 04:33–04:34 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Mixed local/provider batch, ordered gather, parent continuation, terminal follow-up | PASS RUNTIME/LIFECYCLE / PARENT FORMAT MISS | The real Batch Worker emitted one disclosed two-job `spawn_batch` in caller order: Nanbeige local `A` and stable remote-provider target `B`. The Ask dialog exposed both exact targets and inputs. One admitted execution wave reported `configured_max_subagents: 2`, `max_parallel: 2`, `local_jobs: 1`, `remote_jobs: 1`, `effective_local_slots: 1`, `engine_slots: 2`, `ram_slots: 21`, local subwaves `[1]`, and `residency_mode: unload_restore`. Ordered exact child summaries were `MIXED-LOCAL` at 65.2 tok/s and `MIXED-REMOTE` at 604.9 tok/s; the remote envelope reported 0.0053 s and the emulator log independently recorded the `/v1/chat/completions` POST. Aggregate status was 2/2 succeeded. The parent was coherent and included `MIXED-PARENT-DONE` but added an explanatory sentence, recorded as an instruction-format miss; a separate follow-up returned exact `MIXED-FOLLOWUP-PASS` at 50.3 tok/s with Stop gone and input unlocked. Post-row process physical footprint was 2,635 MB. Screenshots: permission `/private/tmp/osaurus-subagent-batch-6d621e26-mixed-local-remote-permission.jpeg` (SHA-256 `bc6459fe5294d785246cb68834b1909e0a37eed5fbf60061279ec5a66aa9bb9a`), expanded result `/private/tmp/osaurus-subagent-batch-6d621e26-mixed-local-remote-result.jpeg` (`118fe0f7ab316434a578d96548b89a8845434c5f79033ad79bc29173c7c31442`), and follow-up `/private/tmp/osaurus-subagent-batch-6d621e26-mixed-local-remote-followup.jpeg` (`55d71c10713ee6682183cbd97681c7c05be729d4ca4c91949d4c182babeb7dbe`). This is explicitly a deterministic local OpenAI-compatible provider-emulation row, not an authenticated public-cloud claim. |
| 2026-07-29 04:36–04:49 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Stop during active remote child/provider stream | PASS CANCELLATION/LIFECYCLE / FOLLOW-UP CONTENT MISS | The provider emulator held the child stream for 30 seconds. Clicking the visible parent Stop immediately settled the card with `Subagent 'remote-provider:…/proof-remote-echo' was cancelled with the parent run`; the provider then hit a broken pipe, independently proving that Osaurus closed the active stream socket rather than only hiding UI. Stop disappeared and input unlocked. The next turn completed at 50.3 tok/s but repeated the prior requested token instead of the new exact token, recorded as a model content-fidelity miss. Screenshots `/private/tmp/osaurus-subagent-batch-6d621e26-cancel-active-remote.jpeg` (SHA-256 `feec87f574401a18b777e6169babfc62bc43a9c3415eeb72383248c32f65fe8c`) and `/private/tmp/osaurus-subagent-batch-6d621e26-cancel-active-remote-followup.jpeg` (`773e65dcb6e58f0ce79a084ea66a0868385f7578737cbb38338f0eeedad0a4d8`). |
| 2026-07-29 04:42–04:44 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Continuous Batching off; Stop cancels active local child plus queued-before-start child | PASS | The saved server UI showed Continuous Batching Off. The disclosed two-job Nanbeige batch reported `engine_slots: 1`, `limited_by: [continuousBatchingDisabled, engineCapacity]`, and local subwaves `[1,1]`. Clicking Stop while job one was active produced its honest `cancelled with the parent run` error; job two returned `cancelled: true` and `Batch job was cancelled before it started.` Aggregate status was `all_failed`, zero success/two failed/one queued cancellation. Stop disappeared, input unlocked, and exact follow-up `QUEUED-CANCEL-FOLLOWUP` completed at 74.8 tok/s. Continuous Batching was then restored On and the visible effective limit returned to two. Screenshots `/private/tmp/osaurus-subagent-batch-6d621e26-cancel-active-and-queued-local.jpeg` (SHA-256 `85bf90c32d543476b5dd0b1b8679b8324307d69a1f61a487a6f94bf364def5be`) and `/private/tmp/osaurus-subagent-batch-6d621e26-cancel-active-and-queued-followup.jpeg` (`d0e0ab1e737b880e252b24cee8bdd2d6d2d42b015565738eadbcefa0041d87c2`). |
| 2026-07-29 04:47–04:49 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Stop during parent continuation after successful child | PASS | The remote child completed exact `POST-CHILD-READY` in 0.0042 s at 1,138.3 tok/s. The parent then visibly began a long continuation while its Stop control remained available. Clicking Stop ended only the parent continuation after 34 tokens at 10.7 tok/s, preserved the settled successful child card, removed Stop, and unlocked input. A separate exact `PARENT-CANCEL-FOLLOWUP` completed at 53.5 tok/s. Screenshot `/private/tmp/osaurus-subagent-batch-6d621e26-cancel-parent-after-child.jpeg`, SHA-256 `85c3b5c44ba59af4163a1521bb462381432e0ae2c54db157ecc9582406d7ade1`. Together with the Ask/Escape no-child row above, this completes visible approval, active, queued, and post-child parent cancellation coverage; automated cancellation suites retain the phase-specific preparation/admission/prefill/decode guards. |
| 2026-07-29 04:52–04:59 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Strict custom RAM policy and pre-side-effect dense-model refusal | PASS | Server RAM Safety was changed live from the normal resolved 60% load budget to a custom 10% (`~12.8 GB`) and saved. A routed Ornith 35B JANG_4M child still ran coherently at 12.9 tok/s because its effective active working set fit; this was correctly not misreported as a refusal. A separate dense Ornith 35B MXFP8 request was refused before child output or model load with `Estimated request working set ~42.7 GB exceeds the selected ~12.8 GB load budget`; the parent settled and exact `RAM-REFUSAL-FOLLOWUP` completed at 53.6 tok/s. Post-refusal process physical footprint was 2,563 MB. The custom override was cleared through the real UI, which visibly restored `Load 60%`; both temporary 35B targets were removed from the agent pool, the isolated app was stopped, and only the two temporary APFS clones were moved to recoverable Trash paths while the original `/Users/eric/models` bundles remained untouched. Screenshots: 10% setting `/private/tmp/osaurus-subagent-batch-6d621e26-ram-strict-10-percent.jpeg` (SHA-256 `d49ae7bf78662bf9936753353257c77a61c6520c6011a78bc1e44d293e16400d`), target pool `/private/tmp/osaurus-subagent-batch-6d621e26-ram-target-allowed.jpeg` (`37c23a3cf4c18c4a846d982abe3bbba04418bbe1b3b166be1857e575e4529351`), refusal `/private/tmp/osaurus-subagent-batch-6d621e26-ram-strict-refusal.jpeg` (`d8b890855434d59b262524115c71bd0435d8d240bc33ebcb6e5427eb412ea257`), and follow-up `/private/tmp/osaurus-subagent-batch-6d621e26-ram-strict-refusal-followup.jpeg` (`64af17d531983e36c5bf1591ce8ea2ab36bd17b9eba2d700abe2d42cfc1ddb7a`). |
| 2026-07-29 05:05–05:09 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Thinking on; reasoning → tool → reasoning → tool → reasoning → final; follow-up | PASS LIFECYCLE / PARENT FORMAT MISS | The model picker was changed live from Thinking Off to On. The resulting turn exposed three closed reasoning cards around two separately approved, settled Nanbeige subagent cards in the required order. Both children returned exact `THINK-TOOL-ONE` and `THINK-TOOL-TWO`; the parent produced a coherent final containing `THINK-INTERLEAVED-DONE` but added a short summary line, recorded as an instruction-format miss. No raw `<think>` content or protocol debris leaked into the final. Stop disappeared, input unlocked, and exact `THINKING-ON-FOLLOWUP` completed at 55.4 tok/s with its reasoning card closed. Screenshots `/private/tmp/osaurus-subagent-batch-6d621e26-thinking-interleaved.jpeg` (SHA-256 `8e4c30e37a1e8bd73c5c803b6fe5043be654858047dadbb5ce1abcf97e817457`) and `/private/tmp/osaurus-subagent-batch-6d621e26-thinking-on-followup.jpeg` (`f02a9d5526e69633ac0d1ebaa5a940f8566cf90e1e7f10917a27aa4db3c7b75f`). |
| 2026-07-29 05:10–05:13 PDT fresh fixed Release UI | `6d621e26` + vMLX `84612e14` | Thinking off; exact child, exact final, exact follow-up, no reasoning UI | PASS | Thinking was changed live back to Off. In a clean chat, the visible Ask dialog exposed exact `OFF-CHILD-20260729`, the Nanbeige child returned that exact summary at 67.7 tok/s, and the parent returned exact `OFF-FINAL-20260729` at 55.4 tok/s. The turn contained no reasoning card. Stop disappeared, input unlocked, and exact `OFF-FOLLOWUP-20260729` completed at 55.7 tok/s without tools or reasoning UI. The expanded result also reported normal handoff/restore and cache telemetry (`disk_l2_misses: 8`, `disk_l2_stores: 3`) rather than a separate spawn cache implementation. Screenshots `/private/tmp/osaurus-subagent-batch-6d621e26-thinking-off-tool.jpeg` (SHA-256 `88b23eb3b09633d80fdf498d1ac21e368bcb62e5b57a2fbb1f917108247e6e71`) and `/private/tmp/osaurus-subagent-batch-6d621e26-thinking-off-followup.jpeg` (`3f5e8b7727397a6c972a017f602f570317f488c2d3ae4ea56209a24e04158f25`). |
| 2026-07-29 06:33–07:11 PDT exact post-rebase freeze | `c317e0f0` on `09a3dee9` + vMLX `84612e14` | Full Core, full Evals, i18n, Release build, changed model-discovery/settings surface, save/relaunch | PASS | Upstream PR #2219 changed only the OsaurusAI fetch cap; all 13 campaign patches are range-diff identical. Core passed 7,311/7,332 with 21 skips and zero failures; Evals passed 299/299 across 36 suites. The final localization-only source delta passed the i18n catalog/reference/literal gate. The fresh ad-hoc keychain-free Release bundle passed strict deep code-sign verification. Computer Use exposed 61 local models, assigned Nanbeige JANG_4M, persisted its note, changed the batch maximum 3→2, and re-proved target/note/Ask/tools/limit/handoff/RAM-Safety after relaunch. The isolated proof app was quit and production Osaurus was untouched. |
| 2026-07-29 final upstream rebase | `033eb498` on `af68b064` + vMLX `84612e14` | Full Core/Evals/Release build followed by General -> Server UI navigation | FAIL LIVE / AUTOMATED PASS | Core passed 7,311/7,332 and Evals 299/299, but the exact Release app blocked in `SecItemCopyMatching` from `RelaysSectionView.body` during General -> Server navigation. Sample SHA-256 `5997d856076637dd93118276eac5bd820000de7f98cc728179136e1fca293c0e`; merge was stopped pending an owning-layer fix. |
| 2026-07-29 final relay fix | `315f1f63` on `af68b064` + vMLX `84612e14` | Background relay identity, full Core/Evals, exact Release build, Settings navigation/relaunch/restore | PASS | Both automatic relay-identity call sites now use the detached Keychain helper. Focused source contracts passed 101/101, Core 7,312/7,333 with 21 skips, Evals 299/299, and strict deep code signing passed. Computer Use proved responsive General -> Server -> General, quit/relaunch persistence, and restoration through the UI to the measured shared defaults of three-per-batch plus RAM-Safety off. Production Osaurus remained running. |
| 2026-07-29 final PR #2222 base move | `ebdd2293` on `f013ccc7` + vMLX `84612e14` | Patch-identical rebase, full Core/Evals/i18n, exact Release build, Settings navigation/relaunch/restore | PASS | PR #2222 touched only chat-import UI and localization. Core passed 7,312/7,333 with 21 skips, Evals 299/299, i18n passed, and strict deep code signing passed. Computer Use proved 3->2 plus RAM off->on, responsive General -> Server -> General, quit/relaunch persistence, and UI restoration to 3/off. Shared config returned to its original hash; the isolated app quit and production Osaurus remained running. |
| 2026-07-29 exact-pin model gate | `ebdd2293` + vMLX `84612e14` | Nanbeige registration/two-loop cache slots, chunked prefill, reasoning and tool parsers | PASS | Exact dependency checkout passed Nanbeige 6/6, chunked prefill 9/9, and reasoning/tool parsers 139/139. The final runs used the packaged Cmlx metallib after two explicitly recorded terminal-runner resource failures. No product assertion failed. |

## 2026-07-29 post-merge shared-concurrency follow-up

This follow-up starts from merged PR #2221 and is intentionally separate from
the proof rows above. Its exact pre-fix checkpoint is Osaurus
`4d83b440e435695ca9653472597996d275dc1d92` with vMLX
`84612e143d2e51da865316dbc49167530a1717ad`.

Two new findings were recorded before changing their owning fixtures or
runtime:

- **BATCH-28 — different-local eval fixture omitted the canonical server
  limit.** `agent_loop.spawn-batch-two-different-local-workers` configured the
  legacy per-agent mirror as two but did not configure
  `fixtures.runtimeConcurrency.maxConcurrentSequences`. After unifying the
  product to one server-owned limit, the isolated eval inherited the default
  limit of one and honestly rejected the two-job call before handoff. The
  fixture must set the production server value explicitly, as the same-model
  row already does; changing product admission to consult the stale mirror
  would reintroduce two sources of truth.
- **BATCH-29 — Nanbeige parent final duplicated once after a successful
  same-model batch.** The runtime contract passed (one call, two simultaneous
  slots, ordered settled children, `max_parallel=2`, parent finalization), but
  the visible final paragraph was emitted twice. This is a content/lifecycle
  failure until repeated exact-source runs and the Release UI determine
  whether it is stable model output or a runtime continuation regression. It
  must not be hidden by prompt coercion, sampler overrides, output
  deduplication, or parser masking.
- **BATCH-30 — headless AgentLoop omitted parent model/Thinking task-local
  scope and Chat inference provenance.** Even after BATCH-28 was corrected,
  the different-local row was rejected because `AgentLoopEvaluator` bound the
  agent id around the loop but not `ChatExecutionContext.currentModelName`,
  `currentEnableThinking`, or `currentSessionSource`. It also constructed its
  `ChatEngine` with the default HTTP provenance while this suite claims the
  in-app Chat contract. Production chat publishes all three task locals and
  constructs the engine from the session's inference source. The spawned tool
  therefore saw Nanbeige as unrelated protected HTTP work and could not
  exercise handoff/restore. The eval harness now binds `.chat`, constructs the
  engine with `.chatUI`, and publishes the exact parent model and explicit
  Thinking value. Residency ownership remains fail-closed for real unrelated
  API/plugin/scheduled work.
- **BATCH-31 — equal-value Spawn edits could leave Server concurrency in
  Automatic.** The Server controller compared an explicit Spawn-editor request
  against the *resolved* Automatic capacity. If both displayed the same number,
  it treated the edit as a no-op and left `maxConcurrentSequences` nil, despite
  the UI contract that an explicit Spawn edit owns and persists that number.
  The controller now compares the raw optional override. General-settings
  notification mirrors are separately gated against their loaded baseline, so
  Server -> Spawn synchronization cannot accidentally materialize Automatic.
- **BATCH-32 — legacy prompt/schema fallback read the stale Spawn mirror.** A
  production `AgentConfigSnapshot.capture(...)` already freezes the canonical
  Server-owned limit, but hand-built or legacy snapshots without
  `spawnConfiguration` recomputed `spawn_batch` guidance and `maxItems` from
  `SubagentConfiguration`. Both fallback sites now resolve the shared limit
  from `ServerRuntimeSettingsStore`; a regression test holds the mirror at
  seven and the Server at two and requires both prompt and schema to advertise
  two.

Fresh evidence at this checkpoint:

| Row | Result | Evidence |
|---|---|---|
| Full Core | PASS | 7,324 passed, 21 skipped, 0 failed; `/private/tmp/osaurus-shared-concurrency-full-v3.xcresult` |
| OsaurusEvals harness | PASS | 299/299; log SHA-256 `2b542fd61ba761764546a46d7e29f5602203f7699ad3ee3ac6d4b932af5eeb2a` |
| Deterministic eval floor | PASS | 101/101; log SHA-256 `ef061682f87ffd5fcef935fee91941e47869870564d3300a8342d50258eaf4a5` |
| Pinned vMLX Nanbeige/parser/cache | PASS | Nanbeige 6/6, reasoning/tool parsers 119/119, mode isolation 9/9, cache coordinator 13/13, cache topology 42/42 |
| Nanbeige disk-L2 longest prefix | PASS CACHE / CONTENT PARTIAL | Paged RAM off; turn 2 restored 301/730 tokens, turn 3 restored 729/730 from disk; L2 +2 hits/+9 stores, 72.5 tok/s, 1,808 MB peak. Turn 2 stopped at the 256-token cap, so this row proves cache selection and accounting but not exact-answer fidelity. Report SHA-256 `4bcd26ebaae3d386efbb3e9b370ed391f8972c2f9c4f99a9967f36c813330a91`. |
| Full Nanbeige AgentLoop | PARTIAL | 40 total: 24 passed, 13 failed, 3 skipped. The same-model batch runtime row passed; the different-local fixture hit BATCH-28; the same-model final exposed BATCH-29. Report SHA-256 `116da099329bc9cbf7e50080010dc9b1850f4fe693d43c003843f30cb42ac9eb`; log SHA-256 `8eb8fb6fdebb69d784da66fafb38dc9fb0baf12a64b1ba3effe405870d4bc9ab`. Self-judge failures are retained and are not release-pass claims. |
| Eval Chat-context source contract | PASS (automated only) | 101/101, zero failures/skips; `/private/tmp/osaurus-shared-concurrency-eval-context-v2.xcresult`; log SHA-256 `b3259efda1f9a608f47e90e83eea67f3f36e022dc12a2ccbb817f1a90e10d295`. The focused source contract requires the same Chat inference provenance, parent model, and Thinking value used by the live Chat surface. |
| Spawn-batch fixture/scorer | PASS (automated only) | 11/11; log SHA-256 `bd0b4327321ffe5bfd97778a6ed968c2225010820d2091178e24abca46dfd29b`. The different-local fixture now declares Continuous Batching on and canonical server maximum two. |
| Different-local Nanbeige -> Ornith handoff/restore | PASS (model-backed) | One `spawn_batch`, two ordered successes, `max_parallel=2`, two serialized one-job local waves, Nanbeige parent restored, no tool errors; 30.5 tok/s, TTFT 4.871 s, peak physical footprint 3,883 MB, disk-L2 +1 hit/+1 store. Report SHA-256 `3f4c3483614699403bb9aa40d86710d925bf724c22eff3850003071df7ab5e55`; log SHA-256 `eaff0b4d539e25f061a3e1103681fa4362f7f55493b22c9e399db267447d2e5c`. |
| Same-model concurrent batch repetition | PASS RUNTIME / BATCH-29 LIVE UI PENDING | The aggregate repeat passed 3/3 and three separately persisted trials also passed: one call, two concurrent child slots in one `[2]` subwave, ordered 2/2 settlement, no tool errors, cache available, and one non-duplicated parent final in each retained trial. Aggregate report SHA-256 `423cbf880e4e220e8037e0a9ee6db1ec14a5f639e6317431b44405fc1677e07c`; individual report hashes `876755aca315e8f1608163227948da81109994163d06069ff4d7523aaa9eee33`, `5e13865f85a67b72904790f2f234f88fc59063ea6e40e0a0fc02ed440cb89f95`, and `920bee23c41d566ff6789cfb45baf91c298b0caba786758027910c17fcf10b40`. The earlier duplicated final remains a real recorded occurrence; six clean current-source trials do not replace the required Release UI lifecycle row. |

### Final follow-up freeze — `cf97cedd`

The follow-up was tested at behavioral SHA
`cf97ceddfc5250c28fe6ee5d78e34df3f45f5662`, then rebased patch-identically
onto Osaurus `a83f667f944fcea918141b743348f5d27aa6c4d0` as current behavioral commit
`f08d660fc49f96f1d87125190f4c2818bcbd2640`. `git range-diff` matched all ten
product/eval commits exactly; the final proof-only commit changed only to record
the new base. The sole new upstream commit only added `docs/appcast.xml`, so no
product source, configuration, dependency, or test changed and the matrix was
not rerun. All four Osaurus dependency surfaces resolve vMLX Swift
`439f53694f3d630663e97612c264ae73e499121a`; the visible serialized
prefill/completion and SMELT controls remain removed, and the unused SMELT
runtime policy remains disabled rather than being represented as active.

Current-SHA automated evidence:

| Row | Result | Evidence |
|---|---|---|
| Focused concurrency/settings/runtime suites | PASS | 167/167 across 5 suites; `/private/tmp/osaurus-shared-concurrency-focused-cf97cedd.log`; SHA-256 `2b4ceea9f247c42f6823666f4bd6290fd9f27436602d0bed1d079f171c085759` |
| Full OsaurusCore package | PASS | 7,104/7,104 across 786 suites; `/private/tmp/osaurus-shared-concurrency-full-cf97cedd.log`; SHA-256 `b32586343b17b54f871d90dd0cfd9268240e99463d9ed47aaa63efbc9c4aea63` |
| Full deterministic OsaurusEvals harness | PASS | 299/299 across 36 suites; `/private/tmp/osaurus-shared-concurrency-evals-harness-cf97cedd.log`; SHA-256 `b5c6e5c8884aa5e6fd13344cec4323116cd9a808ba6e9c80b6c35e6c2ea9e505` |
| Deterministic delegation floor | PASS | 101/101; `/private/tmp/osaurus-shared-concurrency-evals-deterministic-cf97cedd.log`; SHA-256 `b49f2b4241dd7f949515917d13ca2ebf31bd597e4d56d248a4cddcb1259b4c2c` |
| Exact-pin vMLX model registration, prefill, parsers, isolation, and cache | PASS | Nanbeige 6/6; chunked prefill 9/9; reasoning/tool parsers 335/335; mode isolation 9/9; cache coordinator 13/13 plus quota; cache topology 42/42; general cache 105/105; paged/disk 19/19. Log SHA-256 values respectively: `9224bca94b818b2d78cd179e089b736f11e00787e2c0e9ba2f7c4135b86d4196`, `2d9423004a1f2b9a2c8c2e85146b404867d10a02f8522533c9da224a304893d7`, `88d59c126db8d5d1345863dcf0cc8a2c4e26cbe6a2ce0420382babc8f7a1e16d`, `4ef058ab22389c0f020105536f7830ef098ca30059de3adca22c7047f38bd243`, `74f03a75b5fd008bf3ef5db0199955ca4c806b2e1a84c26337db1ec8a0eb1` plus quota `b8ed7c927159c196e68c12a8214f5b336e5377c5eb5bd70582191394075a2b20`, `c8b1f5e402769a19a520465daffafbb7d969c6cf328be949c9fbfb6362b29070`, `02a7888892b429b712979bc0e4e12f11fe27f1f4f1dbb54151eb3b9344096484`, and `e9b70c74e06ada5b3e98b257862697e22e9c91c97fb61fe676e9bb8974da1390`. |
| Full current-SHA model-backed AgentLoop | BLOCKED — evaluator registration setup | 40 cases: 1 passed, 36 errored before model execution, 3 skipped. Every attempted model row reported `Model 'JANGQ-AI/Nanbeige4.2-3B-JANG_4M' is not installed or registered with any provider.` Report `/private/tmp/osaurus-shared-concurrency-evals-model-cf97cedd/cf97cedd-AgentLoop.json`, SHA-256 `2f185b6695624b3dbdec87ac98b4248d262ccedd907b008a8cb11b3e34455023`. |
| Full current-SHA model-backed AgentLoopFrontier | BLOCKED — evaluator registration setup | 39/39 errored before model execution with the same registration error. Report `/private/tmp/osaurus-shared-concurrency-evals-model-cf97cedd/cf97cedd-AgentLoopFrontier.json`, SHA-256 `0637f37fe7a825b979de205bcbe08dc667d9c443edc0fc6d7560f30a2ed97610`. Combined raw log `/private/tmp/osaurus-shared-concurrency-agentloop-frontier-cf97cedd.log`, SHA-256 `6bed9da340e35428290297ffac7c574dd8dc3d14531f10de6f86473e2cc12cd6`. This is not counted as a pass and was not rerun. |

The exact Release development app was built from `cf97cedd` at
`/private/tmp/osaurus-batching-ui-cf97cedd-DerivedData/Build/Products/Release/osaurus.app`.
The build log SHA-256 is
`4e9183300222542ed9b0161083a02e9d7658439e3303336765f1ac3042f4d07a`,
the executable SHA-256 is
`4a2acdd5034d587372a8619236b71f8c6fac2dcc3f50b3586ab1dd9a2cb06512`,
strict code-sign verification passed, and the CDHash is
`907ccd94e09bd8a9a1add9b1d1e8aad0f578db54`. It ran under an isolated test
root with the real local model directory and keychain disabled; the installed
production app was not modified or stopped.

Current-SHA live Release-app evidence:

| Row | Result | Evidence |
|---|---|---|
| Shared Settings authority and persistence | PASS | Spawn maximum `2 -> 3` immediately changed Server Concurrent Sessions to 3; Server `3 -> 2` immediately changed the Spawn summary to 2. Save, navigation, and relaunch preserved the canonical value. `Always Allow` also persisted. Key screenshots `04`, `05`, `06`, and `07` in the manifest below. |
| Same-model local batch | PASS | Two Nanbeige workers completed with exact ordered results in one concurrent wave. Telemetry reported configured, engine, and effective capacity 2 with process active high-watermark 2; the parent and a separate follow-up completed exactly, Stop disappeared, and input unlocked. Key screenshots `10` and `11`. This closes BATCH-29 for the affected Release UI lifecycle without output masking. |
| Different-local handoff/restore | PASS | Nanbeige -> Ornith -> Nanbeige ran as honest serialized local waves, returned exact ordered results, restored the parent model, completed the parent, and completed an exact separate follow-up. Key screenshots `16` and `17`. |
| Provider discovery and mixed local/remote batch | PASS — localhost emulator | The no-auth OpenAI-compatible localhost provider connected and exposed `proof-remote-echo`. One Nanbeige plus one remote child returned exact ordered results; the parent and follow-up completed exactly. This proves the provider contract without claiming authenticated public-cloud coverage. Key screenshots `18`, `19`, and `20`. |
| Stop during active remote child | PASS | A deliberately delayed 60-second remote child was visibly active when parent Stop was clicked. The tool settled with `cancelled with the parent run`, `retryable:false`; Stop disappeared, input unlocked, and the next turn completed exactly. Key screenshots `22` through `25`. |
| Strict RAM-safety refusal | PASS | Custom Strict 10% was saved. A first 35B target that fit was correctly admitted rather than falsely refused; the larger HY-3 request was then rejected before load because it needed about 130.5 GB with about 78.7 GB available after freeing the chat model. Loaded-model count remained 1 before/after; the card settled and the follow-up completed exactly. Key screenshots `27`, `29`, `30`, `31`, and `32`. |

The live evidence directory is
`/private/tmp/osaurus-batching-ui-cf97cedd-evidence`; its 32 JPEGs are listed
in `SHA256SUMS.txt`, whose SHA-256 is
`b2eb1e2eaa8687319ef0b1640f39dc20459cce6b418315f5524e4587fd5dd8a7`.
Images are local evidence only and must not be uploaded to the repository.
The first non-hermetic launch omitted the keychain-disable environment and a
follow-up spent time in `SecItemCopyMatching`; the correctly isolated repeat
passed. The diagnostic sample is
`/private/tmp/osaurus-batching-ui-cf97cedd-followup-hang.sample.txt`, SHA-256
`cba9cbb36ef56f8be46305d763bbb55cf4c9ec152f7a89f938c4de1282619639`.

The reported Ornith database/tool-output exclamation-loop transcript remains
documented as open and unreproduced in
`GEMMA_BONSAI_EMERGENCY_PROOF_2026-07-15.md`; it is not silently counted as
fixed by this concurrency follow-up. The existing cache/parser/prefill rows
above remain separate evidence: this follow-up did not introduce a second
spawn cache and does not infer longest-prefix restoration merely from a UI
color or a setting toggle.
