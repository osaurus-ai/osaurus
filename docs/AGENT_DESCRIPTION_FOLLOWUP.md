# Agent description fallback and surface audit

No release/tag is authorized. This follows merged PR #2867; that PR's main-path proof is not a claim that every consumer was covered.

## Required behavior

- Preserve and validate descriptions explicitly entered by the user.
- When the description is blank and a system prompt exists, generate a short description with the configured core model before completing creation.
- Without a system prompt, require manual description input.
- Apply the same single-line,160-character,1024-UTF8-byte policy to generated text. Invalid output, failure or cancellation preserves the draft and requires retry/manual entry.
- Do not overwrite saved descriptions or bulk-generate legacy metadata silently. Prevent late results from crossing agent/draft boundaries.
- Resolve config/API-generated descriptions before approval, show their exact text in the plan, and apply that same prepared document.

## Coverage and evidence checklist

- [x] Initial resolver contract:7 isolated deterministic tests passed, including5 invalid-output cases; not provider/UI proof.
- [x] Initial preview-only Release development app built; superseded by automatic-fallback requirements.
- [ ] Updated app build and focused integration tests:manual creation,onboarding,config/API preparation,approval fidelity,stale responses,cancellation and persistence.
- [ ] Live core-model generation, draft failures and retry, actual save/relaunch, visible descriptions in caller payloads and follow-up delegation.
- [ ] Audit every name/description consumer:spawn,orchestrator,watchers,schedules,channels,workspaces,API/CLI/MCP,imports/exports and cached rosters. Mark fixed-ID automation and deterministic wake-name matching separately from model selection.
- [ ] Channel default/per-room agent selectors:initial source gap identified; change implemented, UI proof pending.
- [ ] Agent list/detail API repair metadata:initial source gap identified; additive fields and endpoint assertions implemented, tests pending.
- [ ] Source traces must become live evidence where behavior is claimed. Passing searches/syntax checks are not runtime proof.

## SSD/cache compatibility

Review the recent engine #489–#492 and app #2836/#2841/#2846 changes against the actual dependency pin. Preserve conversation-aware eviction, protected history boundaries, learned resume rows and hit recency.

CoreModelService utility calls set auxiliaryCacheIntent; MLXBatchAdapter translates it to the engine auxiliary intent. Engine boundary-store paths reject auxiliary requests. This is source evidence only: prove actual writes, cache hits, per-chat/model/weights identity, retained user-chat restore and eviction latency during description requests. Do not clear caches, disable them or relax quota to conceal conflicts.

## Remaining campaign

Raptor0.6/Spark2.5 baseline binary built; controlled runtime profiling and optimization remain. MiMo native audio semantic/looping failure remains unqualified. Neither is complete. Keep the full task ledger and merge only proven task PRs.

## Owner clarification: completion gates

The simple flow is authoritative: preserve a supplied description; otherwise generate with the configured core model when a system prompt exists; otherwise require manual entry. A suggestion button alone does not satisfy automatic creation fallback. Generated output must pass the same canonical limits as manual input; never silently truncate it or save a placeholder.

- [ ] Apply this contract to manual creation, onboarding/template creation, chat-driven config tools and HTTP/API creation. For legacy agents, show an actionable repair notice and an explicit generation/repair action when a prompt exists; do not silently rewrite saved agents. Verify import/export and workspace sync preserve descriptions and expose missing metadata for repair.
- [ ] Verify every model-facing roster, spawn/delegation tool schema, orchestrator, watcher, schedule, channel, remote-agent/API listing and refreshed in-chat target list carries purpose alongside name. Distinguish fixed-ID dispatch from model selection; preserve configured automation behavior and deterministic wake-name matching.
- [ ] Verify manual text wins, nonblank invalid text is rejected, blank/whitespace prompts require manual input, and unavailable core model, timeout, cancellation, empty/overlong/multiline/control-character output never causes a partial save. Test Unicode grapheme and UTF-8 limits separately.
- [ ] Exercise double-clicks, dismissal, agent switching, concurrent requests, edits during generation and cancellation followed by retry. A late result must never overwrite a newer draft or another agent. Surface progress and an actionable retry/manual-entry error without contradictory required-field warnings.
- [ ] Resolve generated descriptions before config approval; display the exact resolved value and persist that same value. Test concurrent changes between preparation, approval and apply, and that a plan-only request creates no agent.
- [ ] Audit recent cache PR implementations against the consumed engine pin. Verify configured SSD storage location, migration/old-location cleanup and deletion boundaries, per-chat/model/quant identity, active/history retention, learned resume rows, hit recency and quota eviction. Only task-owned disposable cache fixtures may be pressure-tested.
- [ ] Measure a user chat before and after core-model description generation, then restore it from disk and continue coherently. Repeat with another agent/chat and changed description to detect cache collisions or stale routing metadata. Separate auxiliary utility requests from ordinary API requests, which may write cache entries.
- [ ] During eviction, record cache hits/misses, protected and evicted entries, disk reads/writes, physical footprint and latency. Verify no active-chat corruption, deletion outside the configured cache root, unexpected model reload or unexplained stall; source inspection and quota simulations alone are insufficient.
- [ ] Require a fresh dev-app UI run, persistence/relaunch, focused regressions, applicable local/frontier evals and Osaurus CI before merging this follow-up. Record failures and limitations. Never cut a release or push a tag.

## Current evidence and discovered issues

Revision 2 Release build completed successfully (private `build-r2-receipt.json`). The focused xcodebuild run completed successfully; its Swift Testing summary reports 54 tests in 8 suites (`focused-r2.log`, `focused-r2-receipt.json`). Requested suite selectors are not proof that every requested suite actually ran; reconcile discovery before claiming full coverage.

Live automatic creation is still FAILED: the local Raptor run returned no description after spending its completion budget on character counting. Two app-API diagnostics also returned empty content with `finish_reason=length` at 2048 completion tokens: native defaults 106.2823 tok/s, explicit utility-temperature diagnostic 104.3881 tok/s. These are failure diagnostics, not successful utility-path or controlled speed proof. Artifacts: `live-r2-first-attempt.json`, `description-api-native-r2.json`, `description-api-utility03-r2.json` under the private follow-up evidence directory.

- [ ] Correct the description task instruction/UX and repeat real core-model generation while retaining strict application validation and native reasoning behavior. Do not hide the failure with forced reasoning closure, hidden sampler changes or truncated output.
- [ ] Fix the onboarding task-handle race identified during review; prove duplicate-click and dismissal cancellation.
- [ ] Complete live cache restore/eviction and exhaustive consumer coverage; neither is currently proven.
