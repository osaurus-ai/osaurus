# Native Swift image agent job flow


> ⚠️ UPDATED DIRECTION (2026-06-20): generalizing into one configurable primitive
> **`spawn(name, input)`** (working name; `invoke` alt) — a portable
> PROCESS-spawning framework over Agent personas, gated by a **per-agent
> `spawnable` flag, default OFF**. The flows here (`local_delegate`, `image_*`)
> become the first spawnable KINDS; a local-only **privacy loop** is a planned
> kind. Canonical design + operational lifecycle/cache/tokenizer/image/progress
> nuances: **SUBAGENT_PORTABLE_DESIGN.md**. Status/TODO: SUBAGENT_ORCHESTRATION_STATUS.md.
>
> **IMPLEMENTED (2026-06-25):** this shipped as the unified `Subagent*` framework
> (`SubagentSession` + `SubagentKind`). The flows here are renamed: `local_delegate`
> is gone (folded into **`spawn`**) and `image_generate`/`image_edit` are merged into
> one **`image`** tool (`source_paths` ⇒ edit). Read this historical doc through that
> map; the live wiring is in SUBAGENT_TEAM_SPEC.md §4.


Status: `PARTIAL - SOURCE WIRED, E2E PROOF MISSING`

Branch: `feat/image-generation-vmlxflux`

Local model storage verified 2026-06-18:

- `~/.mlxstudio/models` is a symlink to `/Users/eric/models`, so existing
  Osaurus and vmlx-swift model discovery paths still resolve.
- `/Users/eric/models/JANGQ-AI` contains Laguna and MiniMax local chat bundles.
- `/Users/eric/models/OsaurusAI` contains VibeThinker and Gemma local chat
  bundles.
- `/Users/eric/models/image` contains the 13 local mflux image bundles.

This document records the next Osaurus agent-delegation requirements:

- the main chat agent should be able to ask local native Swift image
  generation/edit models to do work as a first-class job, with low RAM behavior
  on sub-24 GB machines; and
- cloud/API chat models should be able to delegate bounded text/coding subtasks
  to a user-selected local downloaded model to reduce cloud token cost.

Both flows must avoid disturbing the existing chat, privacy, tool, prompt,
permission, or memory-safety contracts.

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

Additional cloud-cost requirement:

1. When the active model is a cloud/API provider, the user may enable a local
   text delegate model that acts like a bounded RLM-style helper for coding and
   analysis subtasks.
2. The local delegate model is selected from downloaded local chat-capable
   models, not from a hardcoded list or cloud catalog.
3. The cloud model may post a local delegate job instead of spending more cloud
   tokens on work that can be done locally.
4. The local delegate job returns a compact result to the cloud model, with
   local-only detail summarized rather than replaying full local transcripts.
5. Text delegation, image generation, and image edit must each have explicit
   permission policy: ask, deny, or always allow.
6. The permission prompt must show the selected job type and target local model,
   and should allow the user to switch to another downloaded compatible model
   before approving.
7. Local delegate settings must include load/unload behavior, budgets, and
   memory-safety behavior so sub-24 GB users do not accidentally keep multiple
   heavy local models resident.

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

The local text delegate flow should also copy the orchestration pattern, not
the privacy filter's redaction logic. It should be a first-class bounded local
job with its own progress, permission, model selection, and result envelope. It
should not be implemented by making the privacy filter recursive or by letting
cloud providers directly operate local tools.

## Existing Image State

Source/runtime evidence currently recorded on this branch:

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

- No live foreground Osaurus run has proven `image_generate` / `image_edit`
  from an actual chat model turn.
- No live foreground Osaurus run has proven the Settings toggles remove and
  re-add delegation tools from the real prompt/tool payload.
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

## Cloud Cost Saver Local Text Delegate

Status: `SOURCE-WIRED - LIVE E2E MISSING`

This is a sibling flow to image jobs. It lets a cloud/API chat model ask a
local downloaded chat-capable model to do bounded helper work, especially coding
analysis, file inspection summaries, test triage summaries, or other subtasks
where local tokens are cheaper than cloud tokens.

The local text delegate is not a fully recursive autonomous agent by default.
It should be a constrained job service with a clear input, allowed context,
allowed tools, token/turn budget, progress events, and a structured result.
Recursive multi-turn delegation can be added later only if it has separate
permission and budget controls.

