# Native Swift image agent job flow

Status: `DESIGN/HANDOFF - NOT IMPLEMENTED`

Branch: `feat/image-generation-vmlxflux`

This document records the next Osaurus image-generation requirement: the main
chat agent should be able to ask local native Swift image generation/edit models
to do work as a first-class job, with low RAM behavior on sub-24 GB machines and
without disturbing the existing chat, privacy, tool, prompt, or memory-safety
contracts.

## User Request

The desired flow is:

1. The active chat model, whether cloud or local, posts an image generation or
   image edit job.
2. If the active chat model is local, Osaurus temporarily unloads it before
   loading the image model.
3. The image generation/edit model loads, runs the job, streams useful progress,
   writes the output artifact, and unloads.
4. If a local chat model was unloaded for the job, Osaurus automatically reloads
   it so the original agent loop can continue seamlessly.
5. If the active chat model is cloud/API-backed, no local chat-model unload is
   needed; the local image job still uses the same progress/artifact path.
6. Manual image-panel use remains a separate mode with separate RAM-safety
   behavior because it is user-directed, not an agent tool call in the middle of
   a conversation.
7. Defaults must be safe for users with less than 24 GB RAM, must respect the
   existing Memory Safety settings, and must not rely on hidden prompt tricks,
   sampler changes, or fake guards.
8. System prompts, tool prompts, and tool flow must remain efficient and must
   not destabilize existing tool use, privacy filtering, reasoning, memory, or
   cache behavior.
9. This must be documented and live end-to-end tested before it is called
   working.

## Current Privacy Filter Behavior

The privacy filter is not a recursive chat subagent. It is a separate on-device
MLX service pipeline that suspends the outbound request, transforms the payload,
and then resumes the original provider request.

Important current behavior:

- `PrivacyFilterPipeline.applyOutbound` is the boundary used before cloud-bound
  requests. It reads settings, lazy-loads the privacy model if needed, scans the
  latest user-turn text, presents review UI when available, scrubs approved
  originals, and returns scrubbed messages plus a redaction map.
- It fails closed. If the engine is missing, detection fails, substitution is a
  no-op, or post-scrub leak checks still find sensitive content, the send is
  blocked instead of silently passing through raw content.
- It only detects new content from the latest user turn, while still applying
  cumulative substitutions across history through `RedactionMap`. That keeps
  latency bounded and avoids reclassifying the whole chat every turn.
- It has a UI presenter model: the pipeline suspends on a review service, the
  chat window presents a sheet, and cancellation maps back to normal chat cancel
  behavior without firing the remote request.
- Inbound responses and tool-call arguments are unscrubbed through the same map,
  including streaming deltas and tool invocations.

The image job flow should copy the orchestration pattern, not the redaction
logic: a first-class service owns the side job, exposes progress, and returns a
safe artifact result to the original chat/tool loop.

## Existing Image State

Already proven on this branch:

- Native image models are cataloged through `/images/models`.
- `ImageGenerationService` owns the only `vMLXFlux` import and exposes
  generation, edit, and upscale events through Osaurus-native types.
- `MetalGate` already treats image generation as an exclusive external MLX
  workload, so it waits for in-flight LLM generation to drain and blocks new
  LLM generation until the image stream is fully drained.
- The SwiftUI manual image composer can send prompt, negative prompt, steps,
  guidance, size, seed, edit strength, and source images.
- HTTP proof has covered Z-Image Turbo, FLUX.1 Schnell, Qwen-Image,
  Qwen-Image-Edit, and Ideogram catalog/generate/edit/reject/cancel/reload rows.

Still not implemented:

- No model-visible image job tool exists for the main chat agent.
- No image-job coordinator unloads the active local LLM before an image job.
- No automatic local LLM restore/reload is tied to a completed image job.
- No agent-loop progress surface exists for image jobs.
- No RAM-safety policy distinguishes agent-triggered image jobs from manual
  image-panel use.
- No live e2e proof exists for local-chat-model unload -> image model load ->
  image output -> image unload -> local-chat-model reload -> final chat answer.

## Recommended Architecture

Add one orchestration layer above `ImageGenerationService`:

```text
Agent/tool loop
    -> NativeImageJobTool
        -> NativeImageJobCoordinator
            -> LocalModelHandoffPolicy
                -> ModelRuntime unload/restore when active chat model is local
            -> ImageGenerationService
                -> MetalGate exclusive image-generation lane
                -> vMLXFlux.FluxEngine
            -> SharedArtifact / chat artifact result
```

### Tool Surface

Expose a compact built-in tool, likely one of:

