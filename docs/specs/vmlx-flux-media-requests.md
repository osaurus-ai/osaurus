# vMLXFlux: requests from Osaurus workflow media steps

**Audience:** the vmlx-swift team (`Libraries/vMLXFluxKit`, `vMLXFlux.FluxEngine`).
**From:** Osaurus workflows. Workflows now have a `media` step (generate, edit, upscale, video) that exposes
every parameter a model takes, runs unattended, chains steps (generate → edit → upscale), and sweeps seeds
over a `map`. This document lists what we need from the engine to go further, in two stages.

- **Stage 1** adds fields and events to the existing requests. Each item stands alone and can ship on its own.
- **Stage 2** is a stage-level API (encode, sample, decode as separate calls with handles). This is what lets
  Osaurus offer ComfyUI-style graphs (hires fix, prompt mixing, latent reuse) without a second runtime.

Every item has the same four parts: **motivation**, **struct diff** (against the pinned
`Libraries/vMLXFluxKit/Requests.swift`), **event contract**, and **acceptance test**. Field names are proposals.
Keep the semantics and rename the fields freely.

## Status

Osaurus pins vmlx-swift `f3586f93` (consumed by Osaurus #3098 and #3104, then by workflow media steps).

| Item | State |
| --- | --- |
| 1.1 Cancellable upscale | Shipped. Adopted by media steps. |
| 1.2 Native batch | Shipped. Adopted by media steps: one job per step with a seed per image. |
| 1.3 Effective parameters | Shipped for Qwen-Image 2.1, Qwen-Image 2.1 Turbo, and SeedVR2. Adopted by media steps. |
| 1.4 Typed limits | Shipped. Every registered family publishes limits. Adopted by media steps. |
| 1.5 Sampler and scheduler | Shipped (Qwen-Image 2.1: euler/heun, qwen-image-2.1/linear, shift). Adopted by media steps. |
| 1.6 LoRA adapters | Shipped in the engine and the chat/HTTP paths. Not adopted by media steps. |
| 1.7 Previews | Shipped. Adopted by media steps as a live thumbnail in the run view. |
| 1.8 Peak memory estimate | Shipped. Adopted: refused before the chat model is unloaded, naming the setting. |
| 1.9 Local video | Shipped for native Wan 2.1 bundles. Adopted by media steps. |
| Stage 2 | Not started in the engine. |

The shipped items differ from the proposals in these ways:

- **1.1:** the interrupt is a field on the request (`UpscaleRequest.interrupt: FluxInterrupt?`), not an extra
  parameter on `upscale(_:)`.
- **1.2:** `ImageGenRequest` takes `numImages`, `seeds` (exactly `numImages` of them), and `batchSize`.
  `ImageBatchPlan` clamps `batchSize` to the family's `maximumParallelImages`, which is 1 for Qwen-Image 2.1, so
  its images share the prompt encoding but denoise one after another. Families whose `maximumImages` is 1 still
  run one request per image inside the same Osaurus job, with `seeds[index]`. Images finished before a failure
  arrive as `.imageCompleted(url:seed:index:effectiveParameters:)`.
- **1.3:** the payload is `ImageGenEvent.completed(url:seed:effectiveParameters: EffectiveImageParameters?)`.
  It is nil for families that do not report yet, and Osaurus never fills it with the requested values. It
  adds `sampleSigmas` (a bundle's fixed sigma grid).
- **1.4:** limits come from `ModelRegistry.lookup(name:)?.limits?(bundleURL)` (or
  `FluxEngine.limits(for:name:)`) and read bundle metadata only. `FluxModelLimits` publishes `fixedSteps`,
  `supportsEditNegativePrompt`, `maximumImages`, `maximumParallelImages`, and the sampling lists. Maxima are
  nil where the engine has no architectural limit, so Osaurus keeps its own capacity caps on top (2048 per side
  and 2–50 steps for Qwen-Image 2.1). SeedVR2's upscale envelope is `SeedVR2BundleMetadata.validateUpscale`.
- **1.5:** names are free strings checked against `FluxModelLimits.samplers` / `schedulers`; `shift` is refused
  unless `supportsShift`. Turbo lists only `euler` with its `bundle-sigmas` schedule.
- **1.7:** previews are `ImageGenEvent.preview(pngData:step:)`, drawn every `previewInterval` steps at most
  `previewMaxPixel` (16–1024) on the long side.
- **1.8:** the estimate is `FluxEngine.estimatedPeakBytes(for:modelURL:name:)` from bundle metadata. Osaurus
  admits it through the resolved Memory Safety plan and refuses with
  `ImageGenerationError.memoryAdmission(field:estimatedBytes:budgetBytes:message:)`. Only the Strict profile
  blocks over budget; the others turn the estimate into a plan warning.
- **1.9:** local video is `VideoGenRequest` on `FluxEngine.generateVideo`. Osaurus's `LocalVideoRequestPolicy`
  owns the request rules: 480p/720p in 16:9, 9:16, or 1:1, 4n+1 frames equal to duration × fps (16 by
  default), sizes in multiples of 16, no audio. The result reports `VideoEffectiveParameters`.

## Where Osaurus uses the engine today

`ImageGenerationService` (Osaurus) holds one `FluxEngine` behind an exclusive lane and drains
`AsyncThrowingStream<ImageGenEvent, Error>` from `engine.generate`, `engine.edit`, `engine.upscale`, and
`engine.generateVideo`. `ImageRequestLimits` wraps the engine's limits and validators. It also does these things:

- It sends `numImages > 1` as one native batch request with explicit seeds when the family's `maximumImages`
  allows it. A media step asks for all of its `count` in one job and, when the batch fails partway, keeps the
  images that finished in the run's folder and names them in the error.
- It reads each installed bundle's engine limits when it lists models. Media steps, the step editor, and the
  Architect's `media_models` action use those limits (sizes, steps, `max_images`, samplers, schedulers, shift),
  and a media step checks its request against them before the job unloads the chat model. The error names the
  step field (for example ``refuses `sampler` = dpm``). Families without engine limits keep
  `ImageModelRequestPolicy`: older families are clamped to 256–1024 in steps of 16, with 1–50 steps, and take no
  sampler, scheduler, or shift.
- It cancels generate, edit, upscale, and local video cooperatively. A stopped or timed-out workflow step fires
  the job's interrupt, and the engine stops at its next step boundary. The image lane stays held until the
  producer drains.
- It forwards `.preview(pngData:step:)` through job progress when a step sets `preview_interval`. The run view
  shows the latest preview beside the step's progress bar; previews are not stored with the run.
- It estimates a job's peak memory before the residency handoff and refuses it there when Memory Safety (Strict) would,
  so the chat model is not unloaded for a job that cannot run.
- It records what the engine ran when the family reports it. Media steps write those values into the PNG
  description, the run record, and each output image's or local video's `effective_parameters`, labeled
  `parameters: effective`. Any value the step asked for differently is kept as `requested_*`. Families that
  do not report are labeled `parameters: requested`.

## Stage 1: request-level

### 1.1 Cancellable upscale

**Motivation.** A workflow upscale step has a timeout, and the person can stop a run. Today the engine
finishes the SeedVR2 pass regardless, so the step holds the image lane for the whole job (minutes at 4×) and
the next queued step waits for it. Generate and edit already stop cooperatively.

**Struct diff.**

```swift
// FluxEngine
- public func upscale(_ request: UpscaleRequest) async -> AsyncThrowingStream<ImageGenEvent, Error>
+ public func upscale(_ request: UpscaleRequest, interrupt: FluxInterrupt? = nil) async -> AsyncThrowingStream<ImageGenEvent, Error>
```

`FluxInterrupt` should be whatever generate and edit use internally. Exposing that same type is enough.

**Event contract.** After the interrupt fires, the stream emits `.cancelled` within one tile/step boundary
(target: under 2 s at 4× on an M-series Max). It writes no partial file and releases all Metal buffers before
the stream finishes.

**Acceptance test.** Start a 4× upscale of a 1024² image, fire the interrupt after the first `.step` event,
and assert all of the following:
- `.cancelled` arrives within 2 s.
- No file appears in `outputDir`.
- `MLX.GPU.activeMemory` returns to within 5% of the pre-job value after the stream finishes.

### 1.2 Native batch (`numImages` encoded once)

**Motivation.** A media step makes up to 8 images, each with its own seed. Today Osaurus runs N full requests,
and each one re-encodes the prompt with the text encoder. For Qwen-Image the text encoder is a large share of
the per-image time at low step counts. We want the conditioning computed once and N latents sampled from it.

**Struct diff.** `ImageGenRequest.numImages` already exists. Make it real, and add per-image seeds:

```swift
public struct ImageGenRequest: Sendable {
    // existing fields…
    public var numImages: Int
+   /// Explicit seed per image. When nil, image i uses `seed + i` (or random seeds when `seed` is nil).
+   public var seeds: [UInt64]?
+   /// Images sampled together on the GPU. 1 = sequential (lowest peak memory). Engine clamps to what fits.
+   public var batchSize: Int = 1
}
```

**Event contract.**
- `.step(step:total:etaSeconds:)` reports per image with `total = steps × numImages`, so one bar covers the
  whole job.
- Add an index to completion: `case completed(url: URL, seed: UInt64, index: Int)`, or a new
  `case imageCompleted(...)`, emitted once per image as each one finishes.
- The stream finishes after the last image.
- If one image fails, the stream emits `.failed` and stops. Images already completed stay on disk and were
  already reported.

**Acceptance test.**
- `numImages: 4, seed: 7, batchSize: 1` yields four `.completed` events with seeds `[7, 8, 9, 10]`.
- Each image is byte-identical to a single-image request with that seed.
- The text encoder runs once: assert on an engine counter or a signpost.
- Wall time is lower than four single-image requests.

### 1.3 Effective parameters on completion

**Motivation.** Osaurus writes the settings that made each file into the PNG (`kCGImagePropertyPNGDescription`,
JSON) and into the run record, so the person can reproduce an image or paste its settings back as a step.
When the engine applies its own defaults or rounds a size, the record does not match what ran.

**Struct diff.**

```swift
+ public struct FluxEffectiveParameters: Sendable, Codable, Equatable {
+     public var width: Int, height: Int, steps: Int, guidance: Float
+     public var seed: UInt64
+     public var sampler: String?, scheduler: String?, shift: Float?
+     public var strength: Float?          // edit
+     public var scale: Int?               // upscale
+     public var modelRevision: String?    // bundle hash or revision the weights came from
+ }
  public enum ImageGenEvent: Sendable {
-     case completed(url: URL, seed: UInt64)
+     case completed(url: URL, seed: UInt64, effective: FluxEffectiveParameters)
  }
```

**Event contract.** `effective` describes exactly what produced `url`, after all engine defaults, clamping,
and rounding.

**Acceptance test.** Send a request with no `steps` override, a non-multiple size (1000×1000 on a family that
rounds), and `guidance` left at its default. Assert all of the following:
- `effective.width` and `effective.height` match the PNG's pixel size.
- `effective.steps` equals the number of `.step` events.
- Re-running with `effective` as the request reproduces the file byte for byte.

### 1.4 Typed validation errors

**Motivation.** Osaurus validates field limits before calling the engine, so a workflow fails at save time,
not three minutes into a run. Today it duplicates each family's limits (`ImageModelRequestPolicy`). We would
rather ask the engine. When the engine does reject a request, its message is a string, so the editor cannot
point at the field.

**Struct diff.**

```swift
+ public struct FluxModelLimits: Sendable, Codable, Equatable {
+     public var dimensionMultiple: Int, minDimension: Int, maxDimension: Int, maxPixels: Int
+     public var stepRange: ClosedRange<Int>, guidanceRange: ClosedRange<Float>?
+     public var supportsNegativePrompt: Bool, supportsStrength: Bool, supportsMask: Bool
+     public var maxSourceImages: Int, outputFormats: [ImageFormat]
+     public var samplers: [String], defaultSampler: String?
+ }
+ extension FluxEngine { public func limits(for model: URL) async throws -> FluxModelLimits }

  public enum FluxError: Error {
+     case invalidField(field: String, value: String, allowed: String)
  }
```

**Event contract.** None. This is a synchronous query plus an error case. `invalidField` is thrown before
any weights load.

**Acceptance test.**
- For each registered family, `limits(for:)` matches the values hard-coded in Osaurus's
  `ImageModelRequestPolicy` today. That test then becomes the policy's source of truth.
- A request with `width: 1000` on Qwen-Image-2.1 throws `invalidField(field: "width", …)` without loading
  weights: assert that load time is below 100 ms.

### 1.5 Sampler and scheduler choice

**Motivation.** The parameters people tune most in ComfyUI are the sampler and scheduler (KSampler's
`sampler_name` / `scheduler`) and, for flow-matching models, the shift. Media steps already bind steps,
guidance, and seed, and these fields would complete the set. They also make a seed sweep meaningful across
samplers.

**Struct diff.** The same three fields on `ImageGenRequest` and `ImageEditRequest`:

```swift
+   public var sampler: String?      // one of FluxModelLimits.samplers; nil = family default
+   public var scheduler: String?    // e.g. "simple", "karras", "beta"; nil = family default
+   public var shift: Float?         // flow-matching timestep shift; nil = family default
```

**Event contract.** No new events. `effective` (1.3) echoes the values that ran.

**Acceptance test.**
- Every sampler in `limits(for:).samplers` produces an image for one seed, and different samplers produce
  different images.
- An unknown sampler throws `invalidField(field: "sampler", …)`.

### 1.6 LoRA adapters

**Motivation.** LoRA is the most requested capability after sampling parameters: a style or character
adapter applied at a weight. A workflow would declare it like a model requirement, so setup can download it.

**Struct diff.** On `ImageGenRequest` and `ImageEditRequest`:

```swift
+   public var adapters: [FluxAdapter] = []
+ public struct FluxAdapter: Sendable, Hashable {
+     public var url: URL          // a local .safetensors file
+     public var scale: Float      // typically 0…1.5
+     public var target: Target = .transformer   // .transformer | .textEncoder | .both
+ }
```

**Event contract.**
- Loading or fusing an adapter emits `.step` events with `total = 0`, or a new
  `case loadingAdapter(name: String)`, so the UI can show what is happening.
- Adapters are cached by `(url content hash, scale, target)`. A second request with the same set does not
  reload them.

**Acceptance test.**
- An adapter at scale 0 produces the same bytes as no adapter.
- Two requests with the same adapter load it once: assert on a counter.
- Removing the adapter on the next request restores the base output byte for byte, so no fused weights leak
  into the next request.

### 1.7 Previews every N steps

**Motivation.** A workflow run shows live progress per step. A small preview every few steps (the partly
denoised latent, decoded cheaply) is the most useful progress there is for a long generation, and the event
already exists.

**Struct diff.**

```swift
+   public var previewInterval: Int? = nil   // steps between previews; nil = none
+   public var previewMaxPixel: Int = 256
```

**Event contract.**
- When `previewInterval` is set, every family emits `.preview(pngData:step:)` at most every
  `previewInterval` steps.
- Previews are at most `previewMaxPixel` on the long side.
- A preview never stalls the denoise loop. It may be dropped under memory pressure, but never delayed.

**Acceptance test.**
- A 20-step generation with `previewInterval: 5` emits 3–4 previews, each under 64 KB.
- Total wall time is within 5% of the same request without previews.

### 1.8 Peak memory estimate

**Motivation.** Osaurus checks RAM before admitting an image job (RAM preflight in its job coordinator). It
must refuse with a typed error naming the setting or resource that applied, not let MLX allocate until the
process dies. Today the estimate is a heuristic per family.

**Struct diff.**

```swift
+ extension FluxEngine {
+     public func estimatedPeakBytes(for request: ImageGenRequest) async throws -> Int
+     public func estimatedPeakBytes(for request: ImageEditRequest) async throws -> Int
+     public func estimatedPeakBytes(for request: UpscaleRequest) async throws -> Int
+ }
```

**Event contract.** None. The estimate covers weights, activations at the requested size and batch, and the
VAE decode.

**Acceptance test.** For each family at 512², 1024², and the maximum size, the estimate is within ±15% of the
measured `MLX.GPU.peakMemory` for the run.

### 1.9 Local video

**Motivation.** `VideoGenRequest` and `VideoGenEvent` exist and are marked "future". Workflow video steps go to
remote providers today. A local WAN path would let a media video step run unattended and free of charge, like
local images.

**Struct diff.** Ship `engine.generateVideo(_:interrupt:)` with the existing structs, and add
`sourceImage: URL?` for image-to-video.

**Event contract.**
- The same `.step`, `.preview`, `.completed`, `.failed`, and `.cancelled` cases as images.
- `.completed` carries `fps` and `frameCount`, plus `effective` (1.3).
- Cancellation follows the same contract as 1.1.

**Acceptance test.**
- A 49-frame 480p clip completes, and the file's duration equals `frameCount / fps`.
- An interrupt after the first step emits `.cancelled` within 2 s and leaves no file.

## Stage 2: stage-level API

**Motivation.** ComfyUI's power comes from wiring the pipeline's stages separately: encode a prompt once and
reuse it, sample a latent, upscale the latent, sample it again at partial denoise (hires fix), mix two
conditionings, or decode only the result you keep. Osaurus workflows already have the graph, bindings, and
`map`. What they lack is engine calls at that granularity. With them, a media step can expose
`encode` / `sample` / `decode` sub-actions, and the Architect can build hires-fix and prompt-mix workflows
from ordinary steps.

**API.** Handles are opaque, `Sendable`, and owned by the engine. They live until released or until the engine
unloads the model; a released or stale handle throws `FluxError.staleHandle`.

```swift
public struct FluxConditioning: Sendable, Hashable { public let id: UUID }   // text-encoder output
public struct FluxLatent: Sendable, Hashable { public let id: UUID; public let width: Int; public let height: Int }

extension FluxEngine {
    /// Text → conditioning. Cached by (model, prompt, negativePrompt, adapters).
    public func encodePrompt(model: URL, prompt: String, negativePrompt: String?, adapters: [FluxAdapter])
        async throws -> FluxConditioning
    /// Weighted blend of conditionings (same model).
    public func mix(_ parts: [(FluxConditioning, Float)]) async throws -> FluxConditioning
    /// Image → latent (VAE encode), for img2img and edits.
    public func encodeImage(model: URL, image: URL, width: Int?, height: Int?) async throws -> FluxLatent
    /// Empty latent of a size.
    public func emptyLatent(model: URL, width: Int, height: Int, batch: Int) async throws -> FluxLatent
    /// Denoise. `denoise` < 1 starts from `latent` partway (img2img / hires second pass).
    public func sample(
        _ conditioning: FluxConditioning, latent: FluxLatent, steps: Int, guidance: Float, seed: UInt64,
        sampler: String?, scheduler: String?, shift: Float?, denoise: Float, interrupt: FluxInterrupt?
    ) -> AsyncThrowingStream<FluxSampleEvent, Error>
    /// Latent resize (nearest / bilinear / bislerp), for hires fix.
    public func resize(_ latent: FluxLatent, width: Int, height: Int, method: String) async throws -> FluxLatent
    /// Latent → file.
    public func decode(_ latent: FluxLatent, outputDir: URL, format: ImageFormat) async throws -> [URL]
    public func release(_ handles: [AnyHashable]) async
}

public enum FluxSampleEvent: Sendable {
    case step(step: Int, total: Int, etaSeconds: Double?)
    case preview(pngData: Data, step: Int)
    case completed(FluxLatent, effective: FluxEffectiveParameters)
    case failed(message: String, hfAuth: Bool)
    case cancelled
}
```

**Residency.** Osaurus serializes all image work through one lane and unloads chat models first. Stage
calls must not load a second copy of the weights, and `release` must free the handle's memory before it
returns. When Osaurus unloads the model, every outstanding handle becomes stale.

**Event contract.**
- Only `sample` streams events.
- Every other call is a single async result and must not hold the GPU longer than its own work.
- `estimatedPeakBytes` (1.8) gains overloads for `sample` and `decode`.

**Acceptance tests.**
1. **Parity.** `encodePrompt → emptyLatent → sample(denoise: 1) → decode` with seed S is byte-identical to
   `generate` with seed S.
2. **Reuse.** Two `sample` calls on one `FluxConditioning` with seeds S and S+1 run the text encoder once, and
   each output matches `generate` with that seed.
3. **Hires fix.** `sample` at 768², `resize` to 1536², then `sample(denoise: 0.45)` produces a 1536² image.
   Peak memory stays below a single `generate` at 1536².
4. **Mix.** `mix([(a, 1), (b, 0)])` decodes to the same bytes as `a` alone.
5. **Lifetime.** After `release`, using the handle throws `staleHandle`, and active memory drops by at least
   the handle's estimated size.
6. **Cancel.** Interrupting `sample` mid-run emits `.cancelled` within one step and leaves the input
   latent usable.

## Priority

From the workflow side, in order:
1. 1.1 cancellable upscale: a correctness gap today.
2. 1.3 effective parameters: the records must match what ran.
3. 1.4 typed limits: one source of truth instead of duplicated policy.
4. 1.2 native batch.
5. 1.5 samplers.
6. 1.7 previews.
7. 1.8 memory estimate.
8. 1.6 LoRA.
9. 1.9 local video.
10. Stage 2.

Items 1.1, 1.3, and 1.4 need no new model work and unblock the most on our side.

## Contacts and pinning

Osaurus pins vmlx-swift by revision. Each item lands behind its own revision bump, and Osaurus adopts it with
the matching test from this document in its own suite. Until an item ships, Osaurus keeps its current
behavior (sequential batch, its own limit table for families without engine limits) and does not fake the
missing capability.
