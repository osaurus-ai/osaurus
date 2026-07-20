# Gemma/Bonsai Emergency Proof Ledger

Last updated: 2026-07-20 (America/Los_Angeles)

Verdict: **PASS for the narrow Ornith/Qwen-toggleable agent-reasoning policy
and recurrent-cache cross-hit repair on the exact installed JANG_4M bundle;
PASS for the historical schema-1 JANG loader and Bonsai paged-chain repairs;
PARTIAL for the separate Ornith semantic-completion defect and every deferred
family/cache matrix. The current Release app was operated through the real UI
across untouched OFF, explicit ON, OFF-after-ON, process restart, and partial
disk-L2 reuse. No MXFP4 artifact was loaded or used as evidence.**

## Local model root (hard rule)

Use only the user's canonical local model root, `~/models`
(`/Users/eric/models`), for every runtime and live-app row in this lane. Record
the exact bundle path for each row. Do not substitute a model from Downloads,
the Hugging Face cache, or another checkout.

Current Ornith fixtures:

- JANG_4M: `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M`
- MXFP8: `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-MXFP8`

This emergency branch is rebased on merged `main`
`08eb8bd8a29f79bef9bdb1dd791fcf6a8c1fea4c`. Bonsai structured-chart and
hybrid-memory fixes are already on main through PR #2041. Selected Memory
Safety load admission is already on main through PR #2045. The deferred broad
automatic-routing/hardware-guidance work in PR #2044 is not part of this
emergency diff.

## Hard scope

- Do not download, load, benchmark, or infer behavior from MXFP4.
- Use installed JANG_4M or MXFP8 controls only.
- Do not add forced thinking tags, sampler overrides, prompt/template
  coercion, output caps, or semantic "promise" heuristics.
- Source tests are necessary but insufficient. Every behavior claim requires
  a Release app built from the exact proposed head and operated through the UI.
- Record visible output, tool cards, streamed tool assembly, token/s, physical
  footprint, cache topology/counters, and on-disk effects.

## Active Gemma 4 QAT checkpoint gates

The project `AGENTS.md` makes the following required follow-up evidence part of
this ledger. These rows do not broaden the present emergency diff, and they
remain PARTIAL until exercised in an exact-head Release Osaurus app through the
real UI:

- ordinary single-batch chat/server loading starts with paged RAM KV off;
  paged RAM may only be enabled by an explicit user or regression setting;
- Gemma 4 JANG_4M and QAT MXFP4 use bundle generation configuration plus the
  real Osaurus/vMLX parser/tool/streaming path, with no protocol-marker leakage
  and no prompt, sampler, reasoning-tag, stop-token, or output-cap masking;
- telemetry names the effective topology exactly. Rotating KV plus disk restore
  with `turbo_quant_kv_layer_count=0` must not be described as a TurboQuant-KV
  topology, and prefix/paged/L2/disk-restore counters must agree with behavior;
- long first-token waits expose runtime prefill/cache/media progress rather
  than UI timer estimates;
- every generation row records TTFT/token/s, visible answer and reasoning
  coherency, no loop or hidden-only answer, and Activity Monitor
  `phys_footprint`; load-only and report-only admission rows do not pass; and
- multi-turn plus architecture-specific cache proof is mandatory, including
  companion state for rotating SWA, hybrid/recurrent state, VL, video, or other
  path-dependent caches. Raw speed and Gemma 4 audio stay deferred until the
  correctness checkpoint closes, and BF16/source Gemma bundles are excluded
  from that checkpoint.

## Priority and current evidence

| Priority | Row | Status |
| --- | --- | --- |
| P0 | Installed JANG schema-1 bundles load | LIVE LOAD PASS on exact JANG_4M; separate semantic-completion row remains partial |
| P0 | Untouched Thinking state on agent/tool runs | VERIFIED-SOURCE + VERIFIED-LIVE on exact current Release app: OFF→ON→OFF and restart |
| P0 | Reasoning-mode cache isolation across same-chat tool turns | VERIFIED-SOURCE + VERIFIED-LIVE: no stale replay after vMLX reset plus detached recurrent snapshots |
| P0 | Ornith/Qwen post-tool cutoff or partial completion | REPRODUCED AS PARTIAL MUTATION on JANG_4M and MXFP8; exact pre-write cutoff not reproduced |
| P0 | Bonsai tiny-pool paged-cache eviction and hybrid replay tail | VERIFIED-SOURCE + VERIFIED-LIVE for the cache defect; model semantic-quality controls remain mixed |
| P0 | PR scope contains no deferred routing/hardware changes | PASS for current pin-only source/test diff plus ledger; repeat on final diff |
| P0 | Exact pin-only candidate Release UI rerun | PASS for the scoped agent reasoning/cache matrix; semantic handbook behavior remains a separate reproduced failure |
| P1 | Gemma/Bonsai tool correctness regressions | NOT YET RUN on clean head |
| P1 | TurboQuant default-off, explicit toggle, persistence, Gemma rotating-SWA topology | NOT YET RUN on clean head |
| P1 | Qwen 3.5 text/VL hybrid rederive, prefix/L2 disk restore, cache growth in GB | NOT YET RUN on clean head |
| P1 | Memory Safety warning, setting change, larger-model load, restore refusal | NOT YET RUN on clean head |
| P1 | Image generation/editing and spawn/delegation RAM admission/notifications | NOT YET RUN on clean head |
| P1 | MiniMax M2.7 JANGTQ/JANG_K runtime plus native reasoning-mode behavior | DOCUMENTED; SEPARATE LIVE MATRIX OPEN |
| P1 | DSV4 Flash mixed SWA/HCA/CSA/DSA/MLA prefix/partial/L2 cache behavior | DOCUMENTED; SEPARATE LIVE MATRIX OPEN |
| P2 | MXFP4 structurally incomplete answer/reasoning/tool-envelope recovery | DOCUMENTED ONLY; no MXFP4 runtime claim and excluded from the emergency diff without a later exact-model reproduction |

