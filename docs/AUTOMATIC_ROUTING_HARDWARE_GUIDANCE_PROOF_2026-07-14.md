# Automatic Routing and Hardware Guidance Proof Ledger

Started: 2026-07-14 (America/Los_Angeles)
Last updated: 2026-07-15 (America/Los_Angeles)

This PR has two product goals plus one settings-truth requirement. A row becomes `CONFIRMED` only when the
source trace, automated coverage, and live verification named below all exist.
Source inspection or unit tests without final-app behavior remain `PARTIAL`.

## Scope

| Goal | Product contract | Current status |
| --- | --- | --- |
| Better automatic model routing | Agents can explicitly choose `Automatic (on device)`. The persisted sentinel resolves to a concrete installed on-device chat model that has a compatible hardware verdict. Normal turns keep the current safe route for cache locality; media turns can upgrade before send. Automatic never chooses a cloud provider or a tight, too-large, unknown, embedding, AppleScript-only, image-generation, or non-MLX route. Manual model selection exits Automatic. | PARTIAL — source, focused tests, explicit UI selection, and three-turn text-route proof exist; real-media upgrade and a live connected-provider boundary remain unverified |
| Clearer hardware guidance | Model selection surfaces distinguish physical unified memory from the smaller recommended local-model working-set budget. Picker rows, model detail, onboarding, download status, and agent settings use the same `GPUMemoryBudget` verdict as routing, and state that current free RAM is checked again at load time. | PARTIAL — source, focused tests, model picker, and agent-settings UI agree; onboarding/download surfaces were not operated in this proof |
| Memory Safety settings are truthful | UI preview, `/admin/cache-stats`, cache construction, and actual model loads use one Osaurus resolver. `No Automatic Limits (Dangerous)` removes mode-derived load, allocator, prefix, KV, concurrency, chat-send, materialized-load-refusal, flexible-eviction, and prefix-store percentage caps when the corresponding advanced fields are blank. Explicit user overrides remain in force; physical/Metal guidance remains visible, and engine/platform allocation failures are still possible. | CONFIRMED — source, 89 focused runtime-policy tests, Release UI mode toggles, persisted values, diagnostics, and subsequent Safe Auto model loads agree |

## Scope guard

- No model-family parser, template, sampler, generation-config, content-delta,
  or tool-JSON behavior changes belong in this PR.
- MXFP4 is not installed and is not a test target. The only Gemma controls are
  the installed MXFP8 and JANG_4M bundles. If the reported Gemma behavior does
  not reproduce in those controls, this PR makes no Gemma behavior change.
- The PR must not infer a fixed user RAM size. Host UI and routing read current
  `ProcessInfo.physicalMemory` plus Metal's advertised working-set value; tests
  use explicit synthetic values only where they are testing pure policy math.

## Required proof matrix

| Row | Source/automated evidence required | Live evidence required | Status |
| --- | --- | --- | --- |
| Text route | Policy tests exclude remote and unsafe candidates, choose the strongest compatible local route, and preserve the persisted Automatic sentinel | Fresh isolated app shows `Auto → <concrete model>` and returns a coherent answer | CONFIRMED — agent setting saved `Automatic (on device)`; chat displayed `Auto → OsaurusAI Gemma 4 12B it qat JANG_4M` and stayed local |
| Multi-turn stability | Policy test proves a current compatible route wins over a gratuitous stronger switch | At least three related turns stay on the same route and produce coherent answers without raw protocol markers | CONFIRMED — three related Jupiter turns stayed on the same JANG_4M route at 64.2, 39.8, and 69.7 tok/s |
| Media upgrade | Policy and composer tests prove only modalities with a concrete compatible local route are advertised, and send-time resolution happens before request construction | Attach real supported media in the isolated app; observe the route upgrade and a concrete media-grounded answer. If this Mac has no safe media route, verify the control is honestly absent/rejected instead | NOT YET VERIFIED |
| No-cloud boundary | Policy tests include connected remote candidates and prove none can win Automatic | With a connected provider visible in the picker, Automatic still names an on-device route and records no remote request | NOT YET VERIFIED |
| Hardware wording | Formatting tests pin unified-memory, recommended-budget, estimated-working-set, and fit wording to `GPUMemoryBudget` | Visually inspect agent settings, local model picker, model detail/onboarding or download status; displayed numbers must agree across surfaces | PARTIAL — picker and agent settings both showed 128 GB unified memory, 107.5 GB recommended budget, current-free-memory recheck wording, and identical per-model working sets; onboarding/download UI not operated |
| Settings persistence | Store tests pin mode/slider round-trip, legacy implicit prefix-cap migration, true unlimited resolution, explicit-override preservation, and the no-limit switch used by Osaurus-owned gates | Change Safe Auto -> No Automatic Limits -> Safe Auto in the isolated app; save/reload each state and compare the visible resolved plan with `/admin/cache-stats.memory_safety` | CONFIRMED — clean Settings entry stayed saved, No Automatic Limits saved with null KV/concurrency and unlimited load/allocator, then Safe Auto restored 70%/128 MB/65,536/1 in both UI and diagnostics |
| Runtime setting effect | Source trace must show the same resolver feeding settings preview, diagnostics JSON, cache construction, `loadContainer` configuration, chat send severity, materialized-load refusal, flexible residency, and prefix-store policy | Unload between modes, load an installed control model, and observe the resolved load/allocator/KV/prefix/concurrency values change in diagnostics; no stale next-load-only state | CONFIRMED — the isolated app loaded JANG_4M while unlimited mode was active, then loaded Bonsai and JANG_4M after Safe Auto was restored; diagnostics reflected the active plan in each phase |
| Runtime safety | Existing current-free-RAM/load-pressure telemetry remains visible; this PR does not change sampler defaults, model generation config, parser behavior, or model templates | Monitor the selected local model load and generation for responsiveness and physical footprint; no beachball or hidden cloud fallback | PARTIAL — app remained responsive and routes stayed local, but the JANG_4M low-RAM row failed at 9,847-9,855 MB footprint against 10,135,442,741 weight bytes |

