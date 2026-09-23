# MiMo runtime integration proof

Status: PARTIAL. Engine osaurus-ai/vmlx-swift#493 merged at `454e5258641f1c004fcc86b1944ce40e0b4f7a5f`. Owner waived engine CI only. Osaurus CI remains required. No release/tag.

## Change

Consume native MiMo V2.6 support and route bundle-declared tools, reasoning, ordered image/audio/video history through the app. Unknown parser metadata falls through to recognized metadata/inference; an explicit supports_tools=false remains authoritative. Native JANG thinking defaults identify their actual template flag. Completed tool calls from a length-stopped response are not executed.

Resident admission prices actual packed payload plus architecture KV/scratch and real host reclaimable capacity. The shared freed-buffer allocator stays within the admitted total budget and explicit user cap, without changing MLX.Memory.memoryLimit, OS limits, live weight residency, quantization, or bundle sampler defaults. MiMo's nine full and 39 sliding layers are priced separately. Eval bootstrap isolates runtime policy for reproducible profiles.

## Source and artifact identity

Pre-pin R19 source is recorded in `post-fixes-r19-source-manifest.json`: app base `93513e8d6c499cdb25931fe1e7205676c5856854` plus hashed companion changes, engine `5a7c0f868f9f5e4d0d320481700d5505e4a94b0b`. Engine merge differs from that tested source only in its checkpoint Markdown, verified by `swift-pr493-merged.json`. The final app replaces its local dependency with the actual merged remote SHA in all four pin files and both pin tripwire tests. Final-pin validation is recorded separately; pre-pin binaries must not be described as final-pin builds.

R19 Release app SHA256 `434d3057aa9467a36ccd227f06c0565551f3df786268cea38786f00133501180`; eval CLI `5faa5fbd884ce7b77528cecd6630d68cc8d440e4c4c9111ca508a2c588886a`.

Private evidence root: `~/vmlx-private-evidence/mimo26-swift-2026-09-22/`. Screenshots remain private and are not committed.

## R19 model and defaults (historical bundle)

`JANGQ-AI/MiMo-V2.6-Flash-RL-JANG_2L`; 52 bundle files verified, publication manifest SHA256 `d4ce2f3eb49e5ff40676f0eb5c4b3bd5d85840169e1a579f067591b664666b03`. Packed weights resident; GPU routing; original affine/MXFP4/FP8-derived bundle representation retained. Temperature 1, top-p 0.95, native thinking default from bundle, no hidden prompt/sampler changes. Optional fused gate/up and down kernels remain off. Effective KV: nine full + 39 rotating BF16, disk-backed restore, paged RAM off, zero TurboQuant layers.

## Completed R19 evidence

- Focused allocator/admission/tool-batch/reasoning regressions: 94/94. Earlier broader unit proof had a temporary-local-pin tripwire failure; final-pin checks must close it, not hide it.
- ReasoningChannel: 13/13 passed. CacheProof: 14/14 passed. AgentLoopFrontier on local MiMo: 42/42 passed. AgentLoop: 41/56 passed, 11 failed, four skipped. CLI exit 1 reflects case failures; no guard trip. `evals-r19-completion.json` pins report hashes and counts.
- Every AgentLoop non-pass is attributed in `evals-r19-agent-failure-attribution.json`. Failures include excess/malformed calls, prose instead of structured clarification, fixture capability/rejection-policy mismatches, an unreached cancellation checkpoint, missing configured workers, and child contracts exceeding the admitted model budget. XLSX readback reported not_found despite output/listing assertions; cause unproven. These are retained as failures, not converted into passes.
- All 11 completed rubric rows manually reviewed in `evals-r19-manual-rubric-review.json`. Some exact file/provenance claims remain partial because the harness persists tool transcripts only for failed rows. Manual grading does not replace the required remote-model comparison.
- Cache five-turn growth: 184 MiB versus unchanged 1024 MiB gate. Actual app fixture growth: 947.13 MiB versus prior 1402.36 MiB. Active MLX bytes remain constant and allocator pool settles near 879315457 bytes. Capped fixture outputs are memory evidence, not full coherence passes.
- Actual Chat/Settings UI: allocator 512 MiB override/save/navigation/relaunch, cold-load Stop, cleanup below 2 GiB within 0.509 seconds and same-chat recovery; two image attachments, changed-media/history, Prefix Cache off/on/save/reload. Natural UI turns 46.3–47.4 tokens/s, closed reasoning, settled controls and unlocked input. Original settings restored. `local-app-r19-ui-observations.json`, `local-app-r19b-ui-observations.json`.
- API nested-tool/result/history and native-default/explicit-off/default reasoning sequence passed. Actual native image/audio/changed-media/video recognition passed; fourth-turn media history invented spoken phrases. Semantic score 3/4, with 44.8294 tokens/s natural stop on the failure. `local-app-r19-media-semantic-review.json`. Current native audio/video/tool-card UI coverage remains to finish.
- Controlled engine decode 42.07–42.17 steps/s over 128 steps; identical 3595-token prefill 96.7–98.9 versus grouped 408.3/474.1 tokens/s. No uniform 45 tokens/s claim; optional kernel optimization deferred.

