# Gemma 4 QAT cache checkpoint — 2026-07-19

## 2026-07-20 explicit mixed-SWA paged-cache checkpoint

Status: **PARTIAL overall; VERIFIED-LIVE for the exact JANG_4M settings,
native/TurboQuant mixed-cache, bounded paged-RAM, eviction, and fresh-process
SSD rows below. The strict low-physical-footprint gate failed, so this branch
is not described as release-ready.**

This run used Osaurus base `4e29c0eb67c75f0892934aa7c629ced434bb12c0`
and vMLX `db39150bc353cfd2df1bd50d796272424037c8bb`. The isolated
Release app was copied to
`/private/tmp/Osaurus Gemma4 Paged Proof 20260720.app`, used bundle id
`com.dinoki.osaurus.gemma4pagedproof20260720`, executable SHA-256
`bc795f0b82a94c54920ce67b3e892a8ecae40f5168e764de7f7a6e52a62848b1`,
and used the keychain-free storage root
`/private/tmp/osaurus-gemma4-paged-explicit-proof-root-20260720-1219`.
Only `/Users/eric/models/OsaurusAI/OsaurusAI--gemma-4-12B-it-qat-JANG_4M`
was loaded. No MXFP4 model was loaded or used as substitute evidence.

### Current source trace

- All four Osaurus resolution points pin the same vMLX revision. The Osaurus
  runtime behavior change is limited to exposing
  `requires_paged_boundary_companion` in `/admin/cache-stats`; admission,
  companion ownership, eviction, and SSD fallback remain owned by vMLX.
- vMLX admits paged RAM only for the exact direct mix of
  `RotatingKVCache` plus full-attention `KVCacheSimple` or
  `TurboQuantKVCache`. Paged blocks contain only token-sliceable
  full-attention KV. An exact prompt-boundary leaf owns the rotating rings and
  their `(keep, maxSize, step, offset, idx)` metadata. A missing companion
  releases the probed paged blocks and falls through to typed SSD state.
- The ordinary default remains paged RAM off. TurboQuant remains explicit
  opt-in with explicit key/value widths. No model template, sampler, parser,
  content-delta stream, tool schema, routing, MLXPress, or Bonsai behavior is
  changed by this branch.

### Current Release UI evidence