Recommended architecture:

```text
Cloud/API agent loop
    -> LocalDelegateTool
        -> LocalDelegateCoordinator
            -> DelegatePermissionPolicy
            -> DelegateModelSelectionPolicy
                -> downloaded local chat-capable ModelPickerItem
            -> LocalModelHandoffPolicy
                -> ModelRuntime load/unload under Memory Safety settings
            -> bounded local model run
            -> compact structured result back to cloud agent loop
```

Minimum `local_delegate` arguments:

- `task`: concise helper instruction
- `mode`: `coding`, `analysis`, `summarize`, or `other`
- `context_refs`: optional file/artifact/message references that Osaurus
  resolves locally
- `allowed_tools`: optional allowlist constrained by the user's permission
  policy
- `max_tokens`: optional, clamped by settings
- `max_turns`: optional, clamped by settings
- `model`: optional local model id, defaulting to the user's configured local
  delegate model

The tool result should include:

- selected local delegate model
- whether the delegate was loaded cold or already resident
- summary result intended for the cloud model
- optional local-only artifact/log id for user inspection
- token counts and elapsed time when available
- whether any requested tool/file permission was denied
- final memory/residency status when available

The cloud model should receive only the compact result unless the user or
policy explicitly allows richer local transcript sharing. This is both a cost
control and a privacy boundary.

### Text Delegate RAM Rules

Cloud/API chat model:

- No active cloud model is resident locally, so only the selected local delegate
  model needs local RAM.
- Default behavior for low-RAM users should load the local delegate for the job
  and unload it when the job completes.
- An advanced setting may keep the delegate warm, but strict Memory Safety
  should be allowed to override that when image generation/edit or another
  local model would exceed policy.

Local chat model:

- Local-to-local text delegation should be disabled by default unless there is
  a clear user-selected reason. It can easily double local residency or create
  confusing recursive behavior.
- If enabled, the coordinator must use the same unload/restore handoff rules as
  image jobs when the delegate model differs from the active chat model and the
  selected Memory Safety mode requires single-model residency.
- If the active local chat model is already the selected delegate model, the
  job should run in-process only if the agent-loop contract can guarantee no
  recursive stream/tool corruption. Otherwise it should be refused with a typed
  error until the coordinator supports it.

## Settings GUI Requirements

Add a small settings surface under local inference/agents rather than burying
these controls inside prompts.

Required controls:

- Master Agent Delegation enablement. When this is off, delegated text/image
  job guidance and tools must be absent from chat prompt/tool payloads.
- Enable cloud-to-local text delegation.
- Enable chat image generation/edit delegation separately from manual image
  panels.
- Default local text delegate model, sourced from downloaded local chat-capable
  `ModelPickerItem`s.
- Default image generation model, sourced from downloaded image-capable models.
- Default image edit model, sourced from downloaded edit-capable models.
- Text delegate load policy: unload after job, keep warm when safe, or strict
  single-job residency.
- Image job load policy: unload displaced chat model first, unload image model
  after agent-triggered job, and obey manual-panel policy separately.
- Delegate budgets: max local delegate tokens, max local delegate turns, max
  tool calls, and max elapsed time.
- Sharing policy: compact result only, allow local transcript summary, or ask
  before sharing expanded local detail back to the cloud model.
- Permission defaults for each spawned job family: ask, deny, or always allow.

The model picker must use the existing downloaded-model catalog path. The
system prompt must not include the full downloaded model list. The coordinator
can resolve `"auto"` or a configured default at runtime and return a typed
missing-model error if the selected model has been deleted or is incomplete.

Current source status:

- `AgentDelegationSettingsSection` exposes the master Agent Delegation toggle,
  cloud-to-local text toggle, chat image-job toggle, default local
  text/image/edit model pickers, load policies, permission defaults, sharing
  policy, and budgets.
- `AgentDelegationConfiguration` persists the master/image toggles with
  backward-compatible decode defaults. Older config files decode with the
  master toggle off, so old installs do not unexpectedly inject delegated tools
  into prompts.
- `ToolRegistry.alwaysLoadedSpecs` and `ToolRegistry.specs(forTools:)` hide
  `image_generate` and `image_edit` unless both the master toggle and chat image
  delegation toggle are on.
