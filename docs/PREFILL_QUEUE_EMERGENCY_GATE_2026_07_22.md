# Prefill Queue Emergency Gate — 2026-07-22

Status: **PARTIAL — the released queue symptom predates current main; a distinct
current-main LFM disk-restore bypass is fixed and live-proven on the exact
merged vMLX pin in the isolated Release app. Bonsai/Qwen-hybrid and Gemma 4
rotating-SWA representatives also pass that exact-pin cache gate, while the
complete all-family/all-setting matrix is not closed.**

Scope: shared Osaurus/vMLX request, warm-up, and cache lifecycle. This is not a
Bonsai-only workaround. AppleScript, Laguna expansion, routing guidance, and
unrelated model work are parked until this queue stall is closed.

## Reported release evidence

Both screenshots show `Bonsai 27B Ternary JANG`, Thinking enabled, and the same
request stuck at `Queued 0/8823` instead of entering prefill:

- `docs/internal/evidence/2026-07-22-prefill-queue/bonsai-release-queued-weather.png`
  - Prompt: `what's the weather in nyc`
  - Visible memory: `33.2 / 48 GB`
  - SHA-256: `23833a7b6501e3639939b695cfcf0eeaa7689f8306a6cba2763ab8783a9c09bc`
- `docs/internal/evidence/2026-07-22-prefill-queue/bonsai-release-queued-hello-world.png`
  - Prompt: `hello world`
  - Visible memory: `29.3 / 48 GB`
  - SHA-256: `01575cd5741556a0d7fca8a5779b9d1d5ee38ae370d6bf6b4c79af7f669c16be`

User report: the stall occurs on the second turn in the release build and does
not recover. The screenshots prove the visible symptom only. They do **not**
yet prove whether the owner is a leaked BatchEngine slot, an orphaned warm-up,
model unloading, SSD restore, cancellation, or UI progress projection.

## Baseline source truth

- Osaurus base: `0c6563c6618782116aa113dbfe7a4cbc32337b2e`
- Baseline vMLX pin: `bbbf49e090449bb42f6cde8f50b6f230e3578aec`
- Osaurus PR integration pin: merged vMLX PR #176,
  `c59024a1b4b1314bf98ce962f99e1ffaaebfc247`. The exact-pin Release rebuild
  and UI rerun are recorded below.
- Shipped release `0.22.8` resolves to commit
  `402060bce30e802ab0e19a932e05c6afa9c71c99`, published before the SSD repair
  series below.
- Current main contains the merged SSD repair series: #2118, #2119, #2122, and
  #2124. The next-release draft lists all four. The release screenshots therefore
  do not represent the current-main runtime.
- Current vMLX `bbbf49e0` descends from the live-proven SSD restore revision
  `feb35555` through merged PR #173 (`d1312c31`). Its later changes are Laguna
  S2.1 support and numeric tool-argument bridging; the SSD restore is not absent
  from the current pin.

## Queue-stage source trace

- The solo BatchEngine publishes `.queued(completed: 0, total: N)` immediately
  before the iterator begins cache lookup/restore. The first `.prefill` event is
  emitted only after the synchronous coordinator fetch and typed-cache restore.
  A visible `Queued 0/N` therefore does not, by itself, prove model unload or a
  leaked scheduler slot.
- Osaurus holds its solo lease and shared Metal generation gate until the
  upstream stream fully drains, including post-generation SSD store. The live
  traces below show a balanced `STREAM-DRAINED` / `LEASE-RELEASED` pair on every
  observed current-main step.
- A foreground send that arrives during an in-flight proactive warm-up waits for
  that warm-up to finish so the just-materialized SSD prefix can be reused. This
  can display the warm-up's queued/prefill phase in the foreground assistant row.
  Current-main live timing below did not strand the wait.

## Current-main isolated Release evidence

App:

- Bundle: `com.dinoki.osaurus.prefillqueueproof20260722`
- Configuration: Release, ad-hoc signed, isolated `OSAURUS_TEST_ROOT`
- Source: Osaurus `0c6563c6`, vMLX `bbbf49e0`
- Visible defaults exercised: Prefix Cache On, GPU/Paged Cache Off, Disk Cache
  On, cache codec Engine Selected, SSM Re-derive On.
