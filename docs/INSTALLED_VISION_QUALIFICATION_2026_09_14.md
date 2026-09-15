# Installed vision qualification

Status: **PARTIAL**. This extends the regression harness; it does not promise
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

## Reusable commands

```sh
osaurus-evals vision-inventory --out inventory.json
make evals-vision-installed
# Or use an already built binary; output directory must be new:
bash scripts/live-proof/run-installed-vision-evals.sh /path/to/osaurus-evals /path/to/new-proof
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

Do not merge or advertise this as universal vision correctness based on header
fixtures, load-only results, or the historical PR's model rows.
