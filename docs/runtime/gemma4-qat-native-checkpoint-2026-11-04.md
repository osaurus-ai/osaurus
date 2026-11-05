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
- Runtime #726 and consumer #3315 remain drafts. Before this documentation update, all ten consumer checks passed on `e87b9fb9`; runtime reference/Linux checks passed, advisory formatting failed and Mac/CUDA jobs remained queued. GitHub reported no branch-required checks. The local runner is registered to a different repository; no shared runner, queued job, global DerivedData or workflow gate was changed.
- Normal runtime landing, repinning all four consumer locations and two test expectations to its actual merge SHA, and affected consumer integration/CI proof remain outstanding. No release operation is authorized.
