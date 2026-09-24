# Runtime and orchestrator task queue

Owner: Eric. Updated 2026-09-23. Work through these tasks in order; merge each proven PR before starting the next implementation. Do not turn this into one broad cleanup PR.

## Standing owner instructions

- **MERGE ONLY. Never cut releases, create/push release tags, or manually dispatch release/deployment workflows.** Urgency and green CI do not authorize a release.
- Finish and prove each task, then merge its Osaurus PR. Runtime-library changes may use their own paired PR; consume the actual merged runtime SHA in Osaurus and verify the app.
- Eric waived engine CI for this MiMo vmlx-swift merge work. Osaurus CI remains required.
- Eric's expectation is to be impressed by the quality of the work: inspect related variables/callers and omitted edge cases, think through recommendations, prove real behavior in a freshly built development app, preserve failures, and keep exact evidence. Do not substitute confidence, guessed speedups, hidden behavior changes, or status prose for proof.
- Run model proof on this Mac with unchanged host guards. Protect Warp, Terminal, active agents/jobs and user data. Never overlap full-model loads or bypass an unsafe preflight.
- Preserve native quantization, dtype, template and bundle generation defaults. No sampler/prompt masking, fabricated credentials, or self-grading presented as independent remote-model proof.

## 1. MiMo runtime and Osaurus integration — MERGED