- `ToolRegistry.availability(forTool:)` reports disabled delegation tools as
  disabled with settings detail, and `capabilities_load` rejects them instead of
  reintroducing disabled built-ins.
- `NativeImageGenerateTool` and `NativeImageEditTool` reject stale direct
  execution when image delegation is disabled.

## Permission Model

Image generation, image edit, and local text delegation should be separate
permission subjects because they have different cost, privacy, and RAM impact.

Recommended subjects:

- `agent.image.generate`
- `agent.image.edit`
- `agent.local_text_delegate`
- `agent.local_text_delegate.tool_use`

Recommended policy values:

- `ask`: show a permission sheet before the job starts.
- `deny`: refuse with a typed tool error.
- `always_allow`: allow future jobs matching the saved scope without another
  prompt.

Permission prompt requirements:

- Show the requesting active model/provider.
- Show the job type: text delegate, image generate, or image edit.
- Show the selected local model and allow switching to a compatible downloaded
  model before approval.
- Show requested tool/file/network scope for local text delegation.
- Show estimated RAM policy and whether another local model will be unloaded.
- Persist `always_allow` narrowly by job family, provider/agent, selected model
  or model class, and scope. Do not make one broad global approval cover every
  future tool or model.
- Deny must not mutate chat history as if the job ran. It should return a
  structured denial that the active model can explain.

Security rules:

- A cloud model must not directly grant itself local file, shell, network, or
  plugin permissions by routing through the local delegate.
- The local delegate inherits only permissions explicitly granted by the user
  or already available under the current agent policy.
- Privacy-filter placeholders must not be expanded into cloud-visible text
  unless the existing local unscrub/sharing policy allows that exact surface.
- Local transcripts that contain private file contents should stay local unless
  the user approves sharing a summary or excerpt back to the cloud model.
- No hidden sampler, system-prompt, or tool-parser changes may be introduced to
  make delegation look successful.

## Progress UX

Progress must be real events, not a timer guess.

Minimum image chat/tool progress states:

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

Minimum local text delegate progress states:

- `Queued local delegate job`
- `Checking delegate permission`
- `Resolving local delegate model`
- `Unloading resident model to free RAM` when applicable
- `Loading local delegate model`
- `Running local delegate`
- `Summarizing delegate result`
- `Unloading local delegate model` when applicable
- `Returning delegate result`
- `Done`

The UI should make the distinction clear: cloud model is waiting on a local
delegate job, not silently continuing to spend cloud tokens.

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
5. Add `LocalDelegateCoordinator` and `LocalDelegateTool`, gated by
   cloud-to-local delegation settings and permission policy. Source status:
   `local_delegate` now exists as a bounded text-only `AgentToolLoop` child
   tool; richer child tool use remains blocked until the separate
   `localTextDelegateToolUse` permission flow is implemented.
6. Add settings storage/UI for default local delegate model, default image
   generate/edit models, load policy, budgets, sharing policy, and per-job
   permission defaults.
7. Wire chat tool post-processing so image job results become image artifacts
   without requiring a second `share_artifact` call.
8. Wire text delegate result post-processing so only the compact result returns
   to the cloud model by default, with local-only logs/artifacts retained for
   user inspection.
9. Add progress event plumbing from coordinators to chat UI and HTTP/SSE proof
   harnesses.
10. Add memory-safety policy for agent-triggered jobs vs manual panel jobs vs
    cloud-to-local text delegate jobs.
11. Add docs and source guards for prompt/tool schema size and no unbounded
    recursive agent workers.
12. Add focused tests for tool argument validation, mode/model compatibility,
    downloaded-model selection, permissions, unload/restore sequencing,
    progress phases, cost/token accounting, and artifact/result shape.
13. Add live proof scripts on `erics-m5-max.local`.

## Live Proof Requirements

Do not mark this feature working until all of these pass:

- Cloud chat model calls image tool -> local image generation -> artifact
  appears -> cloud model final answer references artifact.
- Cloud chat model calls local text delegate -> downloaded local model loads ->
  bounded coding/analysis result returns -> cloud model final answer uses the
  compact result. Record cloud input/output token delta versus a no-delegate
  baseline when possible.
- Local chat model resident -> model emits image tool call -> local chat model
  unloads -> image model loads/generates/unloads -> local chat model reloads ->
  final answer appears.
