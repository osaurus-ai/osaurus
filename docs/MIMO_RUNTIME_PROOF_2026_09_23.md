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
- [ ] Remote-model AgentLoop/AgentLoopFrontier comparison is now owner-deferred for this PR, not passed. See the R27 checkpoint below; the older missing-credential finding is superseded.
- [x] Osaurus CI on `a285a38515bc18d5124618003803c23a821fc0ec` passed.
- [ ] Final amended-head CI and review. Engine CI waiver does not apply here.

Next requested task after MiMo: [required agent descriptions](NEXT_AFTER_MIMO_AGENT_DESCRIPTIONS.md). This is queued only, not implemented in the runtime change.


## R21 rebuilt app, iteration 2: live results

App commit `c0b3b280c3ce132b63fca9b657714ee17f6d2a3c` consumed engine
`cd63706f8302b8cd5d9224b26787d85b473aebc2`. Release development build passed;
binary SHA256 `30e160427d0f669c0f72c9027962a72335985afd13463844c568827fb9045c39`.
Focused tests passed 346/346 across ten suites. The rebuilt eval runner also
built successfully, but its updated-bundle full matrix has not run yet.

The actual UI loaded the updated bundle without the affine-companion error.
Native WAV attachments were selected through the file picker and attachment
chips inspected before Send. Clean audio and changed audio are **FAIL**:
the model recognized blue7/green9 but denied receiving recordings. Decode was
45.2 and 44.7 tok/s; media-history follow-up also failed provenance at 44.4 tok/s.
Do not call native audio fully working or alter prompts/sampling to hide this.
The video attachment passed: red circle then blue square, 44.8 tok/s.
Two real get_current_time calls passed at 45.8/45.1 tok/s; the second used
Asia/Tokyo and correctly quoted the prior UTC result. Tool cards settled,
reasoning closed, Stop disappeared and input unlocked. All seven recorded
turns stopped naturally; these short turns do not establish a controlled
128-step speed baseline.

Raw conversations, viewed screenshots and per-row status:
`local-app-r21c-ui-conversations.json`, `local-app-r21c-live-proof-summary.json`.
Cache telemetry after tools: 3 disk-L2 hits, 52 misses, 25 stores; nine full KV
and 39 rotating layers, zero TurboQuant layers, paged RAM off, disk-backed
restore. Runtime trace includes post-answer disk boundary restores and the
updated weight fingerprint `fedc13adfc70a313`. This does not establish a disk
hit on every tool boundary. The app quit through its actual Quit menu with
exit0, no host-guard trip; peak phys_footprint109862712936 bytes. Protected
Warp/Terminal and unrelated active jobs remained running.

Owner requested coverage across quant variants. The expanded bounded matrix
first passed 36 affine configurations and 14 MXFP4 combinations with exact
native output equality; additional FP8/format-dispatch checks are in progress.
These tensor tests generate no language; token/s is not applicable.


## R22 quant-format follow-up

