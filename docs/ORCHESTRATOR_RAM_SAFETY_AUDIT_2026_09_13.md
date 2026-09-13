# RAM admission audit after the actual 16 GB failure of #2733

**Reporter reproduction remains unresolved.** This audit found a demonstrable
measurement defect plus four reproducible cross-function policy defects. The
implementation follow-up below supersedes the original source-only status. [PR #2752](https://github.com/osaurus-ai/osaurus/pull/2752) is draft; no new PR is merged,
and the original M4/16 GB acceptance rows are not claimed to pass.

Base: Osaurus `a609acdb5`; engine pin
`67ccb4b347a23820b838a98f0c195b0c29c676d2`. The earlier #2733 proof used engine
`74103982a292a5037e82acca6f35b72dc1e75ea7`. SwiftPM was resolved to the current
pin before the new regression runs. The relevant KV-policy behavior exists in
both revisions; the Cmlx source trees are identical between these pins.

Evidence root: `/Users/eric/vmlx-private-evidence/ram-admission-2026-09-13/`.
Local machine: macOS 26.4 / 25E246, Darwin 25.4.0, 128 GiB. The reporter's
machine is M4/16 GB and a different OS version. The implementation follow-up
now includes real exact-bundle generation and a native Release UI campaign
on the local 128 GiB host. These are separate from the controlled 16 GiB
policy regressions and do not qualify the actual reporter machine.

## Implementation follow-up (local, not yet merged)

The user authorized implementing the audit findings and testing locally. The
working branch now additionally separates total engine capacity from new
submission width; drains siblings and replans when aggregate reservations
cannot safely be reconciled with current host headroom; enforces the exact
prepared prompt plus effective output-token allowance before BatchEngine
submission; removes the soft KV default as a hard pricing ceiling; counts
Gemma E2B's actual KV owners and global head dimensions; preserves unknown
host samples; cancels parked memory recovery from child-card Stop; and removes
hypothetical disk-size credit from handoffs.

The handoff has two checks: physical feasibility before unloading, followed by
actual host headroom after releasing the exact parent. Failure at the latter
check runs the existing parent restoration path. Optional volatile paged/SSM
cache tiers are released only after the exclusive GPU gate drains, preserving
model weights and persistent disk entries. Admission still resamples rather
than adding a guessed byte credit.

Host-reservation accounting remains deliberately conservative: we do not have
per-request materialized allocation telemetry. The correction waits under the
existing exclusive lane and measures again instead of pretending that every
reserved byte is already allocated. This may serialize tight-memory overlaps;
it preserves normal batching when the full reservation fits.

Verification of memory implementation `3224aefe7`:

- Final affected Core matrix: **523/523 in 48 suites**, explicitly serialized
  (`--no-parallel`). Two earlier combined parallel runs exposed shared-setting
  and path-alias test interference; their failed logs are preserved. Isolated
  failing suites and the complete serialized matrix passed.
- Eval harness: **346/346 in 42 suites**, including a new exact child-summary
  assertion. A parent's failure explanation echoing a marker cannot pass it.
- CI caught the new batching-off case missing from the committed catalog;
  the entry was added. A local full-harness rerun then reproduced 25 assertion
  issues when scripted scenarios concurrently changed global delegation
  settings. `SubagentEvalTests` now serializes scenarios; individual batch
  tests retain concurrent child execution and overlap assertions. The final
  full harness, with other suites still parallel, passed **346/346**. Both
  failing logs are preserved. These are test-only corrections after the
  final Release runtime; no model output or runtime rule was changed.
- Exact Gemma tokenizer/runtime boundary: **2/2 over-budget calls refused
  before prefill**, 20,008 actual prompt tokens plus 2,048 output against an
  11,596-position contract. Both immediate follow-ups returned exact markers,
  31.68/31.66 tok/s, peak physical footprint 470.63 MiB, active/pending zero.
- Real Metal allocator recovery: **2/2 tests** including parameterized drain
  cases. A 64 MiB freed-buffer cache drained to zero; live arrays remained.
  Cancellation while another producer held the GPU gate did not free its cache.
- Original targeted live run: single-child **3/3**, sequential pair **3/3**,
  native batch admission **3/3** with observed width two. Strict batch content
  was only **2/3**: the first parent expanded the marker task and a child's
  failure explanation was incorrectly accepted by the old contains grader.
  Original JSON and manual correction remain preserved; the stricter rerun is
  recorded separately, never substituted for this failure. The stricter rerun
  passed both single/sequential cases 3/3, but native batch exact content only
  **1/3** despite all three admitting both children at width two.
- The architecture-capped serialization suite was mistakenly run against
  Gemma, which supports width two: **0/3**, preserved. It expects an actual
  architecture cap of one and cannot serve as a batching-off control. A
  separate `AgentLoopBatchDisabled` fixture now sets Continuous Batching off
  explicitly. Its first run exercised width one and `[1,1]` subwaves, but the
  test expectation omitted the `continuousBatchingDisabled` diagnostic; that
  failed run is preserved. The corrected fixture passed **3/3**, including
  exact child summaries, engine width one and `[1,1]` subwaves.
- Full AgentLoop: **36 passed, 7 failed, 4 skipped / 47**. Full Frontier:
  **22 passed, 17 failed / 39**. The process exited 1. Failures include malformed
  tool calls, unperformed file work, compaction expectations, and unavailable
  alternate-worker delegation with no exposed spawn schema. Self-judged
  rubric rows are identified in raw JSON;
  this is not a green full-model qualification or a matched baseline comparison.
- Fresh Release native UI before the time-context correction: two exact
  SysAdmin prompts in separate chats without restart both passed, child
  throughput 42.5/42.6 tok/s. RAM-off control passed at 40.1 tok/s. Parent Stop
  during a live child cleared the run; immediate follow-up child passed at
  33.9 tok/s. Sequential Research/Marketing both admitted, but the parent
  invented a date task and Marketing returned `Marketing-OK`, failing the exact
  requested casing. Native batch attempt failed at malformed tool arguments;
  it did not exercise the batch allocator. Settings changes mirrored the
  Orchestrator and Server concurrency controls, and batching-off was saved.

Native task-expansion evidence exposed a separate input-composition defect:
`SystemPromptTemplates.timeContext` injected the imperative “Resolve relative
dates” and concrete example dates into every latest user message. Coordinator
copied that text into Research's input and subsequently asked about an invented
time-conversion task. The correction retains the timestamp and timezone as
facts and removes that extra instruction/example. It does not change the
user's prompt, bundle sampler, model template, or reasoning controls. All six
focused time-context tests pass. The final Release was rebuilt successfully
from `1c04f615db52dbe4caf0ab937b4ed37d3b92d148` and tested after relaunch:

- RAM on, handoff on, coexistence off and concurrency two persisted; batching
  off persisted and actually produced `[1,1]` child subwaves. Active/pending
  counts returned to zero. The corrected handoff description was inspected.
- The unchanged batch prompt still failed semantically: Coordinator invented
  `Find information about X` and `Generate marketing copy for Y`. Both children
  ran successfully, but asked for context. Removing the date imperative does
  not solve general task expansion; no prompt or sampler masking was added.
- Restored the reporter's batching-on/concurrency-one settings through native
  Settings. Two further fresh chats without restarting returned the exact
  SysAdmin marker, child throughput **49.3/49.5 tok/s**.
- Unchanged Research then Marketing prompt: parent first attempted an invalid
  batch and malformed spawn calls, recovered, then both children admitted.
  Research returned `RESEARCH-OK` (20.3 tok/s); Marketing returned
  `Marketing-OK.` (25.8 tok/s), so exact workflow output still **fails**.
- Final UI peak physical footprint: **2,823.97 MiB**, sampled every 250 ms.
  Cache telemetry: **15 layers = 3 ordinary KV + 12 rotating KV**, fp16,
  disk-backed restore required, paged RAM off, TurboQuant KV layers **0**.
  Final counters: disk L2 17 hits / 337 misses / 46 stores; prefix hits/misses
  zero; active and pending requests zero. Bundle temperature/top-p/top-k
  remained 1/0.95/64 and `sampler_was_changed=false`.

The handoff setting description now reflects both the feasibility check and
the post-unload measurement/restoration path. No setting title changed.
Cross-model handoff still uses the existing conservative raw-weight × 1.3
plus reserve load estimate; this work removes hypothetical release credits,
not all conservatism in mmap model-load pricing. The reporter uses the same
model and does not traverse that unload leg. Cross-model, watcher/scheduled,
and knowledge-heavy live workflows are not newly qualified here; their shared
contract wiring and affected unit paths were audited/tested.

Private evidence: `implementation-3224aefe7/` under the root above contains
raw test logs, all full-eval JSON/failed transcripts, targeted reports, native
chat database exports, cache snapshots, and a 250 ms `proc_pid_rusage`
physical-footprint stream. The actual M4/16 GB failure remains unqualified.
Requested: complete failed spawn JSON including `memory_decision`, Memory
Safety slider, and TurboQuant KV setting. No answer has arrived yet.

The ranked findings below describe the pre-fix audit and its original evidence.

## Confirmed defects, ranked

### 1. High: an immediate recheck can return pre-recovery kernel counters

`ChatResidencyHandoff.availableMemoryBytes` calls `host_statistics64`.
`SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded` previously
called it immediately after allocator recovery and treated the result as
fresh. Apple's XNU implementation caches this API for non-platform binaries,
with a one-second window and a randomized fresh-query allowance. A successful
call does not guarantee a new measurement.

Primary source: [Apple XNU host.c](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/host.c#L576),
especially `rate_limit_host_statistics` and `host_statistics64_from_user`.
This is a cross-process kernel cache, not Osaurus's own cached settings.

Local reproduction: `scripts/live-proof/probe-host-memory-freshness.c` allocates
64 MiB, exceeds the fresh-query allowance, frees the allocation, and compares
the host counters with `proc_pid_rusage` physical footprint. **5/5 trials**
returned identical wired/compressor/internal/purgeable counters immediately
after footprint fell from 68,223,360 to 1,065,272 bytes. A later sample after
1.1 seconds changed. Other processes were active, so later host deltas are
not attributed entirely to this allocation.

Artifacts: `freshness/probe.c`, `freshness/results.jsonl`,
`freshness/provenance.json`. Compile with `xcrun clang -O2 -Wall -Wextra`;
the probe uses no model, Metal work, memory purge, or RAM-limit override.

Local correction: after a successful recovery, wait cancellably for 1.1 seconds
before resampling. No reserve, model budget, child price, or slot minimum is
relaxed. This prevents that final sample from coming from the pre-reclaim
kernel window; it is not a promise that system memory stops changing.
Unknown-estimate and explicit-budget failures still skip ineffective recovery.

The regression `recoveryDoesNotReuseKernelCachedPreReleaseFacts` failed before
the correction (one test, two assertions: stale facts and capacity zero).
Afterward, **109/109 tests across seven suites passed**, including cancellation
and sequential prepared-child reservation cleanup. Logs: `freshness-red.log`
and `freshness-green.log`.

Relevance to Harris: directly applicable to the claimed fresh recheck and a
plausible explanation when freed bytes would cross the threshold. It cannot
explain a genuine remaining shortfall or an explicit-budget rejection. His
actual before/after decision inputs are still needed to attribute the report.

### 2. High: live engine availability is reused as an aggregate reservation ceiling

Trace: `SpawnBatchTool.localAdmissionPlan` → `engineAdmissionWindow` →
`makeLocalAdmissionPlan(engineParallelLimit: engineWindow.parallelLimit)` →
`SubagentAdmission.reserveLocalInPlace(slotCapacity: plan.localCapacity)`.

The engine window already subtracts occupied engine slots. The reservation
actor then subtracts existing same-model reservations from that remaining
number as if it were the total capacity. This is a units mismatch.

Reproduction using the real helpers and reservation actor, RAM safety off:
engine maximum 2, one existing child, one nominally free engine slot. The
planner passes aggregate ceiling 1, and the second reservation times out
against the existing reservation instead of taking the free slot.
`engineAvailabilityIsNotAnAggregateCeiling` fails its desired admission assertion.

Correction needed: keep aggregate engine ceiling separate from this call's
submission width. Preserve the engine's architecture cap and queue behavior;
do not simply add a slot or raise configured concurrency.

Relevance: real same-model batching defect; not an explanation for the first
child in an otherwise idle one-slot workflow.

### 3. High: additional host headroom and total child capacity are conflated

Trace: `SubagentBatchAdmissionPlanner.resolveMemoryCapacity` divides CURRENT
host residual by per-child cost, then passes that value as total capacity to
`SubagentAdmission.resizeLocalInPlace`, which subtracts sibling reservations.

For an already-allocated sibling, its bytes are already absent from measured
host headroom. Subtracting its slot again can reject the next child. The total
model-budget constraint, however, really IS an aggregate constraint. Taking
`min` of these differently scoped slot counts does not make them equivalent.

Reproduction: a sibling already owns its full 512 MiB charge; host memory has
3.5 GiB reclaimable, reserve 3 GiB, next child 512 MiB, model budget 11 GiB,
weights 3 GiB, engine width 2. One new child fits, but resizing the new caller's
reservation returns zero. `hostHeadroomAndReservationCapacityHaveDifferentUnits`
fails its desired retained-slot assertion.

Correction needs allocation-aware reservation accounting. Blindly adding all
reserved siblings back is unsafe: a queued reservation may not have allocated
anything yet, and an active child may still grow toward its peak. Pending
allocation commitments and already-materialized state must be distinguished.

Relevance: concurrent-child false refusals. No sibling means this particular
double subtraction does not explain Harris's tiny first-child failure.

### 4. High: admission prices a soft KV default as a hard cap

Trace: `SubagentChildRequestEstimate.boundedPositionBudget(policyCap:)` always
clamps to the policy cap; `ModelRuntime.estimatedArchitectureKVHeadroomBytes`
also clamps its position estimate. Conversely,
`CacheCoordinatorConfig.resolveKVPolicy` applies `defaultMaxKVSize` only when
prompt length exceeds `longPromptMultiplier * cap`, unless explicitly set on
the request. Osaurus deliberately passes no explicit `maxKVSize`.

Reproduction with the pinned runtime resolver: cap 8,192, multiplier 2,
prompt 12,000 tokens. Runtime maxKVSize is nil, but admission prices 8,192
positions even with a 14,048-position child contract. The prompt alone exceeds
the price. `softKVDefaultIsNotAHardMemoryCeiling` fails the desired price bound.

Correction needed: price the effective request policy and actual retained
topology. Making full-attention caches rotate silently to justify the cheaper
estimate would change model behavior and is not an acceptable shortcut.

Relevance: underpricing larger inputs and possible RAM growth; does not raise
the price of Harris's tiny child to zero capacity.

### 5. High: the delegated position ceiling is enforced only through heuristics

Trace: `DelegatedRunContract.derive` → `ChatSession.delegationBudget` →
`AgentLoopBudget.makeBudgetManager` → `ContextBudgetManager` estimated-token
trimming → request. Admission calls this a fully measured, enforced ceiling,
but the budget manager uses character/UTF-8-length estimates. There is no
propagation of the contract into an exact post-tokenization admission check.

Exact local Gemma E2B tokenizer measurement: a 20,000-character ASCII number
list is **20,000 tokens**; the budget estimator counts 5,000. The resulting
delegated contract is **11,596 positions**, yet the real trim/overflow helper
preserves the entire input and reports `overBudget=false`.
`delegatedCeilingIsOnlyAnEstimate` fails its desired bound. No decode occurred.

`tokenizer-estimates.json` also records code punctuation, Han text, and normal
English controls; the heuristic is workload-dependent. Tokenization used the
exact local bundle revision `433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`, with
`add_special_tokens=false`; template overhead can add tokens, not make the
20,000-token input fit this bound.

Correction needed: enforce the already-declared contract against the actual
prepared input and output allowance before GPU allocation, with a typed
over-budget outcome. Another fixed heuristic multiplier does not establish a
hard memory bound. The response reservation also deserves correction:
`cappedResponseReservation` can reserve less than the `max_tokens` value the
chat request actually forwards.

Relevance: underpriced tool/task growth. Not evidence that a trivial ASCII
marker itself needs excessive KV memory.

## Additional source findings and limits

- **Gemma cache shape drift:** the estimator counts all 35 decoder layers with
  head_dim 256. This E2B bundle creates 15 cache objects because 20 layers share
  KV, and its global attention uses head_dim 512. At 4,096 and 16,384 positions,
  both estimates still hit the 512 MiB floor. At 65,536 positions the current
  estimate including its slack is 605,552,640 bytes versus a cache-shape-based
  512 MiB floor. These are calculated shapes, not measured peak allocation.
  Artifact: `gemma-cache-pricing.json`. KV codec selection is also absent from
  the host estimator, so its price does not reflect actual TurboQuant layers.
- **Child-card Stop gap:** `InterruptToken.interrupt()` only sets a flag.
  `SubagentSession` checks that flag after awaiting capacity. Recovery's
  `MetalGate.acquireCancellable` watches Task cancellation, not that flag.
  Parent Stop cancels the task, but child-card Stop can remain parked behind
  another producer. The existing test flips the flag inside an override that
  returns immediately; it does not prove prompt interruption of a blocked
  real gate. This finding is source-traced, not a new live UI proof.
- **Different-model handoff credit:** `memoryPreflight` adds chat-owned models'
  on-disk weight sizes to a host estimate that already regards file-backed
  pages as reclaimable. Disk size is not measured releasable physical memory;
  it can include unmapped/cold pages and does not describe exact-parent
  ownership. The unload leg targets one exact parent. This can over-credit a
  handoff and deserves a dedicated allocation/ownership test. Same-model reuse
  does not take this unload leg, so it is not the reported direct cause.
- **Measurement failures look like shortages:** a failed host_statistics64
  returns zero bytes; host_page_size's return code is ignored. Diagnostics
  cannot distinguish a failed measurement from actual zero headroom. Failing
  closed is appropriate, but claiming a measured stable shortage is not.
- **Reservation loss is mislabeled as a RAM refusal:** `SubagentSession`
  emits `stable_memory_refusal` for either zero refreshed capacity OR a lost
  reservation. The latter can be a concurrency/settings change even when RAM
  safety is off and refreshed capacity is positive. The reporter specifically
  reported capacity zero, so these outcomes must not be conflated when
  attributing his result.
- **Bare-run bound omits composed context:** the no-tool bare/model-override
  path estimates `input.count + turns * output`; execution also adds the
  target system prompt and optional memory section in `seedMessages`. The
  fixed floor does not bound arbitrarily large composed context. This is
  another reason a seed heuristic cannot serve as enforced allocation proof.
- **Reserve versus real pressure:** the fixed 3 GiB spare-memory reserve plus
  a 512 MiB child floor requires 3.5 GiB reclaimable memory. For the reporter's
  earlier wired/compressor/purgeable counts, internal pages above 416,676
  (about 6.36 GiB) would cross this refusal threshold. That missing counter is
  essential. Lowering this reserve is a policy decision until a false price
  or unaccounted reclaimable owner is demonstrated.

## Wiring checked without finding the proposed defect

- Resident same-model weights are charged once against the total model budget
  and zero times as an incremental model load. Engine, agent, and RAM ceilings
  remain distinct; a ceiling of one does not reserve one slot permanently.
- The same-model residency plan preserves RAM-safety state, even though it
  skips unload/restore. Handoff on does not require unloading the same model.
- Normal Settings and HTTP runtime-setting updates use the shared reload
  decision. Cache/profile edits unload resident containers; concurrency is
  resolved through the shared memory-safety plan. Stale loaded cache settings
  were investigated and are not asserted as a normal-settings defect.
- SwapPressureMonitor emits warnings based on residency-episode swap growth;
  its severity is not a direct input to child admission. Host compressor pages
  still legitimately affect the host estimate. Neither swap-used bytes nor
  memory_pressure's headline percentage are a direct RAM-slot calculation.
- Kernel counter overlap was checked against [Apple's host statistics code](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/host.c#L816).
  `internal_page_count` is populated from pageable internal pages plus local
  queue internal pages, not the broader resident internal-object count.
  Therefore merely adding wired and internal counters is not evidence of
  charging every wired anonymous page twice. No speculative counter refund
  was introduced.
- Scheduled/watcher/delegated chat paths propagate the delegated contract via
  DispatchRequest, BackgroundTaskManager, ExecutionContext, and ChatSession.
  The main problem found there is what the contract actually enforces, not a
  missing stored cap. Knowledge/tool results can grow the transcript and make
  that distinction consequential.
- Coordinator task expansion remains separate. PR #2718 is still open/draft
  at `46c8e399a40e82c773353751e8d88ca477622a04` and concerns delivery-footer
  contamination of tool-choice inference. This audit does not establish that
  it explains the native UI's expanded Research/Marketing tasks.

## Proof ledger and next work

- Real kernel measurement probe: **5/5 stale immediate rechecks observed**.
- Freshness regression before patch: **0/1**, two expected failing assertions.
- Affected focused regressions after patch: **109/109**, seven suites.
- Cross-function audit invariants: **0/4**, all four defects reproduced.
  `RAMAdmissionAuditProbes.swift` and `audit-probes.log` preserve the exact
  temporary probes. They were removed from the normal test target after the
  diagnostic run; no failure is relabeled as a passing production test.
- Exact bundle tokenizer controls: four measured rows, no generation.
- New Release UI / throughput / full AgentLoop matrix: see the current
  implementation follow-up above. Actual 16 GB: **still unqualified**.
  The previous #2733 campaign does not validate this new patch.

Prioritize the reporter's decision-time `memory_decision` and before/after
recovery values alongside the demonstrated freshness correction. Correct the
capacity-unit and exact-token/KV-price contracts independently; their distinct
failure modes must not be bundled into an unsupported "16 GB fixed" claim.
Keep same-model serialization, width-two batching, cross-chat reuse, child and
parent Stop, true memory refusal, and RAM-off behavior as separate acceptance
rows. Merge readiness still requires the final code's applicable Release/UI
matrix and the original actual-machine reproduction.
