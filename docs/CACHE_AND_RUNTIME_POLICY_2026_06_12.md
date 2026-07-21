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

### New-chat SSD checkpoint reuse gate (reported 2026-07-20)

Users report that ending a chat and starting a new one repeatedly pays an
initial prompt warmup from zero. This is **PARTIAL-LIVE / ORNITH MXFP8 FIX
PROVEN IN THE REBUILT RELEASE UI; OTHER REQUIRED FAMILY/SETTING ROWS REMAIN
OPEN**. A new chat must start with a fresh semantic
transcript, but that does not require recomputing an identical stable prefix.
The model/template system prefix, enabled tool schemas, and other byte-identical
leading blocks should be eligible for the SSD prefix/block-L2 longest-prefix
restore across new chats, model unload/reload, and process restart.

The cache key must invalidate affected blocks when any state that changes the
rendered prefix or cache representation changes, including model artifact or
revision, runtime/cache format, attention topology, RoPE/context settings,
reasoning template kwargs, system prompt, enabled tool schemas, live KV codec
and TurboQuant bit widths, processor/media configuration, and media salt. A
new chat/session identifier by itself must not invalidate otherwise identical
prefix bytes. UI-only settings that do not affect inference must not erase a
valid checkpoint. Reuse must never carry user conversation state from the old
chat into the new one.

The live proof must distinguish model weight load/kernel preparation from
prompt prefill: SSD KV restore can reduce TTFT/prefill but does not imply that
an unloaded model has no weight-loading cost. Every row must record the stable
prefix token count, restored boundary, remaining raw-prefill tokens, TTFT,
token/s, disk hit/miss/store counters, companion hit/rederive counters, cache
bytes on disk, and visible coherent output.

Required Release-UI matrix:

| Family/topology | Cold and new-chat sequence | Required warm evidence |
| --- | --- | --- |
| Gemma 4 | Rotating SWA plus full-attention KV; paged RAM Off; SSD On; native codec default | A second brand-new chat and a fresh-process run restore the longest valid SSD prefix, rebuild/restore every rotating/full companion consistently, and avoid a full zero-prefix prefill |
| Qwen 3.5 text, Ornith, Bonsai | Hybrid KV plus GDN/SSM recurrent companion state; paged RAM Off; SSD On | Disk hit and matching async companion restore/rederive are both observed; output, reasoning state, and tool calls remain coherent across exact and partial prefix matches |
| Qwen 3.5 VL | Same hybrid state plus media processor/mRoPE inputs | Same-media reuse hits the valid media-salted prefix; different media misses at the changed boundary; text-only and post-media turns do not cross-hit incorrectly |
| Explicit paged RAM On | Bounded hot blocks over the same SSD tier | RAM hit wins when present; eviction falls back to the matching SSD block; a fresh process proves SSD rather than stale RAM supplied the restore |
| Explicit TurboQuant On | Separate cache representation/key from native | Only supported KV layers are encoded; rotating/SSM/GDN/media companion state stays in its correct native/typed form; returning to default native must not consume the TQ entry |
| Configuration change controls | Change one inference-affecting setting at a time, then restore it | Changed configuration misses only where required; restoring the prior configuration can find its prior compatible SSD checkpoint; no global cache flush or cross-config poisoning |

The visible Settings state and effective runtime telemetry must agree. The
intended defaults for this gate are Prefix/SSD On, paged RAM Off, and
TurboQuant Off, but no current-version default is promoted solely from this
document; it must be observed in the development Release app and confirmed by
the next request's effective counters.

