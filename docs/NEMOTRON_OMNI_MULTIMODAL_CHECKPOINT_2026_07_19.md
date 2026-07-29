# Nemotron Omni Multimodal Checkpoint — 2026-07-19

Status: **PARTIAL — the current isolated Release app passes image, AIFF audio,
video, persisted mixed media, paged/L2 hybrid restore, selective 4/4
TurboQuant-KV, and default restoration. Automatic tool choice, one-shot mixed
instruction compliance, detailed TQ-video accuracy, low-RAM override, and
delegation remain open.**

Exact proof model:

`/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-JANGTQ4-CRACK`

This checkpoint does not use or make claims about MXFP4.

## Current follow-up source and app

The current cache/media follow-up uses:

- Osaurus `1244a8a94ff8b5b3b00a375fe138964f5589a809`;
- vMLX Swift `0975201e745a1774fda1e78d1bc99b5bd1c668c6`;
- Release app
  `/tmp/osaurus-nemotron-cache157-dd-9662b79/Build/Products/Release/osaurus.app`;
- isolated bundle id `com.dinoki.osaurus.nemotroncache157proof`;
- isolated storage root
  `/tmp/osaurus-nemotron-cache157-runtime-ae910a19-clean2`.

The app was built from the exact source above, ad-hoc signed, and operated
through its real SwiftUI Settings, agent editor, attachment picker, and chat
composer. The model remained the non-MXFP4 JANGTQ4 bundle named above.

## Follow-up app-side root causes

The generic attachment picker accepts `UTType.audio`, but
`FloatingInputCard.audioExtensions` did not include AIFF/AIFF-C, CAF, or the
common alternate WAV/MPEG/M4A extensions. A selectable AIFF file could
therefore fall through the router instead of reaching `attachAudio`. The
follow-up adds `wave`, `mpeg`, `x-m4a`, `aif`, `aiff`, `aifc`, and `caf` to the
same tested routing set. `ChatAttachmentSecurityTests` now checks all accepted
audio extensions; 10/10 focused tests passed in
`/tmp/osaurus-nemotron-aiff-attachment-xcode-tests-1244a8a94.log`.

The tools-enabled assistant also reproduced a separate prompt/schema defect:
model-facing capability guidance contained example IDs that were not live
capabilities. The follow-up removes those fictitious IDs and requires exact IDs
from the live list or discovery results. This does not claim that general
automatic tool selection is solved: the AIFF tools-enabled row still selected
irrelevant web search after first transcribing the phrase correctly.

Source trace found no image/audio overwrite in the mixed-media path.
`ModelRuntime.mapOpenAIChatToMLX` extracts images, videos, and audio separately
into the same message; `MLXBatchAdapter` preserves those fields while
pre-encoding audio; `NemotronHOmniProcessor.prepare` and
`NemotronHOmni.prepare` process and splice visual and audio placeholders
independently. The current mixed row below therefore remains an honest
instruction-following partial, not a transport fix invented without evidence.

## App-side root cause

Nemotron Omni keeps the text decoder contract in `config.json` and the outer
multimodal contract in `config_omni.json`. `VLMDetection.isVLM(at:)` inspected
only `config.json` for `vision_config`, so the installed bundle could be
filtered/routed as text-only in Osaurus even though vMLX's factory supports its
RADIO vision, temporal video, and Parakeet audio towers.

The detector now treats a present `config_omni.json` sidecar as multimodal,
matching the vMLX factory boundary. Other families retain the existing
`vision_config` rule.

## Exact engine pin

OsaurusCore and all three checked-in package resolutions point to vMLX commit:

`4634af5151ffd71262d180e32962939dd8b2263f`

That engine commit fixes the Nemotron vision projector and RADIO normalization,
removes the hidden media-only prompt/Thinking override, bounds multimodal Mamba
prefill, enables safe image/audio hybrid-prefix capture, and adds strict
multimodal regression coverage. Its detailed direct-model matrix is in
`docs/NEMOTRON_OMNI_MULTIMODAL_CHECKPOINT_2026-07-19.md` in vmlx-swift.

## Pre-patch live reproduction

The isolated Release app at the former `6fb10658` pin selected the exact model
through the UI with Thinking visibly off. It correctly described a two-region
image at 115.1 tok/s and recalled it in a text-only follow-up at 55.4 tok/s, but
reached a 76 GiB physical-footprint peak and visibly re-prefilled `0/4729` on
the follow-up. The isolated cache database contained full 4433/4577 and
4729/4758 boundaries but no reusable stripped media prefix. This proves the
old failure; it does not verify the newly pinned build.

## Current-source evidence

`/tmp/osaurus_nemotron_focused_tests2_20260719.log`:

