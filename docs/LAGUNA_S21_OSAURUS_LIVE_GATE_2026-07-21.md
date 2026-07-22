# Laguna S 2.1 Osaurus live gate — 2026-07-21

## Status

`PARTIAL — Laguna 2L isolated-Release chat, explicit reasoning Off/On,
cross-chat/restart SSD reuse, non-adjacent reuse without stale-memory
contamination, and the rebuilt standalone Thinking control have live evidence;
the 4M/paged/TurboQuant/eviction/delegation matrix and Laguna tool-selection
root cause are not yet live-proven`

This is a live-app gate for the local text-only bundles:

- `/Users/eric/models/JANGQ-AI/Laguna-S-2.1-JANG_2L`
- `/Users/eric/models/JANGQ-AI/Laguna-S-2.1-JANG_4M`

MXFP4, MLXPress, and JangPress are not part of this gate. RunBench evidence is
diagnostic only and cannot close any Osaurus row.

## Exact candidate

- Osaurus base: `c07f29878a237a219ed4fdc5d75f4d95a5570b50`
- vMLX candidate: `a3b047e05871e1271fc86d2ef0ab2f8270aa832f`
- vMLX PR: `osaurus-ai/vmlx-swift#174`, merged as
  `fdd06d427276ad4c51ac066f6a3eb7121260832f` (the Osaurus pin intentionally
  resolves the reviewed head `a3b047e05871e1271fc86d2ef0ab2f8270aa832f`)
- Osaurus dependency surfaces that must agree:
  `Packages/OsaurusCore/Package.swift`, both workspace/app lockfiles,
  and `Packages/OsaurusCore/Package.resolved`

The word `DFlash` in Candidate 1-3's historical proof-app identifiers does not
mean a DFlash model or drafter was loaded. The selected bundle is
`LagunaForCausalLM`; its `generation_config.json` merely recommends the
separate, not-installed `poolside/Laguna-S-2.1-DFlash` accelerator. Candidate 4
uses a non-DFlash proof identifier to avoid that ambiguity.

## Root causes carried by the pin

1. Laguna S 2.1 routed expert tensors use `mlp.switch_mlp`; the prior Swift
   module path used `mlp.experts`.
2. The no-cache prompt path omitted Laguna's 512-token SWA band mask.
3. S 2.1 requires ordinary growing full-attention KV plus
   `RotatingKVCache(maxSize: 512, keep: 0)` for SWA; it has no attention sink.
4. Bundle `default_chat_template_kwargs.enable_thinking` and its JANG mirror
   did not reach tokenizer rendering when the request/UI stayed silent.
5. The Swift fallback had drifted from the released Poolside turn/template
   protocol.
6. A growing prompt changes the hash of its final non-block-aligned leaf, so a
   stored exact partial prefix was not found after the chat/task extended.
7. TurboQuant disk records preserved the encoded snapshot and later logical
   offset but discarded the exact post-compression live window. Restoring such
   a record could produce KV/mask length mismatch and incoherence.
8. Direct full-KV + rotating-SWA stacks stopped publishing the safe N-1 SSD
   prompt seed after the rotating ring wrapped, so a new chat/process could
   cold prefill even when Disk L2 was enabled.
9. Osaurus classified any `generation_config.json` DFlash reference as though
   the selected model itself were a DFlash-only architecture. Laguna S 2.1 is
   an ordinary `LagunaForCausalLM` target with an optional DFlash draft
   recommendation, so the real UI was blocked before vMLX could load even
   though speculation was not forced. The candidate now blocks only actual
   DFlash model/tokenizer identity; it keeps the optional feature unimplemented
   and visible instead of silently enabling it.

## Required real-user UI matrix

Every row must use the isolated Release app and Computer Use. Source tests,
CLI requests, and RunBench do not close these rows.

