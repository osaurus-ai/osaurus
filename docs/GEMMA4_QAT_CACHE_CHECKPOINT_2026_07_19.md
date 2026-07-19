# Gemma 4 QAT cache checkpoint — 2026-07-19

Status: **PARTIAL — source contracts and the prior pinned Release app are
verified; the current Osaurus pin/settings patch still needs an isolated
Release rebuild and live UI repeat before merge.**

This checkpoint uses only the locally installed Gemma 4 12B MXFP8 and
JANG_4M bundles under `~/models`. MXFP4 is not a substitute artifact and is
not part of this checkpoint.

## Scoped changes

- Pin all four Osaurus SwiftPM resolution points to vMLX
  `86f8634d85fdbf228f2981645f1d3b0a7fb1dacd`.
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

No parser, tool schema, content-delta streaming, AppleScript, Sentry,
MLXPress, Bonsai, or automatic model-routing implementation is changed here.

## Current evidence

| Gate | Evidence | Status |
|---|---|---|
| Four-pin equality | Manifest, package resolution, app workspace resolution, and root workspace resolution all name `86f8634d...` | VERIFIED-SOURCE |
| Default cache policy | Focused persistence/default tests show prefix on, paged off, block-disk L2 on, legacy disk off, engine-selected codec retained; vMLX resolves that codec to native KV | VERIFIED-SOURCE |
| Explicit Off | vMLX focused regression preserves block-disk Off with prefix on and paged off through memory-safety resolution | VERIFIED-SOURCE |
| Explicit TurboQuant | Osaurus policy test resolves explicit bit widths to `turbo(k,v)` while engine-selected remains native | VERIFIED-SOURCE |
| Exact transition telemetry | vMLX transition suite 3/3 plus Osaurus admin JSON shaping 1/1 report 48 layers before/after, 8 KV to 8 TQ, 40 rotating preserved | VERIFIED-SOURCE |
| Prior JANG_4M native/TQ UI | Exact visible codes, 39.1/41.4 tok/s native and 34.3/32.5 tok/s TQ; cold/partial SSD hits; exact 8-to-8/40 transition | VERIFIED-LIVE on prior pin `718522bc` |
| Prior MXFP8 native/TQ UI | Exact visible codes, 32.0/31.7 tok/s native and 28.1/26.1 tok/s TQ; cold/partial SSD hits; exact 8-to-8/40 transition | VERIFIED-LIVE on prior pin `718522bc` |
| Current pin UI | Fresh isolated Release app, visible settings toggles, endpoint counters, coherent restart continuation, tok/s, and Activity Monitor footprint | OPEN |

## Current-build live matrix

- Fresh isolated bundle ID, preferences root, files root, and SSD cache root.
- Settings defaults visibly show paged RAM off, engine-selected/native cache,
  and SSD L2 on.
- Endpoint agrees: paged false, block-disk true, legacy disk false, native
  live codec, null TurboQuant transition before explicit opt-in.
- Turn SSD L2 off in Settings, save, restart/load, and prove zero disk
  hits/stores plus no new cache artifacts in the isolated root.
- Turn SSD L2 back on, save, restart/load, generate a unique sentinel, quit,
  relaunch, and prove full and partial longest-prefix disk hits with coherent
  exact continuation while paged stays off.
- Enable explicit TurboQuant 4/4 and prove the live transition converts only
  8 full-attention KV layers while preserving all 40 rotating SWA layers.
- Return to Native and prove transition null/TQ-layer count zero.
- Exercise the visible RAM-safety refusal and No Automatic Limits override on
  the next real load, then restore Safe Auto.
- Inspect the exact proof process and executable path in Activity Monitor and
  record physical footprint, TTFT, tok/s, visible answer, and no loop/marker
  leakage.

Gemma's rotating cache topology is paged-incompatible in the pinned runtime.
An explicit paged request must therefore report its effective state truthfully
instead of fabricating paged hits. SSD L2 restore remains independently usable
with paged RAM off.

## Wider cache campaign retained after this checkpoint

- Qwen 3.5/3.5 VL, Ornith, Bonsai, Nemotron, and other hybrid SSM/GDN/GLA
  families: TurboQuant off/on, partial SSD-only reuse, typed companion-state
  sync/async rederive, VL media salt, multi-turn coherence, TTFT/tok/s, and
  physical footprint.
- LFM and MiniMax M2.7: TurboQuant off/on, paged eviction where supported,
  partial SSD reuse, multi-turn coherence, TTFT/tok/s, and footprint.
- DSV4/ZAYA/MiniMax-M3 native composite-cache exceptions remain separate and
  must not be inferred from Gemma proof.
- JANGTQ/MXTQ weight correctness remains separate from TurboQuant KV-cache
  encoding.

No row is merge-ready from a setting value, source inspection, or aggregate
counter alone. Current-build UI and matching runtime telemetry are mandatory.
