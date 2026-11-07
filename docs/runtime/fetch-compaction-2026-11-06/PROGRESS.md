# Fetch recovery and compaction inference deadlines

Status: implementation and proof in progress. Not fixed, merge-ready or release-ready.

Base: Osaurus0eb0d0c867c116af7aac5af020ce141e095556fb / vmlx1bcd74ad182103a3b83941f61e57ee0bac23b330. Read-only four-day audit retained at /Users/eric/vmlx-private-evidence/osaurus-release-settings-20261106/fetch-truncation-investigation/history-audit/AUDIT.md. New proof root /Users/eric/vmlx-private-evidence/fetch-compaction-fixes-20261106.

Protected: AgentToolLoop, AgentTaskState, ChatView, SystemPromptComposer, SystemPromptTemplates. No retry/scheduling/tool-continuation edits; no new tool/schema fields, sampler overrides, source model downloads or runtime repins. User requests real dev-app proof and rigorous edge cases. No release actions in this fix task.

## Ordered TODO

- [x] Inventory67 merged PRs and81 main commits; locate historical caps, tool-batch trigger and deadline ownership.
- [x] Reproduce deadline ambiguity with unchanged production helper and scaled component cases; this is not affected-user or app proof.
- [x] Reproduce oversized fetch and record actual arguments, output, history growth and follow-up behavior in baseline app.
- [x] Implement bounded session/agent-scoped retained-result cache plus existing file_read resource paging. Preserve all pre-cap normalized bytes with hashes, no external refetches, no cross-session access, small outputs unchanged. Cap and cache failures stay explicit.
- [x] Implement opt-in compaction phase deadlines with passive handoff-stage observation; leave ownership/order unchanged and other auxiliary callers on existing behavior.
- [ ] Focused deterministic suites: byte fidelity/Unicode/single-line results, error envelopes, secret-marker bypass, permission/scope isolation, cache expiry/quota/failure, malformed URI, batching and cancellation.
- [ ] Focused deadline suites: admission/execution/restoration expiry, phase boundaries, duplicate/stale notifications, Stop-before-install race, noncooperative drain, error precedence and callback-default compatibility.
- [ ] Build fresh isolated Release dev app at exact proposed source/pin. Reuse source-package checkout cache only when pins match; retain baseline artifact.
- [ ] Actual candidate Chat UI: large fetch, cached missing-middle retrieval, complete answer and grounded follow-up, saved-settings/model defaults, relaunch/cache ownership and expired/missing recovery.
- [ ] Actual compaction UI: normal real-model summary/continuation; concurrent local work / admission; cancellation and parent restoration; controlled failure UI with exact source and phase attribution. Synthetic fixtures are marked separately from real-model proof.
- [ ] Relevant full eval lanes and regression checks; record denominators and every failure. No model-family/performance clearance from source-only evidence.
- [ ] Verify protected-file hashes unchanged; document source/live receipts and remaining gaps; commit scoped change and normal PR/CI only after qualification. Do not merge unproven fixes.
- [ ] Retire only this task's superseded binary/build/cache payloads after preserving sufficient source, hashes, requests, logs and canonical repro state; never canonical models or unrelated work.

## Current receipts

SOURCE EVIDENCE: Base commit 0eb0d0c8 and runtime 1bcd74ad; protected source hashes in the private proof root's PROTECTED-SOURCE-BASELINE.json. The seven candidate product files are frozen per CANDIDATE-BUILD-04-COMMAND.json. No agent-loop edits.

LIVE EVIDENCE: BASELINE-ACTUAL-TRUNCATED-RESULT.json was extracted from the real GUI-initiated Raptor inference request (activity sequence29, input5). A116845-character fixture became119002 normalized characters, capped to100000 preview bytes. The middle audit note was absent and no recoverable reference existed. The real GUI retry again returned the incomplete document and did not recover the hidden fact. Fixture source is a controlled local MCP provider; inference is the actual bundled Raptor model. This is not a reproduction with the affected person's unknown model/provider.

The initial baseline turn's attempted curl fallback was denied in the native tool approval UI; that denial is not attributed to this bug. The subsequent explicit fetch retry completed naturally with an incomplete answer. Activity receipts retain all output rates (including background Foundation rows); no matched speed claim yet.

Candidate builds01–03 failed (toolchain selection, package-plugin trust validation, then two candidate compiler mistakes). Logs and exact commands remain private. Build04 is underway after correcting the timeout snapshot's scope and integer parsing. Nothing has been committed or merged.

A real app delegation running a controlled220-second terminal wait now overlaps manual compaction, to check admission versus inference timeout behavior. No test-only product guard, changed timer, synthetic model response or CLI inference is used.

