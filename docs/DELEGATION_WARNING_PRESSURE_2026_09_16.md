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

## Changes and proof status

- Add the exact screenshot regression, OFF/ON repeated waves, unknown/critical
  inputs, cold targets, zero estimates and preservation of non-memory limits.
- Add save/export/apply/cold-read and stale-editor persistence coverage.
- Record the effective `ram_safety_enabled` in each decision, including when
  estimates are absent. With OFF, `ram_slots` is diagnostic only.
- Name the opt-out and risk in refusals and Settings; add a direct settings
  search landing entry. No default safety arithmetic or sampler changes.

SOURCE EVIDENCE: based on `d42dee07a0532fa174aa2a2f93da9e133b16da52`, engine
`8ba593aff16c13cf526211b8477c0a037f0122af`. Admission code at this base matches
official tag 0.25.5 (`e20ffcfb0d8b370a32ca34e5dc9c137cebd5ef20`). The reporter's
exact build version was not supplied. Relevant methods are
`SubagentBatchAdmissionPlanner.plan/resolveMemoryCapacity`,
`ModelRuntime.reclaimMemoryForSubagentAdmission`,
`SubagentResidency.resolve`, `SubagentSession.localInPlaceCapacityDecision`,
`ChatResidencyHandoff.memoryPreflight` and `SubagentConfigurationStore`.

LIVE EVIDENCE: PARTIAL. Current-source model-free execution: 44 tests in five
suites, zero failures; this compiles the production planner, recovery sampler,
reservation actor and evaluator with telemetry-only type scaffolding. The new
effective-setting diagnostic assertions first failed eight times on unchanged
production code and then passed. This is not a native app/settings/inference
claim. Current-source UI, real allocator-drain, full Core/evals and merge proof
remain pending. Private artifacts:
`/Users/eric/vmlx-private-evidence/ram-safety-warning-2026-09-16/`.

The authorized proof host is M5 Max2, not the reporter's M4/16 GB. Private
downward headroom and pressure-input emulation must be distinguished from actual
system pressure or physical OOM. No deliberate OOM stress is required.