- Same as above for image edit with a real source image artifact.
- Permission `ask`, `deny`, and `always_allow` are proven separately for local
  text delegate, image generation, and image edit.
- Permission prompt model override is proven with downloaded local text and
  image models.
- Deleted/incomplete configured delegate model produces a typed error and does
  not silently pick a random cloud model.
- Cancellation during image model load and during denoise both leave server
  health clean and unload state correct.
- Cancellation during local delegate load and delegate generation leaves server
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

## Team E2E Proof Matrix

Use this matrix as the shared red/green ledger for the Osaurus team. Do not
delete failed rows. Change a row from `RED`/`BLOCKED` to `GREEN` only when the
required evidence exists under an artifact directory and the exact commit,
machine, command, model id, and output are recorded.

Recommended artifact root for the next full run:

```sh
export IMAGE_AGENT_PROOF_ROOT="/tmp/osaurus-native-image-agent-e2e-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$IMAGE_AGENT_PROOF_ROOT"
git rev-parse HEAD > "$IMAGE_AGENT_PROOF_ROOT/git-head.txt"
sw_vers > "$IMAGE_AGENT_PROOF_ROOT/sw_vers.txt"
uname -a > "$IMAGE_AGENT_PROOF_ROOT/uname.txt"
```

### Build And Source Gates

| Row | Status | Command | Required evidence | Current blocker |
| --- | --- | --- | --- | --- |
| Source image UI wiring contract | SOURCE-WIRED, RERUN PENDING | `scripts/live-proof/assert-image-ui-wiring.sh` | stdout copied to proof root | Not rerun in the current proof pass; still not UI click proof |
| SwiftPM build | GREEN | `swift build --package-path Packages/OsaurusCore` | exit 0 log | Fresh local build passed on 2026-06-18 after strict resolver/prompt changes |
| Native image coordinator tests | BLOCKED local | `swift test --package-path Packages/OsaurusCore --filter NativeImageJobCoordinatorTests` | Swift Testing output for all focused tests | Local machine has package-wide `no such module 'Testing'`; compatible-host rerun pending after latest resolver changes |
| Keychain-free Release app build | RED | `scripts/live-proof/build-keychain-free-osaurus.sh "$IMAGE_AGENT_PROOF_ROOT/DerivedData"` | built `osaurus.app` path, xcodebuild log, ad-hoc codesign log | Not rerun after agent tool/residency commits |
| Foreground SwiftUI launch | RED | `scripts/live-proof/open-keychain-free-osaurus.sh "$APP" "$IMAGE_AGENT_PROOF_ROOT/ui"` | app PID/window screenshot/log | Manual foreground click-through pending |
| Headless app/server launch | RED | `scripts/live-proof/launch-keychain-free-osaurus.sh "$APP" "$IMAGE_AGENT_PROOF_ROOT/server"` | pid, app log, `/health` response | Needs current app build |

### Settings And Permission Persistence