Current status: **Osaurus [#2863](https://github.com/osaurus-ai/osaurus/pull/2863) merged on 2026-09-23 at `32a8b845dae3cbc85e21c4ce4b657d9868734706`**, consuming vmlx-swift #500 at `6b8dda85a3659b255377a76caf8914c005d2eef1`. The merged tree equals tested head `74e5cf76d7e77c6c84698c3f9d883fc5d4030682`; all seven required CI jobs passed. No release was performed. Eric directed the next task to proceed.

Final R29 proof: actual image/video/cache-toggle/history flows passed at 45.2–46.8 tok/s; two five-turn typed-tool probes passed, including disk restore. Normal Quit exited 0 with no memory guard trip and no swap. Audio transcription remains **failed/unqualified**, including an excessive tool-call loop; do not describe all MiMo media or all eval rows as passing. Current full matrix: Reasoning 13/13; Cache 14/14; Frontier 37 passed, 2 failed, 3 errors / 42; AgentLoop 41 passed, 11 failed, 4 skipped / 56; Subagent 31 passed, 1 error, 14 skipped / 46. The remote comparison remains owner-deferred, not passed. Source/live receipts: `~/vmlx-private-evidence/mimo26-swift-2026-09-22/r29-current-app-proof.json`, `r29-osaurus-pr2863-merged.json`, and `r29-audio-failure.json`.

Historical implementation and proof progression (superseded current-state statements below are retained for provenance): [Osaurus #2865](https://github.com/osaurus-ai/osaurus/pull/2865) isolates the eval residency/runtime snapshot correction from #2863 on current main. It includes migration provenance and isolated writable cache paths. **Merged at `70546416f55184d1534ecc91a3c162a169280469`** after 27/27 local bootstrap/isolation tests, 29/29 deterministic eval cases in each of two settings setups, and all CI green (358 eval tests in 44 suites). It does not qualify MiMo audio. Main #2863 CI at `374714d06179f3f9f20e7ad0f9b7368e0c372b4a` is now green. Audio/current-bundle eval gates below remain open. Current runtime source is `51358261c284880dfc9203a0b6ac2a6c3ae78419`, after merging main/#2865. R27 Release app/eval builds and 346/346 focused tests passed. All CI passed on this source (`35890316856`). At Eric’s explicit request, one monitored load waived only the extra startup reserve; the model loaded without a live guard trip. ReasoningChannel13/13 andCacheProof14/14 passed. AgentLoopFrontier stopped intentionally at8passed/1failed after discovering a MiMo string-transport defect in the shared XML parser. Engine follow-up `fix/mimo-native-tool-values` is active; finish it, consume its proven merge, rebuild, and rerun qualification. `r27-local-baseline-summary.json`, `r27-parser-baseline-stop.json`.

- [x] Native mixed-quant runtime, resident packed expert dispatch, multimodal inputs and cache work implemented in vmlx-swift.
- [x] Engine PR [#493](https://github.com/osaurus-ai/vmlx-swift/pull/493) merged at `454e5258641f1c004fcc86b1944ce40e0b4f7a5f`; owner engine-CI waiver recorded.
- [x] Osaurus integration implemented and pinned to merged runtime in all four locations; two source tripwires updated.
- [x] Osaurus draft PR [#2863](https://github.com/osaurus-ai/osaurus/pull/2863) opened. R21 runtime source commit `c0b3b280c3ce132b63fca9b657714ee17f6d2a3c`; later pin work remains separately identified.
- [x] Final remote-pin Release development app built successfully; source manifest and binary hash recorded.
- [x] Final-pin focused regressions: 253 tests in nine suites passed, including both dependency-pin checks.
- [x] Full R19 local matrix completed on identical runtime source: ReasoningChannel13/13, CacheProof14/14, AgentLoopFrontier42/42, AgentLoop41/56 passed, 11 failed, four skipped. Every non-pass attributed; scores unchanged. R19-to-final-pin source comparison recorded separately from live proof.
- [x] Actual R19 Chat/Settings proof: load cancellation/cleanup/recovery, allocator override/persistence, image attachments/changed images, prefix off/on/save/reload/history. Prior evidence is explicitly tied to its source/app identity.
- [x] Loader follow-up [vmlx-swift#494](https://github.com/osaurus-ai/vmlx-swift/pull/494) merged at `cd63706f8302b8cd5d9224b26787d85b473aebc2`: native 3/5/6-bit packed loading and mapped/resident routing proved, 13 tests passed with default flags and 13 with optional fusions enabled; all four Osaurus pins and both source tripwires updated.
- [x] Updated installed iteration2 explicitly selected by Eric; all 54 manifest files passed checksum verification.
- [x] R21 rebuilt app and eval runner; 346/346 focused app tests passed. Actual iteration2 loads without the old affine-companion error.
- [x] Native quant follow-up [vmlx-swift#495](https://github.com/osaurus-ai/vmlx-swift/pull/495) merged at `fce53ef0e5cf5eb052a5a38490661bc48218917f`: native MXFP8 and quant-independent fused dispatch; 18 default-flags and 27 optional-flags/runtime tests passed. All four app pins and both tripwires updated.
- [x] Expanded bounded quant matrix covers all supported affine widths, projection roles, group32/64/128, F16/BF16 companions, MXFP4/MXFP8, exact packed retention, native output parity and malformed companions.
- [x] R22 Release app/eval rebuild completed; 346/346 focused app tests passed, exact source/binary hashes recorded.
- [x] Resolve R22 diagnostic admission before retry: protected file-cache is excluded, actual-free admission strengthened,13 guard tests pass. R22e full load/generation and normal Quit pass with no guard trip, normal pressure/zero swap, peak107.53GB physical. Earlier three aborted runs remain retained; no safety limit raised. This private guard correction is not a production app admission change.
- [x] MiMo string-transport fix [vmlx-swift #500](https://github.com/osaurus-ai/vmlx-swift/pull/500) merged at `6b8dda85a3659b255377a76caf8914c005d2eef1`: literal newlines/backslashes preserved, 108 strict tests passed; normal TF32 run retains four existing known issues. All four Osaurus pins and both tripwires updated.
- [x] R28 current-source Release app/eval builds and 346 focused app tests passed at `b32a57b50e6a90786d230e24538b9d641f88d3b6`. Live byte-exact file-write regression now passes; ReasoningChannel13/13 and CacheProof14/14 pass. Agent-loop/subagent matrix remains active.
- [x] Complete updated full local eval matrix and document current-bundle qualification limits; final scores above supersede R19.
- [x] R21 actual audio/video/history UI and tool cards with follow-up exercised and recorded: video/tool calls pass; audio and media-history provenance fail. Natural stops, settled UI, tokens/s, memory and cache telemetry captured.
- [ ] Diagnose retained audio semantic failure and repeat affected proof after any further runtime pin. R22e native API transcribes correctly but reasoning-only at49.0/48.4tok/s; fresh UI still denies attachment at46.4tok/s. Independent Python native-default generation now reproduces the exact double-opener/transcript/EOS failure; BF16 codec differential also retains that sequence as top1 in all12positions. Shared architecture/bundle attribution and visible-answer resolution remain open; no masking.
- [ ] **Owner-deferred for this PR:** remote-model AgentLoop/AgentLoopFrontier comparison. Existing HF credential produced one real passing smoke case, then the full attempt hit HTTP 402. Eric replied “no need for this one atm”; no credit purchase or demo deployment. Deferred is not passed. See `r27-owner-frontier-deferral.json`.
- [ ] Resolve/attribute any remaining in-scope failures; do not call every media/agent row passed. API media recall currently has a retained 3/4 semantic result.
- [x] Osaurus CI passed at `a285a38515bc18d5124618003803c23a821fc0ec`.
- [x] R21 Osaurus CI passed at `c0b3b280c3ce132b63fca9b657714ee17f6d2a3c`.
- [x] R22 Osaurus CI passed at `ec6e370487a57aa0d3516e05aaf752a7a175fbe9`; receipt `osaurus-pr2863-ec6-ci.json`.
- [x] R28 code-head Osaurus CI passed at `b32a57b50e6a90786d230e24538b9d641f88d3b6`, run35899508536.
- [x] Final amended-head CI and review complete at `74e5cf76d7e77c6c84698c3f9d883fc5d4030682`.
- [x] Final proof/limitations recorded and Osaurus #2863 merged. No release/tag.

Evidence index: [MiMo proof](MIMO_RUNTIME_PROOF_2026_09_23.md). Private command/results/source manifests: `~/vmlx-private-evidence/mimo26-swift-2026-09-22/`. Current builds/tests/UI logs and raw eval denominators must remain traceable there.

## 2. Required concise agent descriptions — ACTIVE

Isolated branch `feat/required-agent-descriptions`, based on the actual MiMo merge `32a8b845`, in `/Users/eric/osaurus-required-agent-descriptions`. Implementation is in progress; no description PR has been merged. Canonical validation, creation/editor fields, legacy decoding, routing metadata, and delegation admission are being implemented. The current combined regression run passed 241 tests in 25 suites, including creation/repair, schema refresh, permission persistence, Settings search, and import identity. Its explicit Xcode test-scheme environment uses a private profile and empty models directory. Evidence: `~/vmlx-private-evidence/agent-descriptions-2026-09-23/integration-r6.log` and `integration-r6-receipt.json`. Earlier failed runs and the corrected test-isolation incident are retained in the private implementation status; they are not promoted as qualification.

Draft PR #2867 is open. The next regression run passed **243/243 tests** in 25 suites, including description-only refresh of frozen schemas, ten near-limit routing descriptions (about 1,017 estimated tokens with no duplication), and chat-selected model inheritance. `integration-r7-receipt.json` and `integration-r7-source-verification.json` identify that run.

Live app proof at `5610a7a7`: onboarding rejects blank/whitespace/overlong input and saves a valid manually supplied description; the legacy Chat notice repairs three incomplete agents, counts down to zero, preserves original identity/settings, survives restart, and does not overwrite a saved description with an invalid draft. Raptor completed two coherent chat turns (107.5/107.8 tok/s) and configuration-driven creation (106.5 tok/s). The following delegation **failed** because a new agent inherited no model when only the current chat had selected one. The fix carries the current chat model into new agents; it requires a rebuilt app and repeated live proof. Raw failure remains `legacy-r2-routing-history.json`. Normal Quit exited 0; peak app physical footprint was 3,775,548,224 bytes.

R3 live proof confirmed exact chat-model inheritance and preserved every seeded legacy session/turn field during repair. The follow-up still failed: a frozen conversation omitted `spawn_agent` after the first target became runnable. A new regression reproduced that omission (1 test, 2 failed assertions); the refresh fix then passed **244/244 tests in 25 suites**, including removal when targets become unavailable again. Evidence: `integration-r8-red.log`, `integration-r8-green-receipt.json`, `legacy-r3-inherited-model.json`, `legacy-r3-history-after-repair.json`, and `legacy-r3-routing-history.json`. R3 generation rates were not captured before normal Quit, so it is not a complete model qualification row. The previous eval build was intentionally stopped before changing source; no eval pass is claimed.

Added catalog cases for description-based routing with opaque agent names and avoiding unnecessary delegation for a simple calculation. These still require actual model runs. Next: rebuild and repeat creation/delegation, finish manual editor/history/settings-search proof, run full applicable routing/eval comparisons and final CI, then merge only after proof. No release.

Current-head R4 live proof at `71f9bf8a5` completed two actual delegations to the model-created Citation Checker Two; the second parent answer recorded 103.6 tok/s, 233 tokens and 0.87 s TTFT. Cards settled, Stop disappeared, and input unlocked. Manual Create Agent rejected whitespace and 161 characters, previewed a valid manually supplied description, then persisted its trimmed value. Normal Quit exited 0; peak physical footprint 4,093,561,184 bytes. Raw receipt: `legacy-r4-live-proof.json`. Manual-editor relaunch, Settings search, and actual legacy-history continuation still remain.

Full local AgentLoop/AgentLoopFrontier/Subagent/DefaultAgent evaluation is running as `evals-local-r3`, using the exact `71f9bf8a5` CLI binary. Preserve the earlier failures: R1 lacked host-version bundle metadata and rejected inference; R2's wrapper omitted linked frameworks. R3 retains the binary hash and uses the same development-app version metadata plus original framework/resource links; neither model metadata nor admission rules changed. The first new direct-answer case **failed**: it returned 42 but unnecessarily spawned Agent B. Do not claim descriptions eliminate unnecessary delegation, or omit this row from the final report. Catalog-only commit `02440faae` adds the two missing case IDs caught by CI; all 575 cases across 35 suites match the inventory. Final CI and full scored model results remain pending.

R5 UI-only relaunch verified the saved manual description, the real Settings search result/landing control, and Cancel without creating an agent. `legacy-r5-live-proof.json` names the observed controls and screenshots. The shared-agent audit found credential refresh was not updating descriptions; the patch now carries fresh metadata into the exact paired provider, preserves workspace names/avatars, and sends explicit empty host descriptions to clear stale values. Invalid optional roster blurbs fall back to a valid paired description. The combined regression run passed **255/255 tests in 27 suites**, including real scheduled refresh with a mocked handshake and sibling-workspace isolation; this is not a live remote-workspace pass. Evidence: `integration-r9-workspace-receipt.json` and unchanged source manifest. A fresh Release app, final eval matrix and CI remain required.

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
