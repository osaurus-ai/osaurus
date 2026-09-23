# Next after MiMo: required agent descriptions

Requested by Eric on 2026-09-23. Queue this immediately after the current MiMo runtime, native audio/visual proof, and companion merge work. Do not expand the active MiMo PR with this feature. No release/tag is authorized.

## Problem and intended behavior

Small orchestrator models choose agents from names with insufficient purpose/context and may call Osaurus Helper or another default agent when it cannot help. Every available agent must expose a concise human-authored description beside its name so the calling model can distinguish purpose and when delegation is useful.

## Required scope

- [ ] Trace every agent discovery, prompt/manifest, capability lookup, spawn schema, worker-pool listing, and orchestration path. Record exactly which name/description/id fields the model actually receives, including dynamic tool loading and per-agent allowed pools.
- [ ] Add one canonical required description field with a small enforced character limit. Choose and document the limit after inspecting existing fields; do not invent a second competing notes/description field. Define whitespace trimming, empty-string handling, Unicode counting, over-limit feedback, and identical validation across all writers.
- [ ] Require explicit description input for manual UI creation and in-app model/tool-driven agent creation. A name copied into a description or an automatic generic fallback must not silently satisfy the requirement. Show actionable errors; preserve entered drafts.
- [ ] Inspect all built-in/default agents (including Osaurus Helper), templates, seeds, reset/recreation flows, import/export, duplication, CLI/API/tool creation, and persisted user agents. Write specific purpose/when-to-use descriptions for every default agent based on its actual abilities and permission scope, not invented capabilities.
- [ ] Define safe migration for preexisting user agents with missing descriptions, without deleting agents or breaking saved IDs/references. Distinguish reviewed default descriptions from user-authored text needing completion. Cover editing and legacy imports consistently.
- [ ] Preserve descriptions through save, reload, relaunch, sync/import/export, duplication, and any profile/agent-scoping boundary. Avoid stale prompt caches after edits; update settings/help catalog and anchors if touched.
- [ ] Keep descriptions as untrusted metadata, clearly separated from instructions. Prevent description text from overriding permissions, selected model, allowed targets, or execution budgets. Include length/escaping tests and verify that unavailable or disallowed agents stay unavailable.
- [ ] Test creation failures/success and edits through both actual UI and the in-app creation tool. Verify identical validation, default seeding idempotence, migration, persistence, prompt propagation, cache invalidation, and no regression in target IDs/order or delegation boundaries.
- [ ] Build an isolated development Osaurus app and inspect actual controls. Create/edit/save/relaunch, exercise small-model agent discovery and meaningful delegation, inspect the exact payload seen by the caller, wait for child cards/reasoning/Stop/input to settle, and complete a follow-up turn. Record model defaults, tokens/s, source/app hashes, actual results and failures.
- [ ] Run applicable focused tests plus required local/frontier AgentLoop and AgentLoopFrontier comparisons. Use a controlled baseline with the same small model and tasks to measure unnecessary Helper calls and correct delegation. Do not force desired behavior via hidden prompt/sampler changes or cherry-pick outcomes.

## Recommendations to evaluate, not silently add to scope

1. Descriptions should answer both what the agent does and when it is useful; names alone, generic biographies, and duplicated system prompts are poor routing metadata.
2. Determine whether the existing target notes already provide this concept and extend that contract if possible. Ensure the same descriptions appear in every calling surface, not only the editor.
3. Include negative and positive routing cases: tasks the parent can answer directly, tasks that genuinely need Helper, multiple similarly named agents, missing permissions, disabled/removed targets, and changed descriptions within an existing chat.
4. Measure routing quality before adding any recommendation to delegate by default. Descriptions should improve selection without making every task spawn a child.
5. Keep user-authored descriptions and model-visible tool permissions consistent; description text must never promise unsupported tools, remote access, or privileges.

## Acceptance evidence

A PR must include exact source/app/model identities, before/after routing observations, full denominators and failure attribution, screenshots inspected locally (not committed), persisted-state receipts, and actual in-app tool/delegation results. Source inspection or a rendered field alone is not live proof. Eric requested this as the next task; it is documented, not implemented in the MiMo change.
