# Delegation refusal under warning pressure

## Report and reproduced decision

The report concerns same-model Gemma 4 E2B 8-bit delegation on a 16 GB M4.
The screenshot supplies these inputs, not a live measurement on the test host:

| Input | Bytes/value |
| --- | ---: |
| Reclaimable memory | 3,290,628,096 |
| Resident target | true |
| Target load footprint | 5,899,232,198 |
| Child state estimate | 1,014,497,280 |
| Model load budget | 12,025,908,428 |
| Parent release credit | 0 |
| Kernel pressure | warning |
| Effective reserve | 3,221,225,472 |

The resident target does **not** incur another weight load. Warning pressure
disables the normal-pressure incremental-resident rule, leaving the conservative
3 GiB reserve in force. Only 69,402,624 bytes remain after that reserve, below
the 1,014,497,280-byte child estimate. This produces zero RAM slots even with
one engine slot free and no leaked child reservation. The model-budget residual
is larger than the child estimate, so it is not this receipt's limiting term.

This establishes a policy refusal, not that the requested run would necessarily
OOM. A fresh app process does not reset system-wide memory pressure. A smaller
different-model child unloads the parent before the post-unload sample, so that
handoff is not a matched comparison with resident same-model reuse.

## Cleanup and settings contracts

The existing runtime recovery waits for the exclusive GPU gate, synchronizes,
releases volatile inference caches and freed allocator buffers, synchronizes
again, then waits 1.1 seconds before sampling host statistics. The delay covers
XNU's cached host-statistics window. It is not a promise that physical headroom
or the pressure state improves. Persistent warning inputs still refuse after
successful reclamation; extra arbitrary delays do not change that arithmetic.

`ramSafetyPreflightEnabled` is a shared delegation setting, not an independent
per-agent switch. The Orchestrator UI, configuration export/apply, custom-agent
residency planning and post-wait replanning must preserve the same value. OFF
bypasses the delegation RAM slot clamp and handoff preflights, including unknown
or critical pressure. It does not remove permissions, ownership, cancellation,
explicit fan-out or engine serialization. Server Memory Safety load budgets
are a distinct configuration; this change does not rewrite them.

## Changes

- Add the exact screenshot regression, OFF/ON repeated waves, unknown/critical
  inputs, cold targets, zero estimates and preservation of non-memory limits.
- Add save/export/apply/cold-read and stale-editor persistence coverage.
- Record the effective `ram_safety_enabled` in each decision, including when
  estimates are absent. With OFF, `ram_slots` is diagnostic only.
- Name the opt-out and risk in refusals and Settings; add a direct settings
  search landing entry. No default safety arithmetic or sampler changes.

This is a diagnostics, discoverability and regression-coverage change. The
existing OFF path already bypassed the reported admission gate; this PR does
not claim to introduce a new bypass or relax the enabled policy.

## Source and build identity

SOURCE EVIDENCE: tested app source
`f9eeec01c3aa02475d998621b8bd3bc5da6ba37b`, based on
`d42dee07a0532fa174aa2a2f93da9e133b16da52`, engine
`8ba593aff16c13cf526211b8477c0a037f0122af`. Admission code at this base matches
official tag 0.25.5 (`e20ffcfb0d8b370a32ca34e5dc9c137cebd5ef20`). The reporter's
exact build version was not supplied. Relevant methods are
`SubagentBatchAdmissionPlanner.plan/resolveMemoryCapacity`,
`ModelRuntime.reclaimMemoryForSubagentAdmission`,
`SubagentResidency.resolve`, `SubagentSession.localInPlaceCapacityDecision`,
`ChatResidencyHandoff.memoryPreflight` and `SubagentConfigurationStore`.

Development-only bundle ID: `com.dinoki.osaurus.ramoptout0916`. Binary SHA-256:
`c836d99183ae70a58d03dc58d06e5f7579ce0eb5500ca8003f8ee076fd5572c7`.
UUID: `7D6F4306-C3ED-3BD7-BE89-8B75021ACA07`. It uses an optimized Release
configuration locally, not a packaged/published release. No installed app,
production profile, model weights, signing release or tag was changed. Later
documentation-only commits do not change this tested runtime source.