| Row | Visible app evidence | Matching runtime evidence | Status |
|---|---|---|---|
| Fresh defaults | Server -> Settings -> Cache visibly showed Prefix On, GPU Cache Off, SSD Disk Cache On, Codec Engine Selected, and SSM re-derive On; chat showed Thinking Off | `paged_kv_enabled=false`, block-disk true, native fp16, 48 layers = 8 KV + 40 rotating, TQ layers 0, MLXPress disabled | VERIFIED-LIVE |
| Default native turn | Exact answer `NATIVE-DEFAULT-OFF-7319`; TTFT 1.25 s, 31.5 tok/s, 15 tokens | Paged false; SSD hits 2 / misses 4 / stores 4; companion required; bundle defaults temperature 1, top-k 64, top-p 0.95 | VERIFIED-LIVE |
| Explicit paged native | Settings visibly saved GPU Cache On with a 32-block cap. Exact answers `PAGED-NATIVE-PARTIAL-8426` and `PAGED-NATIVE-WARM-1957`; TTFT 1.63/0.61 s and 43.5/43.0 tok/s | Paged hits rose to 83, misses 4, and evictions 2; SSD hits 4 / misses 4 / stores 6; topology stayed 8 KV + 40 rotating | VERIFIED-LIVE |
| Paged native multi-turn ledger | A separate real-UI chat retained 180 numbered records. The first response returned exact first/middle/last values at TTFT 3.69 s and 41.4 tok/s; a second same-chat prompt returned three different exact values at TTFT 1.17 s and 41.2 tok/s | Native 8 KV + 40 rotating; paged hits 93 / misses 4; SSD hits 4 / misses 11 / stores 6; companion required; MLXPress disabled. The UI context estimate was only `~3.0k` including base context, so this is not promoted as a newly quantified >1,024-token semantic-ledger row | VERIFIED-LIVE multi-turn; long-window claim retained from prior 8,635-token row |
| TurboQuant validation | Selecting TurboQuant without widths visibly produced `TurboQuant KV requires explicit key and value bit widths`; entering 4/4 removed the error and saved | Settings reported `live_kv_codec=turboquant`, key/value bits 4/4; saving unloaded the prior model | VERIFIED-LIVE |
| Paged TQ4/4 cold/warm | Exact answers `PAGED-TQ44-COLD-6048` and `PAGED-TQ44-WARM-9173`; TTFT 3.75/0.85 s and 14.1/37.5 tok/s. The warm turn was visibly observed first as a partial content delta and then as the complete exact answer | Exact transition 8 native KV + 40 rotating to 8 TQ + 40 rotating; paged enabled with hits and SSD hit/store activity; MLXPress disabled | VERIFIED-LIVE |
| Fresh-process L2 plus paged | The exact app was quit, relaunched with the same isolated root, the prior chat was selected from History, and `TQ44-RESTART-L2-2864` completed at TTFT 0.79 s, 34.1 tok/s, 18 tokens | New PID 99553 loaded 8 TQ + 40 rotating; SSD hits 3 / misses 9 / stores 4 and paged hits 84 / misses 4 / evictions 2. Quitting removed the old process RAM tier; the focused vMLX test below establishes the causal eviction-to-SSD fallback contract | VERIFIED-LIVE for fresh-process disk and paged activity; causal fallback VERIFIED-SOURCE/UNIT |
| Defaults restored | The same UI visibly saved GPU Cache Off, Codec Engine Selected, and blank Max Blocks while retaining Prefix and SSD On. `DEFAULTS-RESTORED-NATIVE-4092` completed at TTFT 3.01 s, 42.1 tok/s, 19 tokens | Native fp16, 8 KV + 40 rotating, TQ layers 0, transition null, paged disabled, SSD hits 1 / misses 10 / stores 3, MLXPress disabled | VERIFIED-LIVE |
| Physical footprint | Activity Monitor visibly showed the exact proof PID 98028 at 9.38 GB after the native UI row | Runtime weights were 10,135,442,741 bytes; this is close to full dense-weight residency and is not a low-footprint pass | FAILED-LIVE |

The current Debug Xcode result at
`/private/tmp/osaurus-gemma4-focused-tests-derived/Logs/Test/Test-OsaurusCoreTests-2026.07.20_12-37-14--0700.xcresult`
records 94/94 passed, zero failed/skipped, for the complete
`RuntimePolicySourceTests` and `ImageGenerationBridgeContractTests` selections.
The isolated Release app build also exited zero before ad-hoc sealing and
strict signature verification.

The live counters prove that the user-facing settings reach the runtime and
that a fresh process uses both SSD and a newly populated bounded paged tier.
They do not alone assign each individual disk hit to a particular evicted RAM
leaf. That ownership is established by vMLX's exact
`gemmaMixedTurboQuantRotatingUsesPagedThenDiskAfterEviction` regression, which
forces the eviction, restores from SSD, appends the same suffix to both
rotating rings, and compares the temporally ordered KV. The missing-companion
regression separately proves safe SSD fallback rather than partial paged
restore.

## Current-main Gemma/Bonsai follow-up

Status: **PARTIAL overall; VERIFIED-LIVE for the narrow Gemma effective-cache
telemetry and Bonsai first-call chart rows described here.** The wider model,
RAM, cache-family, multimodal, AppleScript, Sentry, and protocol matrix remains
open and is not made release-ready by this follow-up.