| Row | Real user operation | Required visible/runtime evidence | Status |
| --- | --- | --- | --- |
| Pin/build isolation | Launch the custom app/bundle ID with a unique `OSAURUS_TEST_ROOT` and keychain disabled | Release configuration, exact resolved vMLX SHA, app code signature/bundle ID, no production preference/root reuse | VERIFIED-LIVE — rebuilt exact-source Release app `/private/tmp/Laguna S21 Memory Gate Proof Isolated 20260721.app`, bundle ID `com.dinoki.osaurus.lagunas21memoryproof20260721`, preserved isolated root, keychain-free launch, executable SHA-256 `75da1ff3459b5b14463fe4008492552d31fd0be1bda412b979a272c48b5f5631`; resolved checkout is vMLX `a3b047e05871e1271fc86d2ef0ab2f8270aa832f` |
| Model discovery/load 2L | Pick Laguna JANG_2L from `~/models` in the app and send a normal chat | Correct label/path, `LagunaModel`, resident load rather than MLXPress/JangPress, coherent answer, token/s, Activity Monitor physical footprint | PARTIAL-LIVE — real picker/load and coherent 42.2–45.0 tok/s turns observed; Activity Monitor physical-footprint evidence is still missing |
| Model discovery/load 4M | Repeat with Laguna JANG_4M | Same evidence | OPEN |
| Default cache policy | Open Settings as a user | Prefix and Disk L2 effective, paged RAM Off by default, TurboQuant KV Off by default; save confirmation and runtime plan agree | VERIFIED-LIVE for rebuilt 2L candidate — Computer Use opened Server -> Settings -> Cache and visibly confirmed Prefix On, Disk On, Paged Off, SSM re-derive On, engine-selected codec, and `All changes saved`; runtime kept paged blocks at zero. 4M remains open |
| SSD-only cold/store | With paged RAM Off and Disk L2 On, start a fresh chat and send a long stable prompt | Cold miss/store, real prefill progress, TTFT, token/s, coherent output, disk store delta | PARTIAL-LIVE — Alpha completed coherently at 0.921s TTFT/42.2 tok/s and disk files/counters grew; a preserved request-local counter snapshot is still required |
| First new-chat partial restore | Create a genuinely new chat/task with the same stable system/tool prefix but a changed user suffix | Disk-tier matched boundary, partial suffix count, lower prompt work/TTFT, coherent output, no stale answer | PARTIAL-LIVE — a separate Beta chat visibly restored 1,586/1,690 prompt tokens and returned the current `BETA-OK` suffix at 0.777s TTFT/44.9 tok/s; repeat with saved cache-stat snapshots |
| Non-adjacent reuse | Run intervening different prompts/chats, then create another matching-prefix chat | SSD partial hit after unrelated work; correct response to the current prompt | VERIFIED-LIVE for rebuilt 2L candidate — with preserved cache/memory after intervening Ornith work and app replacement, new chat visibly restored 1,586/1,619 tokens, trace recorded `HIT disk boundary=1586 remaining=33` with paged blocks zero, and the UI returned only `EPSILON-OK` at 1.86s TTFT/40.8 tok/s. Raw prompt SHA-256 `3236aecc09a66fbc748f4ef1fc96f933b5fd17d5ea3c1cc8ce84394936db2ede` contains no `[Memory]` or Ornith text |
| App restart reuse | Quit and relaunch the isolated app, reload the same model, create a new matching-prefix chat | Disk hit from persisted files after process restart, matched/suffix tokens, TTFT/token/s, coherent answer | VERIFIED-LIVE for rebuilt 2L candidate — Candidate 4 launched a new app PID/executable against Candidate 3's persisted root, then the Epsilon chat restored 1,586/1,619 from disk and answered coherently; Gamma remains the earlier independent restart row |
| Negative control | Turn Disk L2 Off in Settings and save, then repeat the matching-prefix new chat | Request-local miss/cold prefill and slower TTFT; no disk hit. Restore Disk L2 On afterward | OPEN |
| Paged hot tier | Turn paged RAM On in Settings, reload if required, repeat matching-prefix chat | Paged hit before disk and correct partial suffix; setting visibly effective | OPEN |
| Paged eviction fallback | Create enough distinct work to evict the old hot blocks, then repeat the original prefix | Paged miss/eviction followed by SSD hit, not cold prefill; coherent current answer | OPEN |
| TQ off | Keep TurboQuant KV Off, reload, run 2L and 4M cache rows | Effective topology has 12 ordinary full-KV + 36 rotating SWA layers and zero TQ compressions | OPEN |
| TQ on | Turn TurboQuant KV On, save/reload, run 2L and 4M cold/new-chat/restart rows | Exactly 12 full-attention layers encoded; 36 SWA layers remain rotating; cache size/counters grow; SSD restore remains coherent | OPEN |
| Reasoning control discoverability/sync | Use the standalone footer control, then open the picker; repeat from the picker at normal and narrow window widths | Labeled footer control remains visible, picker/footer/model-glyph state agree, persisted semantic value is not inverted | VERIFIED-LIVE for Laguna 2L and Ornith 9B MXFP8 — the exact Release UI kept the labeled footer visible at 550x641; picker, footer, and model chip agreed after picker On and footer Off writes; switching from Laguna to Ornith showed Ornith's independent Off state rather than leaking Laguna's value |
| Reasoning default/off/on | Exercise untouched model default, explicit Off, and explicit On in ordinary chat and later turns | Bundle default honored; explicit UI choice wins on every turn; content/reasoning deltas separated; no raw tags or hidden-only answer | PARTIAL-LIVE — Laguna and Ornith MXFP8 explicit Off/On reached both initial and post-tool template renders. Candidate 4 additionally kept Laguna Thinking visibly On and displayed 152- and 90-character reasoning cards around a tool-result continuation; `hi` legitimately closed an empty reasoning segment. Other families, untouched-default semantics, API parity, AppleScript, and delegated-agent propagation remain open |
| Tool continuation | Use a real harmless Osaurus tool, accept its result, ask a grounded follow-up, then request another call | Exact tool/JSON args, tool-result grounding, second tool use after history, no protocol leakage or loop | FAILED-LIVE — Laguna over-selected tools for arithmetic, first mis-shaped `todo`, then hallucinated unavailable `shell_execution`; do not classify as usable until root-caused or explicitly proven model-inherent with a matched control |
| Load cancellation | Start a load/first turn, cancel/close once, then load normally | No zombie GPU work or runaway memory; later load succeeds | OPEN |
| Settings composition | Repeat representative rows after changing memory safety and cache toggles | UI state, persisted values, next-load behavior, runtime topology, cache telemetry, and visible answer all agree | OPEN |