- `create_image`
- `edit_image`
- one combined `image_job` with `mode: "generate" | "edit"`

Recommended: one combined `image_job` tool to keep prompt/tool tokens low.

The schema should not list every installed model in the system prompt. Use
`model: "auto"` by default, plus optional exact model id for advanced callers.
The tool can return a short catalog error if no compatible local image model is
installed.

Minimum arguments:

- `mode`: `generate` or `edit`
- `prompt`: required
- `negative_prompt`: optional
- `source_artifact_id` or `source_image_path`: required for edit, forbidden for
  pure generation
- `size`: optional, constrained to supported presets
- `steps`: optional, clamped by model limits and RAM-safety policy
- `guidance`: optional
- `seed`: optional

The tool result should include:

- generated artifact path/id
- selected image model
- mode
- dimensions
- steps/guidance/seed
- elapsed load/generation time
- whether a local chat model was unloaded/restored
- final memory/residency status when available

The chat layer should process the output through the existing artifact path so
the user sees an image card/markdown image without the model needing to call
`share_artifact` separately.

### Coordinator Responsibilities

`NativeImageJobCoordinator` should own the sequence:

1. Snapshot active chat provider/model context.
2. If the active chat provider is local and a model is resident, wait for the
   current assistant tool-call stream to finish and for `ModelLease` to release.
3. Unload the local chat model through `ModelRuntime.unload(name:)` or a narrow
   public wrapper. Do not tear down while a lease is active.
4. Clear MLX cache through the existing runtime unload path.
5. Start `ImageGenerationService.generate` or `.edit`.
6. Emit progress events to the chat turn/tool row.
7. On completion/cancel/failure, unload the image engine/model.
8. If a local chat model was displaced, mark it for restore. The next model
   step can reload naturally, but the UI should say `Reloading chat model...`
   if Osaurus proactively reloads before asking for the final answer.
9. Return a structured tool result with artifact metadata and status.

The coordinator must not spawn recursive local agents, helper LLMs, or shell
workers. It should be normal Swift service code.

### Local vs Cloud Chat Model

Cloud/API chat model:

- No local chat model unload is needed.
- The tool executes locally and returns an artifact/result to the cloud model's
  agent loop.
- Privacy filter still applies before cloud model calls, but image prompt text
  sent into local image generation should remain local.

Local chat model:

- The tool call is produced first while the chat model is resident.
- Once the tool call stream is complete and the tool is about to run, unload
  the local chat model.
- Run and unload the image model.
- Reload the original chat model before the follow-up model step, or let the
  normal agent-loop step reload it while surfacing progress.
- Preserve model defaults, generation config, reasoning state, tool state, and
  session history. Do not alter sampler or template settings to hide reload
  latency.

## Progress UX

Progress must be real events, not a timer guess.

Minimum chat/tool progress states:

- `Queued image job`
- `Waiting for current chat generation to finish`
- `Unloading chat model to free RAM`
- `Loading image model`
- `Generating image step N/T`
- `Decoding/saving image`
- `Unloading image model`
- `Reloading chat model`
- `Done`

For HTTP/SSE parity, image job events should map to machine-readable frames
with the same phases. The chat UI should show these in the assistant/tool row
without requiring the model to narrate progress.

## RAM Safety Policy

Agent-triggered image jobs should default to the safest low-RAM behavior:

- Prefer single-model residency during the image job.
- For local chat models, unload the chat model before loading the image model.
- Use model registry defaults for steps/guidance unless the user or tool call
  explicitly overrides them.
- Clamp image size/steps to model limits and the selected safety mode.
- Fail before unsafe allocation when a strict user-selected policy cannot be
  satisfied.
- Surface a typed error that names the setting or resource limit that blocked
  the job.
- Do not add hidden hardcoded RAM percentage blocks. Any refusal must flow from
  documented Memory Safety settings, model metadata, or a real preflight
  estimate.

Manual panel mode is different:

- The user explicitly selected the image model/workflow.
- It may keep image controls and manual model selection visible.
- It should still show RAM warnings and obey strict settings, but it does not
  need to unload/reload a chat model unless a chat model is resident and would
  violate the selected safety policy.

## Prompt and Tool Stability

The system prompt must stay efficient:

- Prefer one compact tool schema over separate verbose generate/edit tools.
- Do not inject long model catalogs into every prompt.
- Avoid prompt instructions that force the model to use image generation for
  every visual mention. Let it call the tool when the user asks for image
  creation/editing.
- Keep existing `todo`, `complete`, `clarify`, `share_artifact`, memory,
  sandbox, MCP, and configuration tool flow unchanged.