| Row | Status | How to test | Required evidence | Current blocker |
| --- | --- | --- | --- | --- |
| Agent Delegation settings save/load | SOURCE-WIRED, LIVE-RED | Open Settings, toggle master delegation, cloud text delegate, image delegate, choose local text delegate, image gen model, image edit model, load policies, budgets, and permission defaults; quit/relaunch; confirm same values | `~/.osaurus/config/agent-delegation.json` from test root plus before/after screenshots | Focused tests did not execute on this host; no live UI persistence proof |
| Delegation off removes image tools from prompt/tool payload | SOURCE-WIRED, LIVE-RED | Turn master delegation off, start chat, inspect outgoing tool schemas/context budget | outbound request/tool schema log, context-budget screenshot | Source tests cover `ToolRegistry.alwaysLoadedSpecs`; no live provider payload proof |
| Image delegation off blocks capability reload/stale execution | SOURCE-WIRED, LIVE-RED | Master on, image delegation off; ask model to load/call `image_generate` | disabled availability detail, rejected stale call envelope | Source tests cover registry/spec/direct execution; no live agent-loop proof |
| Downloaded-model picker filtering | SOURCE-WIRED, LIVE-RED | Confirm local text picker shows chat-capable downloaded models only, image gen picker shows text-to-image models only, image edit picker shows edit-capable models only | screenshots plus `/images/models` JSON | Needs live app |
| Permission `deny` for image generate | SOURCE-WIRED, LIVE-RED | Set image generate permission to `deny`; ask cloud/local chat to create an image | tool result envelope shows rejected, no image model load in logs | No live agent-loop run |
| Permission `ask` for image generate | SOURCE-WIRED, LIVE-RED | Set image generate permission to `ask`; trigger tool; approve once | prompt screenshot, resulting job, saved policy state if "always allow" chosen | Prompt UI not live-proven |
| Permission `always_allow` for image generate | SOURCE-WIRED, LIVE-RED | Set image generate permission to `always_allow`; trigger two jobs | second job starts without prompt, logs identify selected model | No repeated live proof |
| Permission `deny` / `ask` / `always_allow` for image edit | SOURCE-WIRED, LIVE-RED | Repeat the three image-generate permission rows using a real source image artifact | prompt/result screenshots, no dangling tool call | No live edit agent-loop proof |
| Permission `deny` / `ask` / `always_allow` for local text delegate | SOURCE-WIRED, LIVE-RED | Repeat with `local_delegate` | prompt/result screenshots, local delegate logs | Source tool enforces deny/ask/always_allow; no live app permission proof |
| Permission prompt resolved-model display | SOURCE-WIRED, LIVE-RED | Omit model args and trigger `image_generate`, `image_edit`, and `local_delegate` with `ask` permissions | screenshots showing resolved model and load policy before approval | Source enriches prompt arguments; no live prompt screenshot |
| Permission model override in prompt | SETTINGS-SOURCE-WIRED, LIVE-RED | In the permission sheet, switch from default image model to another compatible downloaded model before approving | screenshot and final tool payload selected model | Prompt model override not proven |

### Image Agent E2E Flows

| Row | Status | Flow | Required evidence | Current blocker |
| --- | --- | --- | --- | --- |
| Cloud chat -> `image_generate` -> local image artifact -> final answer | RED | Select cloud/API provider, ask for a concrete image, let model call `image_generate`, verify final assistant answer references result | chat transcript, tool call JSON, progress events, generated image path, `/health` before/during/after | No live cloud agent-loop proof |
| Local chat -> `image_generate` -> chat unload -> image job -> image unload -> chat restore -> final answer | RED | Select local chat model, preload/send one turn, then ask for image | `cachedModelSummaries`/`/health`, Activity Monitor footprint, app log showing unload/restore phases, final answer | No live resident-model proof |
| Cloud chat -> `image_edit` with artifact path -> edited artifact -> final answer | RED | Generate or import source image, ask cloud chat to edit it, ensure `source_paths` points to local artifact | source image, edited image, tool payload, transcript | Source path/artifact integration not live-proven |
| Local chat -> `image_edit` with artifact path -> unload/restore | RED | Same as local generate, but with real source image | RAM footprint, unload/restore logs, edited image | No live edit + residency proof |
| Manual image panel generate | PARTIAL | Use manual composer with prompt, negative prompt, steps, guidance, size, seed | foreground screenshot, generated image, app log | Prior source/API proof only; current foreground click-through pending |
| Manual image panel edit | PARTIAL | Attach or select source image, edit with Qwen-Image-Edit path | source and output images, screenshot, app log | Prior source/API proof only; current foreground click-through pending |
| Cancellation during image model load | RED | Start large image job and cancel while loading | cancellation log, `/health`, resident model state | No live cancellation proof |
| Cancellation during denoise/generation | RED | Cancel after step events begin | cancellation log, no stale image residency, `/health` | No live cancellation proof |
| Repeated image jobs under `always_allow` | RED | Run 10 sequential image jobs: 5 generate, 5 edit | all outputs, no stale leases, no memory growth trend | No stress loop proof |

### Local Text Delegate E2E Flows

