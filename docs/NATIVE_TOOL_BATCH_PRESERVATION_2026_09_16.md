# Preserve native local tool batches

NOW: Authorized follow-up to the two-call bridge audit. Base is current canonical main `fa706a5de9f824c3d22475aa3cada15a99636f2e`, engine pin `8ba593aff16c13cf526211b8477c0a037f0122af`.
DO NOT: Change RAM policy, model prompts, generation defaults, engine weights, or installed profiles. Do not equate source/fixture tests with model/UI proof.
BATCH OWNER: All parsed local calls must reach native Chat/agent execution once, in order, with real cancellation and cache ownership intact.
NEXT: Reproduce on main, remove both first-call cutoffs, run regression tests, build and exercise the isolated Max2 app, review and merge a PR after the required gates.

## Cause and design

Two independent first-call cutoffs exist on the base:

1. `ModelRuntime.bridgeToolEventStream` ends the public stream with the first invocation and discards every subsequent event in native mode. Complete-response API mode already collects all calls.
2. `MLXBatchAdapter.generate` requests `cancelActiveSoloGenerationAndWait()` after the first `.toolCall` on its single-request path. Even a lossless downstream bridge cannot recover calls that this early stop prevents the model from generating.

The pinned engine flushes its detokenizer and tool parser before `.info`; this is the logical response boundary, not the first closed call. The adapter deliberately retains `.info` until engine/cache/allocator cleanup finishes. Preserve that ordering: it prevents an immediate next request from overlapping allocator windows. The mapper then publishes `.completionInfo` and ends its public surface while draining the remaining wrapper tail.

Collect each invocation through logical completion. Native mode may stream call previews immediately, but must not execute a partial batch. Publish the ordered single/batch error at `.completionInfo`; use clean EOF as a compatibility fallback when no completion event exists. Full-response APIs retain their existing EOF/error accounting. Real consumer cancellation still cancels the exact producer and suppresses queued calls. Remove only the adapter's call-triggered stop, retaining its actual cancellation handler and awaited producer drain.

Tradeoff: native single calls no longer execute at the first closed envelope. They wait for response completion and the existing adapter cleanup barrier, allowing subsequent calls to arrive. No timer can safely determine that a second call will not arrive; no prompt or token-limit masking is allowed. Live proof must record this latency and tail behavior rather than assert unchanged first-call latency.

## Acceptance and evidence

- Model-free production-body replay: two calls must produce two, native and API.
- Full-module regressions: delayed calls, identical calls, clean EOF, error before completion, cancellation before/between calls, completion-before-wrapper-drain, strict API terminal accounting, source guard against call-triggered adapter cancellation.
- Fresh isolated development app: parsed/published call counts, actual tool cards/arguments/results, two-child delegation, follow-up, Stop, input unlock, cache telemetry, generation rates and supervised physical footprint.
- Relevant core tests, AgentLoop / AgentLoopFrontier evals, exact-head CI and diff review.
- No release/tag/install. Existing main checkout contains unrelated dirty work; this isolated PR branch starts exactly at remote main and leaves that checkout untouched.

Private evidence: `/Users/eric/vmlx-private-evidence/native-tool-batches-2026-09-16/`.

Status: implementation and new live proof pending. The previous audit's approval blocker is resolved by the user's explicit follow-up request.