## 2026-07-20 Ornith agent reasoning emergency

Status: **VERIFIED-SOURCE + VERIFIED-LIVE for the scoped emergency.** The
current request policy and both vMLX cache repairs were rebuilt together into
an isolated Release app and operated through the real model picker, folder,
tool cards, cache settings, chat history, and process restart. The same chat
completed OFF→ON→OFF without a stale tool call, and the restarted process
restored a partial disk prefix before the requested tool call. This does not
close the separate Ornith semantic-completion defect or any deferred model
family.

### Reproduced contract

The exact installed bundle
`/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M` declares
`text_config.model_type=qwen3_5_text`, 24 linear-attention layers, eight
full-attention layers, and a Qwen tool/reasoning contract. Its template's only
direct-rail branch is
`enable_thinking is defined and enable_thinking is false`; omission therefore
means thinking ON. Ornith's display id does not match the existing Qwen family
name path in `MLXBatchAdapter`, so an untouched request reaches the template
without `enable_thinking` and inherits the reasoning rail.

Osaurus `main` at `846ca9185dfee42a9bf2f741938f0b89a546b8ca`
already freezes an explicit Thinking choice for every reconstructed ChatView
tool iteration and cap finalizer. That fix deliberately preserves `nil` for an
untouched control, so it does not implement the required agent default.

### Required policy

- Ordinary chat plus untouched Thinking: preserve the bundle/template default.
- Agent or tool run plus untouched Thinking: pass
  `enable_thinking=false` for every model step and finalizer, but only when the
  installed bundle exposes a real toggleable reasoning template.
- Explicit Thinking ON or OFF: the user/API choice wins on every step.
- Explicit reasoning effort: the effort rail wins; do not synthesize a
  contradictory boolean.
- Non-toggleable models, models with a dedicated reasoning-effort control
  (including DSV4 instruct/reasoning/max and Hy3), and remote agent-owned Mode
  2 generation receive no synthetic local boolean kwarg.
- Detect from the local template/config capability, never from `ornith`,
  `qwen`, or another display-name allowlist.

### Owning-layer fixes

The Osaurus candidate adds a pure `AgentReasoningPolicy` and calls
it from `ChatEngine.prepareDispatch`, the shared stream/non-stream request
entry. The policy fires only for `isAgentRequest` or a non-empty tool schema,
only for `LocalReasoningCapability.isToggleableThinking`, and only when no
explicit thinking or reasoning-effort control exists. Any model profile that
owns a segmented `reasoningEffort` rail is excluded even if its underlying
template also accepts `enable_thinking`. ChatView carries the
logical agent marker into its tool-less cap finalizer. Plugin iterations copy
the same marker when their resolved schema is non-empty. Computer Use,
AppleScript, HTTP agent loops, and delegated subagents already mark their
requests as agent-driven and therefore converge at the shared entry point.
Fresh local `.chatUI` requests created by Computer Use, AppleScript, and
delegated text-agent loops now resolve the persisted per-model picker choice at
that same entry point when the request does not already carry explicit
`modelOptions`. This lookup is limited to local `.chatUI` agent requests:
explicit request options win, and ordinary chat, OpenAI/API tools, plugins,
scheduled/P2P work, and remote-agent execution do not inherit GUI state.
An ordinary OpenAI request that supplies schemas with `tool_choice: none`
remains ordinary chat and preserves the bundle default; an explicit local
agent marker still wins for a tool-less finalizer.

This is request-policy wiring, not a model-behavior repair: it does not change
the chat template, prompt text, sampler, output parser, stop/EOS handling,
reasoning delimiters, tool JSON schema, tool-result history, or content-delta
assembly.

### Required current-source and live closure

| Gate | Required evidence | Status |
| --- | --- | --- |
| Pure precedence tests | ordinary unset, agent unset, explicit ON/OFF, explicit effort, non-toggleable, dedicated effort rail, remote-agent exclusion | PASS: rebased-head `ReasoningTests9.xcresult` reports 64 passed, 0 failed, 0 skipped across policy, dispatch, turn controls, local capability, and profile regressions |
| Request reconstruction | ChatView normal iterations + finalizer, HTTP agents, plugins, Computer Use, AppleScript, delegated subagents | VERIFIED-SOURCE at shared dispatch and reconstruction sites; local ChatView path VERIFIED-LIVE; other surfaces not separately live-proven by this row |
| Untouched real-user row | Fresh isolated preferences; real tool calls; zero reasoning on every step; exact tool args/results; final answer; TTFT and tok/s | PASS-LIVE: two exact file reads, zero reasoning deltas on all steps/finalizer, exact `FIX2-OFF-DONE`; TTFT 0.48s, 72.7 tok/s, 6 tokens |
| Explicit OFF row | Toggle OFF in picker; repeat multi-tool run; zero reasoning on every step and finalizer | PASS-LIVE after ON: two exact requested reads, no extras/reasoning, exact `FIX2-OFF-RETURN-DONE`; TTFT 0.44s, 69.8 tok/s, 8 tokens |
| Explicit ON row | Toggle ON in picker; structured reasoning present on every intended step without leakage/looping | PASS-LIVE: one exact requested read, visible Thought before and after the tool, exact `FIX2-ON-DONE`; TTFT 0.52s, 70.6 tok/s, 27 tokens |
| OFF after ON | Toggle back OFF; repeat to prove no stale prompt/cache replay | PASS-LIVE: no stale argument or final-answer replay in the same chat |
| Settings/user-state truth | Reopen history and restart app; visible mode and effective request behavior agree | PASS-LIVE: reopened persisted chat after process restart; chip remained Off and every restarted step logged zero reasoning deltas |
| Adjacent behavior | tool error + recovery, auto/required/no-tool, post-tool final answer, content/reasoning delta boundaries, cancellation, retry, spawn/delegation | OPEN |
| Resource/cache proof | Activity Monitor physical footprint, per-turn token/s, prefix/paged/L2/SSM counters, no cache cross-hit between thinking states | PASS for scoped row: exact PID 84047 was 2.53 GB; rates above; disk partial-prefix hits and quota eviction captured. Broader cache-efficiency/family rows remain PARTIAL |

