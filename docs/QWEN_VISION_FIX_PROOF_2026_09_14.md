# Installed vision evidence — implementation and proof

Image admission and attachment preservation have current source and local Release
UI/API evidence below. **PARTIAL for the original reporter's exact failure and
broad video quality**: the reporter's bundle/error are unavailable, and open-ended
video answers remain unreliable. This is not a 16 GB RAM-safety qualification.
Merge status belongs to PR #2756; this document does not imply it is merged.

## Change and source trace

`Models/Configuration/LocalVisionEvidence.swift:29` reads the installed config,
processor config and actual safetensors headers. The configured architecture must
exist in the engine's VLM registry. Index entries must exist in their selected
shard headers. Qwen2/2.5/3VL, Qwen35/MoE and Qwen4Exp require patch input, every
declared encoder block, and merger weights; Gemma4/unified require patch input,
declared encoder blocks and the vision embedding projection. Other registered
architectures require encoder input and block evidence. Header reads are bounded
to 64 MiB per shard and validate offsets against actual file size. These are
component-presence checks, not full shape, quantization or numerical validation.

`VLMDetection`, `MLXModel`, `ModelMediaCapabilities`, composer/send resolution and
MLX preflight share this evidence. Local display names neither grant nor deny
vision. External HF/model locators participate in API resolution. Explicit local
negative evidence overrides picker hints. Preflight refreshes the directory;
invalidation generations stop an older read from republishing after notification.

`Views/Chat/ChatView.swift:6645` validates new attachments before history filtering.
The selected-model subscriber preserves draft attachments. Unsupported sends show
a visible error; switching to a compatible model can recover the image.
`Services/ModelRuntime.swift:4444` reconciles installed vision expectations with
constructed model modalities, rejecting a silent text-factory fallback.
Independent audio projection evidence survives an absent optional vision tower.
`qwen4_exp` receives its engine architecture's video capability; no product-name
pattern was added. Video quality is limited as recorded below.

Core's swift-http-types lock moves 1.5.1 to the app's existing 1.6.0 to resolve
NIO's FoundationURL trait for SwiftPM tests. The vMLX pin is unchanged.
The HTTPAPI prefix probe now checks successful, nonempty responses and a hit in
either the memory-prefix or disk-L2 tier. A zero memory-prefix counter is not a
failure when the active topology requires disk restore. No hit in either tier
still fails. No sampler, thinking control, template, or runtime output repair was
introduced.

## Tested source and artifacts

- Core/app source: `7a4f5057326ea3c5e95aa33572577d25fba693d4`.
- Evals source: `0e5d76f79abfdef3cd80ad029e31f14a651a4765`; app/Core trees are
  identical to 7a4f50573. Subsequent proof-document commits do not change them.
- vMLX: `67ccb4b347a23820b838a98f0c195b0c29c676d2`, checked in both build trees.
- Fresh isolated Release binary SHA256:
  `da840573f8da69e6e104270b4587928fad4fe52903a61d5965b54de4a2031173`.
- App: `/private/tmp/osaurus-qwen-vision-derived/Build/Products/Release/osaurus.app`,
  bundle `com.dinoki.osaurus.visionproof20260913`, development version 1.0.
- Test root `/private/tmp/osaurus-qwen-vision-ui`, API `127.0.0.1:19314`.
- Private evidence: `/Users/eric/vmlx-private-evidence/qwen-vision-2026-09-13/`.
  Images remain outside the repository. `release-build-final.json` and
  `eval-build-settled.json` identify binaries/locks. Evals resolves some other
  dependency versions differently; it supplements, rather than replaces, the
  actual app tests.

Host: local 128 GiB Mac. Models are referenced in place, with no changes to their
source files. Test agent has empty system instructions and no tools, knowledge,
memory, web, delegation or screen context. Actual UI Thinking control is Off.
Sampler overrides are blank; live cache-stats reports `sampler_was_changed=false`,
temperature 1, top-p .95, top-k 64 for Gemma and 20 for both Qwen bundles. API
probes explicitly cap output at 1024 tokens. Runtime policy: safe_auto slider 2,
strict one-model residency, continuous batching on/max 1, prefix on, paged RAM KV
off, disk block cache on, legacy disk cache off, live KV engine_selected, stored
KV auto. This is a vision lane, not a low-RAM/batching stress campaign.

