# Nemotron Omni Multimodal Checkpoint — 2026-07-19

Status: **PARTIAL — source and focused boundary tests pass; rebuilt-app live
multimodal acceptance is still required.**

Exact proof model:

`/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-JANGTQ4-CRACK`

This checkpoint does not use or make claims about MXFP4.

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

OsaurusCore and both checked-in package resolutions point to vMLX commit:

`6fb106582a3681ed33e6e186165327a0069ff785`

That engine commit fixes the Nemotron vision projector and RADIO normalization,
removes the hidden media-only prompt/Thinking override, and adds strict
multimodal regression coverage. Its detailed direct-model matrix is in
`docs/NEMOTRON_OMNI_MULTIMODAL_CHECKPOINT_2026-07-19.md` in vmlx-swift.

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

## Remaining live acceptance

- Build and ad-hoc sign the isolated Release app with a non-production bundle
  identifier and `OSAURUS_TEST_ROOT`.
- In the UI, inspect and record the effective Multimodal, Thinking, RAM safety,
  prefix, paged, L2 disk, SSM re-derive, and TurboQuant-KV controls.
- Load the exact JANGTQ4 bundle through the model picker.
- Exercise image, video, audio, mixed media, multi-turn recall, same/different
  media cache isolation, post-media text, and Thinking off/on.
- Record visible TTFT/token rate and Activity Monitor physical footprint plus
  exact runtime cache telemetry. JANGTQ weight format must not be reported as
  TurboQuant KV encoding.
- Keep the row PARTIAL if video Thinking-on still length-stops. Do not force
  Thinking off or inject a prompt to manufacture a pass.
