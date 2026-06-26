# Chained image gen→edit loop — cache/context-window investigation

Symptom (#88): in ONE agent turn, "generate an image then edit it" → the model
(gemma-4-12b) re-calls `image_generate` repeatedly instead of `image_edit`, loops to
the client timeout, empty final text. NOT a crash (#89 GPU crash is separately fixed).

Human lead: the root is the **osaurus cache/context window**, not vmlx wiring.

## What the code shows (verified, HTTPHandler.swift agent-run path)
- The image `image_generate` tool result — the full envelope INCLUDING `images[].path`
  (`NativeImageJobCoordinator.toolPayload`) — IS appended to the run's `messages`:
  `onBatchComplete` (5161) → assistant `tool_calls` msg (5197) + `role:"tool"` result
  msg carrying `outcome.result` (5206–5208). So the path is in the prompt for the next step.
- `messages` is handler-local and persists across loop iterations, so the
  `agent_single_residency` model unload/reload (KV reset → full re-prefill) does NOT by
  itself drop the path — the prompt is rebuilt from `messages` each step.
- BUT each iteration runs `buildMessages` → `AgentLoopBudget.composeIterationMessages`
  (4922/4928), which TRIMS `messages` against a budget from
  `AgentLoopBudget.resolveContextWindow(modelId:)` + `makeBudgetManager`.

## The suspect (to confirm)
`resolveContextWindow(modelId:)` order: foundation ids → `ModelInfo.load(modelId).contextLength`
→ `ChatConfigurationStore.contextLength ?? 128_000`. If `ModelInfo.load` fails to resolve
for the passed model id (or the run resolves model="default"/empty), the window can fall
to a small/biased value (cf the old BUG F 4096 fallback / #74). A small window →
`trimPreservingSystemPrefix` drops the oldest tail entries → the `image_generate` tool
result (the path) gets trimmed before the model's next step → the model "forgets" it
generated and re-generates → loop.

Open sub-questions:
1. What window actually resolves for `osaurusai--gemma-4-12b-it-qat-mxfp4` in the agent run?
2. gemma-4 is SWA (sliding-window attention) — does the sliding window or the budget
   trim evict the image tool result specifically?
3. Does the `display_note: "...just briefly confirm..."` in the image result steer the
   model away from a follow-on edit independent of trimming?

## Status
- Codex GPT engaged as second-opinion debugger (task-mqq7gtg7-ec310d) to confirm/refute
  the trim-drops-the-tool-result hypothesis against the real code + propose the fix.
- Next concrete step on our side: instrument/observe the resolved window + whether the
  image tool-result message survives into iteration 2.

## Probe result (instrumented build, live chained run)
```
iter1: msgs 2→2  imgRes 0→0   (pre-image)
iter2: msgs 4→4  imgRes 1→1   (post image_generate)  overBudget=false
```
**Prompt-compaction does NOT drop the image tool-result** (imgRes survives 1→1, nothing
trimmed). The run then ended with gemma NARRATING "Now I will update the image to change
th…" (truncated) and **0 image_edit invocations**. So in this minimal case the failure is
MODEL tool-selection / possible max_tokens truncation BEFORE the tool call — NOT
prompt-compaction dropping the path.

### Caveat — the probe measures the PROMPT, not the KV cap
"Cache window" most likely means the **KV-cache cap** (the model's actual attention
window / TurboQuant-or-slider KV limit), where the image result can be present in the
prompt yet fall OUTSIDE what the model attends to. That mechanism is NOT captured by this
probe. Still to check: (a) the resolved KV cap for the agent run, (b) whether under a
LARGER preceding conversation the result is evicted, (c) whether max_tokens truncates the
narration before the image_edit call. Codex second opinion pending on all three.

## RESOLVED — root cause + fix (probe + Codex second opinion, converged)
The cache-window hypothesis is **REFUTED** by two independent methods:
- Live probe: the image_generate tool-result (with path) **survives compaction** (imgRes 1→1).
- Codex traced the KV-cap path (`ModelRuntime.swift:1558-1563,1622-1627,1877-1889`,
  `ServerRuntimeSettingsStore.defaultMaxKVSize`) and found nothing in the agent-run path
  exceeding the attended window for this symptom.

**Real root cause = STEERING PROMPT** (both confirmed it):
- `NativeImageJobCoordinator.toolPayload` `display_note`: "...just briefly confirm the
  image was created."
- `SystemPromptTemplates.imageGenerationGuidance` (line 631): "After it's created, just
  briefly confirm in one sentence."
- `AgentToolLoop.run` exits on the FIRST final-text response (968-971). So the model obeys
  "just confirm", emits narration, the loop halts, and `image_edit` never fires.
- Secondary: omitted `max_tokens` → resolved budget (model `generation_config` override)
  can truncate the narration mid-word before the tool call ("th" cutoff).

**FIX** (both steers made conditional): "If the user asked for a follow-up edit, continue
by calling `image_edit` with the saved `images[].path`; otherwise briefly confirm." No
forced tool calls, no fake guards — fixed at the source. Lesson: this was the "R3"
display_note over-steer flagged early and wrongly dropped.

## Live validation of the steer fix — HONEST result
Rebuilt with the conditional steer + tested chained gen→edit in ONE turn:
- gemma-4-12b (max_tokens=800): generated once, then stopped — **0 image_edit**.
- qwen3.6-27b (max_tokens=1200): narrated a plan ("I'll set up a checklist and then
  generate…"), turn ended — **0 image_edit**.

CONCLUSION: the steer fix is the CORRECT root-cause fix (the "just confirm" steer was
genuinely counterproductive; probe+Codex agree the model had the path), but it does NOT
by itself make one-turn chaining reliable on these local models. Both models
narrate/plan/stop rather than emit the sequential second tool call — a MODEL ORCHESTRATION
limitation, not a single flippable osaurus bug.

RELIABLE edit paths (proven working): the direct `/images/edits` HTTP API, and editing in
a SEPARATE turn with an explicit path. One-turn "generate AND edit" is best-effort and
model-dependent. Recommend: keep the steer fix; for product UX, drive edit via the direct
API or a follow-up turn rather than relying on one-turn chaining.

## ACTUAL ROOT CAUSE + FIX (corrected — it is NOT a model limitation)
My earlier "model orchestration limitation" call was WRONG. Codex (2nd opinion, code-verified)
+ the wiring confirm the real osaurus-side cause:

`AgentTaskState.nextStepBias()` had **no case for native-image tool results**. After an
`image_generate` result, the loop appended the result but staged **no continuation notice**,
so the model defaulted to narrating "I'll now edit…" as a final answer — and `AgentToolLoop`
exits on the first final-text response, so `image_edit` never fired. (Tools WERE re-sent every
iteration — HTTPHandler:4951-4952 — so it was never missing tools; it was the missing nudge.)

FIX (AgentTaskState.swift): add `ToolResultClass.nativeImageGeneration(paths:)`, track
`lastToolName`, classify `native_image_generation_job` results, and have `nextStepBias()`
return a continuation notice after `image_generate` (guarded to image_generate, not
image_edit → no infinite-edit loop) steering the model to call `image_edit` with
`source_paths` = the saved path. Injected via the existing transient-notice path
(`AgentToolLoop` 1155/1221), no forced tool_choice. This is the "re-inject the tool prompt
after the result" the user identified.

Ruled out with code evidence: tool-call parser after reload (fresh ToolCallProcessor per
generation), cache/prefix (prompt rebuilt each request), prompt compaction (probe: result
survives 1→1).

NOTE: the Codex run had collateral damage — it wiped the repo `.git` HEAD/config (1182 files
showed deleted) and replaced the 635-line/34-test AgentTaskStateTests with a 62-line/2-test
stub. Both repaired: git metadata restored, all 1182 files restored, 34 original tests
restored + Codex's 2 added.

## ✅ FIXED + PROVEN (chained one-turn gen→edit now works)
Three layered osaurus-side fixes (NOT a model limitation, NOT cache window):
1. Softened the "just confirm" steer (display_note + imageGenerationGuidance) → conditional.
2. Added `nextStepBias()` native-image case → stages an image_edit continuation nudge after
   image_generate (AgentTaskState.swift).
3. Promote THAT nudge from a tool-role message to a transient USER turn (AgentToolLoop
   `appendingTransientNotices`) — gemma underweighted the tool-role notice after a tool
   result; a user turn is salient enough to trigger the call.

LIVE PROOF (gemma-4-12b, one turn "generate a red cube then edit it green"):
image_generate → FLUX PNG, then image_edit → a NEW qwen-image-edit PNG (1024×1024, this run),
process alive. Both tools fired in one turn. Pre-fix: 0 image_edit across many runs.

Minor follow-up: the model sometimes ends with empty final text (no closing confirmation)
after the edit — cosmetic; the gen+edit work completes. Direct /images/edits API +
separate-turn editing also remain reliable paths.