## Current Release image matrix

Real image A: red circle left, blue square right. B swaps their colors. UI tests
ask for the shapes/colors and follow up asking which is on the right. API tests
send A, repeat A, then B. All have correct shape/color/order, visible final text,
no protocol leakage or loop, and a normal terminal state. UI Stop disappears and
input unlocks. These simple-image results do not establish arbitrary captioning
quality.

| Config architecture / exact bundle | UI image / follow-up tok/s | API A / repeat A / B tok/s | Score | Peak physical footprint GiB |
| --- | --- | --- | --- | --- |
| gemma4 / OsaurusAI/gemma-4-E2B-it-8bit, snapshot 433003a1e3fbfd10819ad15179d5e3c4d02d7ea7 | 93.1 / 89.7 | 93.2677 / 92.4023 / 91.9156 | UI 2/2, API 3/3 | 1.888 |
| qwen3_5 / JANGQ-AI/Qwen3.8-27B-JANG_4D | 25.4 / 25.7 | 25.6658 / 25.7521 / 25.7504 | UI 2/2, API 3/3 | 6.560 |
| qwen4_exp / JANGQ-AI/Qwen3.8-Flash-Next-JANG_1L | 46.4 / 46.8 | 47.4869 / 47.3792 / 47.2869 | UI 2/2, API 3/3 | 46.873 |

Evidence: `final-gemma-{recovery,followup}.ax.txt/png`,
`final-qwen35-{first,followup}.ax.txt/png`,
`final-qwen4exp-{first,followup}.ax.txt/png`; API JSON/request/cache artifacts
`final-gemma-api-*`, `final-qwen35-image-*`, `final-qwen4exp-image-*`.
Gemma's first current UI row recovers the retained image from the negative test.

Footprint uses `proc_pid_rusage` rusage_info_v2 `phys_footprint`, sampled every
0.5 seconds, not RSS or allocator bytes. Model windows derive from live
`last_load_decision.timestamp` records. Raw `physical-footprint-final.jsonl` and
`physical-footprint-final-summary.json` name the windows and source records.
These sampled peaks are not instantaneous maxima, a 16 GB qualification, or a
claim that Qwen4Exp has a small working set.

## Negative cases, policy, and cache

- Real text Qwen3-0.6B-8bit exposed as **Qwen3 VL Proof Text**: picker has no
  Vision badge; switching to it preserves the attached draft image; Send shows
  the typed unsupported-image error and settles. API rejects with HTTP 400
  before inference. Artifacts: `final-retained-draft.*`,
  `final-unsupported-attachment.*`, `final-vl-name-negative*`.
- Switching back to Gemma recovers the retained image and answers its follow-up.
- Current Release Settings Force Off → Save: HTTP 400, explicit server vision
  policy error, 28 ms. Auto → Save → navigate away/back → quit/relaunch: Gemma
  image returns the correct answer, HTTP 200, 96.7491 tok/s. Artifacts:
  `final-force-off*`, `final-auto-settings.ax.txt`, `final-auto-relaunch*`.
- Actual topology: Gemma 3 KV + 12 rotating layers; Qwen35 16 KV + 48 Mamba;
  Qwen4Exp 12 KV + 36 Mamba. All require disk-backed restore; all report
  `turbo_quant_kv_layer_count=0`; paged RAM is off. Repeated images hit disk L2;
  changed images have different media salts and correct changed answers.
- Qwen sidecar counters are zero, but v2 disk payloads contain recurrent state:
  Qwen35 48 state0/state1 pairs at offset 216; Qwen4Exp 36 pairs plus state2/3
  at offset 155. `qwen-inline-ssm-cache-evidence.json` records actual headers.
  Engine source: `Cache/TQDiskSerializer.swift` serialization/deserialization and
  `Evaluate.swift` disk restore. `hasArrays=false` refers to a separate sidecar;
  it does not mean the inline Mamba state is absent. Do not claim sidecar reuse
  or TurboQuant KV-layer topology.

## Automated scores

- Focused Core: **156/156, 8 suites**, 3.399 s after build:
  ModelMediaCapabilitiesMCDCTests, VLMDetectionTests,
  CapabilityFromDirectoryTests, MultiTurnCapabilityStabilityTests,
  CapabilityFromModelIdTests, ComposerAudioCapabilityTests,
  ChatAttachmentSecurityTests, RuntimePolicySourceTests.
  Raw `focused-tests-settled.log`.