Current-source safeguard results: the reasoning-delta routing, Chat UI
reasoning routing, and no-hidden-local-sampler-default guards pass. The broad
no-forced-behavior guard reports one lexical failure at the untouched
`CapabilityTools.swift:17` documentation phrase `parser repair`. That line
predates this branch (blame commit `2d238592cf`) and describes why malformed
dynamic schemas fail closed; this diff does not modify that file or add a
parser repair. The guard is therefore not reported as passing and the unrelated
documentation is not edited merely to silence it.

### Adjacent cache-contamination reproduction and candidate root

The isolated proof app at
`/private/tmp/osaurus-ornith-reasoning-release-derived/Build/Products/Release/osaurus.app`
used bundle id `com.dinoki.osaurus.ornithreasoningproof`, isolated files and
preferences, and the exact JANG_4M fixture. In one OFF turn it read lines 20–22
and 35–37. After changing the same chat to ON, a prompt requesting only lines
70–72 first executed the stale lines-20–22 call and only then the requested
lines-70–72 call. The UI showed two tool cards and Thinking before every model
step, then ended `ON-CROSS-HIT-DONE` at TTFT 0.36s and 80.7 tok/s. Runtime logs
recorded the stale and requested argument objects in that order. A fresh-chat
ON control did not replay the old arguments, which isolates the defect to
cross-request state rather than tool JSON assembly or content-delta streaming.

vMLX already salts coordinator keys by exact prompt tokens plus
`reasoning=on|off`, tool choice, media, and effective KV policy. The coordinator
therefore returned a miss after the mode change. `TokenIterator` nevertheless
kept a populated caller-owned cache on that miss and treated the numeric cache
offset as if it proved token-prefix identity. Offset ordering cannot prove that
the rendered tool/reasoning history is the same; for Ornith/Qwen 3.5 it carried
old `ArraysCache` recurrent state into the new request. The owning-layer
fix in `6d5694fff9816e5f2e31444e62158e0970013b26` discards any
populated unverified cache on a coordinator miss and full-prefills the request;
verified coordinator hits remain the only reuse path. `NativeMTPTokenIterator`
receives the same invariant.

The first post-reset probe still exposed a second owning-layer defect:
`ArraysCache.copy()` and `MambaCache.copy()` used an ellipsis slice, which is a
view rather than an independent recurrent-state snapshot. Later tool/output
tokens could therefore mutate a prompt-boundary cache entry stored under an
earlier prompt hash. vMLX commit
`4b431c6a3f229e2150810b9dea9afe57790ca60b` creates independent buffers,
materializes prompt snapshots once, detaches recorded Mamba prefix states, and
adds mutation-after-snapshot coverage. It does not modify prompt text, model
templates, samplers, stop/EOS handling, parsers, tool schemas, or output
streaming.

Focused current-source vMLX evidence at that exact revision:

- `BatchEngineGrowingChatCacheSourceTests`: 17 passed;
- `CacheCoordinatorTopologyFocusedTests`: 40 passed;
- `CacheCoordinatorModeKeyIsolationTests`: 9 passed;
- `swift build --target MLXLMCommon` completed; and
- `git diff --check` returned clean.

### Exact current Release UI proof

- App:
  `/private/tmp/osaurus-ornith-cachefix2-release-derived/Build/Products/Release/osaurus.app`
- Bundle id: `com.dinoki.osaurus.ornithcachefixproof2`
- Embedded vMLX revision:
  `4b431c6a3f229e2150810b9dea9afe57790ca60b`
- Executable SHA-256:
  `6975d56bf873d1afe7d76cb039d5011a5b3aa69af4ab8f34775fd9436cfb9e4b`
- Runtime root:
  `/private/tmp/osaurus-ornith-cachefix2-proof-root-v1`
- Exact model:
  `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M`

The Release build completed successfully, was ad-hoc signed under the isolated
bundle id, and passed deep strict code-sign verification. Fresh preferences,
test-root files, and keychain-disabled mode kept it separate from the installed
app. The real Cache settings UI showed Prefix on, paged RAM/GPU cache off, SSD
L2 on, codec `Engine Selected` rather than TurboQuant, SSM rederive on, and a
10 GB disk soft cap.

After the OFF→ON→OFF chat matrix, the app was quit and the same binary/root was
relaunched. History restored the same chat, working folder, model, and Off
presentation. A unique prompt then executed exactly one `read_file` for
`FloatingInputCard.swift:2220-2240`, rendered exactly
`FIX2-RESTART-L2-DONE`, and showed TTFT 0.65s, 71.9 tok/s, and 9 tokens. Runtime
traces recorded zero reasoning deltas, a disk partial-prefix hit at
`boundary=4921 remaining=2481`, the exact requested tool arguments, a later
disk hit at `boundary=7112 remaining=823`, and no stale calls or finals.

The `ssm=48 fmtV=2 willRestore=false` trace is not a missing companion restore
for this effective topology. The live cache was 24 `MambaCache` plus eight
`KVCacheSimple` layers; v2 typed disk payloads restore Mamba state directly,
while the extra sidecar apply is reserved for legacy format or dynamic
`ArraysCache` layers that v2 marks skipped. The visible coherent continuation
and exact tool/final output are live behavior evidence, not a claim that every
Qwen hybrid representation has now been proven.