| Row | Status | Flow | Required evidence | Current blocker |
| --- | --- | --- | --- | --- |
| Cloud chat -> local coding delegate -> compact result -> final cloud answer | SOURCE-WIRED, LIVE-RED | Cloud model posts bounded local text job; local model returns compact result | transcript, token counts, delegate model load/unload log | `local_delegate` source exists; no live cloud agent-loop proof |
| Local delegate model picker and settings | SOURCE-WIRED, LIVE-RED | Pick downloaded chat model in Agent Delegation settings | settings JSON/screenshots | Source settings exist; no live UI persistence screenshot |
| Local delegate tool permissions | SOURCE-WIRED, LIVE-RED | Prove deny/ask/always_allow and scoped local tool permissions | permission prompt screenshots, result envelopes | Source deny/ask/always_allow exists; no live app proof; child tool-use scope intentionally refused |
| Local delegate budget enforcement | SOURCE-WIRED, LIVE-RED | Exceed token/turn/time/tool budgets and verify typed refusal/stop | result envelopes and logs | Source turn/token/time budgets exist; no live delegate proof |
| Cloud token-cost comparison | RED | Run same coding task with and without local delegate, record cloud input/output tokens | billing/token logs, prompts, final answers | No live cloud comparison proof |

### Privacy, Prompt, Tool, And Artifact Stability

| Row | Status | How to test | Required evidence | Current blocker |
| --- | --- | --- | --- | --- |
| Privacy filter still scrubs cloud-bound text | RED | Enable privacy filter, send direct private info to cloud model, verify outbound scrub and inbound/tool unscrub behavior | scrubbed request log, redaction review screenshot, no raw PII in cloud-bound payload | Needs live cloud run |
| Local image prompt remains local | RED | With privacy filter enabled, ask cloud model to generate image using private text; verify local tool receives allowed local text/placeholders and cloud payload stays scrubbed | provider request log, tool args, output image | Needs exact live proof; placeholder behavior must be inspected |
| Existing tool loop unaffected | RED | Run todo/complete/clarify/share_artifact/file read before and after image job | transcript, tool result envelopes | No post-image tool-loop regression run |
| Prompt/schema budget stable | SOURCE-PARTIAL | Compare tool schema token estimate before/after; ensure no model catalog injected into prompt | prompt manifest or schema dump | Needs current prompt dump proof |
| Artifact card/result shape | SOURCE-WIRED, LIVE-RED | Image tool result should render image artifact/card without requiring a second model-generated `share_artifact` call | screenshot, content blocks, artifact path | Source bridge/test added; no live chat screenshot |

### RAM And Stress Gates

| Row | Status | How to test | Required evidence | Current blocker |
| --- | --- | --- | --- | --- |
| Strict single-model residency under local chat | RED | Record footprint before local chat, after unload, during image generation, after restore | Activity Monitor `phys_footprint` screenshots or `vmmap`/memory log, `/health` | No live RAM proof |
| Sub-24 GB safety simulation | RED | Run with strict memory settings and a model combination that should refuse before allocation | typed refusal, no large allocation, no app crash | No strict preflight/refusal implementation proof |
| 10-turn live-proof plan | RED | Mixed turns: normal chat, image generate, follow-up chat, image edit, denied image, approved image, cancel load, cancel denoise, privacy-filter cloud, final tool call | transcript, logs, images, `/health` after each turn | No live run |
| 30-job stress loop | RED | 10 generate + 10 edit + 10 permission/cancel/error rows | output inventory, failure log, no memory growth trend | No stress harness |
| App restart persistence | RED | Save settings, quit, relaunch, repeat one cloud generate and one local generate | settings JSON, screenshots, transcript | No relaunch proof |

### Evidence Bundle Checklist

Each completed live row should save:

- `git-head.txt` with exact Osaurus commit and `Package.resolved`.
- `vmlx-swift-revision.txt` from `Packages/OsaurusCore/Package.swift`.
- `build.log` from SwiftPM or Xcode build.
- `osaurus.log` from the launched app.
- `/health` JSON before, during, and after the job.
- `/images/models` JSON before the job.
- chat transcript export or screenshots showing tool call, permission prompt,
  progress row, artifact, and final answer.
- generated source/output images for image rows.
- Activity Monitor or equivalent `phys_footprint` evidence for RAM rows.
- explicit `GREEN`, `RED`, `PARTIAL`, or `BLOCKED` status in this document.

## Current Status

`SOURCE-WIRED / BUILDS`:

- Native image API and manual composer wiring exist.
- Model catalog and capability metadata are exposed.
- `ImageGenerationService` serializes image generation through `MetalGate`.
- Local model roots were verified on 2026-06-18 after the move to
  `/Users/eric/models`; `~/.mlxstudio/models` points at that root, and the
  JANGQ-AI, OsaurusAI, and image bundle folders are present.