Engine [#495](https://github.com/osaurus-ai/vmlx-swift/pull/495) merged as
`fce53ef0e5cf5eb052a5a38490661bc48218917f`; merged tree equals tested feature
`b2ae8cb868f8d4bdaacf68223186152317ad5d51`. It fixes native MXFP8 expert
loading and quant-dependent architecture selection. Bounded Metal proof passed
18 default-flags tests and27 optional-flags/runtime tests, including64 format
matrix configurations, dtype/packed-byte retention, malformed companions,
legacy dispatch and indexed-model rotating-cache parity. Receipts:
`native-quant-matrix-r4-defaults-receipt.json`,
`native-quant-matrix-r5-optins-receipt.json`. All four app pins and both source
tripwires now reference the merged SHA. Fresh app/eval rebuild and affected
current-bundle proof are required; the R21 audio failures remain open.
Osaurus CI passed at R21 head c0b3b280 before this next dependency update.


## R22 rebuild complete; full-load qualification held

The Release development app and eval CLI rebuilt at app commit
`ec6e370487a57aa0d3516e05aaf752a7a175fbe9`, consuming merged engine
`fce53ef0e5cf5eb052a5a38490661bc48218917f`. Frozen inputs:
`post-pin-r22-source-manifest.json`. App SHA256
`7e335c22dcfb4ef1a6284723aa5d45d5254707c6d63478fe19c19b80a49ba370`;
eval SHA256
`9569f86c600e080492ccf2254d6a032b393d5a90ed98de8c1e2fa147438d57f9`.
All 346 focused app tests passed across ten suites. Receipts:
`local-app-r22-build-outputs.json`, `local-evals-r22-build-outputs.json`,
`post-pin-r22-tests-receipt.json`.

Three full-model loads were stopped by the unchanged compressor-growth guard:
`local-app-r22`, `local-app-r22b`, `local-app-r22c`. Peak physical footprints
were 85,875,995,848; 97,799,951,936; and 99,415,137,104 bytes. Host pressure
remained normal with zero swap; only the owned development-app processes were
terminated. The third run added a stricter actual-free-memory preflight and
still failed. More initial free RAM alone is not a verified correction.
These are failed load rows, with no generated output or token/s.
`R22-FULL-MODEL-LOAD-HOLD.json` now blocks both private app/eval launchers.
Further full-model retries require a concrete bounded validation, without
weakening safety limits. Warp, Terminal and unrelated jobs remain protected.

A bounded load of actual layers11/12/13 retained 5,972,688,896 packed bytes,
with matching MLX active memory, zero MLX cached memory, and physical footprint
6,317,315,304 bytes. After release and clearing only that test's MLX cache,
active/cache memory returned to zero and physical footprint to341,689,376.
This does not show a large accumulating duplicate in this bounded loader;
it does not qualify full-model loading. Evidence:
`native-resident-r22-allocation.log`, `native-resident-r22-allocation-receipt.json`.

The current-bundle audio differential also completed without loading the text
backbone: all three clips' mel values and all2,940 RVQ codes exactly matched
the independent local Python implementation. Clip-b and neutral-control
features were exact; clip-a differed in1,389/49,152 values, maximum absolute
difference0.00048828125. This remains numerical component evidence, not a
resolution of the retained audio semantic failures. Evidence:
`native-audio-r22-components-receipt.json`, `actual-audio-r22-reference.json`.
No language generation in these bounded tests; token/s is not applicable.

The required remote comparison remains unavailable: the configured no-auth
provider endpoint failed to connect, no supported environment key is present,
and no existing suitable eval workflow/credential source was found in the
bounded alternatives check. See `r22-configured-provider-probe.json` and
`r22-remote-eval-alternative-check.json`. Osaurus#2863 remains draft/unmerged.
No release/tag or manual release-workflow dispatch.

A further bounded GPU-touch diagnostic did not validate an early-residency fix:
three-bank reductions added temporary/cache allocations and retained more
physical memory at the immediate release sample. No production change was
made; full-load hold remains. Artifacts:
`native-resident-r22-gpu-touch-receipt.json`,
`native-resident-r22-gpu-touch-summary.json`.

The actual installed expert weights also passed a bounded cross-language
comparison: layers1/11/12, decode1 and prefill8, eight varied routes across
0..255, native BF16 input. All six production resident outputs were bit-exact
against independent Python MLX0.32.2 native gather_qmm using the same complete
256-expert bank geometry. This covers actual MXFP4/group32 plus affine2/group128,
affine3/group128 plus affine2/group128, and uniform affine2/group128 layers.
The first reduced-eight-expert reference changed prefill reduction geometry
and differed; that result is retained, and no tolerance was loosened.
Receipts: `native-installed-r22-quant-receipt.json`,
`native-installed-r22-quant-reference-fullbanks.json`,
`native-installed-r22-quant-reference-fullbanks-receipt.json`. These tests load
one expert layer at a time, not the complete model; they do not close the
full-load/audio/eval gates. No host-guard trips, no language generation.

All Osaurus CI checks passed at R22 runtime head
`ec6e370487a57aa0d3516e05aaf752a7a175fbe9`; receipt
`osaurus-pr2863-ec6-ci.json`. This does not waive the live/eval gates above.


## R22e stricter-admission full load and retained audio failures

The private admission correction now subtracts kernel-protected file-cache
pages and also requires actual free RAM sufficient for the expected footprint.
All previous running guards remain unchanged. Thirteen guard regressions pass;
no OS limit, runtime quantization or production app source was changed. The
written hold was resolved only after bounded validation and a fresh passing
preflight. Earlier failed rows remain retained. Receipts:
`host-guard-tests-r22-filecache.log`, `R22-FULL-MODEL-HOLD-RESOLUTION-E.json`,
`local-app-r22e-host-memory.jsonl`.

R22e loaded the complete updated iteration2 bundle in the rebuilt development
app. It exited normally through Quit Osaurus, return0, no guard trip, peak
physical footprint107,530,104,360 bytes, normal pressure and zero swap. The
frozen R22 runtime inputs are unchanged; app head ed963032 is documentation
only, verified by `r22-documentation-only-source-comparison.json`.
This proves this guarded run, not a guarantee against future driver/OS faults.

Native-default API audio transcriptions were accurate but entirely in the
reasoning field, with empty visible content: neutral recording49.0189tok/s,
code recording48.3717tok/s. Both are FAILED visible-answer rows despite natural
stop. Fresh actual UI audio also FAILS at46.4tok/s (317tokens, TTFT5.85s): the
reasoning hears the recording, but the visible answer denies an attachment.
The attachment and settled result were visually inspected. No forced tags,
prompt changes or sampler overrides were introduced to mask these failures.
Artifacts: `local-app-r22e-live-proof-summary.json`,
`local-app-r22e-api-neutral-result.json`, `local-app-r22e-api-code-result.json`,
`local-app-r22e-neutral-ui-conversation.json`,
`local-app-r22e-neutral-ui-clean-ready.png`,
`local-app-r22e-neutral-ui-result.png`, `local-app-r22e-memory-summary.json`.

Audio attribution is extended below. Full current-bundle eval and remote
comparison gates remain open. Osaurus#2863 remains draft; no release/tag.

All checks also passed at documentation head ed9630328a01197a59ff5e072a9a1ecb7b9ff262: `osaurus-pr2863-ed963-ci.json`. Runtime inputs remain identical to the R22 build.

The private raw-token audio probe built successfully (`raw-audio-r22-build-outputs.json`), but its next full-model attempt was refused before child launch by strict admission (`raw-audio-r22-host-memory.jsonl`). It was not run. Identity hashing now uses bounded uncached reads in the private API/eval harnesses, avoiding whole-binary allocations. No production runtime change was made by these diagnostics.

CPU-only cache-key reconstruction subsequently corroborated the prior API output tokens: code clip emitted one `<think>` opener, neutral clip two, then transcript and EOS151645 without a closer. Both original prompt hashes and post-answer hashes match the persisted cache index exactly. This is identity evidence from the earlier live run, not a new generation. See `local-app-r22e-audio-cache-token-identity.json` and `local-app-r22e-neutral-cache-token-markers.json`. The actual app WAV normalization was also tested: all2,940RVQcodes remained exact, so its small amplitude difference does not explain these rows (`actual-audio-r22-app-pcm-reference.json`).

## Independent backbone reproduction and dtype diagnostic

The updated installed bundle was evaluated through the independent Python
MiMo backbone, loading and releasing one decoder layer at a time to stay within
an 8 GiB diagnostic cap. All 48 layers, full 256-expert banks and native quantization
were retained. This private diagnostic does not change the resident app path.
The neutral audio features reused here were independently bit-exact against
the Python encoder, rather than freshly recomputed in the language run.

Teacher-forced logits ranked all 12 observed tokens first, including EOS
(`r22-layerwise-audio-r2-reference.json`). More decisively, free-running native
temperature 1/top-p 0.95 generation reproduced the exact sequence
`<think><think>A red bicycle is beside the wooden fence.<|im_end|>`.
It stopped naturally, with no fabricated tags, parser repair or prompt changes.
Receipt `r22-streamed-audio-receipt.json`: exit 0, no guard trip,
peak 6,656,349,800 bytes. Raw result `r22-streamed-audio-reference.json`:
270.377 s, 12 tokens including EOS,0.04438 tokens/s end-to-end and0.04606 decode
tokens/s. These intentionally slow diagnostic rates include per-token layer
reloads (1,220,649,802,240 bytes read), and are not app performance results.
The actual app remains the 46.4–49.0 tokens/s rows above. This reproduces a
model/backbone failure independently of Swift's output parser; it does not
prove whether the shared architecture, bundle conversion or source weights
caused it.

The FP32 codec policy originated in the local Python omni wrapper
(`v26_omni.py:39–43`); it differs from Xiaomi's bundled loader default BF16 and
SGLang's BF16 load followed by FP32 RVQ. A bounded BF16 diagnostic changed
207/920, 142/840 and 215/1180 codes for the three clips, but the neutral backbone
still ranks every token of the same invalid output first, with probability
at least 0.97135 (`r23-audio-dtype-reference.json`,
`r23-layerwise-audio-bf16-reference.json`). These are component/logit rows,
not free-running BF16 generation or proof of a semantic fix. The production
dtype path has not been changed on this evidence.

The updated full local eval matrix was then attempted with the rebuilt CLI,
but refused before child launch: safe capacity 115,852,132,352 bytes versus
119,382,780,232 required (`local-evals-r22-host-memory.jsonl`). No model was
loaded for that attempt. Read-only invalidation had already reclaimed
78,237,827,072 bytes of clean cache from the completed reference's inactive
model files; every target had no open handles and unchanged size/mtime
(`r23-after-reference-cache-invalidation.json`). The remaining owned build
and proof files account for only 38,600,704 cached bytes
(`r23-after-reference-owned-file-cache-census.json`). Closing the small vMLX
GUI would not recover the missing 3.3 GiB; protected terminals, active jobs,
system processes and unrelated files remain untouched. This refusal is not
an eval score. Remote-model comparison also still needs an existing reachable
provider/credential source; the configured endpoint's latest probe failed
with curl 7/HTTP 000 (`r22-latest-provider-probe.json`).

A further bounded differential executed the installed Xiaomi PyTorch source
(`modeling_mimo_v2.py`, SHA256
`a8c3cb3aae473bcc15f023010547c919f15eba6546e6ed7efb61a8937b12f3ad`)
with the actual BF16 codec and audio encoder weights. Its codes differ from
both FP32 and MLX-BF16 paths, but feeding those native PyTorch features into
the independent backbone still ranks all 12 tokens of the same invalid
answer first (minimum probability 0.97585). This is a logits comparison, not
a new free-running answer or a full PyTorch language-model comparison.
Artifacts: `r23-torch-audio-r2-reference.json`,
`r23-torch-encoder-reference.json`, `r23-layerwise-audio-torch-reference.json`.
All three guarded runs exited 0 without guard trips; peaks 0.86/2.76/4.73 GB.
The first private PyTorch attempt failed on an unmaterialized nonpersistent
RoPE buffer from meta-device construction; that harness failure remains
recorded in `r23-torch-audio-reference.log` and was corrected by ordinary CPU
construction before the successful run. No production source changed.

## R27 current-source checkpoint

Tested app source `51358261c284880dfc9203a0b6ac2a6c3ae78419`, engine pin `fce53ef0e5cf5eb052a5a38490661bc48218917f`. Main/#2865 is merged into the branch, including the migration-provenance test. Both Release builds succeeded. App SHA256 `032af3b5ab010640c3777890964280b30eb82b8b8f58af3a84bbb8ec97bbab19`; eval SHA256 `67392675a870a6cc68abb1eff071995e47fe22d27065fec3e66bc04a82a1cdb3`. Source manifest `post-pin-r27-source-manifest.json`; build receipts `local-app-r27-build-receipt.json` and `local-evals-r27-build-receipt.json`. Focused regression result: **346/346 tests, 10 suites**, `post-pin-r27-tests-receipt.json`. These do not replace current-source full model/UI proof.

The existing HF credential authenticated and the real DeepSeek-V4.1-Flash router smoke passed 1/1 AgentLoop case. The full attempt hit HTTP402; partial AgentLoop output contains 2 passed, 19 errored, 4 skipped rows. This is infrastructure-limited and not a complete model score. Eric explicitly deferred this comparison (“no need for this one atm”), recorded in `r27-owner-frontier-deferral.json`. No credits purchased, no demo deployed, and no comparison reported as passed.

Current full local matrix and app generation have not run: unchanged admission refused safe capacity112919674880 bytes versus119382780232 required, with normal pressure and zero swap. Remaining shortfall6463105352 bytes. Receipt `r27-final-preflight.json`. Task-owned cleanup retained all files; subsequent read-only census found only2146304 resident bytes across5082 large owned files. No model was started and no memory gate lowered. Existing audio semantic failures remain open; prior runs are historical, not current-source passes.

### R27 admitted diagnostic and parser finding

The owner explicitly requested the load despite the startup reserve refusal. The diagnostic runner retained the actual-free requirement and every running pressure/compressor/swap/reserve/footprint abort, while waiving only the extra initial reserve. It loaded and generated with no live guard trip, peak106532431480bytes physical. This is not an unchanged-admission pass. ReasoningChannel13/13 andCacheProof14/14 passed; interrupted AgentLoopFrontier recorded8passed/1failed. All CI on51358261cpassed.

The failed byte-exact-write row omitted trailing newlines in dispatched arguments and repeatedly appended empty strings. Source review found XMLFunctionParser strips boundaryCR/LF and JSON-unescapes string parameters. Installed MiMo template emits strings verbatim; the upstream SGLang MiMo conversion preserves all five regression values, including newline-only and literal backslash-n. Attribution cannot blame the model alone. Stopped only the owned baseline process and retained its partial results before fixing this transport defect. No full-matrix pass or new UI pass is claimed. Evidence: `r27-local-baseline-summary.json`, `r27-owner-load-exception.json`, `r27-parser-baseline-stop.json`, `r28-upstream-string-reference.json`.

## R28 parser correction merged; rebuilt runtime qualification

Engine [#500](https://github.com/osaurus-ai/vmlx-swift/pull/500) merged as `6b8dda85a3659b255377a76caf8914c005d2eef1`; tested source `395c993ad4e625d39ae7cc60c0e982d9ed75b4c6` on main `27c50c4915c89a569823305f7f82f08add9be48b`. MiMo now resolves its literal-string XML dialect, including legacy generic stamps in both factories. Swift parser/streaming regressions first reproduced nine failures; the correction passed 81 neighboring tests, then 108 tests on current main. Normal TF32 mode retains four pre-existing known precision issues; the required strict process passed all 108 with none. Receipts: `native-tool-values-r28-main-regression-receipt.json`, `native-tool-values-r28-main-strict-regression-receipt.json`. Engine CI was owner-waived; no Osaurus CI waiver. All four Osaurus pins and both source tripwires now consume the merged fix. Fresh app/eval builds, affected full matrix, actual UI proof and current Osaurus CI remain required. Prior audio semantic failures remain open. No release/tag.

R28 current-source Release app and eval builds passed at `b32a57b50e6a90786d230e24538b9d641f88d3b6`; 346/346 focused app tests in ten suites passed. Current-source full-model parser smoke now passes `frontier.audit-file-write`: both exact file contents, Unicode and trailing newlines preserved, natural final response after three steps. Per-step decode45.50–47.10tok/s, prefill630.92tok/s; this is a case measurement, not a controlled benchmark. Receipt `r28-live-parser-smoke-summary.json`, raw `evals-r28-full/suite-r28-tool-value-smoke.json`. Full matrix and actual GUI proof remain pending. All Osaurus CI checks passed at that source in run35899508536. This is the R28 in-progress checkpoint; subsequent complete reports and actual UI observations are recorded in the private evidence index and the PR validation report.
