# Runtime campaign consumer integration

The four dependency pins and two contract expectations use runtime `75ff99a24296eec31496a396a403c87b3e7d0453`. It includes all twelve merged original runtime PRs, the combined integration and goldens, current parser/cache/error fixes, and merged M2 core `3b39b5e79`. The consumer retains agent defaults and pickers, request-sized terminal SSM replay, export/token provenance and the bundled embedder.

The M2 Max-only long-batched reduction route is capped at 32 matrices, excluding the measured 64-matrix slowdown. Local correctness and regression checks qualified its landing; physical M2 prevention and the separate fused-attention report remain unconfirmed. No device or sampler policy changes here.

## Shared-KV event lifetime

The previous `0840d271` consumer passed 115 contract tests and fresh Release CLI/app builds. Its real long AR answer still failed shared-event allocation at exactly 1,636 output tokens, both after DSpark attachment and in a fresh process without a drafter. Instrumentation found 65,505 live events while command buffers stayed bounded; events returned to zero when the request cache was released. Disabling layer submission completed 5,770 tokens, but that diagnostic is not the production fix or speed acceptance.

DeepSeek supplies the same latent as K and V but consumes only K. A separate lazy V cache-update chain retained old projection rows and their per-layer completion events. The new explicit shared-KV update keeps the K update unchanged and aligns V through a fresh handle. Normal attention, cache-only prefill and speculative prefix commits use it, retaining layer submission and the prefill speedups. Distinct-K/V caches keep their existing update path. Custom cache representations asynchronously materialize their V branch. No host wait, cache-format migration, output clamp or model-behavior guard is added.

A minimal test with the real rotating cache reproduces the allocation error without a model. With the shared update, 4,096 decode steps across 40 caches pass. Two CPU controls match paired updates through prefill, growth, rotation, restored state and companion windows. All 3 new tests pass in one actual suite. Separately, 120 affected runtime tests passed in 16 actual suites. Consumer `888ec37085`, built against the production-identical pre-merge runtime, passed 115 pin-contract tests across 2 suites and fresh Release CLI/app builds. Native Light AR completed 5,260 tokens normally at 27.38 tok/s; its generated module passed 16 unit tests and 130 independent inputs. Runtime PR715 is merged and its full tree equals the qualified final head; the only change since the compiled runtime is the qualification document. This final pin consumes that merge without claiming a separately rebuilt binary.

The earlier draft-window compaction change bounds a separate lazy history used by DeepSeek and MiniMax. Its focused controls pass, but the tail change alone did not prevent the app failure. The failed app rows remain separate from that narrower proof.

## Retained component proof and limits

Earlier consumer `32512e00` passed 135 tests across 4 pin/embedder suites, Release CLI/app builds and all 10 CI checks. Its actual app completed DSV AR/Adaptive tools, SSD restore, new-chat reuse, Stop and terminal-tool recovery. Adaptive kept the target loaded and attached DSpark in 0.2 seconds. Effective DSV cache: FP16, 40 layers (2 rotating plus 38 rotating-wrapper/hybrid pools), disk-backed restore, paged RAM off, zero TurboQuant KV layers. Native temperature 1/top-P 1 stayed unchanged. Earlier M3.1 tools/image/cache and agent editor/sidebar/picker/relaunch evidence remains retained for unchanged files. Owned loading stays enabled; full model-scale physical footprint is disclosed.

Earlier native sampled Adaptive easy-code completed 745 tokens at 33.0 tok/s and passed generated tests plus 130 independent inputs. That is not a 60 tok/s claim or a valid speedup against failed AR. The layer-submission-off diagnostic passed 20 generated tests and 130 inputs, with 3 docstring-example failures retained separately. Native-default quality and explicit greedy performance controls must remain distinct.

Original stacked consumer PR3272 is intended to land into PR3248's branch, then PR3248 into main, with source/tree receipts for both. Runtime follow-up landing and final pin consumption must be accounted for first. No release.

## Current speed controls

The new Release app completed native Light Adaptive greetings at 19.91 and 26.24 tok/s, and native Light Adaptive easy code at 26.69 tok/s. The easy-code function passed 130 independent inputs, but a generated digits-only `islower` test failed (3 passed, 1 failed). SSD restore was active; Adaptive performance remains unresolved.

A separate loopback-only profile with explicit benchmark temperature 0 and thinking off measured raw Adaptive 39.48/51.93/43.88 tok/s for CRC32/factorial/stable-unique, against AR before draft attachment at 32.06/31.22/30.53 tok/s. Requests match within each task; CRC32 and factorial outputs match exactly across modes. Stable-unique outputs differ while passing the independent function checks; one later AR-generated test fails. These are scoped workload controls, not native-default or universal speed acceptance. Historical Python and different-hardware results remain distinct. Further clock/repetition controls are retained privately.