- Do not change chat templates, reasoning envelopes, sampler defaults, or tool
  parser behavior for this feature.

Recommended model guidance: one short line in the tool description that says the
tool creates or edits images and returns an artifact. The tool schema and tool
failure envelopes should carry the detailed correction hints.

## Privacy Filter Interaction

Privacy filter remains text/cloud-bound:

- It should continue to scrub user text before cloud provider calls.
- Image job prompts sent to local native image models do not leave the machine
  and should not be blocked solely because privacy filter is enabled.
- If a cloud model asks the local tool to generate an image using text that was
  scrubbed for the cloud model, the local tool may receive placeholders unless
  the existing inbound/tool-call unscrub path maps them back. This must be
  tested. Tool-call argument unscrubbing already exists for provider-thrown tool
  invocations; the image tool path must confirm it receives original local text
  when appropriate and never sends originals back to cloud providers.
- Image input PII/OCR remains out of scope unless a future OCR privacy pass is
  added. Current privacy docs already treat non-text media as a limitation.

## Error Handling

Required typed failures:

- no compatible image model installed
- selected model incomplete/not ready
- generation model used for edit or edit model used for generation
- edit requested without a source image/artifact
- mask/inpaint requested while masks remain unsupported
- strict RAM safety refused before load
- current local chat generation did not drain in time
- image generation canceled
- image generation failed after load
- chat model restore failed after image job

Failure rules:

- Keep the user turn and surface the failure in the assistant/tool row.
- Do not lose the generated artifact if the final chat-model reload fails.
- Always unload image model state on completion/failure when the job was
  agent-triggered under low-RAM mode.
- Do not swallow cancellation; cancellation should unwind through the same
  job-status surface.

## Implementation Checklist

1. Add `NativeImageJobCoordinator` service.
2. Add a narrow public `ModelRuntime` API for active local model snapshot,
   unload-for-job, and optional restore/reload.
3. Add `ImageGenerationService.unload()` or equivalent so agent-triggered jobs
   can release image weights after completion.
4. Add `NativeImageJobTool` and register it as a compact built-in tool, gated by
   image feature availability and agent/tool settings.
5. Wire chat tool post-processing so image job results become image artifacts
   without requiring a second `share_artifact` call.
6. Add progress event plumbing from coordinator to chat UI and HTTP/SSE proof
   harnesses.
7. Add memory-safety policy for agent-triggered jobs vs manual panel jobs.
8. Add docs and source guards for prompt/tool schema size and no recursive
   agent workers.
9. Add focused tests for tool argument validation, mode/model compatibility,
   unload/restore sequencing, progress phases, and artifact result shape.
10. Add live proof scripts on `erics-m5-max.local`.

## Live Proof Requirements

Do not mark this feature working until all of these pass:

- Cloud chat model calls image tool -> local image generation -> artifact
  appears -> cloud model final answer references artifact.
- Local chat model resident -> model emits image tool call -> local chat model
  unloads -> image model loads/generates/unloads -> local chat model reloads ->
  final answer appears.
- Same as above for image edit with a real source image artifact.
- Cancellation during image model load and during denoise both leave server
  health clean and unload state correct.
- Strict memory-safety mode refuses unsafe jobs before allocation with a typed
  error.
- Manual image panel still works and keeps its separate UI controls.
- Privacy filter enabled with a cloud model still scrubs cloud-bound text and
  does not leak placeholders or raw PII into the wrong surface.
- `/health` before, during, and after each run shows expected resident models,
  in-flight jobs, and no stale leases.
- Physical footprint evidence is recorded for a sub-24 GB style safety profile,
  or the row is marked `PARTIAL`/`BLOCKED` if only run on the 128 GB proof host.

## Current Status

`FIXED`:

- Native image API and manual composer wiring exist.
- Model catalog and capability metadata are exposed.
- `ImageGenerationService` serializes image generation through `MetalGate`.
- Prior image API stress proof passed on `erics-m5-max.local`.

`PARTIAL`:

- Foreground manual SwiftUI click-through is still not proven.
- Image generation is available as direct image-model chat/manual mode and HTTP
  API, not as an ordinary main-agent tool.
- Low-RAM unload/reload handoff is only available indirectly through existing
  runtime unload primitives; there is no image-specific coordinator yet.

`BLOCKED FOR RELEASE`:

- No local-chat-model unload -> image-job -> chat-model restore live proof.
- No cloud-chat-model -> local image tool e2e proof.
- No image-edit agent tool proof.
- No agent-triggered RAM-safety preflight/refusal proof.
- No progress UI proof for the agent-triggered path.
