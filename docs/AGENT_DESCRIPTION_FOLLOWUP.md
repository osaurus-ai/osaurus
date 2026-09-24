# Agent description fallback and surface audit

No release/tag is authorized. This follows merged PR #2867; that PR's main-path proof is not a claim that every consumer was covered.

## Current checkpoint — 2026-09-24

This checkpoint supersedes historical status text below. PR #2869 is still unmerged. The current consuming app source is `7a55f65ead9b933dc430cc0b5fd223e0b964d0f4`, engine `63a10f3ab61c36cb978fcd7d74208c746930006d`. Private evidence root: `/Users/eric/vmlx-private-evidence/agent-descriptions-followup-2026-09-23`.

- Release app build passed; focused tests passed **220 tests in 20 suites** (`pin-r5/build-receipt.json`, `focused-r2-receipt.json`). The first focused attempt caught a stale third tracked lockfile; all three lockfiles and the actual compiled engine now agree (`pin-audit.json`).
- Actual app automatic generation saved a valid description with native defaults, 597 output tokens at 105.9138 tok/s, normal stop (`pin-r5/live-receipt.json`). Short utility throughput is not a controlled Raptor benchmark.
- A separate process relaunch reopened the generated agent through Settings → Agents → Configure and retained the exact description (`pin-r5/relaunch-proof/receipt.json`, `reopened.png`). This closes persistence only, not chat/delegation/cache continuation.
- Legacy absent-description record was loaded in an isolated profile. Actual Agents UI showed the repair notice; its repair action opened Configure. Manual entry saved exact text, removed the notice and survived navigation/reopening (`pin-r5/legacy-repair-proof/receipt.json`). No model was loaded; repaired-record process relaunch/delegation are separate pending rows.
- Final eval binary build passed with an unchanged source manifest (`pin-r5/eval-build-receipt.json`). Local Raptor and remote adlab AgentLoop, AgentLoopFrontier, Subagent and DefaultAgent runs are active; no final scores claimed.
- The non-spawnable negative fixture used an unresolved name and errored before its intended production guard. A canonical disallowed UUID reaches the real guard without seeding/allowing a target. Before: 1 error; after: **1/1 pass**, `rejected` and `not spawnable` assertions unchanged. Repeated on the final binary (`nonspawnable-fixture/final-receipt.json`, `final-results/Subagent.json`). This is a fixture correction, not improved model quality.
- Engine PR #501 closed the auxiliary hybrid-prefill boundary-write defect with a failing-before/passing-after regression, including restore and unchanged payload checks. It is consumed by the current app. Full storage-location/eviction and architecture-wide qualification remain open.
- Remote eval isolation previously relied on an empty models directory, but external discovery defaults on independently. Current evals use a private bundle preference domain with both external imports disabled. Restore the captured prior keys only after both runs finish; inspect the resulting model catalog before calling isolation proven.

Remaining merge proof: full final eval failure attribution, complete consumer/UI coverage and legacy repair, chat/delegation with refreshed descriptions and disk restore, import/export/workspace compatibility, current-head Osaurus CI. Remaining campaign work: MiMo audio failure, controlled Raptor speed improvements and live SSD migration/eviction. Do not treat historical unchecked boxes or past passing rows as current universal coverage.

## Historical requirements and proof

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

CoreModelService utility calls set auxiliaryCacheIntent; MLXBatchAdapter translates it to the engine auxiliary intent. The final-generation boundary-store path rejects auxiliary requests, but the hybrid-pool prefill-seed path requires a separate regression: at engine `6b8dda8`, `BatchEngine.swift` calls `storePrefillCapturedDiskSeed` before the final auxiliary guard. Raptor does not exercise this topology. Do not claim universal auxiliary write isolation. Required proof: prove actual writes, cache hits, per-chat/model/weights identity, retained user-chat restore and eviction latency during description requests. Do not clear caches, disable them or relax quota to conceal conflicts.

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

Tested implementation: `a04ed9a724875ba589b343c8f56dc65d9924c158`; consumed engine: `6b8dda85a3659b255377a76caf8914c005d2eef1`. Private receipts are under `/Users/eric/vmlx-private-evidence/agent-descriptions-followup-2026-09-23`. `r4-commit-equivalence.json` verifies the app, focused-test and eval source manifests against that commit.

- Fresh isolated Release app built successfully (`build-r4-receipt.json`). Focused tests passed:108 tests in18 suites (`focused-r4.log`, `focused-r4-receipt.json`).
- Actual UI automatic creation with a blank description and a supplied prompt saved a valid purpose:795 generated tokens,106.4565 tok/s,normal stop. A blank prompt and description disabled Create. `live-r4-after-create.png` and `live-r4-api-persistence.json` pair visible UI with saved state.
- Suggest preview did not change the field until Use; a161-character value disabled Create. Manual replacement persisted without another utility generation. Cancellation left no saved agent. Cancellation throughput was not captured and is not a qualified generation-rate row.
- Onboarding double-click Create produced one Helper with purpose `Everyday user task assistance`:672 tokens,109.6829 tok/s,normal stop. The subsequent transition from provider setup to Chat was not observed in the resumed segment; no clicked Set up later claim. `onboarding-r4.log`, `onboarding-r4-current-front.png` and the isolated profile preserve the evidence. Normal menu quit returned0 with no guard abort (`onboarding-r4-exit.json`).
- Actual HTTP config plan/apply rejected missing and overlong metadata, preserved manual text, showed generated plan text without creating an agent, and persisted generated apply text (`live-r4-config-api.json`, `live-r4-api-persistence.json`).
- Raptor utility generation preserved all11 existing cache payloads byte-for-byte and preserved indexed model/token/chain/companion identity (`live-r4-utility-cache-result.json`). This is neither quota-eviction proof nor all-model cache proof.
- Local Raptor and remote adlab full AgentLoop, AgentLoopFrontier, Subagent and DefaultAgent matrices are running. Final scores, failure attribution, remaining consumer UI rows and exact-head CI are still pending. PR#2869 remains draft; no merge or release claim.

The earlier r2 empty-output/length-stop failures remain recorded in `live-r2-first-attempt.json`, `description-api-native-r2.json` and `description-api-utility03-r2.json`. The summarizer instruction was changed to request a concise action phrase; canonical output validation remains unchanged. The new utility caller passes nil temperature to retain bundle defaults. No forced reasoning closure, truncation or hidden sampler rescue was added.

Remaining cache work includes the hybrid-pool auxiliary prefill-seed regression, actual eviction/storage-location proof and disk-restored chat continuation with updated agent metadata. Real two-host workspace proof is also unverified. Do not convert these gaps into passing claims.
