# Gemma QAT native checkpoint: scoped results and open gates

Status: partial qualification. No release, tag, broad model-family pass or low-RAM claim.

SOURCE EVIDENCE: runtime `f1747342d881ba7b8b6a3bed84fd5fd60b99e96c`, consumer Release26 `8327e0b179b1a2485a53d1dacf8e48e9a9e387ff`, app build `2026110426`. Consumer `e87b9fb919aecf5e354cce9f86d217b3184c8ba5` adds eval/documentation changes after that app; Core production sources are unchanged. The archived executable, plist and full Metal library were hash-verified before this continuation. Forty-eight protected loop/tool files match their retained baseline. No implementation changes were made during these checks.

LIVE EVIDENCE: the private evidence root `/Users/eric/vmlx-private-evidence/goal-storage-cache-resume-20261104` contains the native exports, screenshots/accessibility captures, actual tool arguments/results, process logs, physical-footprint samples and cache headers. `build26-26b-jang-native/NATIVE-RECEIPT.json` closes the previously missing final export. `build26-31b-mxfp4-native/NATIVE-RECEIPT.json` and `build26-31b-jang-native/NATIVE-RECEIPT.json` bind the new actual-app runs.

## Newly closed native rows

Each row executes `53 * 47 = 2491`, then `2491 * 3 = 7473`. A real attached image supplies `M913-CP28`, `7265`, purple; the model actually calls `7265 + 3 = 7268`. After normal app termination and relaunch, it calls `7268 * 2 = 14536`. All four workflows settle, input unlocks and visible answers match the executed results. These are four named workflows per bundle, not four full evaluation suites.

| Bundle | Native workflows | Displayed task decode rates | Persisted KV | First restart SSD restore | Peak sampled physical footprint |
| --- | --- | --- | --- | --- | --- |
| 26B A4B JANG_4M | 4/4 | 56.7–61.8 tok/s | F16; 5 full + 25 rotating | 6369 / 6459 tokens | 22,823,386,928 bytes |
| 31B MXFP4 | 4/4 | 12.6–19.1 tok/s | BF16; 10 full + 50 rotating | 6302 / 6462 tokens | 28,985,931,048 bytes |
| 31B JANG_4M | 4/4 | 10.1–10.6 tok/s | F16; 10 full + 50 rotating | 6369 / 6459 tokens | 36,651,338,832 bytes |

Each native row contains eight actual model requests with positive reported output/rates and explicit `enableThinking=false`; runtime receipts report `toggle_off`. Sampling inherits the bundle's temperature 1, top-p .95 and top-k 64. Saved q6 head, prefix/SSD on and paged RAM off remain effective; there is no native MTP head. Twenty persisted payloads per row validate the actual configured layer kinds and floating dtype. TurboQuant KV layer count is zero: these are raw/rotating, disk-backed restores, not a TurboQuant-KV-layer topology. No duplicate model weights or cache-payload copies were made.

All three physical-footprint gates fail against their model weight sizes. Owned loading is retained by explicit user choice. Rates are correctness observations, not controlled speed comparisons. A transient `Prefill 4608/5673 · 81%` was observed in the MXFP4 live accessibility output; the subsequent screenshot was after prefill and must not be cited as a screenshot of that percentage.

## Selected calculator evals and failure attribution

`GEMMA-CALCULATOR-SELECTED-RECEIPT-20261105.json` binds two unchanged calculator cases on each of five bundles: exact large multiplication and summing a CSV containing the quoted amount `1,249.99`. All pass and fail transcripts are retained. Official reports self-judge; independent integer/Decimal checks of fixture values, actual arguments/results and visible finals agree with the scores.

| Bundle | Selected eval score | Attributed failure |
| --- | --- | --- |
| E2B MXFP4 | 1/2 | Sends 249.99 instead of 1249.99 to calculate; correct calculation of wrong operands yields 1930.74. Also emits reasoning despite explicit Off. |
| E2B JANG_4M | 1/2 | Chooses naive comma-split awk, omits the quoted amount and returns 1680.75; required file_read/calculate calls are absent. |
| 26B A4B JANG_4M | 2/2 | None in these two cases. |
| 31B MXFP4 | 2/2 | None in these two cases. |
| 31B JANG_4M | 2/2 | None in these two cases. |

