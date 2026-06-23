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
