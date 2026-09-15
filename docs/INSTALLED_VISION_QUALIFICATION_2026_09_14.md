# Installed vision qualification

Status: **PARTIAL**, draft PR #2772. This extends the regression harness and
repairs discovery/agent transport defects; it does not promise
support for every architecture or qualify the separate 16 GB RAM issue.

## Problem and source trace

The September 14 Ornith report follows the config/weight admission change in
merged PR #2756 (`dc1a250f70a79c77251d2e54c5d7d2a0d12d0610`). The supplied
Discord attachment returned HTTP 403, so its exact error and artifact are still
unknown. Current base is `7666cc6ba0cf8c1b24b93c220b8c0331c392cab5`; the engine
pin is `5b0c8e6b8b29a7ead21fe785688bc0621580cc62`.

`LocalVisionEvidence`, `ModelMediaCapabilities`, `VLMDetection`, and
`ModelRuntime` already share installed configuration/weight/runtime modality
checks. Renamed dense and MoE Ornith fixtures now exercise their actual
`vision_tower` layout and reject a missing configured block. Names do not grant
vision capability. Header evidence alone cannot prove processor construction,
tensor shape correctness, image processing, or generation.

The old `EvalRunnerHTTPAPI.runMultimodalImage` skipped every non-200 response
and accepted a color anywhere in the answer. This could hide a load failure or
an answer mentioning both colors. It did not require a cache hit or exercise
streamed images, the agent endpoint, or retained image history.

The strict `Vision` suite uses seven actual image requests through the Osaurus
HTTP server: image A, identical A, changed B, streaming B, a temporary custom
agent with A, an image-history follow-up, and changed B after that history.
It requires exact background colors, visible normally terminated answers,
measured token/s, valid stream termination, and a replay cache hit. Raw JSON,
SSE, and cache stats stay in the report. Only the output budget is explicit;
the media request no longer inserts temperature 0. Other chat suites are
unchanged. The video case also treats load/server errors as failures but is
not part of this image matrix.

The first live matrix exposed the agent route discarding `StreamingStatsHint`.
`AgentRunUsage` now aggregates measured model-step decode time, and the handler
emits the requested usage chunk. Final cumulative stats replace intermediate
updates. Missing measurements remain missing, not a fabricated speed. A runtime
`length` stop follows the existing incomplete-run path instead of a normal finish.

The broader inventory exposed two discovery defects:

1. Foundation returned ENOTDIR when enumerating `/Users/eric/models`, a symlink
   to an external volume. The generic external scanner now resolves its starting
   root just as it already resolved child directories, and records enumeration
   errors. Containment still checks the resolved root. The unnormalized root call
   traces to #1355, with the report wrapper in #1372; it predates #2756.
2. A headless media run could read a cold external catalog before the UI singleton
   started discovery. The full initial matrix returned 32 model-not-found errors
   for bundles the inventory had just found. Media evals now complete the same
   production discovery before warm-up and HTTP routing.

## Reusable commands

```sh
osaurus-evals vision-inventory --out inventory.json
make evals-vision-installed
# Or use an already built binary; output directory must be new:
bash scripts/live-proof/run-installed-vision-evals.sh /path/to/osaurus-evals /path/to/new-proof
# Optional smaller coverage campaign, selected by bundle contract rather than name:
bash scripts/live-proof/run-installed-vision-evals.sh /path/to/osaurus-evals /path/to/new-proof --representatives
```

Inventory awaits the managed scan and an external rescan before reading the
app's catalog. It records config-declared bundles rejected by weight evidence.
The script runs every image-capable bundle in that inventory sequentially and
returns failure for rejected vision declarations or any failed runtime row.
No model-name list, download, or safety bypass is added by the script. Normal
`evals-prep` prerequisites still apply. `OSU_MODELS_DIR` can select a bounded
local test store; report that scope rather than claiming every disk artifact
was tested. The inventory covers bundles accepted by Osaurus's scanner, not
every incomplete folder on disk. Unregistered processor implementations,
video/audio, OCR, and broad image semantics still need their own evidence.

`plan-installed-vision.py` audits metadata and actual safetensors header hashes
for every inventoried bundle, including rejected architectures. It records
config architecture, vision architecture, selected processor declarations,
quantization declarations, actual storage dtypes, and file sizes. Default mode
executes all admitted image bundles. Optional representative mode chooses the
smallest weight set in each contract group; other members remain `not_run` and
are never assigned the representative's result. Execution reaches each
architecture before additional same-architecture formats. `coverage-results.json`
keeps the full inventory, exclusions, selected rows, reports and runtime outcomes.