Current Ornith evidence from the isolated Release app
`com.dinoki.osaurus.applescriptemergency20260720` (SHA-256
`114fbe282e9e2872abe88ca8c991da6ebc1b7c9e19f0ef5029bd94c54511fd9b`)
shows that SSD L2 is enabled and persistent, but the hybrid full-hit selection
is wrong. With Prefix and Disk Cache visibly On, paged RAM Off, Codec Engine
Selected, and SSM rederive On, a fresh process hit the 2,201-token disk
boundary with 48 recurrent states. A second new chat reported an exact
2,234-token disk hit with `remaining=0`, yet the UI then visibly advanced raw
prefill in 512-token chunks. Source trace in the pinned vMLX revision explains
the contradiction: callers set `skipExactDiskBoundary=true` for
path-dependent cache topologies, but `CacheCoordinator.fetch` re-admits the
exact boundary through `candidateTokenCounts`. The later GDN full-hit guard
cannot safely seed N-1 without a matching companion and rolls back to full
prefill. The candidate change excludes the exact boundary from every probe so
the longest safe partial boundary (2,201 of 2,234 here) can be restored.

The same pre-fix live trace also showed unconditional post-generation rewrites of
already-restored boundaries (roughly 125-143 MB KV files plus roughly 26 MB
SSM companion files) and repeated quota eviction at the 10 GB cap. The vMLX
candidate adds a process-validated, fingerprint-checked no-rewrite path; a
fresh process or changed/missing/corrupt/index-mismatched file still takes the
full healing write.

Current rebuilt-app evidence uses `/private/tmp/Osaurus SSD Cache Proof
20260720.app`, ad-hoc signed as
`com.dinoki.osaurus.ssdcacheproof20260720`. Its Release executable SHA-256 is
`8dcb022e282b28a2b800a7cdef858a86f300c3999db12c1fdb97f67f24ba3516`,
and the resolved Xcode checkout was the exact vMLX revision
`74caefd907e6df15780a454d8523b78bf889964c`.

Fresh-preferences setup was performed through onboarding and Settings in the
real app. Server -> Settings -> Cache visibly showed Prefix Cache **On**, Disk
Cache **On**, GPU Cache (paged KV) **Off**, Codec **Engine Selected**, and SSM
rederive **On**. The model picker visibly selected the locally installed
`Ornith 1.0 9B MXFP8`; Thinking remained visibly **Off**.

Observed rows:

- First real chat after selection: the runtime logged
  `HIT disk boundary=1734 remaining=18 ssm=48 ... skipExactDisk=true` instead
  of admitting the unsafe exact hybrid boundary. The visible response was the
  requested exact `CACHE PROOF ONE.` at TTFT 0.50s, 49.0 tok/s, 5 tokens, with
  no reasoning deltas.
- Brand-new chat in the same process: background warmup logged
  `HIT disk boundary=1731 remaining=3 ssm=48 ... skipExactDisk=true`. The
  write-through then emitted `disk-store SKIP validated` for both the 1,734-
  and 1,731-token KV payloads and matching `ssm-store SKIP validated` lines
  for both 48-state companions. The repeated visible answer was exact at TTFT
  0.33s, 49.1 tok/s, 5 tokens.
- Full app quit/restart, preserving only the isolated app root and SSD cache:
  warmup again logged `HIT disk boundary=1731 remaining=3 ssm=48`; the UI
  reached `Model warm` without a zero-prefix raw prefill. The first visible
  answer after restart was exact at TTFT 0.39s, 49.4 tok/s, 6 tokens.

This closes the reported Ornith/Qwen-hybrid new-chat and restart reuse defect:
SSD is not merely enabled or populated; the live runtime restores a safe
partial KV+SSM boundary and computes only the suffix. It also proves
same-process rewrite suppression for a currently validated KV/companion pair.
It does **not** close the entire cache campaign. The safe exact 1,734-token
boundary is deliberately not restored for this GDN topology, so a fresh
process rewrote that exact post-warmup payload once while the restored
1,731-token checkpoint was skipped; whether that one healing write should be
replaced by an independent read-validation path remains an explicit follow-up.
Gemma 4 rotating-SWA, Bonsai, Qwen VL/media salt, paged-On hot-to-SSD fallback,
TurboQuant-On, corruption recovery, and configuration-change invalidation all
remain separate unproven Release-UI rows.

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