- `VLMDetectionTests/isVLMAtDirectory_trueForNemotronOmniSidecar()` passed.
- Existing text-ZAYA, ZAYA-VL, Qwen-VL, DiffusionGemma, missing-config, and
  malformed-config detector rows passed, guarding adjacent routing behavior.
- `MultimodalContentPartTests` passed for image/audio/video content decoding,
  video forwarding, WAV-to-samples, container materialization, all-role media,
  and MP4 extension preservation.
- Two live-audio registry freshness tests were skipped by their existing
  environment preconditions; they are not counted as passes.

## Current isolated Release-app proof

The exact `4634af5151ffd71262d180e32962939dd8b2263f` pin was built in Release at
`/tmp/osaurus-nemotron-proof-dd-4634/Build/Products/Release/osaurus.app`,
ad-hoc signed, and launched as the non-production bundle
`com.dinoki.osaurus.nemotron4634proof` with
`OSAURUS_TEST_ROOT=/tmp/osaurus-nemotron-ui-proof-20260719-4634`. The model was
selected from `/Users/eric/models` through the real model picker. The UI
identified it as `Nemotron Omni Nano JANGTQ4 CRACK`, VLM, Vision + Language,
and JANGTQ4. No MXFP4 bundle was loaded.

The real Server settings showed and persisted:

- Prefix cache on, paged RAM cache off, SSD L2 on, SSM re-derive on.
- Live KV codec `Engine Selected` by default. The fresh post-test restart
  reported effective KV mode `fp16`, six KV layers, 23 Mamba layers, zero
  TurboQuant-KV layers, disk-backed restore required, and paged cache off.
- RAM safety `safe_auto`, slider 2, 70% load budget, one concurrent request,
  and a 65,536-token KV cap. The exact external bundle had no catalog size
  estimate, so this run did not display the low-RAM override warning and does
  not prove that separate warning/override UI.
- Thinking was changed through the real toolbar control. The persisted model
  option encoded `disableThinking=true` for the off rows and
  `disableThinking=false` for the on rows.

Visible/default-cache rows recorded in the isolated chat database at
`/tmp/osaurus-nemotron-ui-proof-20260719-4634/chat-history/history.sqlite`:

| Row | Result |
|---|---|
| Image, Thinking off | Correct yellow upper half / blue lower half; TTFT 6.46s, 103.4 tok/s, 32 tokens. |
| Image follow-up, no attachment | Correct recall; TTFT 0.95s, 103.2 tok/s, 16 tokens. |
| App restart + L2-only image recall | Correct without reattaching; TTFT 1.17s, 102.6 tok/s, 13 tokens. Fresh-process telemetry reported four disk-L2 hits and four SSM-companion hits while paged/prefix counters remained zero for this paged-incompatible hybrid topology. |
| Audio, controlled transcript | Correctly returned `The verification phrase is "Silver Comet 42."`; TTFT 1.05s, 101.3 tok/s, 13 tokens. The preceding attempt made an unsolicited but schema-valid `share_artifact` call, so automatic tool choice is still a separate user-visible caveat rather than an audio-transport pass. |
| Image + audio | Correctly reported yellow over blue and `silver comet 42`; TTFT 5.53s, 101.4 tok/s, 27 tokens. |
| Video, Thinking off | Correctly recognized the SMPTE bars and changing timecode/frame label; TTFT 12.20s, 109.3 tok/s, 198 tokens. It estimated the final frame as 140 rather than the fixture's late-frame value near 148, so fine numerical video accuracy is not claimed. |
| Thinking already on, fresh mixed-media chat | Correct one-time image/audio answer; TTFT 5.56s, 101.8 tok/s, 32 tokens, followed by a correct no-attachment turn at 0.95s and 101.9 tok/s. |
| Off-to-on transition follow-up | One run repeated the correct sentence three times. A fresh Thinking-on chat did not reproduce it. This remains PARTIAL; no forced closer, sampler override, or output post-processing was added. |

`vmmap -summary` measured 17.6-17.9 GiB physical footprint and a 20.3 GiB
peak during the current app matrix, replacing the pre-patch 76 GiB peak.

## Explicit TurboQuant-KV toggle proof

TurboQuant-KV was enabled by a real user path in Server -> Settings -> Cache
with explicit 4-bit keys and 4-bit values, then the app was restarted. This is
independent of the model's JANGTQ4 weight format. Runtime telemetry reported:

- effective mode `turbo(4,4)`;
- exactly six ordinary KV layers converted to six TurboQuant-KV layers while
  all 23 Mamba layers remained Mamba companion state;
- three TurboQuant compressions, four disk-L2 hits, four SSM-companion hits,
  zero paged hits, and a 20.3 GiB physical-footprint peak.

