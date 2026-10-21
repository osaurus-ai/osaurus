# Ornith DFlash2 adaptive runtime audit

Status: draft; fixed-app qualification pending. No release/tag/model upload.

This pin consumes engine c73225e9f: dynamically sized GDN tree verification (fixes a reproduced app warm-up crash at32rows), DFlash2 canonical checkpoint ownership/early SSD handoff, and selected-strategy native-head loading.

The app passes the same model directory to load and strategy resolution. A compatible DFlash2/DSpark drafter takes precedence over native MTP without also loading the unused native head. Existing native selection remains for bundles without a compatible drafter; Off disables speculative execution.

On (Adaptive) now clears the legacy external fixed block size on the same settings persistence/API/import path that already removes native depth caps. The selected drafter path is preserved. Explicit fixed-width diagnostics remain available in the engine, not in the app's adaptive product mode.

## Evidence and remaining proof

Baseline production app sources match main055f071 and engine5bbcaf8. Two UI-triggered Ornith122B4M sends terminate during the load warm-up with SIGTRAP at Qwen35.swift:1207 (the old16-row tree precondition). No visible answer and no completion tok/s: failed rows.

Engine focused kernel/caching tests pass; full results and known unrelated cache-size test failure are recorded in the engine PR. These do not replace a rebuilt app.

Pending: fresh app load, clean visible multi-turn answer, Off/Adaptive setting and effective strategy, matched easy-code/prose throughput, SSD restore/write and terminal latency, physical footprint versus MLX active/cache, JANGH2, real media, delegated/concurrent requests and cancellation. No universal speedup or all-family RAM claim.

Private artifacts and command/identity ledger: ~/vmlx-private-evidence/ornith-dflash2-adaptive-20261020/LEDGER.md.

Engine pin updated to 260ad6187: same-path drafter load coalescing and eviction-safe publication; terminal aggregate adaptive timing diagnostics. The app diagnostic log now records resolved strategy and the constructed model's nativeMTPAvailable property, so selected strategy is not confused with a loaded unused head. Earlier c73225e9f app completed two visible adaptive turns with SSD restore and settled writes; exact new-head app proof remains pending.