## Active issue ledger

This section is the working checklist. A source edit or focused test cannot by
itself close a live row.

1. **Standalone Thinking control — VERIFIED-LIVE for Laguna 2L and Ornith 9B
   MXFP8.** Current source adds a footer `SelectorChip` and routes
   picker/footer writes through the same semantic `thinkingStoredOption`
   conversion. In the exact Release app, the label remained visible at 550x641,
   picker/footer/model-chip states agreed after writes from both controls, and
   switching models restored the selected model's independent value.
2. **Reasoning choice across reconstructed requests — PARTIAL-LIVE.** Current source
   freezes `ChatTurnGenerationControls` once per manual turn and reapplies it
   to every normal and iteration-cap request. Computer Use and AppleScript mark
   their internally rebuilt requests as agent requests; local delegation asks
   `ChatEngine` for the delegated model's persisted option. Exact Release UI
   proof now covers initial and post-tool On/Off rendering for Laguna 2L and
   Ornith 9B MXFP8. AppleScript, delegated-agent, and other-family live proof is
   still required; the current offered tool surface did not expose delegation.
3. **Reasoning/content delta separation — PARTIAL-LIVE for Laguna 2L and Ornith
   9B MXFP8.** Laguna Thinking On produced three separate Thinking blocks and
   Off stored zero thinking characters. Ornith On produced visible 148- and
   214-character Thinking blocks around exactly one tool call; Off stored zero
   thinking characters. Raw prompt-tail evidence confirms the model-specific
   renderings differ: Laguna uses `<assistant><think>` versus
   `<assistant></think>`, while Ornith uses an open `<think>` versus an empty
   closed `<think></think>` block. Streaming and non-streaming API, 4M, and
   other-family rows remain open.
4. **Laguna tool selection/continuation — FAILED-LIVE.** A harmless arithmetic
   task invoked `todo`, retried after invalid arguments, hallucinated an absent
   `shell_execution` tool, and then called `complete`. No semantic prompt guard,
   forced no-tool rule, or parser masking is acceptable. Compare the same bundle
   with a matched no-tool/direct-runtime and exact offered-schema control before
   deciding whether ownership is model behavior, template/schema exposure, or
   loop integration.
