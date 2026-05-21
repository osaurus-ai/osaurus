# Native Swift image generation integration

This documents the Osaurus-side boundary for native Swift MFlux/Flux-family
image generation through vMLX. It is a wiring contract and release gate, not a
claim that Osaurus can serve native Swift image models today.

## Current status

Osaurus currently routes local MLX text/VLM generation through
`vmlx-swift-lm`:

```text
ChatEngine
    -> ModelRuntime
        -> MLXBatchAdapter
            -> BatchEngine.generate(...)
```

There is no Osaurus local `/v1/images/generations` or `/v1/images/edits`
runtime path wired to native Swift `vMLXFlux` yet. Remote provider image
generation, VLM image input, and artifact rendering are separate surfaces and
do not prove local native image generation.

The native Swift image work currently lives in `/Users/eric/vmlx-swift` as
`vMLXFlux`, `vMLXFluxKit`, `vMLXFluxModels`, `vMLXFluxVideo`, and the
`vmlxflux-probe` executable. The latest local full-matrix probe is:

```text
/Users/eric/vmlx-swift/docs/local/vmlx-flux-probes/20260516T-native-mflux-full-matrix/
```

Result summary:

| Local bundle | Detection/load | Generation | Verdict |
| --- | --- | --- | --- |
| `FLUX.2-klein-9B` | detected, load path entered | `0/3` turns complete | blocked: model body throws `notImplemented` |
| `qwen-image-mflux-4bit` | detected, load path entered | `0/3` turns complete | blocked: model body throws `notImplemented` |
| `Z-Image-Turbo` | detected, load path entered | `3/3` PNG turns | blocked: scaffold/noise output |
| `Z-Image-Turbo-mflux-4bit` | detected, load path entered | `3/3` PNG turns | blocked: scaffold/noise output |

The `loaded` rows above only prove the native constructor accepted the local
directory and opened safetensors metadata/arrays. They do not prove real
prompt-conditioned weights are applied or resident.

## Required Osaurus wiring after vMLXFlux passes

Do not expose native Swift image generation in Osaurus until the vMLX matrix
has at least one `production_candidate` or stronger row with prompt-sensitive
images.

When that gate exists, the Osaurus integration should add a dedicated image
runtime lane instead of forcing images through `MLXBatchAdapter`:

```text
HTTP /v1/images/generations or app image UI
    -> ImageModelRuntime
        -> one FluxEngine actor per loaded image model
            -> FluxEngine.load(name:from:)
            -> FluxEngine.generate(...)
                -> ImageGenEvent.step / preview / completed / failed
```

The runtime lane must own:

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

Before Osaurus exposes a native image model as local production-capable, the
same exact bundle must pass all of these:

1. `vmlxflux-probe --matrix` on `/Users/eric/vmlx-swift` reports no blockers
   for that bundle.
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

Until then, Osaurus documentation must describe native Swift image generation
as blocked upstream in vMLX, not as a supported local inference feature.