This is not full graph-level weight validation. The current engine's `Load.swift`
updates with `.noUnusedKeys`, with a comment describing absent optional MXFP
quantization biases. Changing that blindly to `.all` risks rejecting valid
quantized bundles. Config/header admission plus a constructed vision modality
does not establish completeness of every parameter or numerical correctness;
these remain explicit audit limits rather than an invented universal capability.

## Current evidence

Private artifacts: `/Users/eric/vmlx-private-evidence/ornith-vision-2026-09-14/`.
Screenshots and model files remain outside the repository. Host: local Apple
M5 Max, 128 GiB physical RAM. This does not reproduce the reporter's 16 GB host.

The all-bundle campaign used source `6389aa7f591ea1fdc2d7bc23ef0bea074e5ea184`,
engine pin above, and CLI SHA256
`6527227ee0d5ee28ae6deef871776e24e397f4c30703fd06d1877db48f587e0d`.
It inventoried **79 bundles**, audited their actual headers, and executed all
**34 admitted image bundles across 11 configured architectures**. No manual
model-name selection was used. `full-runtime-matrix-3/coverage-results.json`
preserves every bundle, exclusion and runtime result. `full-matrix-3-summary.json`
includes responses, rates, physical-footprint measurements and cache settings.

| Configured architecture | Strict cases passed | Strict cases failed |
| --- | ---: | ---: |
| nemotron omni (`NemotronH_Nano_Omni_Reasoning_V3`) | 2 | 0 |
| `lfm2_vl` | 2 | 0 |
| `muse_glimmer` | 2 | 0 |
| `gemma4` | 6 | 0 |
| `gemma4_unified` | 1 | 0 |
| `qwen3_5` | 6 | 3 |
| `qwen3_5_moe` | 2 | 0 |
| `qwen4_exp` | 3 | 2 |
| `zaya1_vl` | 0 | 2 |
| `glm5_next` | 0 | 2 |
| `deepseek_vl_v2` | 0 | 1 |
| **Total** | **24** | **10** |

These are bounded seven-request image/history cases, not family-wide quality
or low-RAM certification. Four failures were ordinary RAM-admission refusals
(two GLM artifacts and two large Qwen4Exp formats); the gate was not bypassed.
One was a format-preflight mismatch. Five were answer-contract failures: a
verbose Ornith 2D agent response, verbose/reasoning output from a CRACK Qwen
27B derivative, an orange answer on Qwen 27B 6D's repeated red image, and wrong
history colors on both ZAYA variants. Do not turn these failures into passes
by accepting any matching word, overriding sampling, or borrowing a sibling's
result. Default sampling means this campaign is not a deterministic quality
comparison between quantizations.

Both ZAYA variants were also tested with the existing memory-only diagnostic:
`zaya4-memory-only.json` and `zaya-k-memory-only.json`. Runtime telemetry confirms
disk L2 disabled, paged RAM disabled and zero cache hits/stores. Wrong colors
persisted. Therefore stale disk-cache restoration alone does not explain the
failure. The diagnostic intentionally fails the required replay-cache assertion
and is not qualification. Template, processor, numerical and model-quality
attribution remains unresolved; this lane does not change ZAYA weights/templates.

## Format parity follow-up

The broad campaign admitted DeepSeek-OCR as image capable, then load preflight
returned HTTP 500 because its installed headers declare `format: pt` and it has
no MLX quantization declaration. This is evidence of an existing preflight
policy refusal, not proof that every PyTorch-tagged tensor is numerically
incompatible with the engine.

Source `c99b2f78b1f79a63d9d5159a3761b0c34f6b4cd3` makes image admission consult
that same format policy and removes the `OsaurusAI/` publisher-name bypass
from both `MLXModel` and `ModelCompatibilityDiagnostics`. All aliases now use
the same installed evidence. Refreshing vision evidence also refreshes the
format cache after an on-disk change. The generic format policy itself is
unchanged; its broader correctness remains a separate audit boundary.

- `format-parity-tests.log`: **208/208** focused Core tests, including renamed
  bundles, changed headers, HTTP streams, agent usage and stop reasons.
- `evals-format-tests.log`: **350/350** eval tests, serialized to avoid existing
  shared-settings races. The earlier parallel run's 25 issues are retained;
  no delegation source was changed.