Baseline queued-compaction receipt: BASELINE-COMPACTION-RECEIPT.json contains activity seq43 at180010.13ms, error `timed out`, output rate absent because inference did not produce output. The same live app's delegated terminal task finished normally afterward with WAIT_COMPLETED. Original conversation remained approximately60k tokens. The spinner stopped; the durable error is in Insights (the transient toast was not captured). This is actual queue-timeout app proof, not only the scaled helper probe. Screenshots and AX snapshots retained.

## Qualification log

- The standalone production CompactionDeadline helper passed the combined queue/generation/restore scenario, each of four phase deadlines and100 immediate-cancellation races (DEADLINE-PROBE-RESULT.json). This is component evidence, not candidate app evidence.
- Focused02 executed217 tests across26 suites. One new metadata test reported two assertions because it compared raw URI text against JSON-escaped slashes. Exact byte reconstruction, ownership, expiry, quota, cancellation, async registry/file-reader integration and the existing selected suites passed. The metadata assertion now decodes JSON before comparing the reference and checks the transcript retains that exact metadata. Failures retained; no product output was changed to satisfy those assertions.
- Focused03 caught an actor-isolation error in the new optional-observer test fixture, before executing tests. The fixture now performs the non-UI auxiliary operation off the main actor; no production API contract was changed for it. Focused04 is running.
- Build04 caught an escaping local observer closure capturing the existing non-escaping producer. Build05 preserves the producer's original non-escaping contract via a non-escaping observation wrapper, keeping ownership and cleanup inside the existing handoff. All source hashes are frozen for Build05 and Focused04.
- The bounded cache uses the same integer coercion as ordinary tool arguments. Its private directory is700, payload/metadata files600, and batched retained-result reads debit the existing batch content budget. Small result normalization avoids introducing detached I/O work.

## Real candidate05 results and current revision

SOURCE EVIDENCE: CANDIDATE-ARTIFACT.json records the fresh signed Release binary hash, exact seven product-source hashes, base0eb0d0c8 and runtime1bcd74ad. Exact candidate05 product source was retained under the private proof root's source-05/ before the next edit. No source/model/pin evidence was discarded.

LIVE EVIDENCE: CANDIDATE-05-ACTIVITY.json records actual GUI-initiated model calls and output rates; CANDIDATE-CACHE-READBACK.json reconstructs all119002 normalized source bytes and verifies both SHA-256 hashes. The middle audit note is present in the retained source. Files are0600. The provider was connected explicitly through Tools & MCP after an initial setup mistake (first attempt had no connected provider; its unrelated shell fallback was denied). That attempt is not attributed to the cache fix.

The first connected, unguided Raptor task failed: it read one partial page, ignored has_more=true/next_read and incorrectly claimed the full document lacked the note. An explicit follow-up to read the next_read chain recovered MAPLE-4827 and USD38147.62 without another fetch. The subsequent grounded arithmetic turn returned USD38247.62 and the same code; Stop disappeared and the composer unlocked. All failures, an invalid read attempt in the guided tool trace, reasoning and follow-up receipts remain retained. This is successful guided recovery, not successful autonomous paging.

Candidate06 addresses the new response-contract gap: a partial retained-result page now carries the standard truncated=true flag and a bounded warning identifying the returned chunks and next_read. The last page clears the flag. The page cap includes the warning bytes. This changes only the opaque retained-result path, not ordinary files, tool schemas, prompts, samplers or agent-loop behavior. The byte-reconstruction tests also check warning/flag completeness. Fresh Release build06 and full core02 are running; candidate06 has not yet been qualified in the app.

Candidate05 verification: focused218/218 across26 suites; eval-harness384/384 across50 suites; all12 token-free floor suites exited0. Full core01:12556 passed,43 failed,64 skipped of12663 per xcresult; baseline full-suite comparison on the identical clean main source tree is running. No regression-free claim from that red full run. New source changes must pass their affected checks again.

Reproducer: fetch_fixture.py generates the identical116845-character synthetic document (SHA25644773db4fcc4a1ebab2f3b2adc5757912a8a41fba54686932cda312c895b5e2f). It is a stdio MCP fixture, never an HTTP fetch or inference client. Use a disposable dev profile and empty working folder; connect the fixture in Tools & MCP before sending the identical baseline prompt.

Baseline comparison completed: CORE-01-BASELINE-COMPARISON.json reports zero candidate-only failing test names. All43 candidate05 full-suite failures also occur on the identical clean main tree; baseline has45 failures, including two additional names. Both retain64 skipped cases. These are red full-suite runs, not a green production gate. The current candidate06 retained-result and deadline suites have also passed inside full-core02; the full run and candidate06 app proof remain in progress.

All12 token-free floor suites completed with exit0 (TOKEN-FREE-EVALS-RESULT.json), with scripted-only/no-warmup flags and an empty model directory. These do not replace real-model app proof. Live AgentLoop/Frontier CLI inference was not run: the machine policy requires native GUI inference, and the protected driver/prompt files remain unchanged. No harness driver edits.
