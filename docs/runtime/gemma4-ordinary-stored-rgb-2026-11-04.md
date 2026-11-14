# Gemma 4 ordinary stored RGB consumer — 2026-11-04

Consume runtime PR725 merge `ca5bdc98313aafd080475207cda4c29ec85392ee` in all four dependency pins and two source-contract expectations. The merge tree equals its reviewed head, whose implementation equals native-qualified `200bb81ac1fcc655013dda55a148856161ea78db`. The ordinary Gemma processor now uses the same stored-RGB and white-alpha conversion already qualified for unified Gemma. Geometry, sampling, templates, weights and decode kernels are unchanged.

## Accepted implementation evidence

The actual processor regression fails eight of nine ordinary RGB/alpha cases before correction and passes ordinary 9/9 plus unified 9/9 after correction, at unchanged tolerance. Fourteen XCTest and twenty-two SwiftTesting tests cover the affected component selections. The initial consumer candidate passes 115 focused host tests across two suites.

Native implementation qualification uses consumer `54b1939403672559287f4af210783d25ea654fc6`, runtime `200bb81ac1fcc655013dda55a148856161ea78db`, fresh Release2026110416, executable SHA256 `b17d79b13781c98c715492f50fb3bc1f3c6fc523ac9cd69c473c01d78d80b034`, and actual `OsaurusAI/gemma-4-E4B-it-qat-JANG_4M`. The isolated profiles initially have 123 byte-identical regular files. Sanitized input, tools and generation match. Both runs use the same transparent PNG; Insights redacts media bytes, so this is not exact wire-byte equality.

The prior app reports code and amount unavailable, with Green correct (1/3 fields). Corrected E4B reads `G918-NZ37`, `6409`, Green (3/3), with expected identifiers absent from the prompt and previous answers. Both opaque slips remain correct (6/6), for 9/9 named image fields. Nine actual requests across six manual cases complete naturally, including actual calculator `1767 → 3534 → 10602` after a full restart.

Generation inherits bundle temperature 1 / top-p .95 / top-k 64, runtime min-p 0, no max/penalty/seed override, explicit Thinking Off. Native effective sampler confirms K64 and existing app fallback max16,384. All generations have positive rates; runtime decode61.49–68.80tok/s is separate from prefill-inclusive exports and is not a controlled benchmark.

Six actually restored SSD checkpoint files contain four raw KV plus twenty rotating layers with correct offsets and F16 state. Fresh process restores5568/5797 then5797/5856. Unchanged prepared six-image history has stable media salt. Native PrefixOn/pagedGPUOff andSSDOn controls are visible. This is disk-backed rotating/raw KV reuse, not TurboQuant-KV or fused-kernel proof. No old-eligible-cache upgrade control is claimed for the ordinary processor.

## Consumer acceptance and remaining scope

The consumer must pass affected tests, a fresh isolated Release build, actual-merge-pin native checks, and required CI before a normal exact-head merge. Current source/app identities and those observations are bound in the PR's source/live evidence report and retained receipt files; implementation evidence above is not a substitute for this consumer gate. No release tags or publishing.

The baseline/candidate native receipts remain under `/Users/eric/vmlx-private-evidence/osaurus-cache-wiring-20261103/`: `GEMMA-ORDINARY-MATCHED-BASELINE-NATIVE-RECEIPT.json`, `GEMMA-ORDINARY-CANDIDATE-NATIVE-QUALIFICATION-RECEIPT.json`, `GEMMA-ORDINARY-CANDIDATE-TYPED-SSD-PROOF.json`, `PR725-MERGED-RECEIPT.json`. These freeze 41 candidate artifacts and preserve the failing control, exact source identity, actual requests, rates and process closure.

Physical footprint still fails: candidate peaks12,307,539,472 and11,965,965,648bytes exceed10,789,234,410weightbytes. Owned loading is retained per user choice; no low-RAM claim follows. A separate E4B Thinking-Off turn emits a thought despite explicit false and runtime toggle_off; the pixel change does not fix or hide that observation. A later26B QAT row returns correct amount/color but an en dash in its identifier, so strict image score2/3 remains a failure. It is recorded separately from the E4B comparison.

Broader QAT/MXFP4 bundles, advanced-setting combinations, scored AgentLoop/Frontier, cancellation at all stages, eviction/quota and full resize parity remain partial. Unified12B OCR4/9 and RAM failures remain retained. No model-family readiness, raw speed benchmark, hidden sampler rescue or forced output claim.