- Historical prior image API stress proof exists from earlier runs, but it was not
  rerun after the latest strict resolver and permission prompt changes.
- Agent delegation settings now have source-wired configuration, JSON
  persistence, compatible downloaded-model candidate filtering, and a Settings
  card for default local text/image models, load policy, sharing policy,
  budgets, and ask/deny/always-allow defaults.
- Agent delegation settings now include a safe-default master enablement toggle
  and a separate chat image-job toggle. When disabled, image delegation tools
  are filtered out of `alwaysLoadedSpecs`, direct `specs(forTools:)`, and
  stale direct execution.
- `capabilities_load` now rejects disabled delegation tools instead of allowing
  a model to re-load disabled built-ins mid-session.
- `ImageGenerationService.unload()` now exposes explicit image-model release
  for agent-triggered low-RAM jobs.
- `NativeImageJobCoordinator` now resolves requested/configured/first-ready
  local image generation models, rejects missing/incomplete/wrong-kind requested
  or configured selections before residency changes, records progress phases,
  runs generation through `ImageGenerationService`, and unloads image weights
  after agent jobs unless manual-panel keep-warm policy is selected.
- The default `agent_single_residency` image policy now snapshots resident
  local `ModelRuntime` chat models, waits for local chat generation to go idle,
  unloads those chat models before the image job, unloads image weights after
  the job, and attempts to warm-load the prior chat models again.
- Native image job progress events now carry the active chat `session_id`,
  `assistant_turn_id`, and `tool_call_id` from `ChatExecutionContext`, giving
  the chat UI a stable binding target for a running `image_generate` or
  `image_edit` call.
- `image_generate` and `image_edit` are registered as compact built-in tools.
  They enforce the Agent Delegation image-generation/image-edit permission
  defaults (`ask`, `deny`, `always_allow`), pass prompt/negative
  prompt/steps/guidance/seed/model arguments to the coordinator, and return
  generated image paths plus progress metadata. `image_edit` accepts one to four
  explicit local source image paths and rejects unsupported extensions,
  non-file paths, and files above 80 MB.
- `image_generate`, `image_edit`, and `local_delegate` now resolve the selected
  default/requested model before `ask` permission prompts and pass the resolved
  model plus load policy in the permission argument JSON. This is source-wired
  only until a live permission sheet screenshot proves the UI surface.
- `NativeImageToolArtifactBridge` promotes successful image tool output paths
  into existing `SharedArtifact` chat artifacts. `ContentBlock` treats
  `image_generate` / `image_edit` enriched results as artifact-card capable,
  so the model should not need to call `share_artifact` for the generated image.
- `local_delegate` is registered as a compact built-in tool and is filtered out
  unless both the Agent Delegation master toggle and cloud text delegation
  toggle are enabled. Its model resolver uses
  `ModelManager.findInstalledModel(named:)` rather than hardcoded paths or
  model lists.
- `local_delegate` runs a bounded, context-isolated text-only child loop through
  `AgentToolLoop`, returns a compact `local_text_delegate_result` envelope, and
  unloads the delegate model after completion/failure under
  `unload_after_job` and `strict_single_job_residency`.
- `local_delegate` rejects parent local-model calls by default; this source
  slice is for cloud/API parent models delegating bounded text work to a local
  downloaded helper.
- `local_delegate` intentionally rejects child tool calls in this source slice;
  no file/shell/tool access is granted through local text delegation until the
  separate `localTextDelegateToolUse` permission flow is implemented and proven.
- Local source verification on 2026-06-18: `swift build --package-path
  Packages/OsaurusCore` passed after the strict resolver and resolved-model
  permission prompt changes. `git diff --check` also passed. Local `swift test
  --package-path Packages/OsaurusCore --filter NativeImageJobCoordinatorTests`
  and `swift test --package-path Packages/OsaurusCore --filter
  AgentDelegationToolAvailabilityTests` remain blocked by the existing
  package-wide `no such module 'Testing'` failure before focused test execution.
- Historical remote proof on `erics-m5-max.local` from fresh clone
  `/tmp/osaurus-agent-image-proof-a47b88d4` at commit `a47b88d4`: `swift build
  --package-path Packages/OsaurusCore` passed, and `swift test --package-path
  Packages/OsaurusCore --filter NativeImageJobCoordinatorTests` ran 4 tests in
  `NativeImageJobCoordinatorTests` and passed.