Activity Monitor visibly showed the exact restarted process PID 84047 at
2.53 GB after generation. The disk root reached 9.8 GB with 219 files and 36
files above 100 MB. Quota traces showed active KV and companion eviction back
under the 10 GB soft cap. Correctness and quota enforcement passed this scoped
row, but per-boundary disk amplification/efficiency remains a separate PARTIAL
follow-up; it is not silently called healthy or changed in this emergency PR.

After adding the shared local `.chatUI` agent-option lookup, this exact app was
rebuilt in Release, ad-hoc signed, and passed deep strict verification again.
The existing isolated root and persisted chat were reopened through the real
sidebar; the model and working folder restored and the visible Thinking chip
remained Off. A new unique request executed exactly one `read_file` for
`ChatEngine.swift:144-171`, rendered exactly
`FIX2-CURRENT-SOURCE-OFF-DONE`, and showed TTFT 1.23s, 68.9 tok/s, and 10
tokens. The tool card reported 925 ms. Runtime logs recorded zero reasoning
deltas on the tool step and finalizer, the exact requested arguments, a disk
partial-prefix hit at `boundary=7734 remaining=943`, the same 24 `MambaCache`
plus eight `KVCacheSimple` topology, and no stale call or final. Activity
Monitor visibly showed exact PID 90712 at 2.45 GB after this generation. The
app then exited cleanly. This live row exercises the main ChatView path on the
final source; the explicit persisted-choice branches for Computer Use,
AppleScript, delegation, ordinary-chat exclusion, and remote-agent exclusion
have current source/test evidence but are still not separately live-proven by
this row.

The branch was then rebased cleanly onto `main`
`08eb8bd8a29f79bef9bdb1dd791fcf6a8c1fea4c`, which added unrelated TTS and
slash-command fixes outside this PR diff. The focused matrix was rerun as
`ReasoningTests9.xcresult` with 64 passed, 0 failed, and 0 skipped; the same app
path was rebuilt in Release, re-signed, and passed deep strict verification at
the final executable hash recorded above. In the reopened real UI, the model,
folder, chat, and visible Off state restored. A new unique request produced
exactly one 923 ms `read_file` card for
`AgentReasoningPolicy.swift:40-55`, exact final
`FIX2-REBASED-HEAD-OFF-DONE`, TTFT 0.67s, 69.9 tok/s, and 12 tokens. Logs
recorded exact arguments, zero reasoning deltas on the tool and finalizer
steps, no stale call/final, and a post-tool disk partial-prefix hit at
`boundary=8466 remaining=708` with 24 `MambaCache` plus eight
`KVCacheSimple` layers. Activity Monitor visibly showed exact PID 93334 at
2.45 GB after generation, and the proof app exited cleanly.

The separate Ornith semantic-completion defect remains separate. A faster
direct rail does not prove multi-step task completion, success detection, tool
selection, tool-error honesty, or final-answer correctness.

The first `test-core` run on PR #2105 then caught a real four-surface repin
inconsistency rather than a flaky runtime test: `Package.swift`, the core
package resolver, and the top-level workspace resolver named vMLX
`4b431c6a3f229e2150810b9dea9afe57790ca60b`, while the nested app resolver and
the image/runtime repin tripwires still named its ancestor `24ce87c...`. The
nested resolver and both tripwires now name the exact merged vMLX revision;
the tripwire comment also records the two vMLX #163 cache invariants. Focused
workspace testing in `PinContractTests2.xcresult` reports 94 passed, 0 failed,
and 0 skipped across `ImageGenerationBridgeContractTests` and
`RuntimePolicySourceTests`. The exact Release app above was rebuilt from that
four-surface pin state, ad-hoc signed, and passed deep strict verification.

The post-repin binary was then relaunched with the isolated root, keychain
disabled, and `OSU_MODELS_DIR=/Users/eric/models`. Computer Use first exposed
that reopening the old proof chat restored its old Gemma selection, so that
chat was not counted as Ornith evidence. A new real-user chat visibly selected
`Ornith-1.0-9B-JANG_4M`, the repository folder, and Thinking Off. It executed
exactly one expanded `file_read` card with JSON
`path=Packages/OsaurusCore/Package.swift`, `start_line=77`, and `end_line=82`;
the visible result contained the exact vMLX pin, and the final response was
exactly `FIX2-FINAL-ORNITH-OFF-DONE`. The UI reported TTFT 0.57s, 71.4 tok/s,
11 tokens, and an 820 ms tool call, with no Thought row or protocol leakage.
Activity Monitor visibly showed exact PID 99370 at 2.47 GB after generation.
The proof app then exited cleanly. This is the final-binary current UI smoke;
the broader explicit ON/OFF/restart matrix above remains the preceding
functional-source proof, not a claim that all of it was repeated after the
resolver-only correction.

### Deferred mixed-cache/runtime matrices

These are required follow-up campaigns and must not be described as closed by
the Ornith reasoning patch:

- MiniMax M2.7 JANGTQ and JANG_K: prove load, coherent multi-turn text and
  tools, the bundle's own reasoning-mode semantics, explicit mode changes,
  TTFT/token rate, physical footprint, and prefix/paged/L2 behavior. Do not
  translate its reasoning contract onto the generic boolean rail unless the
  exact bundle template/config explicitly owns that kwarg.
- DSV4 Flash: prove the effective mixed SWA/HCA/CSA/DSA/MLA cache topology,
  full and partial prefix reuse, paged eviction, disk-L2-only restore, raw
  prefill fallback, companion-state synchronization/rederivation, coherent
  tool continuation, TTFT/token rate, and physical footprint. Exercise
  instruct, reasoning, and max separately; no row may infer one mode from
  another.

Both matrices require an isolated Release Osaurus app operated through the UI
with exact local bundle paths and visible cache/resource evidence. Source
inspection, unit tests, load-only rows, and CLI harness output remain PARTIAL.

## 2026-07-19 Bonsai paged-cache eviction checkpoint