- Evals unit: **345/345, 42 suites**, 1.686 s; `eval-unit-tests.log`.
- Full HTTPAPI lane at 0e5d76f79: Gemma **16 pass / 1 unsupported-video skip / 17**;
  Qwen35 **17/17**; Qwen4Exp **17/17**. Total **50 pass, 1 skip / 51**.
  `evals-final-{gemma,qwen35,qwen4exp}-httpapi.json/log`,
  `evals-final-summary.json`. The simple video grader is narrower than open-ended
  video quality; the next section records its counterexamples.
- Installed-header probes (not inference): Gemma 2649 tensors/27.9 ms;
  Qwen35 2379/23.8 ms; Qwen4Exp 3257/47.7 ms. Neutral and misleading aliases
  produce identical capabilities. Nemotron Omni header-only extra row:
  1835 tensors/33.3 ms, image/video/audio. No Omni inference claim.
- Regression fixtures cover missing/null config, processor/input/encoder/projection,
  stale index, invalid headers/offsets, directory isolation, invalidation/refresh,
  provider fallback, current attachments, and independent optional audio.

## Video diagnostic — PARTIAL, not repaired by prompt changes

Additional app API tests use independently ffmpeg-encoded H264, 224x224, 2 fps,
8 frames/4 seconds: A red then blue; B blue then red. With the open-ended question
"Which color appears first and which appears second in this video?":

- Qwen35 **0/3** (A, repeat A, B): describes only the first color as a still image,
  normal stop, 25.1–25.65 tok/s. Raw `final-qwen35-video-{a,repeat-a,b}.json`.
- Qwen4Exp **2/2 for color order**, but **0/2 for faithful scene details**: invents
  a split-screen transition or incorrect timestamps. 47.0092 / 47.222 tok/s.
  Raw `final-qwen4exp-video-{a,b}.json`.
- Diagnostic with the existing eval's structured question on the SAME Qwen35
  clips: **2/2**, `first=red second=blue` and reverse, 25.4966 / 26.0141 tok/s.
  `final-qwen35-video-eval-prompt-{a,b}.json`. This demonstrates prompt-dependent
  behavior, not a runtime fix; no production prompt/template change was made.

AVFoundation probe decoded all eight frames with both color halves (raw
`video-frame-probe-a.json`); it reproduces engine timestamp sampling but is not a
processor tensor probe. Actual engine traces show video token 248057, 222 input
tokens, a cold all-tier miss for A, disk reuse for repeat A, and distinct media
salts/all-tier miss for B. This rules out a simple stale-image cache hit and
supports video delivery. It does not establish tensor/position correctness or
attribute the remaining quality defect. Engine video/template/temporal behavior
and exact reporter bundles still need separate investigation before claiming
broad video support is reliable.

## Preserved earlier failures and investigation limits

Initial focused tests were 153/154: an obsolete source assertion demanded the
removed name exclusion. Earlier full HTTPAPI scores were Gemma 15 pass/1 fail/
1 skip and Qwen 16 pass/1 fail each: all three failures were the memory-prefix-only
counter assertion despite disk L2 hit delta 1. Both sets of raw failures remain.
An Evals compile attempted during a source change was discarded and rebuilt.
The original background app launcher exited and CUA relaunched without test env;
that process was closed before inference, then a persistent exec launch used.

Earlier app source f780f6ef75f774832203256e582eb386105b8601 had image UI/API
15/15 correct but exposed silent draft deletion on model switch. Commit 5bed81bd5
repairs it; current negative/recovery rows above re-exercise that path. Earlier
Qwen4Exp cancel-load/retry evidence is retained but is not a final-head cancel
proof. A transient file picker Open-disabled state on the final Gemma attempt
resolved by cancelling/reopening; later pickers worked. Cause is unattributed.

The original Discord images returned HTTP 403. Exact reporter repository IDs,
quantization and error text remain missing. No causal regression was assigned to
another contributor: older Osaurus #2389/#2427/#2442/#2504 fixes remain ancestors;
engine #315/#359 optional-tower construction and first app pin #2598 are inspected
boundaries, not proven culprits. See
[the historical audit](QWEN_VISION_REGRESSION_2026_09_13.md) for source traces,
executed old-detector cases, PR links, and remaining reporter questions.