- Visible settings evidence:
  `docs/internal/evidence/2026-07-22-prefill-queue/cache-settings-release-proof.png`
  (SHA-256 `bbc07f9ded19011e1a8aa4ac0fe190494d9b4ab83e196d71a4cfdc052b9bb856`).
- Full-KV cross-chat evidence:
  `docs/internal/evidence/2026-07-22-prefill-queue/vibe-cross-chat-release-proof.png`
  (SHA-256 `2edb41ee9e4bf9131ab8cd05a1b11fc54a6a62ca8e617d38814b5660a764ea1b`).

Bonsai 27B Ternary JANG (Thinking On):

- Two ordinary turns completed with exact visible answers. Turn 2 restored
  `3027/3045`, TTFT `0.60s`, `46.4 tok/s`; disk hits advanced.
- Exact reported weather prompt completed its model/tool loop without a queue
  leak. Every model step left queued, entered prefill/decode, drained, and
  released its lease. The model itself made excessive/failed search attempts;
  that is a separate agent/tool-quality row, not a queue-liveness pass.
- A new-chat send issued while the chip visibly showed `Warming up…` entered
  prefill and returned exact `RACE-PASS`, TTFT `0.62s`, `39.3 tok/s`.
- A 13,572-token prompt visibly advanced through prefill and returned exact
  `HEAVY-ONE`, TTFT `18.81s`, `40.9 tok/s`; its next turn restored
  `13,577/13,596` and completed instead of remaining queued.
- Quit/relaunch was repeated after moving all 30 recurrent companion files
  (1.1 GB) out of the isolated cache, simulating inherited KV entries without
  separate sidecars. The format-v2 folded hybrid payload restored boundary
  `3005/3024` with `ssm=96` and returned exact `STALE-RECOVERY`, TTFT `0.66s`,
  `43.7 tok/s`.

Gemma 4 12B QAT JANG_4M (Thinking Off):

- Cold isolated load/warm-up completed with `KVCacheSimple: 8` and
  `RotatingKVCache: 40`; paged RAM remained off and disk L2 stored typed
  format-v2 payloads.
- `GEMMA-ONE` restored boundary `1940/1953`, visible TTFT `0.50s`, `38.0 tok/s`.
- `GEMMA-TWO` restored boundary `1962/1975`, visible TTFT `0.49s`, `29.8 tok/s`.
- Both outputs were exact and no reasoning leaked while the visible Thinking
  control was Off.

LFM2.5 recurrent/full-attention hybrid follow-up:

- A clean single-process Release rerun completed a natural new-chat turn and a
  grounded second turn (`Chlorophyll`) at TTFT `0.57s` / `0.51s` and
  `227.4` / `179.8 tok/s`. Queue liveness therefore passed.
- Runtime telemetry showed typed format-v2 SSD stores but no fetch attempt or
  hit; Osaurus L2 counters remained zero. Source trace found the owner in
  `BatchEngine`: every LFM2.5 MXFP8 request carrying tool schemas was routed
  around disk restore, and its tool-prompt seed boundary was suppressed. Since
  normal Osaurus chats carry tool schemas, that name-based safety bypass made
  the family effectively write-only even when Disk Cache was visibly On.
- The current-vMLX patch removes only the LFM name-based bypass and leaves the
  separate unproven Gemma-4 MXFP4 seed exception intact.
- The rebuilt Release app then produced partial SSD hits with paged RAM cache
  Off: boundary `1747/1768` on a new chat, `1793/1815` on its grounded
  follow-up, `1765/1777` on another new chat, and `1747/1750` on startup.
- Visible coherent results were an exact requested sentence, `Rayleigh
  scattering`, and `oxygen`, at TTFT `0.41s`, `0.32s`, and `0.49s` and
  `270.0`, `221.5`, and `239.1 tok/s`. The restored topology was
  `MambaCache:18` plus `KVCacheSimple:6`.

