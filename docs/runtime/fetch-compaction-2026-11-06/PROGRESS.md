# Fetch result recovery and compaction deadlines

Status: bounded source/app acceptance complete; normal CI/merge pending on draft PR [#3336](https://github.com/osaurus-ai/osaurus/pull/3336). No merge until CI passes; no release actions authorized in this fix lane. This is a bounded result-recovery/deadline fix, not a guarantee that a model will read every page or that every compaction succeeds.

## Scope and source identity

Base Osaurus `0eb0d0c867c116af7aac5af020ce141e095556fb` (0.25.32); unchanged runtime `1bcd74ad182103a3b83941f61e57ee0bac23b330`. Functional source commit `248d4d9657fc3e642075fa9526a133d4aa41f29f`; localized phase labels `a44ae4d8cfe4b01968a229c4a442eee7d48feec9`. Build07's eight product-source hashes remain current. Subsequent changes qualify tests/docs only.

Protected files: AgentToolLoop, AgentTaskState, ChatView, SystemPromptComposer, SystemPromptTemplates. Their baseline hashes are retained and must remain unchanged. No tool schema/grant, retry, scheduling, continuation, sampler, chat template or runtime pin changes. The auxiliary model handoff retains its existing ownership/order; phase observation is optional for other callers.

Evidence root: `/Users/eric/vmlx-private-evidence/fetch-compaction-fixes-20261106` (P below). The four-day history audit is retained under `/Users/eric/vmlx-private-evidence/osaurus-release-settings-20261106/fetch-truncation-investigation/history-audit`. Private screenshots, raw chat/activity, model receipts, failed attempts and xcresults stay outside GitHub. `fetch_fixture.py` in this folder is the deterministic, model-free reproducer.

## Mechanisms and historical attribution

- The registry's existing 100,000-byte universal result cap intentionally protects context. A provider accepting only a URL cannot recover its missing middle by retrying the same fetch. The original warning suggests narrowing arguments that this provider does not expose. The cap/warning predates this campaign (#1438, June10).
- Compaction's 180-second whole-operation deadline could expire while it was still waiting for local admission (whose own budget is300 seconds), before summary inference started. The deadline originated in #2265; our historical #2798 put shared owned handoff inside it. #3249 added complete-summary validation and #3258 added automatic compaction after drained tool batches. These compose into the reported failure mechanism; the later trigger alone is not the root cause.
- The audit accounts for67 merged PRs (38 app,29 runtime),54 from this campaign author, and81 reachable main commits. Tags0.25.31/0.25.32 have identical cap/compaction/admission/driver source. The original user's model, provider, arguments and Insights are unavailable. Controlled reproductions establish mechanisms, not exact incident attribution. The reported Metal fault is excluded.

## Changes

1. Retain pre-cap normalized results only when existing file_read exposure and session+agent identity permit recovery. Private cache:4MiB source per entry,64MiB combined payload/metadata file-byte quota,24-hour TTL,700 directory/600 files. Opaque canonical UUID references grant no ordinary filesystem access. Failure remains explicit and falls back to the existing cap.
2. Existing file_read pages scalar-safe1024-byte JSONL chunks with exact source byte offsets and SHA256; concatenating text fields reconstructs the normalized result. Existing line/tail/max_chars controls apply. Serialized page cap60000 bytes includes warnings. Partial pages provide truncated/has_more/next_read; an ending page describes its suffix, not proof that the caller previously read every chunk. No automatic reads/refetch/retries.
3. Scoped reads validate owner, expiry, stored size/hash/line count, reject symlinks and preserve typed unavailable responses. Batch accounting includes page content. Large normalization/I/O is detached and cancellation checked; small results retain the existing path. Bounded recovery metadata survives the old1200-character compaction clip.
4. Compaction has separate admission300s, existing handoff/restore budget (default900s), and unchanged inference180s deadlines. Passive observations come from actual admission/handoff/body/cleanup phases. One-shot completion and relay invalidation prevent late work reviving completed UI. Noncooperative cleanup may drain while retaining its original owned resources. No producer or handoff is moved outside its existing lifetime.

## Actual native app proof

All inference was initiated through the signed Release app on erics-m5-max2. No CLI/API inference. Main model: external-drive `OsaurusAI/Raptor-0.7-preview-4B-JANG_6M`, bundle defaults Light, temperature1, top_p0.95, top_k-1, max_tokens1048576, repetition1, presence/frequency0. Agent has zero generation overrides. Memory/concurrency/swap settings and actual request arguments remain in P. This is not global model-family, cache-topology, RAM or speed qualification.

| Row | Observation | Receipt |
| --- | --- | --- |
| Baseline oversized fetch |116845-character document becomes119002 normalized bytes, then an irrecoverable head/tail excerpt. Missing middle note; retry returns same omission. | BASELINE-ACTUAL-TRUNCATED-RESULT.json |
| Baseline queued compaction |Real delegated220-second terminal wait. Compaction fails at180010.13ms without inference output; worker later completes WAIT_COMPLETED. Original history remains. | BASELINE-COMPACTION-RECEIPT.json |
| Candidate byte recovery |All119002 normalized bytes reconstruct exactly; original document SHA25644773db4fcc4a1ebab2f3b2adc5757912a8a41fba54686932cda312c895b5e2f; normalized SHA25604090be68dba383cada4df828541b7ca8beb7fbca0b2c0a1d45674e298463c88. | CANDIDATE-CACHE-READBACK.json |
| Guided recovery/multi-turn |Existing file_read retrieves MAPLE-4827 / USD38147.62, then arithmetic returns USD38247.62 with same code. Exact Build07 repeats recovery and follow-up after an autonomous failure. | candidate-07-fresh-gap-recovery.ax.txt; candidate-07-fresh-followup.png; CANDIDATE-07-FRESH-ACTIVITY-LATEST.json |
| Relaunch/ownership |Same session+agent reference survives relaunch; identical arguments in a different session are denied. | candidate-07 ownership/relaunch AX receipts; CANDIDATE-07-ACTIVITY.json |
| Ordinary file batching |One existing paths batch reads both cache tail and ordinary control SANDSTONE-29 correctly. | ORDINARY-FILE-CONTROL.json; candidate-07 batch AX receipts |
| Expiry |Only test-entry timestamp made48h old; same-owner cached read explicitly refuses it. Runtime clock/code unchanged. | CACHE-EXPIRY-FIXTURE.json; preserved original metadata; candidate-07 expiry AX receipts |
| Real distinct-model handoff |0.7 main ->0.6 summary ->0.7 reload; phases observed in actual logs. Summary398 estimated tokens in16.782s (23.715 aggregate tok/s including handoff), context42k ->5.7k; grounded continuation succeeds. | compaction-07-unified-log.json; CANDIDATE-07-ACTIVITY.json seq89; candidate-07-app.log |
| Current long admission success |Real240-second delegated terminal wait and manual compaction started; native UI says Waiting for other local work. At215.75s still waiting; actual summary succeeds at231360.57ms with490 estimated tokens (2.118 aggregate tok/s including the wait), reclaims23481 tokens, and the grounded continuation returns original38147.62, adjusted38247.62 and MAPLE-4827.The separate expiry/retry row below is also complete. | CANDIDATE-07-QUEUE-240-RECEIPT.json; candidate-07-queue-240-* |

| Real admission expiry |Timed out at300004.657ms while waiting, no output tokens/rate because inference never started. Exact prior22 turn records and decoded summary unchanged immediately and after worker release. Durable error inspected in the actual Insights detail UI. | CANDIDATE-07-QUEUE-TIMEOUT-RECEIPT.json; CANDIDATE-07-QUEUE-TIMEOUT-HISTORY-UNCHANGED.json; CANDIDATE-07-AFTER-WORKER-RELEASE-NO-LATE-APPLY.json; candidate-07-timeout-insights-detail.png |
| Owned worker Stop and explicit retry |Stopped only this delegated worker through its native Stop control; shell result is CancellationError, no false WAIT_COMPLETED success. Expired compaction stayed idle. New explicit compaction succeeds in7477.053ms,560 estimated tokens,74.896 aggregate tok/s, context19k ->5.6k; grounded continuation returns38147.62,38247.62,MAPLE-4827. | CANDIDATE-07-STOPPED-WORKER-HISTORY.json; CANDIDATE-07-FINAL-COMPACTION-RECEIPTS.json seq67; candidate-07-after-timeout-followup.png |

### Failed model behavior must remain visible

Build05 autonomous paging failed; a guided next_read follow-up recovered the data (including a schema-invalid nested-next_read attempt followed by a valid read). Fresh Build06 autonomously followed the pages and succeeded. Fresh exact Build07 read only the first page and tail20, skipped chunks51–97, and falsely claimed complete inspection; no hidden note reached that turn's inference input. Explicitly reading the missing gap then succeeded. CANDIDATE-07-FRESH-CALLS.json and raw activity preserve this failure. The app fix makes omitted bytes recoverable; it does not prove reliable autonomous pagination. No prompt coercion, parser masking, coverage guard or agent-loop change is added to force a pass.

## Automated verification and failures

- Current functional source:218/218 affected tests in26 suites (`CURRENT-AFFECTED-SUITES-RESULT.json`), including exact byte reconstruction, Unicode/control/single-line JSON, quota/orphans/unknown files, owner/TTL/tamper/symlinks, tiny budgets, batching, cancellation, error-envelope and secret-marker contracts; deadline boundary/race/cleanup/relay/default-observer compatibility.
- EvalsKit03:384/384 tests across50 suites. Twelve token-free floor suites:143 passed,15 live ComputerUseLoop rows explicitly skipped, all exits0 (`TOKEN-FREE-EVALS-02-RESULT.json`). These are scripted/model-free and do not substitute for GUI inference. No harness driver edits.
- Full current core02:12555 passed,44 failed,64 skipped of12663. Identical clean-main tree:12529 passed,45 failed,64 skipped of12638. Every44 candidate failing test name also fails baseline; zero candidate-only failing names (`CORE-02-BASELINE-COMPARISON.json`). Both full runs are red, not a green regression gate. Baseline additional failure is mtpResolutionHasNoSpawnDimension().
- Standalone production deadline probe: combined queue/generation/restore, all four phase expirations and100 immediate-cancellation races pass (`DEADLINE-PROBE-RESULT.json`). Component evidence only.
- CI at a44: all jobs except test-core passed. test-core exposed our new restoration test's invalid120ms-sleep/200ms-deadline timing assumption: loaded runner resumed after244ms, so generation correctly expired. Positive phase tests now transition synchronously with scheduler margin while restoration still exceeds the prior generation budget. Production deadline source/budgets are unchanged. Focused07 passes218/218 after the test-only correction (FOCUSED-07-SOURCE-VERIFIED.json records exact current source/test hashes). Normal CI remains required; no forced green.
- Initial248 CI failed three missing localization keys; a44 fixed the catalog, local i18n check passed. Earlier build/test setup/compiler/assertion failures remain retained under P and are not attributed to main. Focused06 was intentionally interrupted after accidentally starting against the same DerivedData as05; retry sequentially, do not count the interrupted run.
- Every GUI generation row retains output_tokens, duration and tokens_per_second in activity. Rates include startup/prefill/handoff where applicable. No matched speed-regression, other Mac/family, low-RAM or universal prevention claim.

## Ordered remaining gates

- [x] Historical source/PR audit and baseline oversized-fetch plus180s queue failure.
- [x] Implement scoped recovery and phase-owned deadline changes without protected-file edits.
- [x] Affected tests, EvalsKit and token-free floors; full baseline comparison retained.
- [x] Fresh signed exact-source Release app; guided recovery/multi-turn, relaunch isolation, ordinary batching, TTL refusal and real distinct-model handoff.
- [x] Current app: capture waiting beyond180s, then actual summary/grounded continuation after natural240s worker completion.
- [x] Current app: real300s admission expiry, no summary/history loss/late revival; fresh retry after owned worker releases.
- [x] Scheduler-robust affected tests: Focused07 exact test hashes,218 passed, zero failed/skipped.
- [ ] Normal PR CI must pass; never bypass failed checks/reviews.
- [x] Source/live receipts updated here. Original incident attribution and autonomous model paging remain explicitly partial.
- [ ] Refresh PR body/head/CI before ready and normal merge.
- [ ] Normal scoped merge only after gates pass. No release/tag.
- [ ] After stopping only our test app/jobs, remove only superseded owned build/cache tensors; preserve canonical external models, raw logs/history/xcresults/hashes and unrelated work. Baseline-test DerivedData already retired (~10GiB logical; no isolated physical-space claim).

## Final boundaries and evidence corrections

SOURCE EVIDENCE: CANDIDATE-07-ARTIFACT.json plus FOCUSED-07-SOURCE-VERIFIED.json bind all eight current product files to the signed Release app (binary SHA25623ac769b8ecc1805ca0f1aa84b2b241517f85a5cbd6c4e50a79352c9654a86bd), unchanged runtime pin and five protected-file hashes. Later test/docs edits do not change product code. The current restoration/admission success tests allow scheduler margin and still prove elapsed previous-phase time cannot consume the next phase's budget.

LIVE EVIDENCE: Exact Build07 native Chat/Settings/Insights actions, activity seq55/63/67 and screenshots prove long admission success, accurately attributed bounded expiry, unchanged history, no late application after release, explicit retry, real distinct-model restoration, saved default-model selection, recovery ownership and multi-turn fact grounding. Direct manual-compaction cancellation has no UI control in this app; do not claim a nonexistent Cancel button. Component cancellation/race/late-relay tests and actual owned worker Stop are separate evidence.

Initial raw JSON-string equality after worker release failed because an existing save reordered summary dictionary keys. Every decoded summary field and all22 turn records were identical; receipts retain both snapshots and the corrected semantic comparison. The original transient timeout badge reset before screenshot capture; the actual durable Insights detail was opened and visually inspected instead.

FOCUSED-07-COMMAND.json reused an older command's source_hashes field. FOCUSED-07-SOURCE-VERIFIED.json explicitly corrects that metadata from actual current file readback, matching Build07, and verifies the test-file hashes. Original artifacts remain retained. These corrections do not change product source.

Space: inactive profile06 KV cache was retired after normal app exit and an open-handle check;45870450200 logical file bytes removed. CLEANUP-RETIRED-06-KV.json retains file inventory/header hashes and RETIRED-06-KV-INDEX.sqlite preserves its index. Chat/activity/result cache, xcresults, source manifests and canonical model bundles remain. No claim of isolated physical free-space delta.