- `driver-tests.log`: **4/4** tests using macOS Bash. Fake envelopes test only
  matrix bookkeeping, not inference. CI runs these tests too.
- `format-inventory.json`: still **79 bundles**, now **33 admitted** and **5
  rejected vision declarations**. The added rejection is the preflight-refused
  OCR artifact; other previously admitted bundles remain admitted.
- `format-negative.json`: live image request now returns **HTTP 400** with the
  explicit installed-format policy reason, before inference. This is expected
  rejection evidence, not a passing vision case.
- `format-positive-lfm.json` and `format-positive-nemotron.json`: current-source
  LFM2-VL and Nemotron Omni each complete all seven image, stream, agent,
  history and replay-cache checks.
- `format-receipt.json`: CLI SHA256
  `065f175facbb0ae3e74c5df0d2eb8c1fdcff593f060c53ffa9e7355c4154957e`.

## Baselines and remaining limits

The first all-bundle routing attempt (`full-runtime-matrix-2`) was 1/34 passed:
32 cold-catalog model-not-found errors plus the CRACK answer failure. Awaiting
production discovery removed those routing errors in the complete second run.
Both new symlink/enumeration tests failed before the root fix. An earlier
manually bounded campaign was 5/6; it is retained as `matrix-attempt-3`, not used
as the broad denominator.

The `c99b2f78b` isolated Release build succeeded (`release-format-build.log`).
`release-format-receipt.json` records bundle
`com.dinoki.osaurus.installedvision20260914`, binary SHA256
`3199836f120607a0c9efe0a5f4cb63843a97b39ba6f9b97625dcfcc06a675a95`.
Native CUA selected LFM2-VL, created an isolated agent with Tools/Memory off,
attached real PNGs through the file picker, and observed **Red → Red → Blue**
across the first image, history follow-up and changed image. Displayed decode
rates were 139.0, 299.3 and 282.2 token/s, each a one-token answer; these are
throughput receipts, not stable speed benchmarks. `native-ui-summary.json`
records the observations; screenshots remain in the CUA conversation evidence.
`native-final-cache.json` and `native-app.log` show one disk hit, three stores,
8 KV layers + 22 Mamba layers, disk-backed restore and zero TurboQuant KV
layers. The changed-image turn used a different media salt and missed the
old cache. Active temperature 0.2, top-k 50, top-p 1 and repetition penalty 1
match the installed LFM generation config; no test sampler override was added.
The physical-footprint collector observed about 3271 MiB during this bounded
native sequence. Native UI does not expose raw finish_reason; the separate
strict API cases assert normal stop. An earlier attachment automation attempt
sent a path as text and is explicitly excluded.
The reporter's exact screenshot/error remains unavailable (Discord HTTP 403).

Uninstalled architectures, other processor layouts, video/audio, OCR accuracy,
long histories, cancellation and concurrent media workloads are not qualified
by this matrix. Header checks are not full graph validation. A nonempty
processor declaration is not proof of successful processor construction; the
live load/request row must succeed. Native Mamba state can be embedded in L2,
so zero SSM-sidecar hits alone is not a failed native restoration. Effective
cache topology and measured rates stay in each report. No low-RAM claim follows
from an image-case pass, especially on the large Qwen4Exp rows.

Keep this PR draft until the remaining failures and exact-head CI are reviewed.
Do not advertise universal vision correctness from these partial results.


## Post-preprocessing image contract

The shared `MLXBatchAdapter.prepareInput` path now checks the processor result,
not only installed capability metadata: an attached image must produce a
nonempty `LMInput.image.pixels` payload before cache lookup or generation.
The guard does not impose a tensor layout, one tensor per image, model name,
architecture list, sampler, or template. Text-only requests pass through.
`PreparedImageContractTests` cover dropped pixels, empty pixels, packed images,
and text-only input. The focused adapter/discovery run passed 128 tests in
four suites (`prepared-image-tests.log`).