## 2026-07-21 merged-pin new-chat and restart evidence

Status: **VERIFIED-LIVE for the named Gemma and Ornith/Qwen-derived native-SSD
rows only; PARTIAL for every other family, TurboQuant, paged-On, and media
row.**

The exact ad-hoc-signed Release app was
`/private/tmp/osaurus-ssd-stable-release-derived-20260721/Build/Products/Release/osaurus.app`,
bundle id `com.dinoki.osaurus.ssdstableproof20260721`, executable SHA-256
`e28cc1a1aad58514fa2cb325cf7f95bb098b6a93cd2a82f7e4f1ceae9244fb7d`,
isolated root
`/private/tmp/osaurus-ssd-stable-finalproof-root-20260721-0320`, and exact
resolved vMLX revision
`b87cdd6b2a9f05f600461e41b239b7197151d9ff`. Server -> Settings -> Cache
visibly showed Prefix Cache On, GPU/Paged Cache Off, Disk Cache On, Codec
Engine Selected, and SSM Re-derive On; the UI confirmed that the changes were
saved. Thinking was visibly Off for both text models.

Current Osaurus source supplies the byte/token-identical warmup intersection
as both a stable boundary and an ordinary store boundary. That is essential:
merely identifying a stable boundary without placing it in the persisted
boundary list would still make each new session prefill it from zero. Current
vMLX source excludes an unsafe exact hybrid/GDN candidate when
`skipExactDiskBoundary` is requested and restores the corresponding recurrent
companion only at the matched partial boundary.

Observed real-UI rows:

- **Ornith 1.0 9B MXFP8 / Qwen-derived hybrid:** a brand-new chat returned the
  exact visible answer `ORNITH-CACHE-OK`, TTFT 0.46 seconds, 49.8 tok/s, and 6
  tokens. The same request restored SSD boundary 2,325 with 276 suffix tokens
  remaining and all 48 SSM/recurrent states. Background warmup separately
  restored boundary 2,322 with only 3 tokens remaining. The disk store enforced
  the configured 10 GiB quota and evicted complete KV/companion records.
- **Gemma 4 E2B QAT JANG_4M / rotating plus full attention:** after selection,
  warmup persisted stable boundary 2,263. A new chat returned exact
  `GEMMA-CACHE-OK`, TTFT 0.30 seconds, 94.9 tok/s, and 6 tokens. The user turn
  restored boundary 2,266 with 255 tokens remaining and persisted 2,521/2,527.
- **Fresh-process Gemma restore:** the app was quit completely and relaunched
  with the same isolated root. The valid source-defined model-root override is
  `OSU_MODELS_DIR`; one discarded diagnostic accidentally used the nonexistent
  `OSAURUS_MODELS_DIR` key and therefore saw only the fallback image models.
  With the correct key, the UI immediately showed the exact Gemma model warm
  and Thinking Off. Warmup restored SSD boundary 2,263 with only 3 tokens
  remaining. The first visible post-restart response was coherent at TTFT 0.37
  seconds and 92.6 tok/s; its request restored boundary 2,266 with 242 tokens
  remaining. It added an unrequested explanatory sentence, so that single row
  is not promoted as exact-instruction compliance.

These rows prove that the scoped native SSD cache is more than a populated
directory: a new semantic chat and a new process restore a byte-identical
stable prefix, retain architecture-specific companion state where required,
prefill only the novel suffix, stream coherent output, and write the extended
boundary back. The AppleScript helper in the same binary also used progressive
SSD partial hits across its clean per-job transcript and completed coherently.

Not proven by these rows: Bonsai itself, base Qwen 3.5 or Qwen VL/media salt,
Gemma 4 VL/media, LFM, MiniMax, DSV4, Nemotron, explicit paged RAM On and
hot-to-SSD fallback, explicit TurboQuant On, corruption recovery, cache-key
configuration invalidation, or Activity Monitor physical-footprint limits.
TurboQuant remained Off/default-native throughout and no TurboQuant topology
claim is made.