Status: **VERIFIED-SOURCE + VERIFIED-LIVE for the paged-chain eviction fix;
PARTIAL for Bonsai answer quality.** This checkpoint used only
`/Users/eric/models/dealign.ai/Bonsai-27b-1bit-JANG-CRACK`. No MXFP4 bundle
was loaded, downloaded, or used as evidence.

### Owning-layer source fix

The pre-fix tiny-pool trace showed that `PagedCacheManager.storeTokenSequence`
released each block immediately after inserting it. With only two blocks, the
pool could recycle a parent while constructing its child, leaving an orphan
leaf that could not satisfy the root-to-leaf prefix walk. Fetch release also
ran root-to-leaf, making the indispensable root the oldest eviction target.
Hybrid SSM replay independently captured every automatic paged boundary even
when the configured pool could retain only one useful boundary.

vMLX commit `24ce87c5ef812f816a242459aec50e544fd228f4`:

- pins the complete block chain until storage finishes;
- re-pins an existing free chain member before constructing descendants;
- releases stored and fetched chains leaf-to-root; and
- caps automatic hybrid companion boundaries to usable paged capacity while
  retaining exact, prompt-minus-one, history, and explicit boundaries.

The diff changes only `PagedCacheManager`, `CacheCoordinator`, `SSMReDerive`,
and their tests. It does not change chat templates, prompts, thinking tags,
reasoning closers, sampler defaults, stop/EOS behavior, token limits, tool
schemas, content-delta assembly, or model routing.

Focused current-source proof passed 109 selected vMLX cache tests: 21 XCTest
cases plus 88 Swift Testing cases covering paged eviction, disk L2, SSM
companion state, TurboQuant transitions, and multi-turn behavior. The Osaurus
pin resolves the same vMLX revision from the manifest and all three lockfiles.

### Exact isolated Release app

- App:
  `/private/tmp/osaurus-cache-campaign-patched-derived/Build/Products/Release/osaurus.app`
- Proof bundle id: `com.dinoki.osaurus.cachecampaignpatchedproof`
- Compiled Osaurus source: `8730a66b8065cce59d5cbcaa654880e554f914e5`
- Embedded vMLX source: `24ce87c5ef812f816a242459aec50e544fd228f4`
- Executable SHA-256:
  `52354ba594599a296e41f131caab27661c54eaae98488c67a56f5e3e1823b90c`
- Runtime root:
  `/private/tmp/osaurus-cache-campaign-patched-live-20260719-2132`

The app was built Release-optimized, ad-hoc signed, verified with
`codesign --verify --deep --strict`, launched keychain-free against the
isolated root, and operated through the actual UI. Settings visibly remained
`All changes saved` when Cache was opened without an edit. The UI then saved
Prefix on, Paged on, two maximum blocks, SSD L2 on, TurboQuant 4/4, and SSM
rederive on; persisted JSON matched those values and did not materialize the
untouched effective-one concurrent-session default.

Final rebased-head recheck after the pin-tripwire correction:

- Osaurus source: `1bbac6d38` (rebased onto `1cbeeb044`)
- Embedded vMLX source: `24ce87c5ef812f816a242459aec50e544fd228f4`
- Isolated bundle id: `com.dinoki.osaurus.cachecampaignpatchedproof`
- Release executable SHA-256:
  `aee9c802642fbf3c8e7ccfce44565c1defd4824e38edc488af900fd57a343b8e`
- Xcode Release build: `BUILD SUCCEEDED`; the app passed strict deep ad-hoc
  code-sign verification.
- Focused current-source Osaurus suites passed 94 tests with zero failures or
  skips: `RuntimePolicySourceTests` and
  `ImageGenerationBridgeContractTests`.
- In the real Settings UI, opening Cache left the footer at
  `All changes saved`. Visible effective settings were Prefix on, Paged off,
  SSD L2 on, Engine Selected/TurboQuant off, and SSM rederive on.
- The exact Bonsai model remained selected with Thinking visibly off. Its
  first smoke answer was streamed without a loop, tool call, reasoning, or
  protocol leakage at TTFT 1.06 seconds and 54.0 tok/s, but it failed the
  requested two-sentence constraint and gave an imprecise explanation. This
  row is a semantic failure, not a pass.
- A visible correction turn produced two numbered sentences at TTFT 1.10
  seconds and 52.5 tok/s, again without a loop, tool call, reasoning, or
  protocol leakage. The admin snapshot recorded five SSD L2 hits and five SSM
  companion hits, paged disabled, effective FP16, 16 ordinary KV layers plus
  48 native Mamba layers, and zero TurboQuant layers. Activity Monitor showed
  the exact proof process at 2.30 GB.

The final-head recheck therefore confirms the source pin, default-off paged and
TurboQuant policy, settings persistence, disk/SSM partial reuse, streaming,
multi-turn correction, speed, and low physical footprint. It does not promote
the failed first-answer instruction/semantic row, and no prompt, parser,
sampler, hidden continuation, or forced-output guard was added for it.

### Paged on plus explicit TurboQuant 4/4

Thinking was explicitly turned off in the real model picker. The first visible
turn produced four coherent numbered sentences with no reasoning or tool call:
TTFT 2.69 seconds, 45.3 tok/s, 79 tokens. The second visible turn produced one
coherent sentence with no reasoning or tool call at TTFT 1.40 seconds and 18.6
tok/s, but it used label `1.` instead of the requested `5.` and gave a generic
LRU explanation. That instruction/semantic row is failed rather than hidden.

After the second turn the admin endpoint reported:

- paged hits 4, misses 6, one eviction, two total blocks, one free block;
- SSD L2 hits 4, misses 12, stores 12;
- SSM companion hits 4 and rederives 6;
- effective KV mode `turbo(4,4)`;
- exactly 16 `KVCacheSimple` layers converted to TurboQuant and all 48 Mamba
  layers retained as native Mamba companion state; and
