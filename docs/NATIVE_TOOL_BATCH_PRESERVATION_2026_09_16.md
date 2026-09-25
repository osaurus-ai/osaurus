# Preserve native local tool batches

NOW: Native batch preservation implemented and exercised in an isolated development app at `4a000c59304f8f0d058d0852ca1465dfe0b69dc8`. Main advanced to `65ff7cc4e032fd90cbf9a5453f1359a9567d4704` with shared tool/runtime and eval-catalog changes; merged without conflicts in `1f26d7b9237be911fbbb3edd601bb1d9e50e8f09`. Integration rebuild, affected native matrix and fresh full evals are required before merge. Engine pin remains `8ba593aff16c13cf526211b8477c0a037f0122af`.
DO NOT: Change RAM policy, model prompts, generation defaults, engine weights, or installed profiles. Do not equate source/fixture tests with model/UI proof.
BATCH OWNER: Forward every completed local invocation once in its original batch order, preserving cancellation, argument/result identity and cache ownership. Existing parallel scheduling does not guarantee child start/completion order.
NEXT: Complete the current-main integration proof and exact-head CI for PR #2792, then review and merge. The tables below are retained prior-source results, not proof of the integrated binary. New source identity, commands, raw scores and limitations are recorded in the private `integration/` evidence subdirectory and PR proof receipt. Broader eval failures remain open; no model-wide or RAM-policy certification.

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

## Source and build identity

- Production fix: `0986c33f430b83b88dea03d93d318f855cd9efa7`; follow-up `4a000c59304f8f0d058d0852ca1465dfe0b69dc8` updates two old test expectations, not production behavior. This receipt update changes documentation only.
- Bridge: `Packages/OsaurusCore/Services/ModelRuntime.swift:5774`; adapter: `Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift:1674`. The bridge retains duplicates and delayed calls; the adapter no longer cancels at the first tool. Real cancellation and awaited cache/allocator cleanup remain.
- Fresh optimized Release-configuration **development** app, ad-hoc signed, not a public release/install: `/private/tmp/osaurus-tool-batch-derived.3Gtb15/Build/Products/Release/osaurus.app`.
- Bundle ID `com.dinoki.osaurus.toolbatch0916`; executable SHA-256 `8cb2ac228691a9a8eb7d35e7d785c5e96efacaa3dc0b135e37f8855875a0378a`; UUID `758C7805-8017-38CB-85C9-5B02148055BB`. App/metallib hashes rechecked after the eval-driver build. Engine pin unchanged; no repin is needed.
- Explicitly user-authorized Max2 isolated proof, 128 GB host, port 19372, profile `/private/tmp/osaurus-tool-batch-ui.unQvx1`. No physical 16 GB or OOM emulation.
- Gemma `OsaurusAI/gemma-4-E2B-it-8bit`, snapshot `433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`, weights 5,899,232,198 bytes. Bundle/runtime defaults temperature 1, top-p 0.95, top-k 64, sampling on, EOS IDs [1,106,50]; no hidden sampler/prompt repair. Effective parent/child limits were 16,384/8,192, not a claim that the older child configuration's 2,048 was enforced.
- Existing different-model child `raptor-0.6-preview-jang_6m` from `/Volumes/EricMLWork/models/OsaurusAI/Raptor-0.6-preview-JANG_6M`, effective temperature 0.6, top-p 0.95, top-k 20. Both model metadata hashes retained privately; no downloads.

## Deterministic and CI evidence

Exact production-body replay of main delivered **native 1/2 vs complete-response API 2/2**; candidate delivered **2/2 on both**. `baseline.log` and `fixed-bridge.log` retain the executable results and generated source bindings. This is a model-free reproduction, not a GUI claim. Focused extracted bridge tests passed 8 tests / 11 cases (`focused-bridge.log`); full-module CI is separate.

