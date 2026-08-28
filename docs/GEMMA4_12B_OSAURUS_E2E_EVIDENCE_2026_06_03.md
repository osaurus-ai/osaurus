# Gemma 4 12B Osaurus E2E Evidence - 2026-06-03

This note records the current Gemma 4 12B merge-prep boundary for the
Osaurus PR branch `codex/gemma4-12b-vmlx-pin`.

## Source Boundary

- Osaurus pins `osaurus-ai/vmlx-swift` at
  `43e0e82d515eb3de480fcb18bc0a6f2430d18389`.
- The vMLX change is a Gemma4 required-tool prompt-contract hardening:
  the latest required-tool user turn no longer exposes raw multiline user
  prose as a competing copy target, and the required call shape explains that
  `\n` must remain the two-character escaped sequence inside `<|"|>`.
- This is not parser trimming, sampler forcing, repetition penalty tuning, or
  close-token biasing.
- vMLX `git diff --check` passed. The focused SwiftPM test could not run in
  the clean vMLX checkout because `Tests/MLXPressPolicyTests` fails to import
  `Testing` before the filtered Gemma4 test executes.

## No-Sign App Boundary

- App build path:
  `build/DerivedData-gemma4-12b-nosign-cec4ce1/Build/Products/Release/osaurus.app`
- Build log:
  `build/gemma4-nosign-rebuild-no-raw-required-user-20260603-143240.log`
- The log shows `BUILD SUCCEEDED`; the app has an ad-hoc signature and
  `TeamIdentifier=not set`.
- Launch path used `scripts/live-proof/open-keychain-free-osaurus.sh` with
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1` and `OSU_MODELS_DIR=/Users/eric/models`.

## Fresh Per-Model Required Tool Rows

Artifact root:
`/tmp/osaurus-gemma4-fresh-per-model-20260603-144111`

All three rows started from a fresh app/root with:

- `current_model: null`
- `loaded: []`
- empty `inflight`
- empty cache model list
- aggregate `disk_l2_hits: 0`

That means the remaining MXFP4 first-turn multiline failure is not caused by
prior chat memory, resident model state, prefix reuse, or L2 disk-cache restore.

| Model | Verdict | Artifact | Notes |
| --- | --- | --- | --- |
| `gemma-4-12b-it-jang_4m` | Green | `/tmp/osaurus-gemma4-fresh-per-model-20260603-144111/art-gemma-4-12b-it-jang_4m` | Strict required/none/required tool row passed. Turn 1 exact `red\ngreen\nblue`, visible turn 2 answer, turn 3 exact `one\ntwo`, no protocol leak, no inflight after. |
| `gemma-4-12b-it-mxfp8` | Green | `/tmp/osaurus-gemma4-fresh-per-model-20260603-144111/art-gemma-4-12b-it-mxfp8` | Strict required/none/required tool row passed with the same exact args and no leak. |
| `gemma-4-12b-it-mxfp4` | Red/partial | `/tmp/osaurus-gemma4-fresh-per-model-20260603-144111/art-gemma-4-12b-it-mxfp4` | Fails only `turn1_args_exact`: emitted `red\n green\n blue`. Turn 2 visible answer and turn 3 exact `one\ntwo` passed; topology passed; no protocol leak. |

## Cache And Engine Topology

The fresh rows prove Gemma 4 12B is detected as SWA/rotating, not a full
TurboQuant-KV/paged model:

- `layer_count: 48`
- `kv_layer_count: 8`
- `rotating_kv_layer_count: 40`
- `requires_disk_backed_restore: true`
- `turbo_quant_kv_layer_count: 0`
- `is_paged_incompatible: true`

Cold rows recorded disk L2 misses/stores but not warm-hit reuse. A separate
eviction/reload warm row is still needed before claiming disk-L2 hit proof.

## Reasoning Rail

Artifact:
`/tmp/osaurus-gemma4-reasoning-rail-20260603-144259`

- Default/no-thinking responses for JANG_4M, MXFP8, and MXFP4 did not place
  Gemma4 thinking text into visible `content`.
- Explicit `enable_thinking=true` routes thinking text into `reasoning_content`
  and keeps reasoning markers out of visible content.
- Explicit thinking is not production-clean yet: streaming thinking-on rows can
  length-stop in reasoning, and MXFP4 thinking-on produced visible corruption.
  The safe production rail is default/no-thinking unless explicitly requested.
- Follow-up UI safety patch: the chat input no longer advertises the Gemma4
  Thinking chip/profile. Gemma4 still has an explicit family profile so it does
  not fall through to generic auto-thinking, but that profile exposes no
  `disableThinking` UI option until Gemma4 explicit thinking is live-proven
  production-clean. Explicit API `enable_thinking=true` remains an explicit
  caller path; this PR does not silently force or strip it.

## Greeting Lane

The weird setup text such as `I' a ...`, `your-core-systemed`, `or0_`, and long
underscore/zero runs was traced to the optional generative greeting lane, not
normal chat or cache corruption.

The PR hardens that lane by simplifying the prompt contract, rejecting unknown
icons and extra pipe delimiters, and requiring the retry output to pass the same
quality gate before rendering. Bad greeting generations fall back to the static
empty-state copy.

## Current Merge Boundary

Merge-ready if the accepted scope is:

- Gemma4 JANG_4M and MXFP8 text/tool/cache-topology support.
- Gemma4 default/no-thinking reasoning routing without visible leakage.
- Gemma4 chat UI does not expose the unsafe explicit Thinking toggle.
- Gemma4 optional greeting hardening.
- Correct SWA topology and TurboQuant-KV exclusion.

Not fully production-ready if MXFP4 exact multiline required-tool fidelity is
part of the merge gate. That one row remains red/partial and should be fixed
or explicitly excluded before claiming full Gemma4 MXFP4 production readiness.