5. **SSD-only cross-chat partial reuse — VERIFIED-LIVE for the rebuilt Laguna
   2L non-adjacent/restart baseline.** The Epsilon row restored 1,586/1,619
   tokens from disk after unrelated Ornith work and a new app executable/PID,
   with 33 suffix tokens left, paged blocks zero, exact current output, and no
   stale-memory text in the rendered prompt. The explicit Disk-Off negative
   control, paged hot/eviction fallback, 4M, and TQ variants remain open.
6. **Paged hot/eviction-to-SSD fallback — OPEN in Osaurus UI.** Turn Paged On as
   a real user, create enough distinct work to evict the original prefix, and
   prove a paged miss falls through to the SSD block rather than cold prefill.
7. **TurboQuant KV Off/On — OPEN in Osaurus UI.** Off is the default. On must
   encode only Laguna's 12 growing full-attention layers while all 36 SWA layers
   retain their rotating cache, then remain coherent across partial SSD restore
   and app restart. UI state alone is not proof.
8. **Laguna 4M — OPEN in Osaurus UI.** Discovery, resident load, physical
   footprint, multi-turn coherence, token/s, reasoning streaming, tools, SSD,
   paged, eviction, and TQ rows all remain live-unproven.
9. **Full-suite/CI/merge gate — BLOCKED/PENDING.** The vMLX focused suites and
   Release build passed, but `/tmp/vmlx-laguna-full-swift-test-20260721.log`
   records two failing areas. Both reproduced alone under the explicit Xcode
   6.3.3 toolchain after the proof app/model was unloaded. The local-family
   snapshot reads external `~/models`: this machine has four of six expected
   families and its Nemotron template renders additional whitespace. MLX's
   unchanged `TransformTests.testCompiledRandom` also fails alone at its first
   `allClose(c1a,c1b)` assertion. The Laguna branch changes neither test nor
   the MLX submodule relative to vMLX main, so these are current-main-equivalent
   environment/upstream failures, not Laguna diffs. They remain honest failing
   full-suite rows. vMLX PR #174 is merged, but all of its GitHub jobs were
   skipped by the upstream-repository workflow guard, so they are not called
   green. Osaurus PR #2127 first passed seven of eight checks; `test-core`
   exposed that the tightened memory classifier also rejected the established
   start-of-query shorthand `exact words <terms>`. The follow-up preserves
   that explicit recall form (plus `what exact words did I type`) without
   restoring output-directive false positives. Focused
   `MemoryRelevanceGateTests` and `MemoryUserPrefixTests` pass locally; the
   full PR CI rerun is pending.
10. **Bare `exactly` triggers stale transcript injection — VERIFIED-LIVE for
    the scoped classifier fix.** `MemoryRelevanceGate.literalRecallPhrases`
    previously classified any prompt containing `exactly` as literal recall.
    Focused tests now reject command/directive uses and preserve explicit
    prior-words constructions. In the rebuilt Release UI, `Reply exactly
    EPSILON-OK` rendered no `[Memory]` and answered exactly; a separate `What
    exactly did I say ...?` chat did render `[Memory]`, proving transcript
    recall was not globally disabled. That retrieved excerpt did not contain
    the requested old Ornith record, so retrieval ranking remains outside this
    classifier proof.

## Carry-forward issues outside the Laguna runtime PR

These rows remain documented so the current narrow Laguna/prefix-cache work
does not erase them. They are not silently pulled into this PR without a
current source diff and their own live matrix.

1. **AppleScript 8B/16B completion and idempotence — OPEN.** Reproduce the
   successful edit followed by duplicate retries, unsolicited Save, false
   failure finalization, wrong-tool fallback, and hallucinated tool-failure
   answer in the exact dev app. Compare Thinking Off/On and a fresh delegated
   context; do not classify as model-inherent without a matched control.
2. **Sandbox idle GPU saturation/uninstall state — OPEN.** Reproduce the
   reported 100% idle GPU after partial uninstall, correlate the actual process
   and sandbox lifecycle, and prove uninstall/relaunch from the UI. Setup
   warnings alone do not establish causality.