## Native proof, 2026-09-16

LIVE EVIDENCE: actual settings clicks, composer submissions, model-generated
`spawn_agent` calls, child transcripts, parent continuations, Stop, relaunch and
visual inspection on the user-authorized M5 Max2. Two supervised processes
(67473 and 26673) used the same binary and isolated profile. Evidence root:
`/Users/eric/vmlx-private-evidence/ram-safety-warning-2026-09-16/`.

The private app-only interposer caps host reclaimable reads at 3,290,628,096
bytes and raises sampled pressure to at least warning. It never increases
available memory or lowers critical pressure. Opt-in/profile-mismatch controls
are in `emulator-controls.log`; real host memory is sampled independently by
the supervisor/collector. Physical RAM remains 128 GiB, not a simulated 16 GiB
machine. The live load budget is 96,207,267,430 bytes and engine slots are two;
the exact reporter budget/one-slot arithmetic is covered separately by tests.

| Native row | Observed result | Retained artifacts |
| --- | --- | --- |
| Safety ON, resident Gemma to Gemma | `stable_memory_refusal`, effective flag true, zero slots; reporter's exact weight/child/reserve/reclaimable values | `ui-on-refusal.*`, `row-on-turns.json`, `run1.oslog` |
| Actual checkbox OFF, same process | Child 69 tokens at reported 64.4 tok/s; parent 32 at UI 80.2 tok/s; no RAM refusal | `ui-off-settings.*`, `ui-off-result.*`, `run1.oslog` |
| Two workers, then follow-up | SysAdmin 124 at 54.7; Writer 41 at 63.5; continued first child adds 56 tokens; parent uses results | `row-batch.*`, `row-repeat.*` |
| Custom agent settings and execution | Saved SysAdmin delegation settings preserve global OFF; SysAdmin to Writer produces 50 tokens at 65.7, parent 71 at 85.6 | `row-agent-settings.*`, `row-custom-agent.*` |
| Cold restart and search | OFF persists; direct search result navigates to actual checkbox; subsequent delegation runs with OFF | `row-cold-off-search.*`, `run2-launch.json` |
| Gemma to Raptor to Gemma | Actual unload/load/run/unload/restore; Raptor 445 tokens at 42.2; parent 52 at 81.0 | `row-raptor-handoff.*`, `run2-measurements.jsonl` |
| Stop running Raptor, then delegate again | Cancelled child settles, Gemma restored, no active inference; next Raptor run 313 at 46.8 and parent 34 at 77.7 | `row-before-stop.*`, `row-cancelled.*`, `row-after-stop.*` |
| Explicit two-call-wave request | Both Writer results complete, 39 at 28.9 and 53 at 67.6, but model issues them sequentially | `row-wave.*` |
| Restore checkbox ON | Same resident Gemma warning facts refuse again with `ram_safety_enabled=true` | `row-restored-on-setting.*`, `row-restored-on-result.*` |

The first ON decision drained cached allocator bytes from 67,371,048 to zero;
the restored-ON decision drained 113,147,948 to zero. Each repeated the trim
and waited about 1.1 seconds before each fresh sample. Available bytes/pressure
remained unchanged and capacity stayed zero. This demonstrates why that warning
receipt does not require a leaked reservation or an incomplete unload to occur.
It does not determine the cause of warning pressure on the reporter's machine.

OFF admission logs explicitly show `ramSafety=false`, `ramSlots=0`,
`localCapacity=2`, `verdict=admitted`. Nine child completions and seven parent
answers end with `stop`, not a length cap. The deliberate cancellation is a
separate row, not a completed-answer pass. The first ON/OFF pair shares a
process but an ordinary idle unload occurred between requests; admission saw
the target resident in both. No claim of uninterrupted residency is made.