Exact tested-source [CI run 35180890946](https://github.com/osaurus-ai/osaurus/actions/runs/35180890946) passed core, CLI, packages, StatsPack, evals, SwiftLint and ShellCheck. Core XCTest summary: 401 executed, 8 skipped, 0 failed, plus passing Swift Testing suites including LocalToolBatchBridge, LocalToolCompletionContract, LocalInputTokenUsage, GenerationEventMapper and RuntimePolicySource. Evals unit tests: 355 Swift Testing plus 2 XCTest; StatsPack: 20 Swift Testing. These unit results are not the live model eval scores below.

The first candidate CI run exposed two obsolete single-call/accounting expectations. They were corrected to assert completed batch/accounting behavior in `4a000c5`; no tests were disabled. Tests cover delayed and identical calls, cancellation, errors, clean EOF, completion before wrapper drain, preview reset, API terminal-error accounting and adapter no-early-stop source guard.

## Actual native Chat / agent proof

`LIVE-MATRIX.md`, run1/run2 full prefill logs, SQLite transcript snapshots, per-turn cache JSON, AX trees and inspected local screenshots bind these results. UI controls were exercised through PID-scoped Accessibility plus osascript activation, not configuration-only assumptions. Continuous Batching OFF/ON and Concurrent Sessions 2 were saved; ON/2 survived app relaunch, and the final OFF change reported effective limit 1.

| Native row | Runtime observation | Final visible generation |
| --- | --- | --- |
| B1, batching OFF | Batch `FA88A375` parsed/published 2, executed two distinct Writer calls, both results bound to their original tasks, parent used both | 101 tokens, UI 81.9 tok/s |
| Same-chat follow-up | Checklist grounded in both child results; terminal controls settled, input unlocked | 63 tokens, UI 80.3 tok/s |
| B2, batching ON / sessions 2 | Batch `E33A77C8` published 2; both child STEP-BEGIN at 21:51:36.605, active high-watermark 2, both results returned | 100 tokens, UI 78.8 tok/s |
| Different-model handoff | Batch `E83ED7D6`: Gemma parent → Raptor child → Gemma Writer → Gemma parent; actual swap_unload_reload receipt and distinct results | 80 tokens, UI 63.6 tok/s |
| Child AgentToolLoop itself emits two tools | Raptor batch `A98152E4`, completeResponse=false, two real get_current_time calls for Tokyo/New York; both executed, child resumed, Gemma relayed both | Child usage 510 tokens / 42.2 tok/s; parent UI 60 tokens / 77.0 tok/s |
| Stop before publication, B2 | Actual Stop after first parsed invocation of `06D91598`; no publication/execution, lease released, active/pending 0 | Recovery 24 tokens, UI 79.1 tok/s |
| Stop active/queued children | Actual Stop while Raptor ran and Writer waited; both executions settled, no queued Writer STEP-BEGIN; active/pending 0 | Recovery 28 tokens, UI 79.0 tok/s |
| Stop before publication, B1 | `A88B0C89` index0 parsed at 22:24:37.656; real Stop 37.676–37.857, lease released 37.815, no publication/execution | Recovery 22 tokens, UI 80.4 tok/s, TTFT 0.35 s |

The old baseline app completed two children in **separate** parent responses on this prompt. That GUI run is not a two-call reproduction; the exact-main executable replay demonstrates the deterministic loss. Candidate traces demonstrate both calls from one response reach actual native execution.

First parsed call → batch publication measured 0.773 s (B1), 1.479 s (B2), 0.869 s (handoff), 0.645 s (child). Waiting for complete response is intentional; no first-call-latency-neutral claim. Cancelled rows only emitted estimates, including a zero-token estimate before publication, and are not successful throughput rows. The active-child automation watcher initially timed out because it matched a zero-tool child and Raptor had two; the retained manual Stop trace is the actual evidence, not that failed watcher.

Effective Gemma cache: fp16, 3 KV + 12 rotating layers, zero TurboQuant layers, paged RAM off, disk-backed restore required. Final run2 active/pending=0 and inference_activity=[]; loaded-model L2 hits=1 versus cumulative BatchEngine L2 hits=66 (different scopes). Cache/topology snapshots are retained; no TurboQuant or generic prefix-hit claim.

Run1 peak sampled app phys_footprint 4,173,564,736 bytes, lifetime peak 4,932,684,608. Run2 938 samples, sampled peak 3,002,550,912, lifetime peak 3,532,786,256. Swap remained 2.59 GB in supervised runs. Run1 app/eval were resource-stopped at 22:12:50–51 when free memory fell below the unchanged 24 GB reserve, with zero owned survivors. No unrelated jobs were killed. Run2 used the identical binary, completed the remaining checks and was quit normally at 22:25:21, exit 0 with zero owned survivors.

## Full live model evals — NOT all-pass

Unmodified suites ran via a lightweight CLI using the isolated app's HTTP inference. CLI's empty local-model root prevented additional model loading. This is complementary API regression evidence, not native-stream proof.

| Suite | Passed | Failed | Errored | Skipped | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| AgentLoop | 34 | 9 | 1 | 4 | 48 |
| AgentLoopFrontier | 16 | 19 | 4 | 0 | 39 |

Frontier resume uses the existing EvalRunner.resumeRows API. `eval-resume-integrity.json` verifies all 29 original completed rows are unchanged and the final report has 39 unique IDs; only the interrupted and unfinished cases ran again. Exit 1 is retained for both non-perfect reports. Original/resumed logs and transcripts remain intact.

The local model judged itself through a provider alias; individual `selfJudge=false` fields are misleading here, while environment says self-judge. All five AgentLoop and four Frontier judged rows were manually reviewed against transcripts; raw outcomes were not rewritten. `EVAL-REVIEW.md` records every failed/errored case and manual rubric decisions.

Attribution: missing CLI-only worker IDs and unprovisioned sandbox/AppleScript-model fixtures limit coverage; the rejection-stops-run fixture disagrees with existing typed-error correction policy. Other failures include invalid arguments, missing/wrong files, forbidden extra tools, partial refactors and unsupported final claims. Empty-after-tool continuations remain **unresolved**, not attributed to Gemma or claimed fixed. One Frontier format-contract step generated 16,384 tokens, reached length stop in 246.177 s and yielded no visible reply: an error, not coherent throughput success. No matched-baseline claim that these failures are regression-free is made.

This PR fixes the demonstrated local invocation-loss mechanism only. Broad model correctness, cloud/media, low-RAM admission, target-pool/settings redesign and all possible delegation lifecycle phases remain outside this receipt. No release/tag/install was performed.
