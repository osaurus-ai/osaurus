# Osaurus + vMLX Cache & Runtime Policy Reference (2026-06-12)

Comprehensive reference for the cache stack, KV codecs, RAM safety, and the
per-family runtime nuances after the Gemma 4 speed/audio work and the
TurboQuant-off-by-default policy change. This is the source of truth for
"what is the default, why, and where is it enforced."

## 1. Default cache topology (every model, unless explicitly overridden)

| Layer | Default | Enforced at |
|---|---|---|
| Paged RAM KV cache | **OFF** | `VMLXPagedKVCacheSettings.enabled=false`; vMLX `CacheCoordinatorConfig.usePagedCache = reuseEnabled && cache.pagedKV.enabled` |
| Prefix cache (SSD-backed) | **ON** | `VMLXPrefixCacheSettings.enabled=true`; forces block-disk L2 on |
| Block-disk L2 cache | **ON** | `VMLXBlockDiskCacheSettings.enabled=true` |
| Legacy disk cache | **OFF** | `VMLXDiskCacheSettings.enabled=false` |
| Live KV codec | **native fp16** | `liveKVCodec=engineSelected` → `shouldUseTurboQuantByDefault` returns false (see §2) |
| TurboQuant KV | **OFF (opt-in only)** | See §2 |
| SSM re-derive | ON | `enableSSMReDerive=true` (hybrid families only) |
| Memory safety | safe_auto | `memorySafety.mode` |

**The only default cache is SSD prefix + block-disk L2. No paged RAM cache for any model. No TurboQuant encode/decode for any model.**

## 2. TurboQuant KV — OFF by default for ALL families (policy 2026-06-12)

### Why
TurboQuant compresses live KV (`turbo(3,3)` = 3-bit key / 3-bit value) to save
RAM. At the context lengths Osaurus serves, the per-step compress/decompress
cost outweighs the RAM savings and measurably regresses decode throughput
across every family that carries KV:
- Gemma 4 26B-A4B MXFP4: 92.3 → 54.0 tok/s (−42%) with `tq33` vs native
- Gemma 4 12B MXFP4: 48.6 → 34.5 tok/s (−29%)
(M5 Max, RunBench, greedy, `kvMode none` vs `tq33`.)

The Gemma SWA regression (the visible "26B used to do 100+ tok/s" symptom)
was one instance of a blanket problem: any rotating/SWA/full-KV topology paid
the same tax.

### The resolution chain (where it's decided)
1. Osaurus ships `liveKVCodec = .engineSelected` (the default codec choice).
2. vMLX's `VMLXServerCacheSettings.defaultKVMode` resolves `.engineSelected` to
   `.turboQuant()`.
3. **`ModelRuntime.shouldUseTurboQuantByDefault(...)` is the single runtime
   gate that decides whether engine-selected actually turns TurboQuant on.**
   As of 2026-06-12 it **unconditionally returns false** — so engine-selected
   resolves to native fp16 KV for every model.

### Opt-in path (unchanged)
Setting `cache.liveKVCodec = .turboQuant` (with `turboQuantKeyBits`/
`turboQuantValueBits`) bypasses the auto gate entirely (`defaultKVMode`
returns `.turboQuant(keyBits:valueBits:)` directly). TurboQuant remains fully
available for anyone who explicitly wants it.

### Telemetry
`/admin/cache-stats` → `effective_kv_mode` reports the actual resolved codec
(`"fp16"` under the default policy; `"turbo(3,3)"` only under explicit opt-in).
`turbo_quant_kv_layer_count` counts actually-materialized TurboQuant layers
(0 under the default policy). Do not describe a model as TurboQuant-encoded
when `effective_kv_mode=fp16`.

### Future lane
A kernel-level TurboQuant encode/decode optimization (threadgroup-shared
codebook, vectorized packed loads, simdgroup-matrix dequant) could make TQ
cheap enough to default on for RAM-constrained loads. Until that lands with a
per-family proof row, the engine default stays native fp16.

## 3. RAM safety

