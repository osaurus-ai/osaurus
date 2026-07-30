# Cache telemetry continuity — 2026-07-30

Status: `OPEN` — two lifecycle defects are source-confirmed; source fixes and
current-head live verification are not yet complete.

## Source baseline

- Osaurus base: `c81491b4b9d78c846a45ac7adccb6b9227137dbc`
- Pinned vMLX: `958eb6bed2e2fd4fde30574141e17a1dce773895`
- Retained failing row:
  `agent_loop.spawn-batch-two-different-local-workers`
- Retained symptom: SSM hit delta `-75`; disk-L2 hit/miss/store deltas
  `-75/-838/-140` after a Nanbeige-to-Ornith model handoff.

## Confirmed source cause

`EvalRunner.runOne` and `SpawnBatchTool` take before/after snapshots from
`ModelRuntime.batchDiagnosticsSnapshot()`. The snapshot currently sums cache
counters only from model holders resident at that instant. Strict-model
handoff removes model A and loads model B, so subtracting the post-handoff
resident set from the pre-handoff resident set reports impossible negative
deltas even though the underlying counters are monotonic.

This is a shared diagnostics defect, not a failed child execution and not an
evaluator-formatting issue. The owning fix must preserve retired engine/cache
counters in the process-level diagnostics source so the Settings UI, health
and admin APIs, `spawn_batch`, CacheProof, and OsaurusEvals all consume the
same truthful boundary.

## Model unload lifecycle defect

The running isolated PR #2235 app accepted a Model Cache Inspector `Unload`
click and its `/health` response subsequently reported both `loaded: []` and
`resident_models: []`. The visible control, however, has no per-row pending,
success, or failure state, and `MLXService.unloadRuntimeModel` discards the
runtime's Boolean result. The user therefore cannot tell whether the command
was delivered, is waiting, or failed closed.

There is also an owning runtime ordering bug when a lease is still held:
`ModelRuntime.unloadClaimed` shuts down the model's batch engine and then waits
for `ModelLease.waitForZero(name)`, but it does not cancel and await the tracked
generation wrapper that releases that lease until *after* the wait. A stuck or
still-open stream can therefore leave the explicit UI unload waiting forever.
`clearAll` already establishes the correct safety discipline: stop the engine,
cancel and drain generation wrappers, then wait for leases before freeing GPU
buffers.

The fix must preserve fail-closed GPU teardown, scope cancellation to the
selected model, provide a bounded UI wait with an actionable failure message,
and refresh the row/count from authoritative runtime residency notifications.

## Acceptance gates

- Focused unit tests prove retired counters are added exactly once, live
  occupancy remains live-only, high-water marks never decrease, and integer
  accumulation cannot wrap negative.
- Existing diagnostics/API/eval tests remain green.
- A fresh isolated Release app visibly shows nondecreasing cache counters
  across a different-local-model handoff.
- The mixed-model delegation turn completes both children, parent
  continuation, terminal tool card, Stop disappearance, unlocked input, and
  a coherent follow-up.
- Raw before/after/delta telemetry contains no negative monotonic counter.
- A loaded model's `Unload` row immediately exposes pending state; success
  removes the row and updates the model count; a held/stuck lease fails closed
  within the UI deadline and exposes an actionable error instead of hanging.
- Explicit unload cancels and drains only that model's generation wrapper
  before waiting for its lease, while idle-policy unload continues to wait
  without cancelling a valid active request.
- Exact source SHA, vMLX pin, model paths, generation defaults, token/s,
  prefill/restored counters, and local evidence hashes are recorded before the
  PR is described as verified or merge-ready.