The private `missing-pixels-fixture` deliberately omits image markers from a
fixture-only text template. Original bundle files were not edited. Osaurus's
ZAYA template fallback recovered the first three fixture attempts; those
attempts do not prove dropped-media refusal. With the existing fallback-disable
diagnostic flag applied identically before and after, the old harness generated
HTTP 200 answers with `media=nil` (including white and black). The new harness
returned HTTP 500 with the explicit missing-image-pixels error on its first
image request, before image-request generation. This is an internal processor
contract failure, not an unsupported-model admission verdict. The normal LFM2-VL
bundle then passed all seven HTTP image/history/cache checks without disabling
fallbacks (`prepared-positive-lfm.json`). `prepared-image-receipt.json` records
the binary, adapter hash, and unchanged engine pin. The explicit negative
`typed_error` eval also passed (`missing-pixels-fixture/typed-error.json`).

An exact-parent comparison removes the earlier diagnostic prototype from the
baseline: unmodified parent `07c61e37e0721f6e7cb866aef711b3017b73501f` and
patched source `03cd12278a0e6aa16d90d7b771b1ed2ccd75c388` use the same stock
engine pin and fixture. The parent returned HTTP 200 with an invented white
background; the patch returned the expected explicit HTTP 500 error with no
image-request cache activity. `missing-pixels-fixture/exact-parent-ab-receipt.json`
records both binary hashes, fixture hashes, identical diagnostic environment,
and raw reports. This is a malformed-processor contract test, not a model
quality or throughput row.

The refreshed Release build (`release-prepared-image-build.log`, identity in
`release-prepared-image-receipt.json`) completed a native file-picker sequence:
Red → Red → Blue, with visible one-token rates of 269.5, 276.9 and 329.9 token/s.
The first turn reused a persisted image cache; the follow-up reused the same
media prefix; the changed-image turn had a different processed-media hash and
missed. `native-prepared-cache.json` records two disk hits, three stores,
8 KV + 22 Mamba layers, disk-backed restore, paged off and zero TurboQuant KV
layers. The collector observed a 2750 MiB peak physical footprint in this
bounded sequence. These are not low-RAM or speed certifications.
`native-prepared-ui-summary.json` records the CUA observations and launcher
attempt excluded from proof. All accepted UI actions used the observed
isolated agent/root.

The complete updated inventory again found 79 bundles, with 33 image-admitted
bundles across 10 architectures. All 33 were executed: **26 passed, 7 failed**
(`full-matrix-prepared-summary.json`, `full-runtime-matrix-prepared`). Three
failures were resource admission (both GLM variants and Qwen4Exp 6S); four were
answer contracts (Ornith 9B 2D, both ZAYA variants, and CRACK Qwen 27B 2D).
No previously passing bundle failed this rerun, and no valid installed bundle
hit the new missing-pixels guard (`prepared-matrix-comparison.json`). This
bounded comparison is not a guarantee against all regressions. A previously
RAM-refused Qwen4Exp 4M row now passed as available memory changed; this guard
contains no RAM-admission change. The previous Qwen 27B 6D color failure did
not recur; the original failed row remains recorded. Declared-but-rejected
bundles remain visible in `unqualified-declarations.json`, and the overall
matrix correctly exits nonzero while failures or unqualified declarations
remain.

A final driver regression caught a false-success edge case: an admitted bundle
with an independent header-audit failure was retained as `not_run`, but did not
make the overall command fail if other rows passed. The driver now writes
`unqualified-header-audits.json` and fails on those exclusions too. The new test
failed before this correction; all five driver tests pass afterward
(`header-audit-driver-before.log`, `header-audit-driver-after.log`). This changes
coverage accounting only; the production app and engine remain unchanged.

## Attention diagnostic retained outside this PR

Ten fresh-process repetitions of the five answer-failing bundles produced
three passing and seven failing rows (`answer-failure-rechecks-c99/results.json`).
Original failures are retained. ZAYA wrong-color responses also occurred with
cache reuse disabled; this is not explained by cache-hit counters alone.

The recommended flash-attention path in Zyphra's reference commit
`5d10c38a767f43c6e99e712bc006af4e12fd2625` uses a bidirectional image prefix,
while the current Swift path is causal. An isolated mask prototype reproduced
the numerical discrepancy (maximum errors 2.0 and 1.0 for two fixtures) and
passed three Metal numerical tests after changing the mask. However, all four
real Osaurus image/history rows failed with that prototype; visible empty
answers and worse instruction adherence appeared. Numerical agreement with
that backend did not establish compatibility with the installed bundles and
Osaurus template path. The prototype is rejected for integration, remains in a
separate local diagnostic worktree, and is not in this PR or its engine pin.
See `zaya-mask-numerical-receipt.json` and `zaya-prefix-prototype/summary.json`.
