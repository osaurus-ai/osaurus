# Next after MiMo: required agent descriptions

Requested by Eric on 2026-09-23. Queue this immediately after the current MiMo runtime, native audio/visual proof, and companion merge work. Do not expand the active MiMo PR with this feature. No release/tag is authorized.

## Problem and intended behavior

Small orchestrator models choose agents from names with insufficient purpose/context and may call Osaurus Helper or another default agent when it cannot help. Every available agent must expose a concise explicitly supplied description beside its name so the calling model can distinguish purpose and when delegation is useful.

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

## Queue order and next performance item

Owner clarified on 2026-09-23: finish MiMo runtime/audio/visual and merge its proven PR; then implement/prove/merge this agent-description task; then optimize Raptor 0.6 JANG6M (Spark x2.5 architecture). No release cuts, release tags, or release-workflow dispatches in any of these tasks.

Raptor acceptance/work checklist:

- [ ] Identify the exact installed bundle/version, architecture contract, native quantization/dtypes and generation defaults before making changes. Confirm the Product Hunt deadline with the current calendar; Eric described it as next Monday.
- [ ] Read internal runtime/cache documentation and inspect relevant merged and open Osaurus/vmlx-swift PRs from the preceding week, including the new SSD-cache location/designation and retention/eviction rules. Trace the actual app dependency pin and executed paths.
- [ ] Establish controlled real-app/engine prefill and decode baselines with identical workloads, warm/cold phases, sufficient decode length, median/p95/max latency, synchronization, physical footprint and disk reads. Keep prompt, sampler and quantization unchanged.
- [ ] Profile concrete bottlenecks and evaluate custom fused Metal kernels for supported M-chip generations. Measure hardware-specific shape/layout/dtype paths and fallback correctness; do not assume one chip result generalizes to every M series.
- [ ] Evaluate TensorOps and CoreML only where supported by the installed OS/toolchain and compatible with this architecture. Count conversion/copy/synchronization costs; retain only measured end-to-end wins with numerical and semantic parity. No speculative speedup claims.
- [ ] Prove coherent multi-turn reasoning/tool/media behavior as applicable, including cached versus uncached equivalence and native defaults. Reject faster looping/truncated/hidden-reasoning-only rows.
- [ ] Exercise prefix/paged/L2 and architecture companion-state topology as actually enabled; validate disk restore and cache identity after model/source/quantization changes. Prove current locations and scoped model/conversation designation, quota behavior, eviction order, stale/oversized entry handling, and cleanup safety.
- [ ] Stress growing chats and quota pressure to detect eviction stalls, excessive synchronous I/O, repeated cache misses, disk-write amplification and throughput regressions. Preserve live/active entries and unrelated model/chat data; never hide a slowdown with a disabled cache or relaxed quota.
- [ ] Build an isolated development Osaurus app, exercise relevant settings/save/navigation/relaunch and actual cache-hit turns, inspect controls through completion/follow-up, and record exact source/app/model identity, tokens/s, memory, latency and disk/cache counters.
- [ ] Run required regressions/evals and Osaurus CI. Document failures, hardware limitations and unsupported paths. Merge proven task PRs; do not cut a release.

Additional recommendation: maintain a small device/shape matrix and numerical fallback contract so each fused path has explicit dispatch conditions. The product showcase claim should use measured end-to-end prefill/decode results on named hardware, not isolated kernel ratios.