The mixed image/audio answer remained correct at 6.71s TTFT and 21.3 tok/s;
its no-attachment follow-up was correct at 0.97s and 68.3 tok/s. Video remained
coherent and recognized SMPTE bars, but the same-prompt A/B materially degraded
quantitative accuracy: 4/4 TurboQuant described the five-second clip as five
minutes / 24 frames, whereas the restored FP16-cache run tracked the counter to
about 140 at 11.91s TTFT and 110.6 tok/s. The 4/4 hybrid-video row is therefore
PARTIAL, not a quality pass. The UI was restored to `Engine Selected`, saved,
and a fresh restart confirmed `fp16`, zero TurboQuant-KV layers, and paged cache
off.

## Current `0975201e` / `1244a8a94` live matrix

A real custom agent named `Media No Tools` was created through the UI. Its
Tools and Memory abilities were both visibly switched off so media transport
could be separated from tool choice and legacy-memory contamination.

| Row | Current visible result |
|---|---|
| AIFF, controlled agent | The picker showed `nemotron-audio.aiff`; the answer was `AmberLighthouse7`, TTFT 0.39 s, 103.4 tok/s, 5 tokens. The database persisted `type=audio`, `format=aiff`. Missing spaces/number normalization remain a model ASR/instruction caveat. |
| AIFF, default tools-enabled assistant | The response initially streamed `Amber Lighthouse 7`, then made irrelevant web searches and fabricated retrieval guidance; TTFT 1.15 s, 101.4 tok/s, 152 tokens. This reproduces a tool-routing defect, not attachment loss. |
| Video, default FP16 cache | `red-green-blue.mp4` returned `Red, Green, Blue`; TTFT 7.74 s, 103.8 tok/s, 6 tokens. |
| Image + AIFF, first turn | The first answer returned only `The verification code is Amber Lighthouse 7.`; TTFT 1.25 s, 107.1 tok/s. This is not counted as a one-shot mixed-instruction pass. |
| Image follow-up, no reattachment | `The background color is red and the center-square color is blue.`; TTFT 0.57 s, 104.5 tok/s. This proves the image remained in the persisted mixed turn. |
| Mixed follow-up after cache-setting reload | Correctly combined the code, red background, and blue center square in one sentence; TTFT 2.16 s, 108.6 tok/s, 24 tokens. |
| Paged cache, 64 blocks | Cold `CACHE PRIME`: 2.06 s, 105.6 tok/s. Warm `CACHE PAGED`: 0.53 s, 101.1 tok/s. Telemetry reported 97 paged/prefix hits and zero evictions. |
| Paged eviction to disk | With block size 64 and max blocks 2 selected in Settings, the coherent mixed follow-up produced 152 evictions, two disk-L2 hits, and two exact SSM-companion hits with no companion miss/rederive. |
| Paged-OFF app restart + disk L2 | Under restored defaults an image turn returned red background / blue square at 0.93 s and 106.9 tok/s. After quitting and relaunching the isolated app, History reopened the chat and a no-attachment follow-up returned `RED / BLUE` at 0.47 s and 111.4 tok/s. Fresh-process telemetry reported disk-L2 hits 4, SSM hits 4, rederives 0, paged hits 0, and FP16. |
| TQ 4/4, cold then warm | Cold conversion returned `TQ HYBRID OK` at 4.26 s and 4.9 tok/s. The warm turn returned `TQ WARM OK` at 0.58 s and 73.0 tok/s. Telemetry converted exactly six KV layers while leaving all 23 Mamba layers native. |
| TQ 4/4 video | The simple fixture returned `Red, Green, Blue`; TTFT 6.99 s, 60.3 tok/s. The prior fine-detail quantitative-video failure is still open. |
| Activity Monitor | Osaurus visibly measured 17.84 GB after paged/TQ/video use. The cumulative isolated cache root measured 6.78 GiB; that is not a clean per-turn compression delta. |
| Defaults restored | The real UI showed paged OFF and `Engine Selected`; the saved live-server state reported `paged_kv_enabled=false`, `live_kv_codec=engine_selected`, prefix/disk/SSM rederive on, and no model loaded. |

## Remaining limits

- Video with Thinking enabled still length-stops in the deterministic direct
  engine matrix. Do not force Thinking off or inject a prompt to hide it.
- Repeat the off-to-on transition row to distinguish stochastic repetition
  from transition/cache state.
- The automatic `share_artifact` selection on one transcript-only request is
  a tool-choice issue, not a multimodal decoder/transport failure.
- The current tools-enabled AIFF row also selected irrelevant web search after
  a correct initial transcript. The Tools-OFF A/B proves media transport; the
  broader automatic-tool policy still needs its own fix and regression matrix.
- 4/4 TurboQuant-KV works structurally for this hybrid topology, including
  disk and SSM companion reuse, but its video-detail accuracy is not accepted.
- Low-RAM warning override behavior remains unverified because this external
  model had no size estimate and the warning did not appear.
- Spawn/delegation RAM preflight and repeated model-swap isolation remain
  unverified on this exact app source.