Current source base is Osaurus `12396f7309e533f572098ddd8810c6229e3ebcb5`
with vMLX `0975201e745a1774fda1e78d1bc99b5bd1c668c6`. The isolated
Release artifact is
`/private/tmp/osaurus-main-gemma-bonsai-derived-20260719/Build/Products/Release/osaurus.app`,
bundle id `com.dinoki.osaurus.gemmabonsaimainproof`, executable SHA-256
`a341c6cd58e60f1cda3b675f0b764a287be976284f811cc69587d6f5726fd600`,
and runtime root
`/private/tmp/osaurus-main-gemma-bonsai-runtime-20260719-d`. The live process
environment was read back and matched that root with test keychain access
disabled. No MXFP4 bundle was loaded or used as evidence.

### Narrow source trace

- `HTTPHandler` now derives the admin `cache_topology`, effective KV-mode tag,
  and companion-cache checks from `last_turboquant_cache_transition.after`
  when present, with the container topology as the fallback. The container
  snapshot is the load-time shape; Gemma's request-local BatchEngine
  conversion is the live shape. Reporting the former after conversion produced
  the contradictory 8-FP16-KV/40-rotating top-level topology beside an
  8-TurboQuant-KV/40-rotating transition.
- `RenderChartTool` reconciles only an explicit CSV/TSV label whose declared
  delimiter yields one column for every sampled nonempty row while the other
  delimiter yields a stable multi-column table for every row. Ambiguous,
  mixed-delimiter, JSON, and ordinary strict-column failures retain the
  declared parsing path. This changes data-format metadata handling, not model
  output, prompts, templates, sampling, content-delta streaming, or tool-call
  JSON assembly.

### Current Release UI evidence

| Row | Exact live evidence | Status |
|---|---|---|
| Real-user model discovery | Settings -> Storage changed the external model folder through the macOS picker from `~/.cache/huggingface/hub` to `/Users/eric/models`; the visible count changed from 5 to 68 and the exact local targets became selectable without copying them | VERIFIED-LIVE |
| Cache defaults | Server -> Settings -> Cache visibly showed Prefix on, GPU/Paged KV off, SSD Disk Cache on, Codec `Engine Selected`, Stored KV Codec `Auto`, and SSM re-derive on | VERIFIED-LIVE |
| Gemma explicit TQ topology | Exact `/Users/eric/models/OsaurusAI/OsaurusAI--gemma-4-12B-it-qat-JANG_4M`; UI-selected TQ4/4 produced five coherent sentinel bullets at 59.3 tok/s, a coherent two-sentence follow-up at 64.8 tok/s, and a same-root restart answer at 63.3 tok/s | VERIFIED-LIVE |
| Gemma telemetry | Top-level admin topology and transition-after both reported 48 layers = 8 TurboQuant KV + 40 rotating KV, zero plain KV; `effective_kv_mode=turbo(4,4)`, paged false, disk enabled, MLXPress disabled | VERIFIED-LIVE |
| Gemma SSD restart | Before restart the row recorded disk hits 3, misses 10, stores 5; after relaunch, the identical prompt had TTFT 0.72s and fresh-process counters hits 2, misses 7, stores 3 with paged still false | VERIFIED-LIVE |
| Bonsai ordinary attached CSV | Exact `/Users/eric/models/dealign.ai/Bonsai-27b-1bit-JANG-CRACK`, Charts on, `disableThinking:true`; the first and only `render_chart` call emitted tab-delimited `month/revenue` data while declaring `dataFormat:"csv"`. It returned `ok:true`, rendered four bars, and the model returned exact `chart-skill-done` at TTFT 0.71s and 36.1 tok/s | VERIFIED-LIVE |
| Bonsai reasoning toggle | UI gray/off persisted `disableThinking:true`; a fresh exact-output turn returned `BONSAI-NOTHINK-907` at TTFT 1.01s and 37.3 tok/s. SQLite recorded zero reasoning characters. The final chart call and post-tool answer also recorded zero reasoning characters | VERIFIED-LIVE |
| Bonsai adversarial no-retry | A separate real-UI prompt required literal TSV data labeled CSV and forbade retry. One call returned `ok:true`, three parsed points, an inline chart card, and exact `adversarial-chart-done` | VERIFIED-LIVE |
| Bonsai current footprint | Activity Monitor visibly showed the exact proof process `Osaurus`, PID 87295, at 2.47 GB after the chart runs. A separate macOS `footprint` read reported 2,527 MB current and 5,587 MB peak; only the 2.47 GB current row is Activity Monitor visual evidence | VERIFIED-LIVE current; peak is direct telemetry |

