# Delegation refusal triage — image_generate / image_edit / spawn

Every observed "I cannot generate / edit / spawn …" classified by ROOT CAUSE, with
evidence and proof status. Categories are mutually exclusive — each refusal is ONE of:

- **SETTINGS** — delegation config / toggle / model-id (agent-delegation.json). User-fixable.
- **CODE** — a real bug in osaurus/vmlx surfacing or execution.
- **TOOL-PASS** — the tool *result* or conversation context fails to carry data
  (e.g. the saved image path) to the next model turn. Real bug if it happens in the
  production flow.
- **MODEL** — the model's own instruction-following (refuses, won't chain, hallucinates).
- **TEST-HARNESS** — my test construction was wrong (wrong endpoint, dropped a message);
  NOT a product defect.

Rule: a refusal is not "explained" until its category is **Proven**, not asserted.

| # | Symptom (verbatim) | Category | Evidence | Status |
|---|---|---|---|---|
| R1 | gemma on `/v1/chat/completions`: "I cannot generate images. I am a text-based model and do not have access to image generation tools." | **TEST-HARNESS** (→ surfaces a CODE/DESIGN fact) | The raw OpenAI endpoint does NOT attach delegation tools; they only surface on `/agents/{id}/run`. Same gemma on `/agents/{default}/run` generated a real 1024×1024 PNG immediately after. | **PROVEN** |
| R2 | gemma (reconstructed 3-msg history) on image_edit: "I cannot access the image from the previous turn because it was rendered directly in the chat rather than saved to a persistent file path." | **TEST-HARNESS** (hypothesis; → checks a TOOL-PASS path) | My reconstructed history omitted the `image_generate` tool-result message that carries the saved path. Code shows the path IS in the model-visible result: `NativeImageJobCoordinator.toolPayload` → `images[].path = image.url.path` (line 203). | **PENDING** — continuous generate→edit run (step 3b) is the arbiter. If it chains the edit → confirmed TEST-HARNESS. If it refuses → reclassify as TOOL-PASS or MODEL. |
| R3 | (risk, not yet observed) model generates then just confirms, never chains the requested edit | **MODEL × CODE (prompt design)** | Same `toolPayload` carries `already_displayed:true` + `display_note: "…just briefly confirm the image was created."` — intended to stop `share_artifact` spam, but may over-steer some models away from a follow-on `image_edit`. | **UNVERIFIED** — watch in step 3b + the cross-model matrix. |

## What is PROVEN about the wiring (so refusals can be triaged fast)
- **SETTINGS are correct on this box**: `agent-delegation.json` has `agentDelegationEnabled:true`,
  `imageDelegationEnabled:true`, `localTextDelegationEnabled:true`, permissionDefaults
  `image_generate/imageEdit = always_allow`, valid model ids (FLUX.1-schnell-mflux-4bit gen,
  Qwen-Image-Edit-mflux-q4 edit), spawnable `[Sparky, Echo]`.
- **Delegation tools only surface via `/agents/{id}/run`** (the agent-loop path), NOT
  `/v1/chat/completions`. Testing image/spawn on the OpenAI endpoint will ALWAYS look like
  a refusal — that's R1, a harness error, not a bug. (This is the #1 thing to not re-trip.)
- **image_edit contract**: requires `source_paths` (1–4 paths) from a prior artifact; the
  prior `image_generate` result supplies them via `images[].path`. Multi-turn editing only
  works if the conversation retains that tool-result message.

## Open verification (must finish before claiming "image/spawn all work")
- [ ] 3b continuous generate→edit chains the edit (resolves R2/R3).
- [ ] image_generate + image_edit + spawn across ≥3 driver models (gemma-4, qwen3-8b, +1)
      — catch model-specific refusals instead of generalizing from gemma.
- [ ] If R3 bites: soften `display_note` for the explicit-edit case.

_Living doc — update the Status column as each is proven._