- a transition from 16 KV + 48 Mamba to 16 TQ-KV + 48 Mamba, with no blanket
  encoding of the Mamba layers.

The prompt-boundary trace reduced the roughly 2,923-token warmup capture from
every 16-token boundary to `[16, 2920, 2922, 2923]`. A coarse UI observation
bounded the first post-answer maintenance tail below 18.3 seconds, versus the
pre-fix 41.04-second diagnostic; this is an improvement bound, not a precise
tail benchmark. Activity Monitor visibly reported the exact proof process at
2.49 GB after the two turns.

### Paged off, SSD-only restart and partial reuse

The real Settings UI turned Paged off while keeping Prefix, SSD L2,
TurboQuant 4/4, and SSM rederive on, then saved successfully. After terminating
and relaunching only the isolated proof app:

- warmup restored an exact 2,923-token disk boundary with zero remaining;
- the user turn restored the same 2,923-token boundary with 36 tokens
  remaining;
- fresh-process counters reached SSD L2 hits 3 and SSM companion hits 3 while
  paged hits/misses both remained zero;
- the real user request triggered the delayed live transition of exactly 16
  normal KV layers to TQ-KV while leaving 48 Mamba layers native;
- visible telemetry was TTFT 1.16 seconds, 44.0 tok/s, 185 tokens, with no
  reasoning, tool call, protocol leakage, stream cutoff, or loop; and
- Activity Monitor visibly reported 2.27 GB for the restarted proof process.

The answer's explanation of SSD controller behavior was factually poor. The
identical prompt was therefore repeated after restoring the UI default codec
and restarting into effective `fp16`; it remained factually poor at TTFT 0.74
seconds and 50.0 tok/s. The FP16 endpoint showed 16 native KV + 48 Mamba,
TurboQuant transition `null`, paged off, and SSD on. This matched control
isolates the misconception to the model's answer quality rather than TQ cache
encoding or delta streaming. No prompt coercion or decoder guard is added.

The proof SSD directory reached 6.9 GB with 17 top-level cache payloads during
the complete native/TQ sequence. TQ and native cache keys remained isolated:
after returning to engine-selected FP16, the first 2,923-token FP16 warmup was
a disk miss rather than consuming the TQ entry.

### Honest boundary

The cache corruption/eviction path is fixed and live-proven on the exact
Bonsai JANG 1-bit bundle. Bonsai's strict instruction following and factual
quality are mixed and are not repaired by this change. The vMLX fork's GitHub
workflow is hard-gated to `ml-explore/mlx-swift`, so all fork jobs are skipped;
the 109-test local Xcode/Swift run is the executable engine evidence. Osaurus
CI must be green on the final four-pin source state before merge.

## Current-source trace

### JANG schema-1 load regression

The exact installed bundle
`/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M/jang_config.json`
declares `tensor_quantization_manifest_schema=1`, 250 entries, asymmetric
quantization, and the `mx.quantize` backend. Its entries record 4/8-bit affine
weights with group size 64 and exact weight/scales/biases keys.

Pinned vMLX `1ca402953bf941341889bb00b186e46bf0c18d6f` introduced
`loadTensorQuantizationManifest` in PR #149. The source comment promises shape
inference fallback for older bundles, but the implementation accepts only
schema 2 and throws `unsupported tensor quantization manifest schema 1`. The
five installed schema-1 bundles under `~/models` are therefore rejected before
model construction. The candidate vMLX change accepts schema 1 only when its
top-level asymmetric `mx.quantize` contract and exact tensor keys validate;
schema 2 retains its per-entry affine validation and unknown schemas still fail
closed. The narrow dependency fix was merged as vMLX PR #153 with merge commit
`a9118c402227accf425113e361cd4520a0cb25ad`; the proven implementation commit
is `a26c7ecec950f18e3d07c8402fbd8c80f40ac764`. The three Osaurus resolution
files are pinned to that exact revision for the candidate build. The two
schema-1 focused tests pass. The final pin-only Release app proved load and
plain generation at that exact pin; the exact evidence is recorded under
Clean-head acceptance below.

The isolated Release app at the candidate vMLX revision visibly selected the
exact JANG_4M folder and reached `Model warm — ready for a fast first response`.
Runtime output recorded `JANG shape walk produced 250 per-layer quant
override(s) over default (bits=4, gs=64)`. The earlier unsupported-schema error
did not recur. This proves the load portion only; the same live row failed the
handbook correctness gate below.

### Ornith post-tool completion

`AgentToolLoop.run` accepts any non-empty model step as `.finalResponse`.
`ModelFamilyGuidance` contains an existing Qwen persistence block specifically
for models that stop after one tool result, but the composer previously selected
that block only from the display/repository id. The installed Ornith bundles
declare `model_type=qwen3_5`; their `Ornith-...` display ids contain no Qwen
marker and therefore received the generic one-line guidance.

A diagnostic experiment carried bundle `model_type` into
`AgentConfigSnapshot` and made a recognized local architecture authoritative
for family guidance, with display-id fallback for remote/legacy models. It did
not change the guidance text, tool schema, stream parser, agent-loop
termination, sampler, generation defaults, or cache runtime.

The first candidate UI run exposed why that plumbing still did not reach the
real external-model path. Insights showed the actual system prompt contained
the generic one-line `## Reminders` block, not the Qwen block. Source trace then
showed `ExternalModelLocator` reads and persists each external bundle's id and
path but its `models()` projection constructs `MLXModel` without `modelType`.
Consequently `findInstalledMLXModelFromCache` can find the selected external
Ornith row but returns `modelType=nil`; the display id contains no `qwen`, so
family routing remains generic. The next candidate records `config.json`
`model_type` at discovery and projects it into `MLXModel`; this requires a new
exact-head Release build and live Insights proof before it can pass.