The current focused Xcode invocation exited zero for both
`TurboQuantCacheTransitionShapingTests` cases and the complete
`RenderChartToolTests` suite. That includes the observed CSV-label/TSV-data
case, the reverse unambiguous case, and strict mixed-delimiter and misspelled-
column failures.

The pre-change captured Bonsai call was valid JSON and reached
`render_chart`; its arguments contained TSV rows with `format:"csv"`, so the
strict CSV parser exposed one header named `month\trevenue` and returned
`Column(s) not found`. The model then retried with comma CSV successfully.
That trace rules out content-delta truncation and malformed tool-call JSON for
this chart failure.

### Retained concerns and non-claims

- The Gemma L2 directory grew from 2.7 GB to 3.9 GB across the tested sequence.
  The in-memory TQ codec and Stored KV Codec `Auto` are separate controls; this
  row does **not** prove that SSD blocks are TurboQuant-compressed. Disk growth
  and eviction remain OPEN.
- The first Gemma multi-turn run also created an unsolicited markdown artifact
  before returning the requested answer. The requested answer was coherent,
  but that semantic over-action is not fixed or hidden here.
- Bonsai thinking-on runs were retained as diagnostics. The later verified-off
  runs show the toggle contract works; no output-stripping or forced closer was
  added.
- No broad automatic routing, hardware guidance, RAM-safety, multimodal,
  AppleScript, JANGTQ weight, DSV4/OpenPangu, or other model-family change is
  included in this narrow diff.

## Historical bbc0 checkpoint

Historical status: **PARTIAL — the exact then-current Osaurus branch and vMLX
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

## 2026-07-20 mmap-alignment and final pin proof

The four Osaurus SwiftPM locations now pin vMLX
`f2b184841e98d969e46dec83109f27cd7bb57357`, which embeds MLX
`a828cb4726f603d1cc9ac63359cd563865fdf8f6`. The MLX change preserves mmap for
aligned tensors in a safetensors shard and copies only dtype-unaligned tensors;
the vMLX change limits fp16/fp32 mmap dtype preservation to Gemma 4
`jang_affine`. No Osaurus model template, sampler, parser, content-delta
stream, tool schema, reasoning behavior, MLXPress policy, or automatic routing
implementation is changed.

The exact isolated Release app was
`/private/tmp/osaurus-gemma4-alignment-release-derived-20260720/Build/Products/Release/osaurus.app`,
bundle id `com.dinoki.osaurus.gemma4alignmentproof20260720`, executable
SHA-256 `61dbf6ddae5d4dded60e00aa383da3c69ec7683c096542f0db53906c2b48fa67`,
and keychain-free root
`/private/tmp/osaurus-gemma4-alignment-proof-root-20260720-1414`. No MXFP4
model was loaded.

| Gate | Current evidence | Status |
|---|---|---|
| Fresh/restored settings | Prefix On, GPU/Paged Off, SSD L2 On, Codec Engine Selected, SSM rederive On, Safe Auto, MLXPress Off; Thinking Off | VERIFIED-LIVE |
| JANG_4M native | Exact cold/follow-up outputs at 1.00/0.99 s TTFT and 37.6/37.5 tok/s | VERIFIED-LIVE |
| JANG_4M explicit TQ4/4 | Exact output at 4.31 s TTFT and 17.2 tok/s; Activity Monitor 6.84 GB | VERIFIED-LIVE correctness; explicit opt-in remains slower |
| JANG_4M explicit paged | Exact cold/warm outputs at 2.35/1.13 s TTFT and 37.6/37.3 tok/s; paged and SSD counters increased; defaults then visibly restored | VERIFIED-LIVE |
| 31B memory control | Strict custom 10% refused at 12.8 GB; visible No Automatic Limits loaded the same 31B model and returned exact output; Safe Auto restored | VERIFIED-LIVE |
| Final switch/reload | Fresh chat selected exact local 12B JANG_4M with Thinking Off, showed `Prefill 512/1887`, and returned exact `GEMMA4-FINAL-SWITCH-7735`; TTFT 2.27 s, 35.7 tok/s | VERIFIED-LIVE |
| Final 12B footprint | Activity Monitor PID 36563: 6.92 GB after generation versus 9.439 GiB bundle | VERIFIED-LIVE; current low-footprint row is below full bundle size |
| Pin contract tests | `/private/tmp/osaurus-gemma4-pin-contract-tests-20260720-1446.xcresult`: 94 passed, 0 failed, 0 skipped | VERIFIED-TEST |