- `memorySafety.mode` ∈ {performance, balanced, safeAuto (default), strict,
  diagnosticDangerous}. Each maps to a distinct load fraction + allocator cap
  (`resolvedMemorySafetyPlan` → `LoadConfiguration.memoryLimit`/
  `maxResidentBytes` → MLX `Memory` limits).
- RAM feasibility is **advisory** in safe_auto (verdict logged + surfaced, load
  proceeds; unified memory + mmap can page/compress). **strict** mode sets
  `blocksOverBudget=true` and refuses loads whose projected working set exceeds
  the resolved budget.
- Backstop when a too-large bundle is loaded: idle-resident-model eviction
  (`strictSingleModel` / flexible-budget eviction) fires before the new load.
  RE-VERIFY: eviction fires before OOM on a genuinely over-budget load (the
  hard pre-load refusal was demoted to advisory in osaurus #1454).

## 4. Per-family cache/runtime nuances

| Family | Live KV (default) | Companion / special state | Notes |
|---|---|---|---|
| Gemma 4 (gemma4/gemma4_unified) | fp16 native | SWA: 5 sliding (RotatingKVCache win=1024) : 1 full (MQA, unbounded). attention_k_eq_v on full layers. | Dual RoPE (proportional p-RoPE θ=1e6 full / default θ=1e4 sliding). Tied 262k embed; q6 head opt-in. Audio: 12B unified raw-frame `embed_audio`; E-series mel + conformer `audio_tower`. |
| Qwen 3.5/3.6 MoE (+MTP) | fp16 native | Hybrid SSM (gated-delta) + MoE streaming experts | MTP autodetection from sidecar tensors → native-MTP draft. Streaming-experts auto-enable (verify decode). |
| LFM2 / LFM2.5 (hybrid) | fp16 native | SSM companion state + required-tool template | Required-tool parser churn — verify e2e tool history. |
| DeepSeek-V4-Flash | fp16 native | HCA + SWA + CSA combo cache; disk-backed restore | Combo cache restore needs all three companion states; never substitute TQ. |
| ZAYA1 / ZAYA1-VL (CCA) | fp16 native | CCA companion disk payload | Fail-closed on CCA disk miss — verify it actually hits, not just fails safe. |
| Nemotron-H / Omni (hybrid SSM) | fp16 native | Mamba SSM + conv decode fast path | Weighted-MoE fast path now opt-in (env flag). Audio: Parakeet conformer. |
| Step 3.7 | fp16 native | Mixed full-KV + rotating/SWA | Text-only + tool-capable; tool parsing owned by vMLX Step runtime. |
| MiniMax M2.7 | fp16 native (was turbo) | Full KV (62 layers) | Now fp16 under blanket-off policy; was the one family auto-TQ'd without topology. |

## 5. Correctness components (kernels / parsers)

- **mx matmul / quantized matmul**: MXFP4 (4-bit packed, affine scales/biases),
  JANG_4M mixed-precision per-layer overrides, JANGTQ TurboQuant packed.
- **Hadamard 2D/3D**: used in rotary/quant transforms; verify shape handling on
  hybrid/MoE paths.
- **mrope**: multimodal RoPE for VL families; Gemma 4 uses dual-RoPE (not mrope).
- **Reasoning parsers**: `ReasoningParser.forPrompt` stamps per family; Gemma 4
  `<|channel>thought` (think_in_template=false). Held-tail detokenizer fix
  (bf5871d) prevents dropped text between chunks.
- **Tool parsers**: per-family `ToolCallFormat` → parser. Gemma 4 = `call:name{}`
  with `<|tool_call>`/`<tool_call|>` markers. Strip-only mode (vMLX #50) strips
  markers when no tools offered so they never leak as visible text.

## 6. Verification gate (every change)
A change to any of the above is not done until **live multi-turn chat in the
dev-built Osaurus app** (pinned to the exact code) confirms: real tool calls,
clean coherent text (no missing/garbled/random-char output), no marker leaks,
correct cache telemetry, and RAM verdicts. CI + unit tests are necessary but
not sufficient.