3. **Cross-family SSD partial reuse — PARTIAL.** Laguna 2L and Ornith MXFP8 have
   request-local disk-hit evidence, including Ornith hybrid companion state,
   but Gemma 4 rotating-SWA, Qwen 3.5/VL, Bonsai, LFM, MiniMax, Nemotron, and
   other supported families still need new-chat, non-adjacent, restart,
   Disk-Off, and eviction-fallback proof. Paged RAM remains default Off.
4. **Cross-family TurboQuant KV — OPEN.** TurboQuant KV remains default Off.
   User-enabled proof must show architecture-specific eligible-layer encoding,
   coherent partial SSD restore, cache-size/counter movement, and correct
   companion-state re-derivation. DSV4 Flash and OpenPangu must not be opted in
   without architecture proof.
5. **Multimodal/cache media rows — OPEN.** Qwen 3.5 VL and Nemotron media paths
   need real image/video/audio payloads as supported, media-salt isolation, and
   restart/L2 restore. Text-only load evidence cannot close them.

## Failure conditions

- A cache counter without a request-local matched boundary and suffix is not a
  cache-reuse pass.
- `Prefill 0/N` may be a cache-lookup stage only if the runtime trace and later
  UI stage show a real restore. A full prompt computation after a claimed hit
  fails the row.
- Reusing stale visible text, reasoning from another task, or an old tool
  result fails even if TTFT improves.
- Any raw `<think>`, `</think>`, `<tool_call>`, argument tag, or unclosed
  protocol marker fails the row.
- A TQ toggle that only changes UserDefaults/UI state but not the 12/36 runtime
  topology fails the row.
- A paged toggle that silently remains globally enabled/disabled fails the row.
- Missing token/s or Activity Monitor physical-footprint evidence keeps a model
  row partial.

## Evidence log

### Candidate 1 — exposed Osaurus DFlash preflight defect

- Release build log:
  `/tmp/osaurus-laguna-s21-release-build-20260721.log` (`** BUILD SUCCEEDED **`).
- App:
  `/private/tmp/osaurus-laguna-s21-release-derived-20260721/Build/Products/Release/osaurus.app`.
- Resolved vMLX checkout:
  `a3b047e05871e1271fc86d2ef0ab2f8270aa832f`.
- Bundle ID: `com.dinoki.osaurus.lagunas21proof20260721`; signature:
  ad-hoc; executable SHA-256:
  `0bddb14f9cae3d8f13a02161b5541fcf3b0b75e9606bef07a468646d33f43cdf`.
- Isolated root:
  `/private/tmp/osaurus-laguna-s21-live-root-20260721-1833`.
- Computer Use visibly completed first-run onboarding, disabled usage/crash
  telemetry, opened Server -> Settings -> Cache, and observed Prefix On,
  GPU/Paged Off, Disk On, Codec `Engine Selected`, and SSM re-derive On.
  Supporting screenshot: `default-cache-settings.png`; supporting request
  snapshot: `cache-before-2l.json`.
- Computer Use selected `Laguna S 2.1 JANG_2L` from the real picker; the UI
  showed a 1,048k context budget. The first real send failed before model load
  with `DFlash speculative decoding incomplete` because the compatibility
  classifier treated optional `generation_config.json::speculative_config`
  metadata as model identity.
- Source owner:
  `Packages/OsaurusCore/Services/ModelCompatibilityDiagnostics.swift`.
  Focused tests and rebuilt UI rerun are in progress; this candidate does not
  prove generation, cache reuse, reasoning, tools, speed, or RAM.

### Candidate 2 — 2L cache/reasoning proof and new failures

- Release app: `/private/tmp/Laguna S21 UI Proof 1852.app`; bundle ID
  `com.dinoki.osaurus.lagunas21dflashproof20260721`; ad-hoc signed; isolated
  root `/private/tmp/osaurus-laguna-s21-live-root-20260721-1851-dflashfix`.
- Computer Use selected and loaded the real
  `/Users/eric/models/JANGQ-AI/Laguna-S-2.1-JANG_2L` bundle. Loaded topology
  reported 48 cache layers: 12 full KV, 36 rotating SWA, Disk L2 enabled,
  Paged disabled, and `turbo_quant_kv_layer_count=0`.