The earlier CI failure at Osaurus head `84b7f7c3` was five stale source-contract
expectations that still named the preceding vMLX commit `db39150b`: four
package-resolution assertions and one runtime-policy assertion. The manifests
already resolved `f2b18484`. Updating only those five expected hashes makes the
same two selected suites pass 94/94 locally; no app runtime source changed.

One adjacent mixed-history probe is retained honestly: after many Gemma exact-
answer turns, switching that same chat to Ornith caused it to copy a prior
Gemma answer. Activity Monitor showed the 2.74 GB Ornith process, and the same
Ornith bundle answered a fresh chat coherently at TTFT 0.50 s and 70.1 tok/s
with unchanged cache settings and Thinking Off. This is not evidence of a
global cross-model KV collision, and this Gemma-only PR adds no guard for it.

## 2026-07-20 SSD partial-prefix, paged-eviction, and final-default proof

This proof used the same local Gemma 4 12B JANG_4M bundle and did not load,
download, infer from, or substitute an MXFP4 artifact. The exact isolated
Release app was
`/private/tmp/osaurus-gemma4-alignment-release-derived-20260720/Build/Products/Release/osaurus.app`,
bundle id `com.dinoki.osaurus.gemma4alignmentproof20260720`, executable
SHA-256 `d0f36260693d7d9c3b3a7691ebbf2c6667c4449467a405a9b9cd7ce03fce60b2`,
PID `75043`, and keychain-free root
`/private/tmp/osaurus-gemma4-alignment-proof-root-20260720-1414`.

The cache ownership trace at pinned vMLX `f2b18484` is explicit:

- `CacheCoordinator.fetch` tries paged RAM first, accepts a Gemma mixed-cache
  boundary only with its typed companion, then probes indexed SSD boundaries
  from longest to shortest before returning a cold miss
  (`CacheCoordinator.swift:398-403,456-562`).
- `PagedCacheManager` removes the prior hash and increments `evictions` when a
  fixed-pool block is reused, while `fetchPrefix` walks block hashes only until
  the first miss (`PagedCacheManager.swift:116-126,312-363`).
- `DiskCache` converts the visible GiB cap to bytes, stores and immediately
  applies the quota, obtains candidate token counts in descending order, and
  deletes the oldest indexed payloads until total bytes are under the cap
  (`DiskCache.swift:116-119,228-229,287-318,492-539`).
- Focused vMLX regressions prove an evicted paged prefix falls through to its
  persisted SSD record and that a fresh paged-off coordinator restores a
  partial hybrid prefix plus companion state
  (`CacheCoordinatorTopologyFocusedTests.swift:831-923`).
- Osaurus saves the entire cache settings value and clears loaded models when
  it changes (`ServerController.swift:326-379`); the next load builds the live
  coordinator from the resolved settings, including the user-selected disk
  directory/cap and host-aware ceiling (`ModelRuntime.swift:2380-2464,2491-2541`).