## Current execution status

- Branch `codex/auto-routing-hardware-guidance` is rebased directly onto merged
  Osaurus `main` at PR #2041 (`eaba91d05`).
- The cold SwiftPM command compiled and emitted `OsaurusCore`, then the SwiftPM
  test target stopped at the known configuration error `no such module
  'Testing'`. This is compile-only partial evidence, not a test pass.
- Both focused Xcode runs passed and executed their requested tests: routing,
  chat selection, hardware guidance, settings migration/resolution, agent,
  image, warmup, picker, model scan, and runtime-policy suites.
- After the exhaustive Memory Safety trace found the remaining chat-send,
  materialized-load-refusal, flexible-eviction, and prefix-store gaps, the
  OsaurusCore SwiftPM build completed again. Focused Xcode routing, hardware,
  settings, RAM-feasibility, and warmup tests passed. The first runtime-policy
  source run found two stale exact-string assertions after a function signature
  changed; after making those assertions signature-tolerant, the complete
  89-test `RuntimePolicySourceTests` suite passed serially. The final rerun also
  covers the Settings-opening concurrency regression and has 89 passed, 0
  failed, 0 skipped:
  `/tmp/osaurus-routing-guidance-derived/Logs/Test/Test-OsaurusCoreTests-2026.07.15_19-28-46--0700.xcresult`.
- The full parallel OsaurusCore scheme is not green: 6,005 passed, 20 skipped,
  and 11 failed under shared global-state/timing contention. A serial rerun of
  all failing suites passed every failure except the local Gemma tokenizer
  assertion at `SwiftTransformersTokenizerLoaderTests.swift:701`. That test
  expects `capabilities_discover` in the Default-agent schema, while the current
  Default-agent source contract explicitly excludes discovery and exposes the
  consolidated `osaurus_*` configuration surface directly. This is a
  source-template control failure, not live inference evidence, and this PR has
  not changed either side of that contract.
- The final source used an isolated Release app at
  `/tmp/osaurus-routing-guidance-release/Build/Products/Release/osaurus.app`,
  ad-hoc signed under `com.dinoki.osaurus.routingguidanceproof`, with isolated
  files and UserDefaults. Merely opening Settings no longer wrote the visible
  concurrency fallback of `1` into an unset advanced override.

## Live inference controls and residuals

No Gemma MXFP4 bundle was loaded or tested.

| Control | Live Release-app result | Verdict |
| --- | --- | --- |
| `OsaurusAI/OsaurusAI--gemma-4-12B-it-MXFP8` | Thinking was toggled on then off in the UI and persisted as `disableThinking=true`. The exact `CEST` `invalid_args` tool error was shown in the tool card, followed by a successful `Europe/Berlin` retry and coherent answer. TTFT 0.63 s, 41.9 tok/s, 34 tokens; post-run footprint 5,132 MB. | PASS for the reported tool-error/streaming loop control; no protocol-marker loop or leak observed |
| `OsaurusAI/OsaurusAI--gemma-4-12B-it-qat-JANG_4M` | Thinking was toggled on then off and persisted. The same `CEST` failure recovered successfully at TTFT 0.51 s, 55.6 tok/s, 34 tokens. A later Safe Auto plain-text load answered at 64.2 tok/s. Cache topology was 48 layers, 8 KV, 40 rotating, disk-backed restore, TurboQuant-KV layer count 0, effective KV fp16, paged off. | PASS for the reported tool-error/streaming loop control; FAIL for the repo low-RAM gate because Safe Auto footprint remained about full weight size |
| `dealign.ai/Bonsai-27b-1bit-JANG-CRACK` | Safe Auto, 64 layers with 16 KV and 48 Mamba layers, SSM companion hits, disk-backed restore, paged off, 4,666,222,032 weight bytes. First turn was coherent at 48.7 tok/s. With Thinking on, a simple recall consumed 2,380 tokens at 28.7 tok/s without a final answer before stop. After toggling Thinking off and confirming `disableThinking=true`, the same recall answered coherently in 28 tokens at 59.2 tok/s; footprint fell to 2,596 MB. | PASS for real-user Thinking-off multi-turn/speed/RAM; FAIL for the adjacent Thinking-on verbosity/no-final-answer row |

The two installed Gemma controls did not reproduce the MXFP4 report's
post-tool-error protocol-marker loop. Per the scope guard, this narrows the
report to the untested MXFP4 bundle or another condition absent from both
controls and does not justify a shared content-delta, tool-schema, parser,
template, sampler, or generation-config change.

## Final scope audit

- Production additions contain no `Gemma`, `Bonsai`, `Qwen`, or `JANG`
  model-specific branches.
- Production additions contain no MXFP4, parser, template, sampler,
  content-delta, tool-JSON, or generation-config behavior changes.
- The branch is a follow-up to already-merged PR #2041. It contains automatic
  on-device routing, shared hardware-budget guidance, truthful Memory Safety
  resolution/wiring, their UI surfaces, tests, and this ledger only.

## Merge gate

Before merge: commit the final concurrency regression, rerun the scoped tests,
push, open a separate follow-up PR, and require its CI. Media upgrade and a live
connected-provider boundary remain PARTIAL and must not be described as live
verified. The JANG_4M low-RAM failure and Bonsai Thinking-on failure are
recorded residuals rather than silently reclassified as passes. The sidebar
layout report and all other community issues are explicitly outside this PR.
