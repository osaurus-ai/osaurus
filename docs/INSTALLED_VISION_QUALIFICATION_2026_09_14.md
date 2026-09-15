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

## Evidence and remaining work

Private artifacts: `/Users/eric/vmlx-private-evidence/ornith-vision-2026-09-14/`.
Screenshots and models remain outside the repository.

- Initial eval test execution: 350 tests, 25 issues from three existing
  delegation tests racing on shared settings. Serialized execution: 350/350.
  Both logs retained; no delegation source change in this lane.
- Cold inventory before waiting for external discovery: 0 bundles. After:
  4 bundles including two image-capable HF artifacts. Bounded store containing
  two Ornith symlinks plus external HF discovery: 6 bundles, 4 image-capable.
- The existing isolated diagnostic Release app at RAM source `6e1dd0f` with
  the same engine pin answered one actual image on Ornith 1.5 9B, HTTP 200,
  normal stop, 76.7664 token/s. This is not current-head or multi-turn proof.
- Strict runtime matrix, focused Core tests, current-head native UI proof,
  architecture-specific companion cache proof, and exact reporter reproduction
  are pending. An attachment automation attempt sent a path as text and is
  explicitly excluded from native vision evidence.

## Broader campaign update

- Source `6389aa7f591ea1fdc2d7bc23ef0bea074e5ea184`; engine pin unchanged.
  CLI SHA256 `6527227ee0d5ee28ae6deef871776e24e397f4c30703fd06d1877db48f587e0d`.
  Receipt: `full-runtime-matrix-3-receipt.json`.
- Full production inventory: **79 bundles, 34 admitted image bundles, 11 admitted
  architectures**. Four declared-vision bundles rejected: one missing vision
  weights, two Step3p7 artifacts and one DeepSeek-V4.1 artifact without a
  registered VLM factory. These are not fabricated inference passes.
- Full first routing attempt: **1/34 passed, 33 failed**, including 32 cold
  model-not-found failures and the CRACK derivative's answer failures. Preserved
  in `full-runtime-matrix-2`; rerun with awaited discovery is in progress.
- Earlier bounded matrix at `8f7f7a72c`: **5/6 passed**, **38/42 exact-color
  assertions**, all seven requests per bundle retained. Both Ornith variants,
  Gemma E2B, ordinary Qwen 27B and Qwen4Exp completed the strict case; the CRACK
  27B derivative remained failed. `matrix-3-summary.json` records every response,
  rate, effective sampler and cache topology. This is a subset, not the test plan.
- Regression tests: 167/167 HTTP/agent-loop/usage/vision at `8f7f7a72c`; 71/71
  discovery/HTTP/usage/vision after the root fix; 350/350 eval tests after the
  routing wait; 4/4 driver tests on macOS Bash. Both new discovery tests failed
  before the root fix. Driver tests use fake envelopes solely to test coverage
  bookkeeping, and are not inference evidence.
- Runtime cache trace supports distinguishing native in-file Mamba restoration
  from separate SSM-sidecar counters. Zero sidecar hits alone does not mean a
  native Mamba disk restore failed. Cache topology and limits remain in each row.
- An initial Release build was interrupted to include the broader discovery
  change. The replacement build and native UI proof are pending. No merge or
  universal-vision claim is authorized by these partial results.

Do not merge or advertise this as universal vision correctness based on header
fixtures, load-only results, or the historical PR's model rows.