The Release UI was operated as a user. With paged RAM off and SSD L2 on,
`SSD-ENABLED-SEED-3303` returned exactly at 6.88 s TTFT and 35.8 tok/s. After
quitting and relaunching the isolated app, a changed continuation,
`SSD-RESTART-PARTIAL-3304`, returned exactly at 1.49 s TTFT and 35.8 tok/s;
Live Activity showed paged prefix `0 / 0` and SSD L2 `3 / 8 / 5`. This is the
paged-off, fresh-process, partial SSD-prefix row.

The UI was then changed to paged RAM On, block size 64, max blocks 100, SSD L2
On, and a 2.0 GB disk cap. An original ledger returned
`PAGED-OBS-SEED-5501` exactly at 1.54 s TTFT and 35.0 tok/s. A distinct long
ledger returned `PAGED-OBS-EVICTOR-5502` exactly at 1.47 s TTFT and 50.4 tok/s.
At that boundary Live Activity visibly showed prefix `442 / 6`, paged
evictions `53`, SSD L2 `5 / 9 / 8`, and TurboQuant compressions `0`. Returning
to the original ledger then produced the exact changed continuation
`PAGED-OBS-DISK-FALLBACK-5503` at 1.51 s TTFT and 35.8 tok/s. Live Activity
advanced to prefix `686 / 9`, paged evictions `106`, and SSD L2 `7 / 12 / 12`:
the request added 53 real paged evictions and two SSD hits before repopulating
the hot tier.

Immediately after that fallback row, while the 2.0 GB cap was still active and
before restoring defaults, the bounded SSD directory contained exactly three
current safetensors payloads of 569,918,297, 584,663,859, and 711,934,779 bytes
(about 1.738 GiB total), with matching SQLite rows at 7,106, 7,151, and 7,152
tokens. Older payloads from the same isolated root were absent. This is direct
file/index evidence that the visible 2.0 GB setting governed
eviction/replacement; counters alone are not used as that claim.

To make this behavior inspectable without a debugger, the current Osaurus
change carries vMLX `pagedStats.evictions` through `MLXBatchAdapter` into
`BatchDiagnosticsSnapshot` and displays `Paged evictions` in Server Settings
Live Activity. The focused current-source `RuntimePolicySourceTests` run under
the Xcode toolchain passed 92/92, and the exact Release app above built and
passed deep ad-hoc signature verification.

Finally, the same UI restored Prefix On, paged RAM Off, blank engine defaults
(64/1000), SSD L2 On with the blank 10 GB default, Codec Engine Selected,
SSM rederive On, and Thinking Off. The settings panel visibly reported
`Settings saved successfully` and unloaded the model. The resulting cold
default launch returned exactly:

```text
GEMMA4-DEFAULT-RESTORED-6601
PAGED=OFF TQ=OFF SSD=ON
```

at 1.29 s TTFT and 36.6 tok/s (31 tokens). Live Activity then showed
TurboQuant compressions `0`, prefix `0 / 0`, paged evictions `0`, and SSD L2
`2 / 3 / 4`, proving that the restored default launch kept paged RAM and
TurboQuant off while still using SSD L2. Activity Monitor visibly showed the
exact PID at 6.85 GB after generation, below the 9.439 GiB bundle.

After rebasing onto Osaurus `76c1f6ae` (the independently merged remote-tool
argument fix), the same arm64-only Release app was rebuilt, ad-hoc sealed, and
deep-signature verified. The new executable hash is the `d0f36260...` value
above and its embedded vMLX checkout remains exactly `f2b18484`. The Cache UI
again visibly showed the restored defaults, and a fresh chat with Thinking Off
returned exactly `GEMMA4-REBASED-DEFAULT-7701` and
`PAGED=OFF TQ=OFF SSD=ON` at 1.23 s TTFT and 36.9 tok/s (31 tokens). Live
Activity showed TurboQuant `0`, prefix `0 / 0`, paged evictions `0`, and SSD L2
`2 / 3 / 4`. Activity Monitor visibly identified rebuilt PID `85362` at
394.4 MB after that response. The rebase introduced no additional PR paths;
the remote-tool changes are part of the new main base, not this diff.
