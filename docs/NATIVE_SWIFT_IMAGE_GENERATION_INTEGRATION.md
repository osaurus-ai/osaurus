# Native Swift image generation integration

This documents the Osaurus-side boundary for native Swift MFlux/Flux-family
image generation through vMLX. It is both the current branch contract and the
release gate for exposing local native image generation as production-ready.

## Current status

On `feat/image-generation-vmlxflux`, Osaurus routes local MLX text/VLM
generation through the consolidated `vmlx-swift` package:

```text
ChatEngine
    -> ModelRuntime
        -> MLXBatchAdapter
            -> BatchEngine.generate(...)
```

The same branch wires a dedicated native image lane instead of forcing image
requests through `MLXBatchAdapter`:

```text
HTTP /v1/images/generations, /v1/images/edits, /v1/images/upscale,
or app image-model chat selection
    -> ImageGenerationService
        -> MetalGate exclusive image-generation lane
            -> vMLXFlux.FluxEngine
```

Only `ImageGenerationService` imports `vMLXFlux`; HTTP DTOs and UI/model-picker
types stay on Osaurus-native request/response structs. Remote provider image
generation, VLM image input, and artifact rendering remain separate surfaces
and do not prove local native image generation.

The native Swift image engine lives in `osaurus-ai/vmlx-swift` as `vMLXFlux`,
`vMLXFluxKit`, `vMLXFluxModels`, `vMLXFluxVideo`, and the `vmlxflux-probe`
executable. This branch pins `vmlx-swift` to:

```text
d725c63f035650f9182648580e98d7776544648a
```

That vMLX revision was stress-tested on `erics-m5-max.local` with the remote
scratch checkout:

```text
/tmp/vmlx-swift-image-extended-20260618T064304Z
```

The synced proof artifacts are:

```text
/Users/eric/vmlx-swift/docs/local/vmlx-flux-probes/20260618-image-extended2/extended-stress-summary.json
/Users/eric/vmlx-swift/docs/local/vmlx-flux-outputs/20260618-image-extended2/extended-stress-contact-sheet.png
```

Result summary from the extended stress run:

| Scope | Result |
| --- | --- |
| Load matrix | 2 cycles, 14/14 bundles loaded |
| Text-to-image | Z-Image Turbo 4-bit/8-bit, Flux Schnell 4-bit/8-bit, Qwen Image 6-bit/8-bit passed |
| Image edit | Qwen image edit q8 single-image, q8 multi-image, q5 multi-image, and q8 diagnostics passed |
| Negative path | Qwen edit mask request rejected cleanly |
| Ideogram | fp8 and NF4 JSON rows passed |
| Summary | 16 rows, `failed_rows=0`, high-water max RSS 40,574,992,384 bytes |

Visual inspection of the synced contact sheet confirms the text-to-image rows
are prompt-sensitive and the q8 edit rows are usable. Remaining quality caveats
are tracked as release gates, not source blockers: q5 multi-image edit still
shows composition/patch artifacts, Ideogram still has JSON-caption/poster quirks,
q4/q3 Qwen edit variants remain noisy or hidden, and masks are intentionally
unsupported.

Osaurus live API proof on `erics-m5-max.local` also passed from the no-sign
Release app built at branch `06920034f79273b5cbbf973e908d959a4ac947cd`.
The app ran keychain-free with:

```text
/tmp/osaurus-image-live-proof-20260618-osaurus-image-live/build/DerivedData-image-live-nosign/Build/Products/Release/osaurus.app
OSAURUS_TEST_ROOT=/tmp/osaurus-image-live-proof-20260618-osaurus-image-live/runtime-root
OSU_MODELS_DIR=/Users/eric/.mlxstudio/models
http://127.0.0.1:17837
```

The API proof artifacts are:

```text
/tmp/osaurus-image-live-proof-20260618-osaurus-image-live/runtime-root/proof/api-matrix/summary.json
/tmp/osaurus-image-live-proof-20260618-local/osaurus-image-api-contact-sheet.png
```

Result summary from the Osaurus API matrix:

| Row | Endpoint | Result | App RSS |
| --- | --- | --- | --- |
| `zimage_gen` | `/v1/images/generations` | HTTP 200 | 6,055,870,464 bytes |
| `flux_gen` | `/v1/images/generations` | HTTP 200 | 15,451,013,120 bytes |
| `qwen_image_gen` | `/v1/images/generations` | HTTP 200 | 44,091,604,992 bytes |
| `ideogram_gen` | `/v1/images/generations` | HTTP 200 | 6,914,867,200 bytes |
| `qwen_edit_q8_single` | `/v1/images/edits` | HTTP 200 | 24,291,950,592 bytes |
| `qwen_edit_q8_multi` | `/v1/images/edits` | HTTP 200 | 22,411,886,592 bytes |
| `gen_only_edit_reject` | `/v1/images/edits` | HTTP 400 | 22,410,641,408 bytes |
| `qwen_edit_mask_reject` | `/v1/images/edits` | HTTP 501 | 22,411,968,512 bytes |

`/health` after the matrix was still healthy with `http_inflight=0`,
`loaded=[]`, and `local_model_scan.status="finished"`. The API rows prove
catalog exposure, model-kind rejection, mask rejection, generation artifact
paths, and q8 edit artifact paths through Osaurus. They do not yet prove the
foreground SwiftUI chat workflow, HTTP cancellation while denoise is in flight,
or unload/reload/generate-again behavior.

## Osaurus wiring

The runtime lane owns:

- exact local model resolution under `~/.mlxstudio/models/image`;
- generation-only vs edit/upscale/video capability checks;
- model lease / unload semantics equivalent to `ModelLease`;
- cancellation propagation from HTTP/UI to the `FluxEngine` task;
- artifact persistence and `share_artifact` surfacing for generated images;
- per-request resource telemetry: load time, generation time, dimensions,
  peak memory where available, and output path/hash;
- failed-row reporting that distinguishes detection, load, tokenizer/encoder,
  key-map, generation, and quality gates.

## Production gate

Before Osaurus marks a native image model as local production-ready, the same
exact bundle must pass all of these:

1. `vmlxflux-probe --matrix` and the extended stress runner on
   `/Users/eric/vmlx-swift` report no blockers for that bundle.
2. The model produces prompt-sensitive images for at least three turns:
   base prompt, same-scene modification, and style/material change.
3. The output artifacts are valid PNG/JPEG files at requested dimensions and
   are manually inspected or scored by a VLM/CLIP-style quality check.
4. The Osaurus API path can cold-load, generate, cancel, unload, reload, and
   generate again without stale state or duplicate engines.
5. Generation-only models reject `/v1/images/edits` with a clear 400, while
   edit-capable models accept source image and mask payloads.
6. The app and HTTP API agree on model capabilities, error wording, and output
   artifact paths.

Until the remaining UI, cancellation, and unload/reload proof rows are complete,
Osaurus documentation must describe native Swift image generation as wired,
source-proven, and HTTP API live-proven on this branch, but not release-cleared
for production use.
