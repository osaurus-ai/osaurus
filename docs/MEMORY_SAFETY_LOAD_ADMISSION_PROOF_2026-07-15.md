# Memory Safety Load Admission Proof — 2026-07-15

Status: PARTIAL overall. The focused source, automated-test, and isolated
Release-app UI matrix is complete. Commit, current-head CI, GitHub diff audit,
and merge are still pending.

## Scope

This branch starts at `eaba91d05d784348215bc4c940f23d4486e0a4c5`, the
merged Bonsai chart/hybrid-memory fix. It does not include PR #2044's automatic
model-routing or hardware-guidance feature.

The change is limited to the user-selected Memory Safety contract:

- pass a concrete, picker-equivalent request working-set estimate into the
  bundle-aware vMLX resolver before a cold load;
- enforce Strict/custom blocking issues before MLX/Metal allocation;
- make No Automatic Limits remove only implicit Osaurus caps while preserving
  explicit cache, concurrency, allocator, and physical-fraction overrides;
- expose the exact last cold-load decision in `/admin/cache-stats`;
- keep the visible refusal architecture-neutral instead of recommending an
  unproven cache codec;
- migrate the historical implicit 15% prefix cap once while preserving a
  later user-selected 15% value.

There is no content-delta, tool-schema, tool-output, reasoning-parser,
chat-template, sampler, generation-default, dependency-pin, model-selection,
or MXFP4-specific behavior change.

## Source trace

Before this change, `ModelRuntime.resolveMemorySafetyLoadPlan` always passed
`request: nil`; production cold loads could therefore never produce the
documented Strict/custom request-budget refusal. Blocking issues were logged as
advisory. The Settings UI and generic cache-stat plan could show a cap that the
real mmap load did not enforce.

The focused implementation now:

1. computes the same 1.25x chat working-set estimate used by the picker;
2. resolves bundle facts first to determine mmap versus materialized footprint;
3. supplies `VMLXMemoryRequestEstimate` for the actual cold load;
4. stores and exposes estimate, resolved budget, mmap choice, allow/refuse
   result, blocking issues, and timestamp;
5. throws a clear load error before the loading-task reservation when the
   selected policy refuses the request.

The generic `/admin/cache-stats.memory_safety.allowed` field still describes a
request-free settings plan. `last_load_decision.allowed` is the authoritative
field for the most recent real cold-load attempt.

## Current automated evidence

- Xcode result: `/tmp/osaurus-memory-admission-tests-final3.xcresult`
- Result: 144 passed, 0 failed, 0 skipped
- Localization catalogs parse; 2,508 Swift keys resolve; 0 suspect literals
- `git diff --check`: clean
- vMLX pin remains `1ca402953bf941341889bb00b186e46bf0c18d6f`

Focused coverage includes Strict request estimation, architecture-neutral error
text, No Automatic Limits send/load/eviction/cache-store behavior, explicit
advanced-override preservation, clearing the stale custom physical-load cap
when No Automatic Limits is selected, actual bundle-specific budget reporting,
last-load diagnostics wiring, historical prefix-cap migration, and later
explicit 15% preservation.

## Live verification environment

- App: `/tmp/osaurus-memory-admission-release/Build/Products/Release/osaurus.app`
- Bundle identifier: `com.dinoki.osaurus.memoryadmissionproof`
- Isolated root: `/tmp/osaurus-memory-admission-proof-root.ps0jny`
- Process: PID 96241, ad-hoc signed, keychain disabled, localhost port 1337
- Models root: `/Users/eric/models`
- Build source: this production-code diff on clean base
  `eaba91d05d784348215bc4c940f23d4486e0a4c5`
- Production-code diff SHA-256 at proof completion:
  `ec64c7f5a1ae1f1aa7e70c8861b59c2d801acc10ff03ff67615b950066ce5447`
- Model under proof: exact local `OsaurusAI  Gemma 4 12B it MXFP8`
  (`osaurusai--gemma-4-12b-it-mxfp8`), never MXFP4

All UI actions below were performed through the real app's model picker and
Settings > Server > Settings > Memory Safety controls with Thinking visibly
off. Runtime values came from the same process's `/admin/cache-stats` endpoint.

## Live verification matrix

| Row | Current live evidence | Status |
| --- | --- | --- |
| Strict refusal | Strict slider 3 with custom physical fraction 0.10; picker showed exact Gemma MXFP8 cold; visible refusal reported ~15.6 GB estimate over ~12.8 GB budget; `models=[]`; `last_load_decision.allowed=false`, estimate 16,700,329,790, budget 13,743,895,347, mmap true | PASS |
| User override | Selected No Automatic Limits in the real Settings UI; the stale 0.10 physical fraction cleared automatically; visible resolved settings showed Load/Allocator/KV unlimited and Concurrency 1; Save Changes succeeded | PASS |
| Cold load | Regenerated the same refused prompt without changing model; exact Gemma MXFP8 cold-loaded and visibly returned `MXFP8 admission toggle works.`; TTFT 3.62 s, 24.5 tok/s, 11 tokens; `allowed=true`, budget null, automatic limits disabled; footprint 3,431 MB, peak 4,450 MB | PASS |
| Warm multi-turn | Asked the resident model to repeat its prior exact sentence; visible grounded reply was exactly `MXFP8 admission toggle works.`; TTFT 0.64 s, 27.2 tok/s, 11 tokens; no loop, protocol marker, or hidden reasoning | PASS |
| Cache/topology truthfulness | Warm row reported block-disk hits 3, misses 5, stores 6; 8 global KV plus 40 rotating layers; disk-backed restore required; effective KV fp16 and `turbo_quant_kv_layer_count=0`; footprint 3,436 MB, peak 4,450 MB | PASS |
| Restored policy | Returned through the real Settings UI to Strict 0.10, saved, switched away to Bonsai and back to exact Gemma MXFP8; picker showed Gemma cold; visible refusal repeated; final telemetry again showed `models=[]`, allowed false, estimate 16,700,329,790, budget 13,743,895,347, mmap true | PASS |
| Model switch | Exact Bonsai 27b 1bit JANG CRACK became the sole resident model before selecting exact Gemma MXFP8; Gemma then appeared cold and its refused attempt left zero loaded models, proving the decision was not stale resident state | PASS |

No MXFP4 model is permitted in this proof lane. TurboQuant rotating/SWA,
prefix/L2 disk cache growth, Qwen 3.5 hybrid/VL, image generation/edit, and
spawn/delegation RAM behavior are separate unproven follow-up matrices recorded
on PR #2044; this focused PR does not claim them.

The live matrix above proves only this focused Memory Safety load-admission and
user-override contract. It does not make the broader follow-up rows verified.
