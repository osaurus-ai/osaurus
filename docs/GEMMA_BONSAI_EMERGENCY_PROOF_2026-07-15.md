# Gemma/Bonsai Emergency Proof Ledger

Last updated: 2026-07-19 (America/Los_Angeles)

Verdict: **PASS for the narrow schema-1 JANG loader pin; PARTIAL for the
separate Ornith multi-step semantic-completion defect, which is not changed or
claimed fixed by this PR.**

## Local model root (hard rule)

Use only the user's canonical local model root, `~/models`
(`/Users/eric/models`), for every runtime and live-app row in this lane. Record
the exact bundle path for each row. Do not substitute a model from Downloads,
the Hugging Face cache, or another checkout.

Current Ornith fixtures:

- JANG_4M: `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M`
- MXFP8: `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-MXFP8`

This branch starts from `origin/main` `504d174ab`. Bonsai structured-chart and
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

## Priority and current evidence

| Priority | Row | Status |
| --- | --- | --- |
| P0 | Installed JANG schema-1 bundles load | LIVE LOAD PASS on exact JANG_4M; multi-step correctness still fails |
| P0 | Ornith/Qwen post-tool cutoff or partial completion | REPRODUCED AS PARTIAL MUTATION on JANG_4M and MXFP8; exact pre-write cutoff not reproduced |
| P0 | Bonsai tiny-pool paged-cache eviction and hybrid replay tail | VERIFIED-SOURCE + VERIFIED-LIVE for the cache defect; model semantic-quality controls remain mixed |
| P0 | PR scope contains no deferred routing/hardware changes | PASS for current pin-only source/test diff plus ledger; repeat on final diff |
| P0 | Exact pin-only candidate Release UI rerun | PASS for JANG_4M load and plain generation; semantic handbook behavior remains a separate reproduced failure |
| P1 | Gemma/Bonsai tool correctness regressions | NOT YET RUN on clean head |
| P1 | TurboQuant default-off, explicit toggle, persistence, Gemma rotating-SWA topology | NOT YET RUN on clean head |
| P1 | Qwen 3.5 text/VL hybrid rederive, prefix/L2 disk restore, cache growth in GB | NOT YET RUN on clean head |
| P1 | Memory Safety warning, setting change, larger-model load, restore refusal | NOT YET RUN on clean head |
| P1 | Image generation/editing and spawn/delegation RAM admission/notifications | NOT YET RUN on clean head |
| P2 | MXFP4 structurally incomplete answer/reasoning/tool-envelope recovery | DOCUMENTED ONLY; no MXFP4 runtime claim and excluded from the emergency diff without a later exact-model reproduction |

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
