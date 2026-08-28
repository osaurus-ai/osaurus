# vmlx Runtime Regression Audit - 2026-05-10

This note records the MiniMax, Hy3, and ZAYA regressions investigated during
PR #1057. It is intentionally split into verified fixes, user-validated rows,
and still-open work so future changes do not collapse separate issues into one
generic "model is slow" or "model is incoherent" bucket.

## Current Pin Chain

Osaurus PR #1057 is expected to use these runtime pins:

- `vmlx-swift-lm` `21adfc8` - Hy3 compiled decode deny-list, ZAYA batch forward repair, MiniMax routing and terminal-info fixes.
- `mlx-swift` `0a56f90`
- `swift-jinja` `58d21aa`

The app build used for validation was the Release scheme from this PR branch.

## Fixed And Verified

### MiniMax M2.7 reasoning rail

Symptom:

- MiniMax M2.7 with Thinking enabled could appear blank or stuck because normal
  MiniMax answers can stay on the reasoning rail instead of transitioning to a
  visible content chunk.
- Earlier investigations also showed `tokenCount=0` when terminal `.info` did
  not reach Osaurus after cancellation or early stream close.

Fixes:

- vmlx routes generation text through the same tool-call processor for both
  content and reasoning channels, then flushes pending routed text on EOS.
- vmlx synthesizes terminal info if a stream closes without upstream `.info`.
- Osaurus promotes MiniMax `.reasoning` deltas to visible `.tokens` for chat UI
  rendering and suppresses `unclosedReasoning` for MiniMax reasoning-only
  completions, because that shape is normal for this family.

Verification:

- `GenerationEventMapperTests` covers MiniMax reasoning-to-token promotion and
  terminal-info handling.
- `MLXBatchAdapterTests`, `RuntimePolicySourceTests`, and `ChatEngineTests`
  were run on the PR branch after the fix.
- GitHub PR #1057 checks passed at head `6c1909c2`.

Still not claimed:

- This does not prove every MiniMax prompt will close `</think>` naturally.
  It proves Osaurus no longer hides normal MiniMax reasoning-only output or
  loses terminal stats when the stream closes.

### Hy3 coherent decode path

Symptoms:

- Hy3 could become incoherent on the compiled single-slot batch trace.
- Hy3 first-turn latency was also confused with a preflight reasoning problem.

Fixes:

- vmlx denies compiled batch decode for Hy3/Hunyuan-style models and keeps Hy3
  on the coherent uncompiled decode path.
- Osaurus `MLXBatchAdapter` mirrors this by disabling compiled batch decode
  when the model id matches Hy3.
- Osaurus preflight fallback generation forces `reasoningEffort: no_think` so
  capability ranking does not spend its timeout generating a full reasoning
  trace.

Verification:

- `MLXBatchAdapterTests.compiledBatchDecodeDisabledForHy3EvenWhenSolo`.
- `RuntimePolicySourceTests.preflightFallbackLLMForcesNoThinkOptions`.
- `ChatEngineTests` covers Hy3 `reasoning_effort` request mapping and prevents
  the generic `disableThinking` flag from leaking alongside Hy3's effort-based
  control.
- Hy3 template smoke on the current bundle showed `reasoning_effort:no_think`
  in the default/preflight-style rendered tail.

Still open:

- Hy3 can still feel slow on first use because model loading/residency is a
  separate cost from decode coherence. Current app logs showed a long interval
  between model switch and ready state, then a separate submit event. That must
  be tracked as load/residency or first-prefill timing, not as the old compiled
  decode incoherence bug.

### ZAYA batch forward contract

Symptom:

- ZAYA needed a batch-compatible forward overload so BatchEngine could call it
  through the same path as other model families.

Fix:

- vmlx adds the ZAYA batch forward overload required by BatchEngine.
- Osaurus pins the vmlx commit containing that repair.

Verification:

- Osaurus source-policy tests verify the pin.
- vmlx has ZAYA forward-contract coverage.
- ZAYA JANGTQ4 was user-validated as coherent in the live app.
- ZAYA MXFP4 was user-validated as coherent in the live app.

Important correction:

- Do not generalize the user-reported ZAYA JANGTQ2 incoherence to all ZAYA
  JANGTQ variants. The current user-validated state is: JANGTQ4 coherent,
  MXFP4 coherent, JANGTQ2 suspect/weak.

## Open Issues

### ZAYA JANGTQ2 chat quality

Current state:

- Prior vmlx handoff notes already mark ZAYA JANGTQ2 as contract/cache/decode
  ready but weak on generic multi-turn chat quality.
