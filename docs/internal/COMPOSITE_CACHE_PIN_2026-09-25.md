# Composite and recurrent cache boundary pin

Osaurus consumes vmlx-swift `934dd5c8dc052cc6c8b4b960fe1bffd6badf0998`, including engine #517 and #518. Composite boundaries are checked through every leaf, all-recurrent boundaries retain their token counts, typed composite state restores through disk serialization, and Falcon-H1 advances its recurrent offsets. The coordinator now uses leaf offsets for stores as well as restores; the prior outer `CacheList.offset == 0` guard refused valid Falcon stores.

The pin also includes intervening Linux portability, CPU embedder precision, and KDA short-convolution changes. No sampler or quantization default is changed by this app PR. Contributor fixes #487/#514/#516 were merged later and are intentionally not part of this frozen pin.

## Source and build identity

Tested executable source: `7fe07345cd222400febfb55c1c88153ee4dae3d2`.
Engine: `934dd5c8dc052cc6c8b4b960fe1bffd6badf0998`.
Release app SHA256: `ccf18bf5957bbf1c37e36d1aa39acafdb28950c269f451ff091fb8cb12df662f`.
Release eval SHA256: `4358d94c2334c033456c25defdfde1ec25bd4be4a48bd7847eae6219d4bc0c2b`.
A subsequent documentation-only commit does not change these executable inputs.

Evidence root: `/Users/eric/vmlx-private-evidence/required-followups-2026-09-25`.
Focused app tests, Release app build, and Release eval build completed without source drift or memory-guard abort. Receipts: `cache-pin/tests-r8-receipt.json`, `app-build-r5-receipt.json`, and `evals-build-r5-receipt.json`. Engine #518's focused matrix passed 29/29.

## Live cache proof and limits

The installed Falcon-H1 0.5B 4-bit bundle produced four disk stores and one accepted restore at boundary161 through the native app. The topology is 36 composite KV/Mamba layers with fp16 KV and disk-backed restore, paged RAM disabled. Do not call this TurboQuant KV. The app was operated through the actual chat and Settings controls, including Save and regeneration.

The cached follow-up gave an incorrect total and stray markers. A cold control used the same333-token prompt and matching recorded digests, disabled prefix reuse through Settings, and logged a full miss with zero disk hits/stores. It also failed quality, omitting the requested total and emitting grounding/marker text. Both answers and failures are retained. Cache reuse was restored through Settings after the control; both private app processes exited normally.

Separately, a production-model test loaded the actual installed Falcon weights, serialized and restored its cache through a safetensors file, and compared eight continuation steps against the untouched cache. All eight maximum logit deltas were exactly0.0. This is bounded cache-state parity, not proof of the full transcript or the cause of Falcon's poor answer quality.

UI measurements: first72tokens at200.8tok/s; cached follow-up313tokens at185.3tok/s; cold control370tokens at206.5tok/s. Concurrent compilation makes these telemetry, not a speed comparison. Peak app physical footprint was1.28GB/1.30GB, with no abort; this is not a low-RAM family qualification. Bundle config identities and defaults are in `cache-pin/proof-bundle-default-identities.json`.

Live records: `cache-pin/ui-proof-r2/LIVE-RECEIPT.md`, `ui-proof-r3/LIVE-RECEIPT.md`, and their raw transcripts, cache snapshots, logs and memory receipts. Installed-weight parity: `coordinator-store/test-installed-falcon-r1.log`. The original refused-store failure remains under `cache-pin/ui-proof-r1`.

## Full eval records and merge gate

Fresh local Gemma matrix: AgentLoop44passed/11failed/4skipped of59; AgentLoopFrontier23passed/19failed of42. Total67passed/30failed/4skipped of101, versus the earlier59/38/4. Outcomes moved both directions; this is not a clean pass or a causal improvement claim. All96 generation rows have measured throughput; the other non-skipped row deliberately exits before generation on context overflow. Peak physical footprint4.87GB, no guard abort.

Local raw scores, every nonpassing case and changed outcome: `cache-pin/gemma-full-r2/results`, `NONPASSING-REVIEW.md`, `comparison.json`, and `receipt.json`. Rubric self-judge limitations are retained separately from deterministic tool/file assertions. The app executable and eval-case sources are unchanged from the prior baseline apart from the engine dependency; source scope is recorded in `cache-pin/baseline-source-diff.txt`.

The fresh remote comparison uses adlab/Qwen3.8-Flash-Next and an empty local-model inventory. Its canonical result and completion records are `cache-pin/remote-full-r2/results` and `receipt.json`; the final PR evidence must include its full denominators and failures. Remote throughput is unavailable from the transport, not inferred. Credentials are not stored in evidence.

Before merge, require both full-lane completion records, failed-case review, unchanged executable inputs, and green final-head Osaurus CI. Preserve all failures rather than changing suite limits or model behavior. No releases or tags.

## Separate follow-ups

- Diagnose Falcon's model/harness quality independently; cache-disabled failure and bounded state parity do not establish a complete root cause.
- Diagnostic labels: `cache_enabled_model_count` currently counts the presence of cache statistics even when reuse is disabled. The cold control confirms no reuse. Review this with the previously documented compiled/eager telemetry mismatch, preserving API compatibility.
- Consume the later contributor tokenizer/config fixes in a separate Osaurus pin with applicable proof.