A prior R14 host watchdog restart remains documented. New host supervision/admission reduce risk, not prove immunity. Full-model jobs run serially on this Mac, with Warp/Terminal protected.

## Final-pin R20b and changed-bundle R20c

App commit `a285a38515bc18d5124618003803c23a821fc0ec`, engine pin `454e5258641f1c004fcc86b1944ce40e0b4f7a5f`: Release build succeeded; app binary SHA256 `ef5b459af145548d1780a75552c7cd6e94645ef802aed238d93dadbe4984144c`. Focused regressions passed 253 tests in nine suites, including both pin checks. All Osaurus CI checks on this commit passed (run `35844779539`). Receipts: `local-app-r20b-build-outputs.json`, `post-pin-r20b-tests-receipt.json`, `r19-r20b-source-comparison.json`. These source/build results do not qualify a changed model bundle.

The installed bundle changed during this build. Current config SHA256 `2fdc2c0f420230a56990aaafd2939fc63e0c44a2b07bae8e98c466b25f689263`, JANG config `0f9bd72fb8837307732ce16766ed2eb62057383cb19696702f466d03ed31a0eb`, index `309688f0a8083543f17180a495cd468d1b61122ba61a02ece456ac366a67ae16`; Legacy `manifest.json` is absent, but the actual `SHA256-MANIFEST.json` is present: SHA256 `9c0f05f02fb4951123e3f9ff39b144071d2fb0ca84bd593bf70c879032a824fa`, iteration 2. All 54 manifest files (110792864362 bytes) passed SHA256/size verification in 53.35 seconds with a 4 MiB uncached read buffer; each file and the manifest remained stable. Receipt `r21-bundle-verification.json`, hashes `r21-publication-file-hashes.jsonl`. New quantization metadata includes 22 affine 3-bit/group128 units. Prior R19 scores apply only to the prior bundle. Payload integrity is verified against the installed manifest; runtime qualification of this iteration is still outstanding.

Actual R20c audio attachment/send failed before generation: `Invalid native affine expert companions: model.layers.11.mlp.switch_mlp.gate_proj`. Its U32 weight shape `[256,2048,384]` and BF16 scales/biases `[256,2048,32]` imply native 3-bit/group128 at input width4096. The R20c catalog rejected widths outside `[2,4,8]`, although native MLX accepts `[2,3,4,5,6,8]`. The new bounded regression reproduced the rejection for all three widths. Follow-up engine PR #494 merged as `cd63706f8302b8cd5d9224b26787d85b473aebc2`, accepting native `[2,3,4,5,6,8]`. Full expert-catalog suite passed 13 tests under default flags and 13 with optional fusions enabled. Unsupported 1/7/9-bit widths remain rejected. Receipts: `native-affine-widths-r3-optins-receipt.json`, `native-affine-widths-r4-defaults-receipt.json`, `swift-pr494-merged.json`. All four app pins and both tripwire tests now consume that SHA; rebuild and new-bundle proof follow. First decode comparisons were bit-exact. Independent per-token QMV versus batched prefill showed maximum absolute differences of 1.57e-5 to 3.05e-5; the follow-up retains exact equality and compares prefill against native batched SwitchGLU/QMM at the matching batch shape. No tolerance was loosened. Optional specialized fusion must keep its format fallback. Eric confirmed that this updated installed bundle is the qualification target. No full-model retry until focused loader tests pass and unchanged safe admission succeeds.

Live artifacts: `local-app-r20c-load-failure.json`, `r20c-current-bundle-inventory.json`, `local-app-r20c-ui-actions.jsonl`, `local-app-r20c-audio-loading.png`, `local-app-r20c-memory-summary.json`. App exited normally, peak physical footprint1198196656 bytes, no guard trip; token/s is N/A because load failed before generation. Audio/video/tool-card UI remains unproven on this current bundle.

## Remaining before companion merge

- [x] R20b final-pin build and 253 focused pin/runtime regressions passed.
- [x] Native affine-width loading regression proved and engine #494 merged; app consumes merged SHA in all four pins and both tripwires.
- [ ] Rebuild and repeat affected proof for the current bundle and follow-up pin.
- [ ] Final-pin actual audio/video and tool-card UI with follow-up, source identity, tokens/s and cache telemetry; retain any semantic failures.
- [ ] Required remote-model AgentLoop/AgentLoopFrontier comparison. Supported environment keys absent; configured endpoint unreachable. `r19-remote-comparison-prerequisites.json`. Existing credential source requested without requesting a pasted secret.
- [x] Osaurus CI on `a285a38515bc18d5124618003803c23a821fc0ec` passed.
- [ ] Final amended-head CI and review. Engine CI waiver does not apply here.

Next requested task after MiMo: [required agent descriptions](NEXT_AFTER_MIMO_AGENT_DESCRIPTIONS.md). This is queued only, not implemented in the runtime change.
