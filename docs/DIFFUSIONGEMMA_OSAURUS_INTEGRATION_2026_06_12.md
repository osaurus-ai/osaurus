# DiffusionGemma Osaurus Integration

Date: 2026-06-12 (updated same day: native engine landed)

## Current Source Truth

- Source bundle: `google/diffusiongemma-26B-A4B-it`
- `model_type`: `diffusion_gemma`, architecture
  `DiffusionGemmaForBlockDiffusion`
- 30-layer Gemma4-style MoE (128 experts, top-8), 26B total / ~4B active,
  256-token canvas, sliding window 1024
- Vision: `vision_config` present, `image_token_id = 258880`,
  `vision_soft_tokens_per_image = 280`
- Audio: `audio_config = null`, `audio_token_id = null`
- Video: processor metadata present, but `video_token_id = null`

## Engine status (vmlx-swift)

The native block-diffusion engine is implemented in vmlx-swift
(branch `codex/diffusiongemma-runtime`, PR #47): encoder prefill +
bidirectional canvas decoder, entropy-bound sampler, adaptive stopping,
self-conditioning — all parameters from the bundle's
`generation_config.json`. Reference doc on the vmlx side:
`docs/DIFFUSIONGEMMA_ENGINE_RUNTIME_2026_06_12.md` (verification rows:
token/s, multi-turn, tool calls, prefix/disk cache, memory, isolation).

## How DiffusionGemma flows through Osaurus — teammate wiring map

1. **Discovery / capability**: `VLMDetection` recognizes
   `diffusion_gemma` as VLM-shaped; `ModelFamilyNames.isDiffusionGemmaFamily`
   keeps it distinct from Gemma-4 AR; `ModelMediaCapabilities` advertises
   image-only (audio/video blocked until runtime-proven).
2. **Loading**: `loadModelContainer` iterates factories; the VLM factory
   rejects `diffusion_gemma` (`unsupportedModelType`) and the LLM factory
   creates `DiffusionGemmaModel`. No Osaurus-side routing code needed.
3. **Generation**: `MLXBatchAdapter` routes every request through
   `BatchEngine.generate`. For `BlockDiffusionModel` conformers,
   BatchEngine takes its **exclusive solo path** (same mechanism as
   native MTP) into `BlockDiffusionTokenIterator`. The batched `submit()`
   path is rejected loudly (the model's `prepare()` throws) — block
   diffusion can never silently AR-decode or share batch slots.
4. **Parsers**: tool calls use the Gemma-4 format
   (`<|tool_call>call:name{...}<tool_call|>`, mapped from
   `model_type` in `ToolCallFormat.infer`); reasoning stamp is `harmony`
   (`<|channel>thought…<channel|>`). Both verified live with zero marker
   leakage through `TextToolTokenLoopHandler`.
5. **Caching**: encoder cache is Gemma4 topology (RotatingKVCache
   window-1024 sliding + KVCacheSimple full layers, fp16 KV — no
   TurboQuant). Rotating layers can't round-trip paged KV blocks, so the
   iterator marks the coordinator paged-incompatible and prompt
   boundaries are served by the **disk (L2/SSD) tier**. Verified:
   fresh-coordinator resume restored 138/138 prompt tokens with
   `prefillSec=0.000`; turn-extension hit passes; multi-turn live-cache
   sessions keep the full reply via the end-of-turn cache commit.

## Speed/quality control (the Osaurus setting)

`GenerateParameters.diffusionMaxDenoisingSteps` (vmlx) caps the
denoising budget per 256-token canvas. Measured on MXFP4, M5 Max,
~740-token essay:

| steps | tok/s | coherency |
|---|---|---|
| 48 (bundle default) | 37 | clean |
| 24 | 58 | clean |
| **16 (Osaurus default)** | **74** | clean (essay + multi-turn recall verified) |
| 8 | 140 | BREAKS (word salad) |

Wiring:

- Contract field: `VMLXServerGenerationDefaults.diffusionMaxDenoisingSteps`
  (`nil` = bundle default; validation errors `< 1`, warns `< 12`).
- Osaurus default: **16**, seeded once by `ServerRuntimeSettingsStore`
  (`diffusion-defaults-migrated.marker`; after seeding, a blank field is a
  sticky "use bundle default" choice).
- Request flow: `RuntimeConfig.snapshot()` →
  `MLXBatchAdapter` sets `mlxParams.diffusionMaxDenoisingSteps` →
  `BlockDiffusionParameters.overriding(parameters:)` at dispatch.
- UI: Server → Settings → Sampling → "Diffusion Models" →
  "Denoising Steps per Canvas" (`GenerationDefaultsSection`).
- Per-request API override: not exposed on the OpenAI wire yet
  (server-level setting only).

## Quant bundles

vmlx PR #45 (merged, `710eb0d7…`) added the converter; both local quants
verified:

- MXFP4: 15 GB, 15 shards, `total_size=15944852880`, 295 quantized
  tensors, 752 passthrough, 1,342 indexed — ~37 tok/s @48 steps,
  ~74 tok/s @16, peak RSS 12.7 GB
- MXFP8: 26 GB, 23 shards, `total_size=27918936056`, 295 quantized
  tensors, 752 passthrough, 1,342 indexed — converges in fewer steps
  (sometimes faster than MXFP4 end-to-end), peak RSS 23.8 GB

## Pin management

`Packages/OsaurusCore/Package.swift` pins `osaurus-ai/vmlx-swift` by
revision; the same revision must appear in BOTH lockfiles
(`Packages/OsaurusCore/Package.resolved`,
`osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`) AND in the
`RuntimePolicySourceTests` "vmlx pin uses consolidated package" expected
revision constant — the focused test fails on any mismatch by design.

Focused verification command:

```sh
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-dg-tests \
swift test --package-path Packages/OsaurusCore \
  --filter 'VLMDetectionTests|ModelMediaCapabilitiesMCDCTests|RuntimePolicySourceTests'
```

Debugging note: a bare `error: fatalError` from SwiftPM is a masked
clang `fatal error:` — grep the full log. Fresh vmlx worktrees need
`git submodule update --init --recursive` (Source/Cmlx) and tests need
`scripts/prepare-mlx-metal.sh` metallibs.

## Boundaries (unchanged)

- Image-only capability advertised; **runtime VL is not yet wired** in
  vmlx (vision tower ships in the bundles but text-only generation is
  what's proven). Audio absent; video has no `video_token_id`.
- Block diffusion is exclusive-solo in BatchEngine; batched canvas
  scheduling is future work.

## Live dev-build verification (2026-06-12)

All proven through the running Debug app's OpenAI API (`/v1/chat/completions`):

- **Detection scoping**: `gemma-4-12b-it-mxfp4` generates with **zero**
  `[BlockDiffusion]` engine lines; `diffusiongemma-*` emits them. Routing
  is by Swift type conformance (`model is BlockDiffusionModel`) — only
  `DiffusionGemmaModel` conforms, so no name-based misrouting is possible.
- **Settings take effect**: changing
  `generation.diffusionMaxDenoisingSteps` 16 → 32 in
  `server-runtime.json` (what the Settings panel writes) and restarting
  flips the engine to `maxDenoisingSteps=32`; restored to 16.
- **Multi-turn single session + reasoning toggle**: 4-turn conversation,
  `enable_thinking` toggled per turn — reasoning content present only on
  ON turns, recall held across all turns (name + number + 42+8=50), SSD
  prefix cache restored 56 tokens mid-conversation, per-turn prefill
  0.09–0.33 s.
- **Vision**: a base64 gradient PNG was correctly described
  ("vertical gradient … vibrant red at the top to deep blue at the
  bottom") at the default 16-step setting.

## Published bundles

- `OsaurusAI/diffusiongemma-26B-A4B-it-MXFP4`
- `OsaurusAI/diffusiongemma-26B-A4B-it-MXFP8`

Each ships the model card (eos `[1,106,50]`, chat template, Gemma-4 tool /
harmony reasoning parser notes, image capability, diffusion-settings docs)
and the Osaurus banner.

## Known limitation: bf16 full-precision bundle (not a shipping path)

`diffusiongemma-26b-a4b-it` (bf16, ~52GB) currently fails to load with a clear
HTTP 500: `Unhandled keys [down_proj, gate_up_proj] ... DiffusionGemmaExperts`.
Root cause: the unquantized bundle ships **bare** stacked expert tensors
(`...experts.gate_up_proj`, `...experts.down_proj` with no `.weight` suffix),
while `DiffusionGemma.sanitize()` only remaps the quantized layout
(`.experts.gate_up_proj.weight/.scales/.biases`). The **mxfp4 and mxfp8
variants — the supported/shipping diffusion paths — load and run coherently**;
bf16 is a reference precision not used on-device. Tracked for the diffusion
engine lane (vmlx-swift `DiffusionGemma.swift`); fails loudly with no crash or
garble, so it does not affect the quantized product paths.