Total: 8 pass, 2 fail across 10 cases and 24 task model steps, all with positive measured decode rates. The failed producer processes exit 1 as expected; the three passing producers and all five resource samplers exit 0. No retry replaced a failure. These observations locate the bad operand/command choices; they do not establish a runtime/cache root cause. No prompt, sampler, tool schema, parser rescue or behavior-forcing change was added.

## Remaining work

- Earlier E2B/E4B reasoning, OCR, stale-memory and empty-response failures, 12B native 2/4 rows, and 26B MXFP4 native 2/4 remain failures. The earlier selected 26B MXFP4 append failure remains recorded; the broader append/edit campaign is not resumed.
- All ten QAT variants now have native observations and a scored selected AgentLoop artifact at this runtime. That does not complete full suites, cross-setting combinations, cancellation/eviction/quota, numerical media parity or family qualification. Different selections and denominators must remain separate.
- Runtime #726 is merged at `309c2a2bae541188164af54f58e0740046f459a4`; its Git tree equals reviewed `0492fee7`. Consumer `b3b22af8` pins that actual merge in four locations and two source expectations. GitHub reported no branch-required checks for runtime #726. The queued optional runtime Mac job covers unchanged Cmlx/MLX bindings, not the changed Gemma loader regressions; it is not represented as passing. No shared runner, global DerivedData or workflow gate was changed.
- Consumer integration and qualification limits are recorded below. No release operation is authorized.

## Actual merge-pin consumer integration

SOURCE EVIDENCE: consumer `b3b22af87ff49026ffc8201d627ed63e95c970c0`, runtime merge `309c2a2bae541188164af54f58e0740046f459a4`, MLX core `3b39b5e7925fa8860ab8ccd79b054349872e24a5`. The reused build directory produces a fresh isolated Release `2026110427`; its actual dependency checkout, signature and full 3,293,300-byte Cmlx Metal library are verified by `APP-IDENTITY-BUILD27.json`. All 115 tests in RuntimePolicySourceTests and ImageGenerationBridgeContractTests pass on this pin. The source/log manifest for the earlier 24 loader combinations plus 11 other checks remains hash-valid; production loader/container sources are unchanged by the merge. This documentation update changes no app or test implementation.

LIVE EVIDENCE: `merged27-31b-mxfp4-native/NATIVE-RECEIPT.json` and `merged27-26b-jang-native/NATIVE-RECEIPT.json` bind new actual-app runs, exports, visible tool/answer/restart controls, samples, exact bundle defaults and typed cache headers. They are merge-pin integration checks for dense MXFP4 and MoE affine JANG; the earlier ten-bundle observations retain their original identities.

| Actual merge-pin row | Strict workflows | Semantic final answers | Typed cache and first restart restore | Observed peak physical footprint |
| --- | --- | --- | --- | --- |
| 31B MXFP4 | 4 pass / 4 | 4 correct / 4 | 20 BF16 payloads; 10 full + 50 rotating; 6295 / 6446 tokens from disk | 27,429,977,712 bytes: RAM FAIL |
| 26B A4B JANG_4M | 3 pass, 1 fail / 4 | 4 correct / 4 after one automatic retry | 21 F16 payloads; 5 full + 25 rotating; 6302 / 6464 tokens from disk | 22,519,152,672 bytes: RAM FAIL |

The JANG image workflow is a failure despite its eventual correct answer. Its first post-calculator response emits 82 tokens as reasoning only and no visible answer, despite explicit Thinking Off and runtime `toggle_off`. The existing client retries the identical request as `r1`, which yields the visible answer. The expanded UI shows “Thought for 1.2s”; original `r0` and successful `r1` both remain in the nine-request export. Request bodies and rendered prompt bytes match exactly between attempts (prompt SHA256 `19a2f0880e3f79accb36755cf34cd63e5d454af2997af6c174b09a422e113daa`), with no injected think directive. No prompt, sampler or retry policy was changed; a cache/loader regression is not established by these stochastic observations. The stricter receipt records 3/4 rather than silently retaining a 4/4 score.

Both rows use explicit Off, bundle T1/.95/k64, saved q6, prefix/SSD on, paged off and zero TurboQuant KV layers. All 17 actual requests have positive recorded generation rates, including the failed reasoning-only response. Displayed task rates are 18.5–18.9 and 61.7–64.5 tok/s respectively, not controlled speed comparisons. All four app processes and resource samplers close normally. Model-quality, Off compliance, full-suite/settings/media/cancellation and low-RAM gates remain partial; owned loading is retained. No loop, orchestration or tool implementation edits, duplicate model weights, release or tag.
