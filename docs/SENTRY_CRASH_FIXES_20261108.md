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

The actual `EventDispatcher.flush` path was also tested with eight overlapping
flushes and 2,000 events with dictionary properties. Shipped 0.3.11 aborts with
SIGABRT; the fixed SDK delivers 2,000/2,000 events exactly once to an in-memory
`URLSessionProtocol` receiver. No external telemetry is sent by this fixture.

Fresh isolated Release CLI and app builds pass. Native Settings/lifecycle smoke
covers consent off/on, navigation, quit/relaunch persistence, restoration to off,
and quit. The native app has no analytics key or Sentry DSN; the SDK fixture
above exercises concurrent sending. Source tested: `0c53af186`; runtime pin:
`1bcd74ad182103a3b83941f61e57ee0bac23b330`. App binary SHA-256:
`b1e1fbb9eaacd77fc539a3cd5ac78a40850136d6e5f4707476493db5ab1e2c45`.
No model generation was needed for this analytics dependency change, so it makes
no model quality, inference-cache or throughput claim. No release was performed.

Full local evidence (including original failed runs, source snapshots,
reproduction binaries, native crash report, screenshots, AX records and build
logs) is retained separately under
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
