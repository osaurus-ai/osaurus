# Gemma 4 QAT cache checkpoint — 2026-07-19

Status: **PARTIAL — the exact current Osaurus branch and vMLX
`bbc0b20d7dd46445c9ff3d76be7caf329310a338` are live-proven in an isolated
Release app for the core Gemma 4 12B JANG_4M/MXFP8 cache and settings rows.
The 31B RAM-limit override control works, but its Activity Monitor Memory
column exceeded the bundle's on-disk size, so low-footprint readiness remains
failed and the PR is not yet described as release-ready.**

This checkpoint uses only the locally installed Gemma 4 12B MXFP8 and
JANG_4M bundles under `~/models`. MXFP4 is not a substitute artifact and is
not part of this checkpoint.

## Scoped changes

- Pin all four Osaurus SwiftPM resolution points to vMLX
  `bbc0b20d7dd46445c9ff3d76be7caf329310a338`.
- Keep paged RAM cache off by default.
- Keep engine-selected TurboQuant KV off by default. An explicit user
  TurboQuant selection with explicit bit widths remains available.
- Keep block-disk SSD L2 on by default even when paged RAM cache is off.
  Bind the visible Settings toggle to block-disk L2, not the deprecated
  legacy disk cache, and preserve explicit user Off through memory-safety
  resolution.
- Expose the exact last TurboQuant cache-class transition per loaded model in
  `/admin/cache-stats` so the app can distinguish 8 converted full-attention
  KV layers from 40 preserved rotating SWA layers.
- Preserve the vMLX type-selective contract: explicit TQ converts only real
  `KVCacheSimple` full-attention layers. Rotating, DeepseekV4, Mamba,
  Arrays/CCA, and composite companion caches remain native; a hybrid prefix
  hit without matching companion state must be rejected and rederived rather
  than blanket-encoded or reported as reusable.

No parser, tool schema, content-delta streaming, AppleScript, Sentry,
MLXPress, Bonsai, or automatic model-routing implementation is changed here.

## Current evidence

| Gate | Evidence | Status |
|---|---|---|
| Four-pin equality | Manifest, package resolution, app workspace resolution, and root workspace resolution all name `bbc0b20d...` | VERIFIED-SOURCE |
| Default cache policy | Focused persistence/default tests show prefix on, paged off, block-disk L2 on, legacy disk off, engine-selected codec retained; vMLX resolves that codec to native KV | VERIFIED-SOURCE |
| Explicit Off | vMLX focused regression preserves block-disk Off with prefix on and paged off through memory-safety resolution | VERIFIED-SOURCE |
| Explicit TurboQuant | Osaurus policy test resolves explicit bit widths to `turbo(k,v)` while engine-selected remains native | VERIFIED-SOURCE |
| Exact transition telemetry | vMLX transition suite 3/3 plus Osaurus admin JSON shaping 1/1 report 48 layers before/after, 8 KV to 8 TQ, 40 rotating preserved | VERIFIED-SOURCE |
| Current Release artifact | `/private/tmp/osaurus-gemma4-bbc0-release-derived/Build/Products/Release/osaurus.app`; isolated bundle id `com.dinoki.osaurus.gemma4proofbbc0`; executable SHA-256 `7b26f98a6d3ae9ddec53357972abebed93829b81ce62b51cb04d4c8392651943`; exact vMLX pin `bbc0b20d...` | VERIFIED-LIVE |
| Current settings defaults | Fresh UI and restored-final UI visibly showed prefix on, paged off, SSD L2 on, Codec Engine Selected, SSM rederive on, Safe Auto, MLXPress off. Endpoint agreed: native fp16, paged false, disk true, TQ transition null | VERIFIED-LIVE |
| Current explicit SSD Off | Settings saved SSD Off; visible `DISK-OFF-CURRENT-2846` at 41.4 tok/s; endpoint block disk false and all disk/paged counters zero | VERIFIED-LIVE |
| Current JANG_4M native/TQ UI | Native `NATIVE-COLD-6724` 36.8 tok/s; partial `NATIVE-PARTIAL-9381` 41.7 tok/s; TQ eight CACHE lines 55.2 tok/s; restart RESTORE lines 52.8 tok/s; exact 8-to-8/40 transition | VERIFIED-LIVE |
| Current MXFP8 native/TQ UI | Native `MXFP8-NATIVE-COLD-7412` 31.9 tok/s; TQ eight lines 38.0 tok/s; restart/partial RESTORE lines 36.7 tok/s; restored-default `MXFP8-DEFAULT-RESTORED-9021` 32.0 tok/s; exact 8-to-8/40 transition | VERIFIED-LIVE |
| Current SSD-only restart/partial reuse | JANG after restart: disk hits 2/misses 11/stores 3; MXFP8 after restart: hits 2/misses 13/stores 3. Paged hits/misses stayed zero; both changed-prefix outputs remained coherent | VERIFIED-LIVE |
| Current paged incompatibility truth | Explicit UI paged On on Gemma yielded requested true but effective `paged_cache.enabled=false`, `is_paged_incompatible=true`, zero paged hits/misses; SSD remained active | VERIFIED-LIVE |
| Current RAM refusal/override | Strict custom 10% visibly refused the 31B JANG_4M at a 12.8 GiB budget. No Automatic Limits then loaded the same model and emitted `RAM-OVERRIDE-3179` at 12.2 tok/s. Endpoint: automatic limits disabled, estimated working set 30.9 GiB, allowed true. Safe Auto restored | VERIFIED-LIVE for control behavior |
| Current Activity Monitor footprint | Exact proof executable: 31B main Memory 28.37 GB; inspector Real 19.30 GB, Private 996 MB. Bundle is 25G on disk (25,926,564 KiB), so the main Memory column fails the low-footprint gate | FAILED-LIVE |

