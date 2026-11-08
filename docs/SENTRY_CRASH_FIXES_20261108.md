# Sentry crash investigation, 2026-11-08

## Analytics queue corruption: APPLE-MACOS-3K9 and APPLE-MACOS-3P3

Both production captures run through Aptabase `EventDispatcher.flush` and
`ConcurrentQueue.dequeue(count:)`. The shipped Aptabase 0.3.11 implementation
mutates its backing array inside plain `sync` on a concurrent dispatch queue.
Overlapping flushes can therefore concurrently remove array elements, producing
invalid array ranges, negative counts, and dictionary-storage lifetime failures.
These captures do not establish a model inference or KV-cache fault.

The dependency is pinned to upstream commit
`a55267506ca9e9413e242cff00309f91bda16679`. Relative to 0.3.11, that commit changes
only the two dequeue operations to exclusive barriers and adds two concurrency
regression tests. All three dependency lockfiles consume the same revision.

Local reproduction uses the exact old and fixed dependency source, eight
concurrent consumers, 2,000 dictionary payloads per round, and batch/single-element
dequeues. Both old paths trap; both fixed paths complete 100 rounds without
missing or duplicate elements. The upstream suite passes 11/11 tests, including
both concurrent-dequeue tests and four dispatcher batching/retry tests.

Native app build and UI smoke are pending. This is not yet a merged or released
fix. Full local evidence (including original failed runs, source snapshots,
reproduction binaries, receipts and build logs) is retained separately under
`/Users/eric/vmlx-private-evidence/sentry-inference-20261108/`. Raw production
events remain private.

## Other investigated signatures

- `APPLE-MACOS-3FJ`: handled Metal interactivity failures. The latest sampled
  event is from November 1, after disk restore during preparation. Initial GPU
  cause and affected-machine prevention remain unproven.
- `APPLE-MACOS-33G` / `33H`: captured October 30 storage-rotation wait during
  Insights initialization. Current main already defers that open during rotation
  through PR #3289; this historical capture does not prove a current regression.
- Model inventory, inference/progress, resource-usage and embedding-usage hangs
  have distinct sampled main-thread locations. A function appearing in a hang
  stack alone does not establish an expensive operation, GPU wait or KV-cache
  deadlock. Controlled reproduction and timing remain required.
- Geometry overflow, accessibility executor assertions, window registration, and
  the old GLM4V rotary-index crash remain separate investigation rows.

Evidence is cumulative. Later iterations must retain earlier captures, failed
runs and their attribution instead of replacing them with successful results.
