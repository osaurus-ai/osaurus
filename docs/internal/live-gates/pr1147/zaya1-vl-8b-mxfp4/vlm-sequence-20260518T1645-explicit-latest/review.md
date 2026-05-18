# ZAYA1-VL 8B MXFP4 Explicit-Latest Live Sequence

Status: **PARTIAL**

Artifact folder:
`docs/internal/live-gates/pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1645-explicit-latest/`

This rerun used the patched live-sequence helper with:

`--different-image-prompt "The image attached to this latest user message is new. Ignore previous image descriptions and describe only the latest attached image dominant color and shape in one short sentence."`

The app was launched through the keychain-safe LaunchServices helper. For this
run only, `~/.osaurus/config/server.json` temporarily set
`modelIdleResidencyPolicy` to `after_seconds: 300`; the prior immediate-unload
config was restored afterward. The debug app was quit after the run and port
`4242` was closed.

## Results

- Chat T1 red: `vibrant red square`
- Responses T1 red: `giant red donut`
- Chat T2 text-only: stayed in red-image context but hallucinated extra blue
  features.
- Responses T2 text-only: stayed red-ish but hallucinated a tomato/green
  background.
- Chat T3 current blue with explicit latest-image prompt: `dominant blue
  triangle shape with a red square background`
- Responses T3 current blue with explicit latest-image prompt: `blue rectangle
  with a unique red stripe`
- Chat/Responses T4 repeat red: returned red, but both added extra blue
  features.

## Cache / Health

The after-sequence `/admin/cache-stats` snapshot includes:

- `prefix_hits=3`
- `prefix_misses=51`
- `disk_l2_hits=3`
- `disk_l2_stores=16`
- `disk_l2_misses=51`
- `ssm_companion_hits=3`
- `paged_hits=0`
- model cache topology: `is_hybrid=true`,
  `is_paged_incompatible=true`, block-L2 enabled with
  `max_size_bytes=10737418240`

## Consequence

This rerun proves the route can ground the latest blue attachment when the turn
is explicit, even after red assistant history. It does not make the ZAYA-VL row
production-clear. Shape grounding remains weak, Responses is less faithful than
Chat, and the row still lacks Activity Monitor physical footprint. This is a
useful live artifact for the media-history boundary, not a full model-family
pass.
