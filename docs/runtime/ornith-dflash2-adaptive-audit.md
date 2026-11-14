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

Engine c2b025e2f corrects routed Qwen tree target-verification arithmetic. Actual Ornith4M and JANGH2 each pass104/104 exact rows and six exact post-commit next-token checks at widths4/16/32 (chain and branching). Scope6/6 and kernel11/11 tests pass. This supersedes the earlier engine pin; earlier app speed numbers do not qualify this corrected path. Exact-head app build/live proof is next. See engine PR627 and its runtime audit for details and the explicit temporary branch-copy cost.

## Current live results and follow-up pin

Current qualification receipts are from engine c2b025e2f / app16e80d09. Default selected DFlash2, unused native head remained unloaded, and Off selected ordinary decoding. Connected tool and13.8k recall turns answered correctly; the recall restored4,120 tokens, prefilling9,661 new tokens at666.7 tokens/s. The492MB checkpoint settled in53ms; physical peak8.04GB. Real image recognition succeeded but discarded the text prefix and reprocessed14,563 tokens. Source and tests, not yet a rebuilt app, now correct that defect in engine510e62774.

This pin consumes that media-boundary fix and opt-in chooser decision-cost diagnostics. Settings help now describes compatible model-specific DFlash2/DSpark discovery instead of incorrectly restricting it to Qwen27B. The existing27B download link is labeled specifically. All four new strings have translations in every shipped locale; i18n check passes.

A single sampled prose pair remains slower with Auto (24.61 vs26.86 app tokens/s, different sampled lengths). No universal speedup claim. Existing Qwen27B/Uno/fusion/clock research is indexed in the private SPEED-TRANSFER-MAP.md; no fixed depth or sampler change was made. Rebuilt media proof,128k, JANGH2 app performance and delegation remain open. PR stays draft.


## Current Release app checkpoint: 130k and adaptive decision audit

This section supersedes the earlier pending media/128k statements. Runtime source is engine `510e62774` / app `9962f6ec`; Release binary SHA256 is `06dd85a863a98f610fd0cefcac1a69df0fc2be2199d88d5ab0a6ae757a5f1880`. Later documentation-only commits do not change that binary.

The connected JANG_4M chat reached 130,343 prompt tokens. It restored 128,867 tokens and prefixed only 1,476 new tokens at 419.8 tokens/s. Final recall answered all three requested facts correctly, with a visible final answer and normal stop. App TTFT was 8.541 s and app decode 18.84 tokens/s. This is a long-context correctness/cache result, not a speedup over AR.

The new-head continuation scored 11/12 valid turns: seven ledger lookups, two calculator turns, real video and final recall passed. The second image OCR returned `HARBO` rather than `HARBOR 7`; it remains a failure. A video attempt without an actual attachment is recorded as an invalid harness row, not a model result. A separate background 256-token length-stop is retained in raw evidence and excluded from completed chat answers.

The image turn now restored 14,562/14,769 tokens; the video turn restored 25,854/26,899. At 130k, physical footprint peaked at 13.21 GB and ended at 5.26 GB. The 3,356,934,920-byte checkpoint published in 578 ms, enqueue took 1.1 ms, and terminal lease wait was zero. No iterator checkpoints remained at decode end. These writer timings describe filesystem publication, not fsync-qualified device bandwidth. MLX active includes mapped allocations; neither it nor physical footprint alone proves small-Mac fit. The current app CI passed all required checks (run 39541476022).

### Reusing earlier speed research

- Qwen27B narrow-row weight sharing is a measured dense-model lead, not evidence that routed Ornith gains the same amount. Preserve row-exact logits, recurrent commits and no duplicate weight layouts when evaluating a port.
- Existing matched Lithos GDN megakernel and Swift chain-prefetch experiments were neutral or slower in complete rounds. Do not rerun them solely because target-only or Python timings look better.
- Uno clock tracking, context buckets and winning-probe behavior are useful designs to examine. Its causal acceptance replay is not valid for a bidirectional block-diffusion drafter, whose candidates change with width.
- Ornith tree verification presently feeds path length and total tree rows into a shared chain-position acceptance estimator. Whether that misprices widths is an open model-fit question. Do not assume acceptance alone establishes throughput.
- Keep per-request adaptive decisions, kernel time, host synchronization, app delivery time, GPU power/clock and SSD publication separate. Never normalize the whole result linearly by MHz.

A clean diagnostic app pair on the current binary gave Default/Adaptive prose **30.93 tok/s** versus UI Off **33.40 tok/s** (832 vs 925 sampled output tokens). Decode GPU clock medians were 1,424 vs 1,425 MHz, with nominal thermals. Default spent 24.069 s in AR, 2.534 s in verification and 0.192 s drafting. It correctly falls back to AR, but exploration still costs time. This is not an always-faster-than-AR result. Per-cycle chooser tracing was enabled; no forced depth or sampler/seed change was used.

One preceding CPU-sampled run is excluded from speed qualification: sampling stalled an AR burst and moved its cost estimate from 30.3 to 74.1 ms/token. The inherited harness also joined GPU samples by time-of-day across several days; those summary clock fields are invalid. The corrected private report selects the current day's ordered log segment, and new runs record byte-bounded per-turn GPU slices. Neither measurement defect was used to tune product policy.

Private evidence: `ornith-dflash2-adaptive-20261020/connected-results.json`, `chooser-live/current-speed.json`, `chooser-live/gpu-current-day-identity.json`, `LEDGER.md`, `SPEED-TRANSFER-MAP.md`; raw app/footprint/UI receipts under `ornith122b-claude-20261019/turns/DF2-G04-image2` through `DF2-G16-recall`, and `DF4-chooser-prose-clean` / `DF5-prose-off`.

Still open: JANGH2 app and 128k qualification, delegated/concurrent requests and Off propagation, cancellation, active-chat protection under full quota, cross-family checkpoint ownership, and prose/code performance. No release or all-family/always-faster claim.


Latest pin: `78203b791cca6ef845b67c37220a6c7e79a774f3`. This adds the routed-bank lane classification correction discovered in the real JANGH2 app run: opaque experts are not lane-backed, so adaptive selection must retain its narrow candidate. The dense Qwen27B classification remains intact. Sixteen focused tests pass, with a captured pre-fix failure. Also corrects AR expected-token trace formatting; no sampler, seed, weight layout or kernel change. Rebuilt-app verification of this pin is pending; previous live receipts identify their older source explicitly.