The rebuilt pre-shrink Release app proves that this metadata plumbing reached
reaches the external-model UI path. Live Insights for the exact JANG_4M run
showed the Qwen family block, including `Keep going until the task is done`, in
the actual system message. That did not fix the behavior: the model made one
valid edit, stopped normally, and claimed an absent second edit. The metadata
experiment was therefore source- and delivery-proven but behaviorally
insufficient. It has been removed from the shipping worktree and must not be
described as the JANG completion fix.

### First candidate JANG_4M correctness row

Real-user UI state: custom Assistant agent, exact JANG_4M selected and warm,
Thinking off, Sandbox off, and
`/tmp/osaurus-gemma-bonsai-emergency-fixture` visibly selected as the working
folder. The exact prompt was `Heads up, we just closed the Denver café. Update
the handbook.`

- Valid `file_read` JSON read all 19 lines and exposed the two-part closure
  procedure.
- Valid `file_edit` JSON removed Denver from Open cafés.
- The model stopped after that one edit, did not add the dated Denver entry,
  and falsely said the handbook was up to date.
- Visible final telemetry: TTFT 0.43s, 69.7 tok/s, 35 tokens.
- Stream logs recorded normal content deltas and both tool invocations; this
  row does not support a content-delta or tool-JSON assembly diagnosis.
- On-disk SHA-256 changed from
  `6e06e8456aa000989133e765f97755a471e7c975635d48a860a931de71f918ab`
  to `b80369249d67bafec424f99646a9a78fbdc520874b25b71174d1e749c2d57aba`,
  confirming the partial mutation.

### Pre-shrink JANG_4M correctness row

Exact source candidate at the time of this diagnostic: Osaurus worktree based on `f3fce1036`, pinned to vMLX
`a26c7ecec950f18e3d07c8402fbd8c80f40ac764`, including the external-model
`model_type` projection fix. Exact Release artifact:
`/tmp/JANG4M Emergency Proof 20260716.app`, ad-hoc signed under bundle id
`com.dinoki.osaurus.gemmabonsaiemergencyproof2`. The copied artifact changes
only its proof display name; its Release executable comes from
`/tmp/osaurus-gemma-bonsai-emergency-proof-a26c`.

Real-user UI state was set and observed again: Storage pointed at
`/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M`, LM Studio discovery was
off, the exact Custom model folder row was selected and warm, a real Assistant
agent was created and selected, Thinking was off, Sandbox was off, and the
fixture folder was selected through the macOS folder picker.

- Load passed again with `JANG shape walk produced 250 per-layer quant
  override(s) over default (bits=4, gs=64)` and no schema-1 rejection.
- Live Insights showed the actual system prompt contained the Qwen persistence
  guidance. This proves architecture metadata reached prompt composition.
- The request contained a valid `file_read` call, a successful result exposing
  the explicit two-part closure procedure, then a valid `file_edit` call that
  removed only the Open cafés row.
- The successful edit result's diff showed no Closure log addition. The model
  then ended with normal finish reason `stop` and falsely claimed
  `2026-07-15 — Denver — Larimer Street` had been added.
- UI telemetry showed TTFT 0.59s, 70.1 tok/s, 33 tokens. Insights for the final
  request recorded 3,563 input tokens, 33 output tokens, 31.1 tok/s, max tokens
  16,384, and finish reason `stop`; both displays are retained rather than
  treating either as the sole speed truth.
- On-disk SHA-256 again changed from
  `6e06e8456aa000989133e765f97755a471e7c975635d48a860a931de71f918ab`
  to `b80369249d67bafec424f99646a9a78fbdc520874b25b71174d1e749c2d57aba`.

This row is a semantic post-tool completion failure. It is not evidence of
content-delta loss, malformed tool JSON, parser truncation, a length cap, or an
unclosed reasoning channel. Thinking-on also failed: it performed a read after
the partial edit, observed only the Phoenix closure entry, then still claimed
the Denver entry was live and shared the incomplete file. Do not add a
stream/parser fallback for this trace.

## Pre-fix isolated Release evidence

App: `/tmp/osaurus-routing-guidance-proof2/Build/Products/Release/osaurus.app`

Bundle id: `com.dinoki.osaurus.routingguidanceproof2`

Source: routing diagnosis checkpoint `0b9e809ff`, vMLX
`1ca402953bf941341889bb00b186e46bf0c18d6f`.

Real-user setup was performed visually: onboarding, Storage -> External Models,
exact local model folder, model selection, Thinking off, fixture folder, and
Sandbox off for writable host-folder tools.

- Ornith 9B JANG_4M: load blocked before generation with
  `Invalid JANG config: unsupported tensor quantization manifest schema 1`.
- Ornith 9B MXFP8, three fresh Thinking-off trials of
  `Heads up, we just closed the Denver café. Update the handbook.`:
  - every trial captured valid `file_read` and `file_edit` JSON and rendered a
    normal final response; no content-delta or tool-JSON loss was observed;
  - 51.2, 48.8, and 76.0 tok/s;
  - all three stopped after one partial edit and failed the handbook's explicit
    closure procedure;
  - trials 1 and 3 falsely claimed a Closure log entry that was absent on disk.

Therefore the permitted MXFP8 evidence points to architecture-specific
multi-step persistence/completion behavior, not a shared content-delta or JSON
assembler defect. The screenshot's `Search knowledge`/`Read knowledge` schema
may be different from writable host-folder tools and remains an explicit
separate row.

## Deferred MXFP4 structural-recovery investigation

This is a required follow-up investigation, not a current runtime claim. Do not
download, load, benchmark, or infer behavior from MXFP4 in the emergency lane.
Do not add an MXFP4 fallback to this PR unless an exact user-provided bundle
later reproduces the defect and the raw stream proves which owning layer is
incomplete.

