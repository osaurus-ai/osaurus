# Runtime and orchestrator task queue

Owner: Eric. Updated 2026-09-23. Work through these tasks in order; merge each proven PR before starting the next implementation. Do not turn this into one broad cleanup PR.

## Standing owner instructions

- **MERGE ONLY. Never cut releases, create/push release tags, or manually dispatch release/deployment workflows.** Urgency and green CI do not authorize a release.
- Finish and prove each task, then merge its Osaurus PR. Runtime-library changes may use their own paired PR; consume the actual merged runtime SHA in Osaurus and verify the app.
- Eric explicitly waived CI only for vmlx-swift#493. Osaurus CI remains required.
- Eric's expectation is to be impressed by the quality of the work: inspect related variables/callers and omitted edge cases, think through recommendations, prove real behavior in a freshly built development app, preserve failures, and keep exact evidence. Do not substitute confidence, guessed speedups, hidden behavior changes, or status prose for proof.
- Run model proof on this Mac with unchanged host guards. Protect Warp, Terminal, active agents/jobs and user data. Never overlap full-model loads or bypass an unsafe preflight.
- Preserve native quantization, dtype, template and bundle generation defaults. No sampler/prompt masking, fabricated credentials, or self-grading presented as independent remote-model proof.

## 1. MiMo runtime and Osaurus integration — ACTIVE

- [x] Native mixed-quant runtime, resident packed expert dispatch, multimodal inputs and cache work implemented in vmlx-swift.
- [x] Engine PR [#493](https://github.com/osaurus-ai/vmlx-swift/pull/493) merged at `454e5258641f1c004fcc86b1944ce40e0b4f7a5f`; owner engine-CI waiver recorded.
- [x] Osaurus integration implemented and pinned to merged runtime in all four locations; two source tripwires updated.
- [x] Osaurus draft PR [#2863](https://github.com/osaurus-ai/osaurus/pull/2863) opened. Current runtime source commit `a285a38515bc18d5124618003803c23a821fc0ec`.
- [x] Final remote-pin Release development app built successfully; source manifest and binary hash recorded.
- [x] Final-pin focused regressions: 253 tests in nine suites passed, including both dependency-pin checks.
- [x] Full R19 local matrix completed on identical runtime source: ReasoningChannel13/13, CacheProof14/14, AgentLoopFrontier42/42, AgentLoop41/56 passed, 11 failed, four skipped. Every non-pass attributed; scores unchanged. R19-to-final-pin source comparison recorded separately from live proof.
- [x] Actual R19 Chat/Settings proof: load cancellation/cleanup/recovery, allocator override/persistence, image attachments/changed images, prefix off/on/save/reload/history. Prior evidence is explicitly tied to its source/app identity.
- [ ] Resolve changed-bundle load failure: native affine 3-bit/group128 rejected by catalog. Prove mapped/resident packing and routing, merge paired engine fix, repin/rebuild and requalify current bundle; do not carry R19 scores over.
- [ ] Finish final-pin actual native audio/video/history UI and real tool cards with follow-up. Inspect reasoning, visible answers, card settlement, Stop/input state, tokens/s, memory and cache telemetry. Preserve any semantic failure.
- [ ] Required remote-model AgentLoop/AgentLoopFrontier comparison. Existing supported credential source requested; none in environment, configured endpoint unreachable. No pasted secrets or invented keys.
- [ ] Resolve/attribute any remaining in-scope failures; do not call every media/agent row passed. API media recall currently has a retained 3/4 semantic result.
- [x] Osaurus CI passed at `a285a38515bc18d5124618003803c23a821fc0ec`.
- [ ] Final amended-head CI and review complete.
- [ ] Update final proof/limitations in PR and repo docs, then merge Osaurus#2863. No release/tag.

Evidence index: [MiMo proof](MIMO_RUNTIME_PROOF_2026_09_23.md). Private command/results/source manifests: `~/vmlx-private-evidence/mimo26-swift-2026-09-22/`. Current builds/tests/UI logs and raw eval denominators must remain traceable there.

## 2. Required concise agent descriptions — QUEUED

Do not begin implementation before Task1 is finished/proven/merged.

- [ ] Audit all agent/default-agent discovery, metadata, creation, storage, prompt/tool/spawn and allowed-target paths.
- [ ] Implement one canonical short required description, consistent validation, manual UI and model-driven creation, specific reviewed descriptions for existing defaults, and safe migration/persistence for existing agents.
- [ ] Upgrade existing user agents: actionable “Description required” notices and direct editing; require explicit completion, preserve data/settings/IDs, and prevent name-only delegation until corrected. Prove old profiles and skipped-version/legacy-import paths in the dev app.
- [ ] Verify actual model-visible descriptions beside agent names everywhere targets are selected; protect permissions/target boundaries and invalidate stale metadata caches.
- [ ] Test UI and tool-driven creation/edit/errors/save/relaunch, defaults/migrations/import/export, and controlled small-model routing versus baseline.
- [ ] Fresh development app live proof, applicable full evals and Osaurus CI; document exact identities, rates, failures and recommendations.
- [ ] Merge the proven Osaurus PR. No release/tag.

Detailed acceptance checklist and recommendations: [Agent descriptions](NEXT_AFTER_MIMO_AGENT_DESCRIPTIONS.md).

## 3. Raptor 0.6 JANG6M / Spark x2.5 speed and SSD cache — QUEUED

Do not begin implementation before Task2 is proven/merged. Eric plans a Product Hunt showcase next Monday; use verified calendar/source context rather than inventing a date or promising an unmeasured speed target.

- [ ] Inspect exact bundle/architecture/dtype/defaults, internal documentation and relevant Osaurus/vmlx-swift PRs from the previous week.
- [ ] Establish controlled prefill/decode/cache/memory/I/O baseline; profile concrete bottlenecks.
- [ ] Develop and validate custom fused Metal paths across applicable M-chip generations. Evaluate TensorOps/CoreML feasibility and end-to-end costs on supported OS/toolchain/hardware.
- [ ] Prove numerics, native-default coherence, multiturn/tools/media as applicable and cached/uncached correctness. Reject faster-but-wrong results.
- [ ] Prove new SSD-cache location/designation, quota/retention/eviction, active-entry protection, stale/oversized handling, growing-chat performance and disk-write/read pressure without data loss or hidden cache disablement.
- [ ] Fresh development Osaurus UI/cache/settings proof, appropriate tests/evals/CI, exact source/app/model/hardware identities and measured gains with limitations.
- [ ] Merge runtime PRs as proven, pin their merged SHAs in the paired Osaurus PR, complete app proof and merge. No release/tag.

Detailed performance/cache checklist follows the agent-description checklist in [the queued-work document](NEXT_AFTER_MIMO_AGENT_DESCRIPTIONS.md).