- Historical remote proof on `erics-m5-max.local` from the same fresh clone after reset to
  commit `89971b42`: `swift build --package-path Packages/OsaurusCore` passed,
  and `swift test --package-path Packages/OsaurusCore --filter
  NativeImageJobCoordinatorTests` ran 5 tests in `NativeImageJobCoordinatorTests`
  and passed. This proves the source-wired coordinator/model-resolver path for
  generation and edit model selection; it is not live chat-agent e2e proof.
- Historical remote proof on `erics-m5-max.local` from the same fresh clone after reset to
  commit `d6147aa4`: `swift build --package-path Packages/OsaurusCore` passed,
  and `swift test --package-path Packages/OsaurusCore --filter
  NativeImageJobCoordinatorTests` ran 6 tests in `NativeImageJobCoordinatorTests`
  and passed. This proves source buildability and the policy gate that enables
  chat-model eviction only for `agent_single_residency`; it is not live
  unload/generate/reload RAM proof.
- Historical remote proof on `erics-m5-max.local` from the same fresh clone after reset to
  commit `36934a98`: `swift build --package-path Packages/OsaurusCore` passed,
  and `swift test --package-path Packages/OsaurusCore --filter
  NativeImageJobCoordinatorTests` ran 7 tests in `NativeImageJobCoordinatorTests`
  and passed. This proves source buildability and progress payload metadata for
  `session_id`, `assistant_turn_id`, and `tool_call_id`; it is not visible chat
  UI proof.
- Historical remote proof on `erics-m5-max.local` from the same fresh clone after reset to
  commit `1d544118`: `swift test --package-path Packages/OsaurusCore --filter
  AgentDelegationConfigurationStoreTests` ran 4 tests and passed; `swift test
  --package-path Packages/OsaurusCore --filter
  AgentDelegationToolAvailabilityTests` ran 4 tests and passed; `swift test
  --package-path Packages/OsaurusCore --filter NativeImageToolArtifactBridgeTests`
  ran 2 tests and passed; `swift test --package-path Packages/OsaurusCore
  --filter ContentBlockDisplayTests/imageGenerateToolResult_rendersSharedArtifactCard`
  ran 1 test and passed; `swift build --package-path Packages/OsaurusCore`
  passed. This proves source buildability, safe-default config decode,
  delegation tool-schema gating, stale-call rejection, and image-result artifact
  promotion. It is not live foreground chat-agent proof.

`PARTIAL`:

- Foreground manual SwiftUI click-through is still not proven.
- Image generation now has a source-wired main-agent tool, but no live
  cloud/local chat e2e proof has run through the actual agent loop.
- The coordinator has a source-wired active local chat model
  snapshot/unload/restore path, but no live resident-model proof has exercised
  unload -> image job -> image unload -> chat warm-load under Activity Monitor
  footprint checks.
- Progress events are recorded and posted through
  `nativeImageJobProgressChanged` with chat/tool-call identifiers, but the chat
  UI progress row has not been wired/proven for the agent-triggered path.
- Image edit now has a source-wired main-agent tool, but no live source-image
  artifact e2e proof has run through the actual agent loop.
- Local SwiftPM test execution is blocked on this host by a global `Testing`
  module import failure in existing tests. The new `local_delegate` and strict
  image model resolver focused tests have not yet run on a Swift
  Testing-capable host.
- Agent Delegation Settings now own source-wired tool availability for image
  delegation, but no live Settings UI screenshot or outbound provider payload
  capture has proven the toggle behavior in the running app.

`BLOCKED FOR RELEASE`:

- No local-chat-model unload -> image-job -> chat-model restore live proof.
- No cloud-chat-model -> local image tool e2e proof.
- No image-edit agent loop proof with real source image artifact.
- No cloud-chat-model -> local text delegate e2e proof.
- No cloud-chat-model -> local text delegate live proof, despite source wiring.
- No runtime permission prompt or ask/deny/always-allow live proof exists for
  spawned image or text jobs.
- No live proof yet shows the resolved default model appearing in the permission
  prompt before approval.
- No agent-triggered RAM-safety preflight/refusal proof.
- No progress UI proof for the agent-triggered path.