- The latest user report says ZAYA JANGTQ2 is incoherent, while ZAYA JANGTQ4 is
  coherent. Treat JANGTQ2 as the failing row.

Likely area:

- Not chat template routing, because JANGTQ4 and MXFP4 use the same ZAYA
  family path and are coherent.
- Not generic ZAYA EOS/template detection, because ZAYA config/template smokes
  pass and JANGTQ4 is coherent.
- Most likely remaining area is JANGTQ2-specific quantization quality or a
  JANGTQ2 sidecar/runtime interpretation difference.

Required next proof:

- Run the same short chat prompt through ZAYA JANGTQ2, JANGTQ4, and MXFP4 with
  the same prompt tokens, thinking setting, tools setting, cache cold state, and
  max token cap.
- Save the rendered prompt, config smoke, generation stats, and raw output for
  each row.
- Only after that compare JANGTQ2 sidecar metadata and routed bit handling.

### ZAYA TTFT on growing chats

Current state:

- User observes long TTFT/loading feel for ZAYA JANGTQ4 and MXFP4 even when
  decode token/s is acceptable.
- App logs from the PR branch showed ZAYA model switch/load taking much longer
  than the actual post-ready prefill/generation row.

Root cause from vmlx source:

- `CacheCoordinator.fetch` uses block-level prefix matching only in the paged
  tier.
- ZAYA uses `ZayaCCACache`, which carries path-dependent CCA state
  (`conv_state` and `prev_hs`) and is paged-incompatible.
- The disk tier currently does exact-token match plus one-token-shorter fallback
  only. It does not do longest-prefix matching for growing chat prompts.

Consequence:

- Turn 1 stores a whole prompt boundary.
- Turn 2 has a longer prompt, so disk exact match misses and one-shorter also
  misses.
- ZAYA then pays full prefill again on each growing chat turn unless the prompt
  is exactly replayed.

Safe next fix candidate:

- Add a vmlx disk-tier longest-prefix fallback for path-dependent cache
  families at a coarse stride, then verify that restoring ZAYA CCA state at a
  shorter boundary and prefilling the remaining suffix is mathematically safe
  and produces identical output to a cold full prefill.

Not safe to claim yet:

- Do not claim ZAYA TTFT is fixed by the batch forward repair. That repair fixed
  a BatchEngine call contract, not growing-chat disk-cache prefix reuse.

### Hy3 TTFT / load latency

Current state:

- Hy3 compiled-path incoherence is fixed by keeping Hy3 off compiled batch
  decode.
- Preflight no-thinking is wired.
- User still reports long TTFT/load behavior.

Likely remaining areas:

- Model residency/loading time.
- First prefill timing after ready.
- Whether the app starts a hidden preflight or context-composition task before
  the visible chat submit reaches BatchEngine.

Required next proof:

- Add or collect timestamps for model switch start, model ready,
  preflight start/end, chat submit, first token, `.info`, and UI stream finish.
- Keep this separate from coherence; Hy3 coherence and Hy3 load/TTFT are now
  different issues.

## Reasoning And Template Rules To Preserve

- Ling: no reasoning; force thinking off.
- Hy3: effort-based reasoning control via `reasoning_effort`; do not also emit
  generic `enable_thinking`.
- ZAYA: reasoning-capable, but default thinking off; explicit user opt-in should
  pass `enable_thinking=true`.
- MiniMax M2/M2.7: inherently reasoning-heavy and can produce normal answers on
  the reasoning rail; Osaurus must display that output instead of waiting for a
  content rail transition.
- VLM routing: text ZAYA (`model_type=zaya`) is not ZAYA1-VL
  (`model_type=zaya1_vl`). Keep the registry distinction.

## Regression Commands

Targeted Osaurus tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -workspace osaurus.xcworkspace \
  -scheme OsaurusCoreTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:OsaurusCoreTests/MLXBatchAdapterTests \
  -only-testing:OsaurusCoreTests/RuntimePolicySourceTests \
  -only-testing:OsaurusCoreTests/ChatEngineTests \
  -only-testing:OsaurusCoreTests/GenerationEventMapperTests \
  -only-testing:OsaurusCoreTests/ModelRuntimeIsHybridTests \
  -only-testing:OsaurusCoreTests/IsKnownHybridModelMCDCTests
```

Full PR gate:

```sh
gh pr checks 1057 --repo osaurus-ai/osaurus
```

## Non-Goals For This PR

- Server-panel controls for KV mode, prefill step size, paged block size, max
  blocks, disk cache GB cap, or model idle residency.
- Wake/sleep observer implementation.
- ZAYA disk-tier longest-prefix restore.
- Broadly declaring ZAYA JANGTQ2 production-chat ready.