Child tool-usage rates and parent UI rates above are separate measurements, not
speedup claims. Continued-child usage is cumulative: 125 tokens at 60.3 tok/s
includes its earlier 69-token answer. `receipt-analysis.json`, generated by the
retained read-only analysis script, also indexes all 29 logged generation
duration/token rows, including tool-call generation and cancellation. Derived
rates use those logged durations and are not substituted for UI decode rates.

## Models, cache and isolation

- Gemma: `OsaurusAI/gemma-4-E2B-it-8bit`, snapshot
  `433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`; 5,899,232,198 runtime weight bytes.
- Raptor: local `OsaurusAI/Raptor-0.6-preview-JANG_6M`, 3,891,010,520 weight bytes;
  weight SHA-256 `117623c91ba7ad769b29dbbdadb3819781d3154a8518a808b91cf13bce76335a`.
  The reporter did not identify his Raptor quant; this is not asserted identical.
- Effective sampler telemetry: Gemma temperature 1/top-p .95/top-k 64;
  Raptor .6/.95/20, no repetition/frequency/presence penalties and
  `sampler_was_changed=false`. Child budget 8192, parent 16384. These are the
  migrated live budgets, not the smaller prelaunch fixture values. App template
  context has `enable_thinking=false`; thinking-on is not qualified here.
- Gemma telemetry: fp16 KV, 15 layers = 3 KV + 12 rotating, disk-backed restore,
  `turbo_quant_kv_layer_count=0`, `requires_paged_boundary_companion=true`.
  Raptor: fp16, 44 KV layers, no rotating/SSM companion. Model cache policy and
  paged-cache API both report paged RAM off. Internal mixed-cache coordinator
  messages mention paged boundary handling; they do not establish RAM paging.
- Final per-process batch counters: run1 L2 hits/misses/stores 12/66/62; run2
  11/127/59. Prefix and SSM companion hit counters are zero. No TurboQuant
  compression is recorded. Unloaded-model aggregate counters can be zero while
  process batch counters retain these values; do not conflate their lifetimes.
- Independent collector lifetime peak physical footprints: 4,428,778,592 bytes
  (run1), 4,164,832,112 (run2), higher than the slower supervisor sample peaks.
  Actual host pressure stayed normal; swap stayed 2,655.69 MiB. Both owned
  processes quit normally, exit 0, with no owned process/watchdog left.

The editor exposes one shared delegation checkbox, not a second custom-agent
RAM flag. The custom-agent view links back to Orchestrator system settings.
Server Memory Safety remained Safe Auto throughout these native rows and did
not block these loads. Its separate No Automatic Limits mode was not exercised
by this UI campaign; explicit server budgets were not silently rewritten.

## Tests and limits

- Current runtime-source CI run
  [35166787719](https://github.com/osaurus-ai/osaurus/actions/runs/35166787719):
  all seven validation jobs passed. Core includes 401 XCTest cases, eight
  skipped, zero failures, plus Swift Testing suites including the five new
  warning-pressure tests, persistence and catalog tests. Evals: 355 Swift
  Testing cases/44 suites plus two XCTest cases; deterministic RAMAdmission
  18/18. Separate Subagent eval totals include 15 intentional skips.
- Local model-free execution: 44 tests/five suites, zero failures, compiling
  production planner/recovery/reservation/evaluator code with telemetry-only
  scaffolding. Eight new diagnostic assertions failed before the change; the
  existing OFF bypass itself was already passing. Full CI logs are retained.
- Both native requests for a concurrent two-call wave were emitted sequentially
  by the model. Concurrent fan-out remains model-free/CI covered, not native
  parallel-model proof. Do not relabel these rows as concurrent execution.
- Raptor returned substantive advice but was verbose and echoed delegation
  instructions; its first answer says NEEDS INPUT while its receipt flag is
  false. This known output-quality/parser gap is not fixed by this RAM patch.
- No physical M4/16 GB, actual OOM, media/audio, seven-minute workload,
  every-model quality, or every cancellation-phase qualification is claimed.
  This closes the reported warning-policy reproduction and tested opt-out
  wiring, not a guarantee that any requested allocation will succeed.