- Chat-history evidence is preserved in
  `chat-history/history.sqlite` under that isolated root:
  Alpha `ALPHA-OK` at 0.921s TTFT/3 generated tokens; Beta `BETA-OK` at
  0.777s/4; Gamma `GAMMA-OK` at 0.762s/4 after quitting and relaunching the
  app. The UI reported 42.2, 44.9, and 45.0 tok/s respectively. Beta visibly
  restored 1,586 of 1,690 prompt tokens with Paged still Off.
- Prompt-tail artifacts are in
  `/private/tmp/osaurus-laguna-reasoning-prompts-20260721`. Explicit On ends
  the rendered prompt with `<assistant><think>`; explicit Off ends it with
  `<assistant></think>`. The hard On session stored assistant-thinking lengths
  1,051, 51, and 441 characters in distinct iterations and displayed separate
  Thinking blocks. The Off session stored zero thinking characters in every
  iteration.
- The same live sessions exposed a correctness failure independent of the
  stream splitter: Laguna selected irrelevant tools for arithmetic, produced
  invalid `todo` arguments, and requested unavailable `shell_execution` before
  completion. This row is failed, not hidden by the final correct arithmetic.
- Current-source focused Xcode tests for runtime policy, per-turn controls,
  agent reasoning policy, model profiles, generation event mapping, and model
  compatibility exited 0 on 2026-07-21. This does not substitute for the
  rebuilt footer-control UI run.

### Candidate 3 — exact standalone control and reconstructed tool-loop proof

- Exact-source Release build log:
  `/tmp/osaurus-laguna-s21-release-build-reasoning-footer-exact-20260721.log`.
  App: `/private/tmp/Laguna S21 Reasoning Footer Proof Isolated 1945.app`;
  bundle ID `com.dinoki.osaurus.lagunas21dflashproof20260721`; executable
  SHA-256 `eb51d4471bc36bfaf2a5194317c42c085d3a9d04908e13dd0e4bedbdc388d8ea`;
  strict deep code-sign verification succeeded. It launched keychain-free with
  the Candidate 2 isolated root and explicit `OSU_MODELS_DIR=/Users/eric/models`.
- Computer Use kept the labeled Thinking footer visible at 550x641. For Laguna
  2L, picker On changed picker/footer/model chip to On and footer Off changed all
  three to Off. Switching to Ornith 9B MXFP8 restored Ornith's own Off value.
- Laguna 2L Off called `get_current_time` exactly once, returned
  `TOOL-OFF-DONE`, reported 0.93s TTFT/43.2 tok/s, and rendered
  `<assistant></think>` both initially and after the tool. On called the same
  tool exactly once, returned `TOOL-ON-DONE`, reported 0.95s/44.3 tok/s, and
  rendered `<assistant><think>` at both steps.
- Ornith 9B MXFP8 Off called `get_current_time` exactly once, returned
  `ORNITH-OFF-DONE`, reported 0.44s TTFT/51.4 tok/s, stored zero thinking
  characters, and rendered an empty closed `<think></think>` block initially
  and post-tool. On called it exactly once, returned `ORNITH-ON-DONE`, reported
  0.45s/60.6 tok/s, displayed/stored 148- and 214-character Thinking blocks,
  and rendered an open `<think>` initially and post-tool.
- Ornith's post-tool request restored SSD boundary 1,733 with 372 tokens
  remaining and `ssm=48`; Paged remained effectively disabled (`blocks=0`).
  This is a request-local hybrid SSD hit, not proof of the full cross-chat,
  non-adjacent, restart, or eviction matrix.
- Raw render artifacts are under
  `/private/tmp/osaurus-laguna-reasoning-footer-prompts-20260721`; structured
  turns are in Candidate 2's `chat-history/history.sqlite`. The current offered
  agent tool surface did not contain a spawn/delegation tool, so delegation is
  still OPEN rather than inferred from source.

### Candidate 3 failure — non-adjacent SSD hit exposed memory contamination

- With the exact app still on Prefix On, Disk On, Paged Off, SSM re-derive On,
  Computer Use switched from the completed Ornith MXFP8 runs back to Laguna 2L,
  created a new chat, and sent `DELTA-NONADJACENT-SSD-20260721. Reply exactly
  DELTA-OK.` with Thinking Off.
- The UI visibly restored `Prefill 1586/1881`; runtime trace records
  `[vmlx][cache/fetch] HIT disk boundary=1586 remaining=295`, Paged blocks zero,
  and a rotating-cache companion. This is valid non-adjacent SSD-tier evidence.
