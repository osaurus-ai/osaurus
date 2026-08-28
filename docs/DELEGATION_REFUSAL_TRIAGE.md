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
| R2 | gemma (reconstructed 3-msg history) on image_edit: "I cannot access the image from the previous turn because it was rendered directly in the chat rather than saved to a persistent file path." | **TEST-HARNESS** | Continuous one-run generate→edit (step 3b) CHAINED: produced both a new `flux1-schnell-*.png` (generate) and a new `qwen-image-edit-*.png` (edit). The path passes in a real conversation and the model used it. My step-3 history dropped the tool-result. | **PROVEN** |
| R3 | (risk) model generates then just confirms, never chains the requested edit | **MODEL × CODE (prompt design)** | `toolPayload` carries `display_note: "…just briefly confirm…"`. In 3b gemma DID chain the edit, so the nudge did not block it for gemma. | **NOT OBSERVED for gemma** — still check across models. |
| R4 | gemma after a continuous generate+edit run: visible text leaks control markers — `"I will now update it to make**thought**\n**<channel\|>**the cube green."` | **CODE** (channel-marker / tool-channel filter miss) | gemma-4 channel tokens (`<channel\|>`, `thought`) leak into user-visible text after image-tool handoffs. Single-gen run was CLEAN; only the 2-image-op (gen+edit) run leaked. Adjacent to BUG C (#70, fixed loop) — residual leak on the chained path. Edit still worked. | **OBSERVED on chained gen+edit; not on single gen — CODE, fix pending** |
| R5 | qwen3-8b on image_generate: "The default image model is not installed for image generation…" | **MODEL** | (1) That phrase is NOT in the osaurus codebase → hallucinated. (2) Isolated re-run: 3s, 0 new PNGs → the tool was never called. (3) gemma generated with the IDENTICAL config; (4) qwen3's own `spawn` tool call worked; (5) the image directive + image_generate tool are surfaced model-agnostically (`SystemPromptComposer` line 1257, gated only on `imageDelegationActive`) — code even notes "small models reach for the search tool instead." So config/code/tool-pass are all exonerated; qwen3-8b simply won't call an image tool it has. | **PROVEN (MODEL)** |

## image_generate driver-model spread (ground truth: did a PNG actually appear?)
8 diverse drivers, `image_generate` via `/agents/default/run`:

| Driver | Verdict | Notes |
|---|---|---|
| gemma-4-12b | ✅ GENERATED | |
| gemma-4-26b-a4b | ✅ GENERATED | |
| gemma-4-e4b (small) | ✅ GENERATED | small model still calls the tool |
| qwen3.6-27b-mtp | ✅ GENERATED | qwen FAMILY works at 27b |
| minimax-m2.7 | ✅ GENERATED | |
| laguna-m.1 | ✅ GENERATED | |
| qwen3-8b | ❌ MODEL refusal (R5) | hallucinates "not installed", 0 tool call |
| qwen2.5-3b | ❌ MODEL refusal | "I wasn't able to generate a response…", 0 tool call |

**6/8 generate. The only 2 refusers are small qwen base models.** Conclusion: the image
delegation wiring is sound; refusals are per-model tool-calling weakness (small qwen),
NOT settings/code/tool-pass. gemma-e4b (small) and qwen3.6-27b (qwen) both succeed, so
it is model-specific, not a pure size or family rule.

| R6 | Successful generations show mid-word text-boundary corruption: `"…on a black bacImage generated successfully"`, `"…on a The image has been generated"` (minimax, laguna, qwen3.6-27b) | **CODE** (text assembly at the tool-call boundary) | The pre-tool-call partial assistant text is cut mid-token and concatenated to the post-tool continuation with no separator. Coherent overall, but a visible seam. Shares a root with R4 (text handling around the image tool call). | **OBSERVED across 3 models — CODE, fix pending** |

## Tool-passing mechanism — CONFIRMED (read AgentToolLoop.swift end-to-end)
The canonical loop (`Services/Chat/AgentToolLoop.swift`, shared by chat/HTTP/plugin):
1. `modelStep` classifies the turn: `finalResponse` | `toolCalls([...])` | `emptyResponse` | `retryWithoutCharge`.
2. On `toolCalls`, HTTP uses slotting mode (`executeBatch`): dedupe → phase-1 serial
   permission gate (`ToolRegistry.resolvePermissionGate`) → phase-2 parallel execute
   (`ToolRegistry.execute`) → record in model order.
3. The tool's **result envelope is the exact string handed to the model**
   (`AgentLoopToolExecution.result`). For image_generate that envelope = `toolPayload`
   **including `images[].path`**.
4. `onBatchComplete` appends the assistant `tool_calls` message + tool-result messages
   into the surface history; the next iteration's `buildMessages` includes them, so the
   model sees the result (and the path) on its next step. ← this is the pass-through that
   makes image_edit chaining work.
5. Empty turns are not silently dropped: nudge-and-retry up to `maxEmptyTurnRetries` (2),
   then `emitFallbackText` writes "I wasn't able to generate a response to that. Please
   try rephrasing your request." (AgentToolLoop:597).

### Correction to R5-family (empty-turn vs hallucinated-refusal)
- qwen3-8b: hallucinated "image model not installed" text (a real text turn, no tool call).
- qwen2.5-3b: its "I wasn't able to generate a response…" is the **loop's emptyTurnFallback**,
  i.e. the model produced an EMPTY turn (EOS, no text/tool) and recovery was exhausted.
  Both are MODEL failures, via different mechanisms.

## NOT yet verified (so "all issues found" is NOT claimed)
- R4/R6 ROOT: lives in the surface `modelStep` streaming/delta routing + channel filter —
  not yet read. Symptom + category known; exact site not pinned.
- `local_delegate` (local/cloud text delegate tool): untested.
- Multi-turn DB-persisted image path across SEPARATE user turns (real chat history store):
  only continuous-run + reconstructed-history were tested.

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
