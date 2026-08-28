# vMLX: Stream prefill progress live (don't buffer events during cold compute)

## Problem / Symptom

On a **cold** generation (model just loaded, long prompt — e.g. Gemma 4 with a
multi-thousand-token prompt), the Osaurus typing indicator does not animate the
prefill counter. The user sees only the bouncing dots, or at most a late/final
counter frame, until the first decoded token appears.

On a **warm** generation (same model, second turn), Osaurus now seeds the
prefill state before submitting to vMLX, so the counter appears as `0/N`.
However, the observed UI still stays at `0/N` until model output begins. That
means the Osaurus-side start state is working, but vMLX is not delivering live
incremental `completedUnitCount` updates to the consumer.

The remaining runtime problem is event delivery timing: Osaurus can only render
frames when the app gets a paint opportunity and when vMLX delivers progress
events across async boundaries. Today, vMLX delivers the start state but does not
deliver visible incremental frames on the tested Gemma 4 path, including the
warm path.

## Root Cause

In `BatchEngine.startSoloFastPath`, the `TokenIterator` is constructed eagerly
and synchronously on the calling thread. `TokenIterator.init` runs the entire
cold prompt forward pass (prefill) inline before returning. The
`SoloPrefillProgressAccumulator` / `PrefillProgressReporter` callbacks *do* fire
during this pass, but they're posted onto a task/continuation that cannot be
serviced until the synchronous `init` returns and the calling thread yields.

The net effect: every prefill progress event for the cold pass is **buffered**
and then **released in a single burst** after the prompt forward pass already
finished. Osaurus now seeds `0/N` before submitting to vMLX, but if the cold
submission immediately monopolizes the relevant executor / runloop, that seeded
state still may not get a paint opportunity before the buffered `… N/N` and
completion events arrive. The UI receives the whole ramp in one runloop turn,
collapses it to the final state, and clears.

On a warm turn the prompt forward pass is cheaper, but the same consumer-visible
problem remains if vMLX emits all increments synchronously inside setup or skips
intermediate reports because cache restore / prepare completes in a single
non-yielding step.

## Required Change (vMLX side)

Defer the cold prompt forward pass out of the synchronous constructor and into a
cooperatively-scheduled producer so progress callbacks are delivered *as they
happen*:

1. **Do not run prefill inside `TokenIterator.init`.** Construct the iterator
   cheaply (capture inputs, cache, config) and run the prompt forward pass
   lazily on first advance, or in a dedicated async producer task owned by the
   engine.
2. **Drive prefill from an async producer task** in `startSoloFastPath` (or
   wherever the solo fast path is kicked off) so the prompt forward pass runs on
   a task that yields between progress chunks.
3. **Yield cooperatively between prefill chunks.** After each
   `PrefillProgressReporter` report (or each prompt chunk evaluated), allow the
   continuation/stream to flush — e.g. `await Task.yield()` or stream the event
   through the same `AsyncStream` the decoded tokens use — so the consumer
   observes intermediate `completedUnitCount` values instead of only the final
   one.
4. **Preserve chunking granularity.** Report progress at the existing prefill
   chunk boundaries (per evaluated prompt segment), not just at start/end, so
   the ramp has enough intermediate frames to animate.

The decoded-token path already streams correctly; the fix is to make the cold
prefill path use the same cooperative streaming discipline rather than a
blocking synchronous `init`.

## Acceptance Criteria (live proof, not source-only)

- Cold turn, long prompt: the consumer receives **multiple** prefill progress
  events with strictly increasing `completedUnitCount` (e.g. several frames
  between `0/N` and `N/N`), spread across multiple runloop turns / `await`
  points — not all in one burst after prefill completes.
- Warm turn, long prompt: after Osaurus shows the seeded `0/N` counter, vMLX
  emits at least one intermediate `0 < completedUnitCount < totalUnitCount`
  frame before first model output.
- `token/s`, total prefill duration, and final decoded output are unchanged
  (this is a scheduling/delivery fix, not a compute change).
- No forced/synthetic progress events: every emitted `completedUnitCount`
  corresponds to real prompt-processing progress.

## Osaurus Consumer Contract

Osaurus already:

- Seeds `InferenceProgressManager.prefillProgress` with `0/N` before calling
  `engine.generate(...)` in `MLXBatchAdapter.generate`, so the warm path cannot
  race the producer and clear prefill before the UI observes a start state.
- Maps each vMLX prefill progress event to `PrefillProgressState`
  (`completedUnitCount`, `totalUnitCount`, `stage`) in
  `GenerationEventMapper`.
- Publishes it through `InferenceProgressManager.prefillProgress`.
- Renders `completed/total` (e.g. `0/12345`) inline next to the RAM indicator in
  `NativeTypingIndicatorView`, carrying the Combine-emitted value directly so
  bursts are not collapsed by a stale singleton re-read.

Once vMLX streams prefill events live and yields between progress chunks, the
existing Osaurus UI will animate the counter with no further Osaurus-side
ordering changes.