Additional representative cache-path rows:

- Laguna S2.1 JANG_2L restored partial SSD prefixes across turns and a new
  chat with `KVCacheSimple:12` plus `RotatingKVCache:36`; the exact cross-chat
  answer had TTFT `0.93s` at `44.2 tok/s`. The 10 GB disk quota also evicted
  one older entry on the same live path.
- VibeThinker 3B MXFP8 restored full-KV prefixes (`KVCacheSimple:36`) with
  paged RAM Off, including a boundary `81/81` cross-chat hit. Its second turn
  leaked visible deliberation, so cache behavior passes but model coherence
  fails.
- ZAYA1 VL 8B JANGTQ4 restored a `ZayaCCACache:40` prefix, but the generic
  Assistant surface hallucinated an image description after search. This is
  cache-path evidence only, not a usability pass.
- Nemotron Labs Audex 2B 8bit failed to load with `Unsupported model type:
  nemotron_dense_audex`; the pinned runtime cannot close that family row.

Telemetry note: `[vmlx][cache/paged-store]` is logged before tier selection.
The in-memory write is still guarded by a non-nil paged cache. With the visible
GPU Cache toggle Off, that trace label does not prove that paged RAM was
silently enabled.

## Exact merged-pin Release confirmation

This rerun used the scoped Osaurus PR head `5926372363033c22f7497f988fa38e2a967c0414`
with the exact merged vMLX pin
`c59024a1b4b1314bf98ce962f99e1ffaaebfc247` in a fresh Release build. The app
was ad-hoc signed and launched as the isolated bundle
`com.dinoki.osaurus.prefillqueueproof20260722`; its executable SHA-256 was
`070faab1e06e425981410ccbcb7f92714509734dbc7608fc34af111dd4e4289d`.
`OSAURUS_TEST_ROOT` isolated app data, and `OSU_MODELS_DIR=/Users/eric/models`
pointed the proof app at the user-specified local model store instead of
changing or copying any model bundle.

Computer Use visually confirmed Settings -> Server -> Cache with Prefix Cache
On, GPU/Paged Cache Off, Disk Cache On, codec Engine Selected, SSM Re-derive
On, and `All changes saved`. The same exact app then selected and exercised
each model through the visible chat UI:

- LFM2.5 8B A1B MXFP8 CRACK: the exact answer `LFM-EXACT-PIN-ONE` displayed at
  TTFT `0.46s` and `210.6 tok/s`. Runtime fetch restored disk boundary
  `1747/1768` (`remaining=21`, `ssm=18`, format v2). A separate new chat's
  proactive warm-up restored `1747/1750` and drained in `0.45s` rather than
  recomputing from token zero.
- Bonsai 27B Ternary JANG CRACK: the user-visible Thinking control was switched
  Off before the measured turn. That configuration change correctly caused one
  cold seed for the new prompt identity, which stored boundary `3005`; the
  measured turn then restored `3005/3031` (`remaining=26`, `ssm=96`, format v2)
  and displayed exact `BONSAI-EXACT-PIN-ONE` at TTFT `0.95s`, `31.8 tok/s`,
  with zero reasoning deltas. The next new-chat warm-up restored `3007/3008`
  with all 96 hybrid companion states and drained in `0.18s`.
- Gemma 4 12B QAT JANG_4M: Thinking was visibly Off. The first exact-pin warm-up
  stored typed format-v2 rotating payloads. The measured turn then restored
  `1729/1747` (`remaining=18`) and displayed exact `GEMMA-EXACT-PIN-ONE` at
  TTFT `0.65s`, `32.7 tok/s`, with zero reasoning deltas. The next new-chat
  warm-up restored `1725/1729` and drained in `0.20s`. Bundle config contains
  48 layers (8 `full_attention`, 40 `sliding_attention`); live storage reported
  `requiredCompanion=true` plus rotating offsets, matching that mixed topology.

Visible exact-pin answer artifacts:

- `docs/internal/evidence/2026-07-22-prefill-queue/exact-merged-pin-lfm25-mxfp8.png`
  (SHA-256 `f8b01fb868ea8cec70333b12b050fdc84f38f59531054ecaacb1aacef9ac5379`)
- `docs/internal/evidence/2026-07-22-prefill-queue/exact-merged-pin-bonsai-ternary.png`
  (SHA-256 `8f934593ede273bcd36ac08a1ae31abf6be1213d880be4432d83d6396d5c2597`)
- `docs/internal/evidence/2026-07-22-prefill-queue/exact-merged-pin-gemma-jang4m.png`
  (SHA-256 `c7df0859b270b42bc224fb2f2d209e3aeebcf5d3e7eaa5ce054e00a3ffafefeb`)

This closes the exact-pin emergency representative gate only. It does not
convert the open paged-RAM, TurboQuant-KV, unsupported-family, AppleScript, or
all-model matrix rows below into passes.

## Required reproduction matrix

All rows must run through an isolated Release Osaurus app operated through the
visible UI. CLI tests may diagnose but cannot close a row.

| Scenario | Required visible/runtime evidence | Status |
|---|---|---|
| Same chat, second turn | Leaves Queued; enters prefill/decode; coherent answer; TTFT | PASS — Bonsai, Gemma |
| New chat, same model | SSD counters before/after; restored tokens; remaining prefill; TTFT | PASS — Bonsai |
| Send while background warm-up owns load | One load owner; foreground request cannot starve | PASS — Bonsai |
| Stop/cancel then send | Cancelled slot/producer exits; next request starts | PARTIAL — stop recovered, immediate post-cancel send not isolated |
| Switch model and return | Old engine lifecycle completes; returned model starts | PARTIAL — forward switches passed; return-to-prior not rerun |
| Quit/relaunch and send | Disk L2 restore is attached before request publication | PASS — Bonsai folded hybrid restore |
| Paged RAM cache off, SSD on | Default user path; partial/exact disk hit truth | PASS — Bonsai, Gemma |
| Paged RAM cache on, SSD on | Hot RAM then warm SSD fallback; no queue regression | OPEN |
| TurboQuant KV off/on where supported | Setting takes effect; coherent multi-turn output | OPEN |
| Plain KV representative | Shared fix works outside hybrid/rotating paths | PASS for cache path — Vibe full-KV disk hits; FAIL for its turn-2 reasoning leak |
| LFM2.5 MXFP8 hybrid | Disk fetch is not globally bypassed merely because Osaurus supplies tools | PASS — partial SSD hits and coherent new-chat/follow-up output in rebuilt Release app |
| Qwen/Bonsai hybrid representative | Companion-state restore/re-derive remains coherent | PASS — Bonsai queue/cache row |
| Gemma rotating-SWA representative | Rotating/global cache remains coherent | PASS — Gemma 4 12B queue/cache row |
| Laguna mixed full/rotating | Cross-chat partial SSD restore and coherent output | PASS — 12 full + 36 rotating layers |
| CCA representative | Typed disk restore | PARTIAL — ZAYA cache hit; generic Assistant coherence failed |
| Unsupported family detection | Unsupported models fail explicitly | BLOCKED — Audex runtime is not in the pinned engine |

## Release gate

The reported Bonsai queue stall belongs to the shipped build and did not
reproduce permanently on current main. The distinct LFM tool-schema bypass is
current and justifies a narrow vMLX follow-up plus Osaurus pin PR because the
rebuilt Release app now proves the before/after fetch delta. It must not be
conflated with the already-merged Bonsai/Gemma repair series or described as
closing unsupported/incoherent family rows.

Before claiming the broader all-setting campaign complete:

1. A root-cause trace naming the request owner, queue condition, and cleanup
   path that failed.
2. Focused regression tests plus relevant full test/build checks.
3. Isolated Release UI proof for second turn, new chat, cancellation, and
   restart with visible settings and cache telemetry.
4. Representative plain-KV, hybrid Qwen/Bonsai, and Gemma rotating-SWA rows.
5. Scoped diff audit and fresh PR CI. No AppleScript or unrelated model work in
   the emergency PR.