A safe fallback cannot trigger merely because an answer is short, non-empty,
or semantically incomplete. The live JANG_4M/MXFP8 handbook rows produced
syntactically valid tool calls and a syntactically valid final answer, so a
stream parser cannot know from those tokens alone that the model failed to
finish the user's multi-step task. Treat that semantic-persistence failure as a
different class from a structurally truncated MXFP4 response.

Before implementing recovery, classify a reproduced failure from the original
stream deltas, finish reason, parser state, active thinking mode, exact tool
schema, and already-executed tool-call ids:

1. incomplete JSON argument assembly for an otherwise recognized tool call;
2. incomplete recognized tool-call envelope;
3. a recognized reasoning channel that opened but did not structurally close;
4. a transport or length truncation reported while the parser still has an
   incomplete recognized structure;
5. ordinary early EOS with valid plain text; or
6. a syntactically valid but semantically incomplete multi-step task.

Only classes 1-4 are candidates for structural recovery. Class 5 requires
model/runtime evidence before any intervention, and class 6 must never be
"repaired" by inventing completion intent in the parser.

Current source already contains two important fail-honest mechanisms. vMLX
`ToolCallProcessor.processEOS()` reparses a buffered envelope at EOS and emits a
call only when the format parser returns a valid call; `ReasoningParser` records
whether EOS arrived inside reasoning, and `GenerateCompletionInfo` carries that
as `unclosedReasoning` into Osaurus's visible warning. Any new work must extend
those contracts rather than bypass them.

Candidate handling, in strict preference order:

- If the inner tool payload is complete and validates against a registered tool
  but only its format-specific wrapper closer is absent, fix that exact
  parser's `parseEOS` path. This consumes only bytes the model actually emitted;
  it does not inject a closer or invent arguments. Prove first that the current
  generic EOS reparse does not already cover the reproduced wire form.
- If a complete final-channel marker is present but was routed as reasoning,
  fix the exact capability/parser marker mapping. Do not relabel arbitrary
  unclosed reasoning as a final answer.
- If JSON arguments or the tool body are themselves incomplete, do not repair,
  pad, close, or execute them. Surface a typed incomplete-response state with
  the original bytes preserved and an explicit user Retry affordance.
- Automatic replay is eligible only for a proven transport interruption, using
  the existing `retryWithoutCharge` class, before any tool side effect was
  committed. It must replay the same logical request at most once, carry the
  exact tool-call/idempotency state, and reject duplicate tool execution.
- Natural EOS, a valid short answer, `unclosedReasoning`, or semantic task
  incompleteness must not auto-retry. Ignoring EOS, forcing a close token,
  adding a hidden Continue prompt, changing sampling, or moving reasoning text
  into the answer would mask the model/runtime defect and is prohibited.

Every structural path must emit telemetry naming the trigger, finish reason,
parser state, buffered-byte count, schema-validation result, retry/duplicate
decision, and final outcome.

Required proof before promotion: a raw-stream regression fixture from the exact
affected MXFP4 bundle; focused tests for each structural class and for duplicate
tool suppression; negative tests showing ordinary EOS, valid short answers,
JANG_4M, MXFP8, Gemma, and unaffected model families never trigger; and a fresh
Release-app UI matrix with Thinking off/on, plain answer, reasoning answer,
single/multi-tool workflows, injected tool errors, multi-turn continuation,
visible token/s, physical footprint, and cache telemetry. Keep this work out of
the Gemma/Bonsai emergency merge unless that evidence directly ties it to the
same narrow owning-layer fix.

## Clean-head acceptance

Final pin-only Release build and test evidence:

- Derived data: `/tmp/osaurus-gemma-bonsai-emergency-proof-a26c`
- Exact build product:
  `/tmp/osaurus-gemma-bonsai-emergency-proof-a26c/Build/Products/Release/osaurus.app`
- Computer Use proof copy:
  `/tmp/JANG Schema1 Pin Rebased Final 20260716 0117.app`
- Isolated bundle id: `com.dinoki.osaurus.jangschema1pinproofrebased`
- Fresh app root: `/tmp/osaurus-jang-schema1-pin-rebased-root-0117`
- vMLX checkout verified from the Release build graph:
  `a26c7ecec950f18e3d07c8402fbd8c80f40ac764`
- Xcode Release build: `BUILD SUCCEEDED`; the proof copy was ad-hoc signed and
  passed strict deep code-sign verification.
- Focused Osaurus suites:
  `ImageGenerationBridgeContractTests` and `RuntimePolicySourceTests`, 92
  passed, 0 failed, 0 skipped. Their resolved graph also used the exact
  `a26c7ecec950f18e3d07c8402fbd8c80f40ac764` revision.

Final real-user UI row:

- Storage visibly used
  `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M`; LM Studio discovery was
  visibly toggled off and the model picker identified the row as `Found in
  Custom model folder`.
- The exact `Ornith 1.0 9B JANG_4M` row was selected. Thinking initially came
  on with model selection and was visibly toggled off before sending.
- Runtime logged `JANG shape walk produced 250 per-layer quant override(s)
  over default (bits=4, gs=64)` and did not emit the former unsupported-schema
  rejection.
- The UI reached `Model warm — ready for a fast first response` and answered
  `What is 2 + 2? Answer in one sentence.` with `2 + 2 equals 4.`
- Visible row telemetry: TTFT 1.25s, 74.0 tok/s, 8 tokens. This is a narrow
  load/plain-generation smoke row, not a family-wide throughput claim.

The final source diff contains only the vMLX pin in all resolution surfaces,
the corresponding pin-expectation updates, and this ledger. It contains no
automatic-routing, hardware-guidance, prompt, sampler, parser, cache, RAM,
image, delegation, or TurboQuant implementation change. The reproduced
Ornith handbook failure remains documented above as a syntactically valid but
semantically incomplete multi-tool workflow; merging this pin must not be
described as fixing it. MXFP4 was never downloaded, loaded, or used.
