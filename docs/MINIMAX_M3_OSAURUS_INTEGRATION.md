# MiniMax-M3 — osaurus integration (lane scaffold)

**Status: WIP scaffold.** This PR exists so a dedicated agent lane can own the
**osaurus-side** MiniMax-M3 (mm3) integration. It is intentionally separate from
any Gemma / tokenizer repin work. **Do not merge until the gate in §6 is met.**

> Why a separate lane: **M3 is not a generic dense-KV transformer.** Its cache and
> decode work differently — most layers use a block-sparse MSA / Lightning-Indexer
> attention with a *third* cache lane, and selection is recomputed every step from
> that lane. The osaurus reuse paths (cache clone/fetch/truncate/store/snapshot/
> batch-merge, scheduler, parsers, autodetect) all need M3-aware handling, or M3
> loops/garbles on reuse (proven on the Python engine). This lane wires that.

## 1. What M3 is (runtime shape)
- Layers **0-2:** dense full attention → stock KV cache.
- Layers **3-59:** sparse MSA / Lightning attention. GQA everywhere (n_kv=4,
  head_dim=128). Sparse layers carry **two append-only caches in lockstep**:
  - `keys`/`values` `[B, 4, S, 128]`
  - `idx_keys` `[B, 1, S, 128]` (Lightning-Indexer keys)
- Indexer scores idx_q against all `idx_keys`, **max-pools per 128-token block,
  selects top-k blocks**; main branch attends those K/V blocks. Selection is
  **recomputed every step from idx_keys, never cached.** Blocks anchored to
  **absolute position (`pos/128`)** → cache is **append-only / trim-and-replay
  only; never shift/rotate/evict.**
- MoE (REAP40-pruned). Reasoning + tool output use the `minimax_m3` parsers.

## 2. The engine (vmlx-swift) — dependency
The MLX runtime is being built in `osaurus-ai/vmlx-swift` (branch
`codex/mm3-runtime`): `MiniMaxM3SparseCache` (3-lane composite cache mirroring
`ZayaCCACache`), the MSA/indexer attention, MoE, decode. **This osaurus PR repins
to that vmlx-swift work once it lands** and adds the osaurus-side wiring below.
Cache contract reference: vmlx-swift `Libraries/MLXLMCommon/Cache/MiniMaxM3SparseCache.swift`
and vllm-mlx `models/minimax_m3/cache.py`.

## 3. THE critical osaurus work — keep the sparse cache first-class
The entire Python repetition-loop saga was osaurus-equivalent reuse paths
**downcasting `MiniMaxM3SparseCache` to a plain KVCache and dropping `idx_keys`**.
Every osaurus path that touches a cache must preserve the M3 type + all four of
`keys, values, idx_keys, offset` together. Audit and make M3-aware:

- [ ] **Memory/prefix cache fetch + clone** — return a per-request clone that
      preserves the sparse type and `idx_keys` (not a `(keys,values)`-only copy).
- [ ] **Scheduler store/truncation** — must NOT rebuild a generic `KVCache`/
      `RotatingKVCache` for M3; slice all three lanes lockstep.
- [ ] **Snapshot / continuous-batching merge** — keep M3 class; include `idx_keys`.
- [ ] **Disk / SSD prefix store** — restore as `MiniMaxM3SparseCache` for sparse
      layers (dense layers stay stock KV).
- [ ] **Cache telemetry** — distinguish dense-KV vs M3-sparse restore; a cache-hit
      response is only accepted if output is coherent AND no loop after the hit.
- Map these to osaurus's `ModelRuntime` / cache coordinator / `MLXBatchAdapter`
  paths (the Gemma KV-prefix-stability work hardened the same surfaces).

## 4. Runtime flags M3 must force
- [ ] **Paged cache OFF** for M3 (no native M3 page format yet).
- [ ] **TurboQuant KV encoding SKIPPED** for M3 native MSA caches.
- [ ] **JIT / `mx.compile` OFF** for M3 (dynamic sparse block selection).
- [ ] Async/lookahead decode must not leave `idx_keys` a step behind `keys/values`;
      async rederive must reconstruct **indexer history**, not just dense K/V.

## 5. Parsers / autodetect / reasoning
- [ ] Autodetect MiniMax-M3 family → route to the M3 runtime + cache.
- [ ] `--reasoning-parser minimax_m3`, `--tool-call-parser minimax_m3`.
- [ ] Reasoning is **first-class state** (content vs reasoning_content): off = no
      leaked think tags + visible content not swallowed; on = reasoning surfaced
      separately + visible final content; auto = adaptive. Streaming parser
      separates the two consistently; OpenAI Chat/Responses APIs expose reasoning
      per the selected surface. UI must not show empty bubbles when reasoning exists.

## 6. Merge GATE (do not relax)
Dev-app live proof on `MiniMax-M3-REAP40-d3-JANG_2L`:
- Logs show M3 autodetected; paged off; TQ-KV skipped; JIT off; parsers `minimax_m3`;
  dense + sparse layers recognized.
- **10-turn real-user chat: coherent, no repetition loop after sparse attention
  activates, cache-hit turns stay coherent**, long-context sentinel recall after
  cache hits. Reasoning off/on/auto behave per spec. Responses API tool-call +
  continuation work. Cache telemetry visible. **Zero loops, zero incoherency.**

## References
- vmlx-swift engine lane: branch `codex/mm3-runtime`; `MM3_LANE_PREP.md`.
- vllm-mlx reference: `~/mlx/vllm-mlx/vmlx_engine/models/minimax_m3/{cache,minimax_m3,runtime}.py`,
  bug/correct paths in `memory_cache.py` / `mllm_scheduler.py` / `prefix_cache.py` / `block_disk_store.py`.
- Notes: `~/vmlx/docs/M3-LOOP-HANDOFF.md`, `M3-CACHE-LAYERS-AUDIT.md`;
  postmortem `~/mlx/vllm-mlx/.agents/MM3-1.5.62-RELEASE-POSTMORTEM.md` (§"Swift engine implications").