## Current-build live matrix

| Row | Result |
|---|---|
| Isolated artifact and exact pin | VERIFIED-LIVE |
| Fresh/restored defaults | VERIFIED-LIVE |
| Explicit SSD Off | VERIFIED-LIVE |
| SSD on with paged off | VERIFIED-LIVE on JANG_4M and MXFP8 |
| Full/partial fresh-process L2 reuse | VERIFIED-LIVE on JANG_4M and MXFP8 |
| Selective TQ4/4 mixed-SWA conversion | VERIFIED-LIVE on JANG_4M and MXFP8 |
| Return to Engine Selected/native | VERIFIED-LIVE |
| Strict refusal and No-Limits next-load override | VERIFIED-LIVE |
| 31B low Activity Monitor footprint | FAILED-LIVE |
| Long rotating-window sentinel | OPEN |
| Ten-turn coherence | OPEN |
| Tool/parser continuation with TQ off/on | OPEN |
| Stream/non-stream protocol parity | OPEN |
| Cancel/preload cleanup | OPEN |

Gemma's rotating cache topology is paged-incompatible in the pinned runtime.
An explicit paged request must therefore report its effective state truthfully
instead of fabricating paged hits. SSD L2 restore remains independently usable
with paged RAM off.

## Wider cache campaign retained after this checkpoint

- Qwen 3.5/3.5 VL, Ornith, Bonsai, Nemotron, and other hybrid SSM/GDN/GLA
  families: TurboQuant off/on for eligible full-attention KV only, partial
  SSD-only reuse, typed native companion-state synchronization/rederive, VL
  media salt, multi-turn coherence, TTFT/tok/s, and physical footprint.
  Detached async rederive is not accepted as a replacement for safe
  prompt-boundary synchronization.
- LFM and MiniMax M2.7: TurboQuant off/on, paged eviction where supported,
  partial SSD reuse, multi-turn coherence, TTFT/tok/s, and footprint.
- DSV4 Flash and OpenPangu must remain hard-excluded from TurboQuant KV even
  under explicit user opt-in until their typed native cache paths have
  separate source and live proof. DSV4/ZAYA/MiniMax-M3 composite-cache
  behavior must not be inferred from Gemma.
- JANGTQ/MXTQ weight correctness remains separate from TurboQuant KV-cache
  encoding.

No row is merge-ready from a setting value, source inspection, or aggregate
counter alone. Current-build UI and matching runtime telemetry are mandatory.

## Current-source focused tests

With the Xcode 26 toolchain selected, 5/5 focused Osaurus assertions passed:
admin JSON mixed-topology shaping, all four exact vMLX pin checks, legacy
settings repair without enabling TQ, per-engine resolved-key diagnostics, and
the shared image-bridge contract's pin-only assertion. The latter contains no
image-runtime behavior change in this diff.
