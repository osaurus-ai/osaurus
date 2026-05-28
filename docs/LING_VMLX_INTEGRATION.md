# Ling vMLX Integration Notes

Date: 2026-05-06

This PR wires the Osaurus UI/catalog side of Ling-2.6 Flash to the vmlx
BailingHybrid runtime path.

## Dependency Pins

- `vmlx-swift-lm`: `7273ba22d6e608b5575bef91e70975a8ad3e1862`
  - Carries forward the prior `4a832400` + `88fc352b` content (BailingHybrid
    model/factory for `bailing_moe`, `bailing_hybrid`, `bailing_moe_v2_5`;
    Bailing/Ling `think_xml` reasoning stamp; Bailing input processor
    template contract; hybrid SSM prompt-boundary re-derive gate and disk
    companion cap; MiniMax JANGTQ_K nested `mxtq_bits.routed_expert`
    decoding; DSV4 SWA+CSA+HSA hybrid cache topology and L2 disk restore
    via `LayerKind.deepseekV4`; Laguna fallback chat template; quiet
    model-factory diagnostics; BailingHybrid `B>1` RoPE / per-slot offset
    correctness; prompt-tail derivation; `ZayaCCACache` round-trip via
    `SSMStateCache` companion).
  - Adds `BatchEngine` lifecycle/fairness hardening: `isShutdown` flag
    rejects late submits with a `.cancelled` info event,
    `controlPlaneYieldInterval=8` keeps long B=1 decodes from starving
    cancel/shutdown/config-update, and `updateMaxBatchSize(_:)` is a
    runtime API so hosts hot-resize without an explicit model evict.
    Osaurus's `MLXBatchAdapter.Registry.engine(...)` adopts the new API
    and evict-rebuilds on `.engineShutdown`.
  - Ports `BailingLinearAttention.recurrentGLA` to a fused Metal kernel
    (`bailing_recurrent_gla` via singleton kernel manager). Closes the
    `EXC_BAD_ACCESS` Metal pipeline-state lifetime crash on Ling JANGTQ2
    long prompts (≥ ~2 k tokens) tracked in `LING_JANGTQ2_LONG_PROMPT_CRASH.md`.
    Reference path is preserved for `D % 32 != 0`.
  - Reorders `Evaluate.swift` `cacheStoreAction` to run AFTER `.info` is
    yielded. Stream consumers see completion immediately; the SSM
    re-derive runs serialized on the same task.
  - Adds ANE acceleration contract scaffolding (`AccelerationMode`,
    `AccelerationRuntime.resolveTextDecode`). Fail-closed for text decode.
  - Unsupported JANGTQ3 route still removed.
  - `enableSSMReDerive` default remains `true`; osaurus now preserves that
    automatic hybrid-cache default so SSM/linear-attention companion state can
    rederive/store after generation and participate in prefix/L2 restores.
- `swift-jinja`: unchanged at the existing Osaurus fork pin. No new parser
  behavior is needed for Ling in this PR.
- `mlx-swift` / `mlx`: unchanged. No MLX kernel or ABI change is required by
  this osaurus integration.

## Osaurus Wiring

- Adds curated catalog entries for:
  - `OsaurusAI/Ling-2.6-flash-MXFP4`
  - `OsaurusAI/Ling-2.6-flash-JANGTQ`
- Both entries declare `modelType: "bailing_hybrid"` so pre-download metadata
  routes through the correct vmlx factory family.
- Adds a Ling runtime profile with no Thinking toggle. Ling-2.6 Flash is
  treated as a non-reasoning chat model in osaurus, and stale persisted
  `disableThinking=false` preferences are filtered out when the model is
  selected.
- Forces `additionalContext["enable_thinking"] = false` for Ling requests at
  tokenization time, including chat, voice, and API paths that omit UI model
  options. vmlx still owns the Ling/Bailing template-specific translation.
- Marks Bailing/Ling names as known hybrid models so the cache coordinator is
  eagerly set to hybrid for Linear-Attn companion cache handling.

## Review Notes

- No osaurus-side prompt mutation is used. The only Ling-specific runtime
  policy in osaurus is the explicit `enable_thinking=false` context passed to
  vmlx before tokenizer rendering.
- No JANGTQ3 path is introduced; the vmlx pin rejects it.
- Ling has no osaurus-side opt-in path for reasoning. This is intentional:
  the Flash SKU is used as a direct-answer chat model, and reasoning-only
  output can leave voice/chat sessions looking stuck behind the Stop control.
- The MiniMax JANGTQ_K decoder fix is included in the same vmlx pin; osaurus
  does not add MiniMax-specific host logic.
- DSV4 cache mode is not forced by osaurus. Leaving `DSV4_KV_MODE` unset is the
  production path because vmlx now owns the SWA/CSA/HSA hybrid cache. Operators
  can still export the env var for diagnostics before launching osaurus.
- Ling/Bailing cache behavior is not guarded in osaurus. Do not add app-layer
  prefill caps or ArraysCache resets; regressions belong in the vmlx
  BailingHybrid/cache topology.
- Large Ling/Bailing speed and memory tuning remains vmlx-side work. The local
  vmlx rows covered short and medium production prompts, including
  `Ling-2.6-flash-JANGTQ2` multi-turn recall.
- No model download smoke test is included in this repo change. The PR relies on
  focused unit coverage and the vmlx `RunBench` build path.

## Verification

- vmlx: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BailingThinkingTemplateContextTests`
- vmlx: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --filter MiniMaxJANGTQConfigTests --no-parallel`
- vmlx: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --filter 'DeepseekV4ModelSmokeTests|LagunaChatTemplateFallbackTests|BatchQuantizeHookTests|CacheCoordinatorTests' --no-parallel`
- vmlx: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --product RunBench`
- osaurus: focused model catalog/profile/hybrid/batch-adapter tests
- osaurus: SwiftPM resolution points tracked workspace locks at the vmlx pin
  above.