- Correctness failed: the UI shows one unrequested `get_current_time` call and
  final `ORNITH-ON-DONE` at 0.62s TTFT/46.4 tok/s. Structured turns are in
  session `059FA5A5-FE10-4F94-8998-35C36A184D8F`.
- The raw prompt dump `prompt-1784689301980-74891-BatchEngine.generate-JANGQ-AI_Laguna-S-2_1-JANG_2L.txt`
  contains prior `ORNITH-MXFP8-TOOL-ON-20260721` text inside `[Memory]` before
  the current Delta request. `MemoryRelevanceGate` selected transcript recall
  solely because its literal-phrase set contained bare `exactly`; the memory
  database confirms those old turns were recorded for the same agent. This
  differentiates prompt contamination from a KV restore serving stale tokens.

### Candidate 4 — rebuilt memory gate, non-adjacent SSD restore, and Thinking On

- Ad-hoc Release build completed with code signing disabled during Xcode build,
  then the copied app was deep ad-hoc signed and strict-verified. App:
  `/private/tmp/Laguna S21 Memory Gate Proof Isolated 20260721.app`; bundle ID
  `com.dinoki.osaurus.lagunas21memoryproof20260721`; executable SHA-256
  `75da1ff3459b5b14463fe4008492552d31fd0be1bda412b979a272c48b5f5631`.
  The derived checkout is exactly vMLX
  `a3b047e05871e1271fc86d2ef0ab2f8270aa832f`.
- Computer Use completed the new proof bundle's first-run UI, selected the real
  `Laguna S 2.1 JANG_2L` local bundle, and opened Server -> Settings -> Cache.
  The visible effective user state was Prefix On, GPU/Paged Off, Disk On, SSM
  re-derive On, engine-selected codec, and `All changes saved`.
- The app reused the preserved Candidate 3 root/cache/memory database. In a new
  chat with Thinking visibly Off, `EPSILON-NONADJACENT-SSD-20260721. Reply
  exactly EPSILON-OK.` showed `Prefill 1586/1619`; trace recorded
  `[vmlx][cache/fetch] HIT disk boundary=1586 remaining=33 ...`, paged blocks
  zero, and disk stores/10 GB quota eviction. The UI displayed exactly
  `EPSILON-OK`, TTFT 1.86s, 40.8 tok/s, four generated tokens, no tool call,
  and no reasoning.
- The raw Epsilon prompt is
  `/private/tmp/osaurus-laguna-memory-gate-prompts-20260721/prompt-1784690451127-86899-BatchEngine.generate-JANGQ-AI_Laguna-S-2_1-JANG_2L.txt`,
  SHA-256
  `3236aecc09a66fbc748f4ef1fc96f933b5fd17d5ea3c1cc8ce84394936db2ede`.
  It contains zero `[Memory]`, `ORNITH`, `TOOL-ON-DONE`, or `TOOL-OFF-DONE`
  matches. Session `7087E9CF-DC16-4DD9-A2DA-31A5DCD62C73` in
  `chat-history/history.sqlite` stores the exact user/output pair.
- A positive-control new chat, `What exactly did I say in the
  ORNITH-MXFP8-TOOL-ON-20260721 test?`, rendered a `[Memory]` block. Its raw
  prompt SHA-256 is
  `206356821dd65e14b226e178440c2ae1505a05862400bbd2caef5f9fe5da146b`.
  The retrieved excerpt contained current Laguna/Epsilon turns, not the named
  old Ornith record, and the model said that record was absent. This verifies
  the explicit-recall classifier path remains active but does not prove memory
  retrieval ranking for an old named record.
- With Thinking visibly On, the arithmetic row displayed separate 152- and
  90-character Thinking cards before and after a tool-result continuation,
  then `$194.40`; stored session
  `5E8F6D77-0111-4AAD-9807-A5113AEAC4E3` agrees. Runtime recorded 62 reasoning
  deltas before and 50 after the tool result. Laguna unnecessarily called the
  unavailable `shell` tool for simple arithmetic, received the structured
  `tool_not_found` result, and recovered. Tool choice remains failed/open; it
  is not hidden by the correct final answer.

Do not change the top status to verified while any required Release UI row
remains open.
