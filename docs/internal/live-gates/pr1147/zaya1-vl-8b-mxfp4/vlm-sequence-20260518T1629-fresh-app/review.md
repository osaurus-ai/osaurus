# ZAYA1-VL 8B MXFP4 Fresh App/API Review

Status: **FAIL / PARTIAL**

Artifact folder:
`docs/internal/live-gates/pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1629-fresh-app/`

This rerun used a freshly rebuilt PR #1147 debug app launched through
LaunchServices with the real user Keychain context. The server was on
`127.0.0.1:4242`. For this run only, `~/.osaurus/config/server.json`
temporarily set `modelIdleResidencyPolicy` to `after_seconds: 300` so
post-request `/health` and `/admin/cache-stats` snapshots could observe a
resident model. The original immediate-unload config was restored after the
probe.

Media fixtures were extracted from the previous red/blue PNG request bodies and
verified before rerun:

- `red.png`: 64x64 PNG, average RGB `(220, 20, 20)`.
- `blue.png`: 64x64 PNG, average RGB `(20, 60, 220)`.

## What Improved

- Fresh app build succeeded before the run.
- `/v1/chat/completions` and `/v1/responses` both returned HTTP 200 for all
  four image/text turns.
- Responses no longer returned the previous generic definition of "media";
  the source fix is live enough for the route to reach the VLM path.
- Non-immediate residency made health/cache snapshots meaningful:
  `/health` showed `current_model` and `loaded` as `zaya1-vl-8b-mxfp4` after
  the first turn with `idle_seconds_remaining: 300`.
- `/admin/cache-stats` now reports the live cache topology instead of an empty
  model list:
  `is_hybrid=true`, `is_paged_incompatible=true`, block-L2 enabled with
  `max_size_bytes=10737418240`, final aggregate `prefix_hits=3`,
  `disk_l2_hits=3`, `disk_l2_stores=16`, `ssm_companion_hits=3`,
  `paged_hits=0`.
- The text-only follow-up preserves the previous red-image context, which is
  expected for T2.

## What Still Fails

- Turn 3 sent the verified blue PNG on both routes, but both outputs stayed
  red:
  - Chat: `The red square is the dominant color and shape in the image.`
  - Responses: `The image features a red circle at the center...`
- Responses reaches the image path now, but it still does not ground the blue
  image correctly.
- Shape grounding is weak on Responses even for the red image: it repeatedly
  says `red circle` while the fixture is a red square.
- Follow-up diagnostics narrowed this failure. The blue-only row at
  `../vlm-sequence-20260518T1633-blue-only/` grounds blue on both routes. The
  pruned-history probe at
  `../vlm-sequence-20260518T1638-pruned-history-probe/` proves the current Turn
  3 attachment bytes are blue; current-blue-only, no-assistant-history, and
  explicit-latest-image variants also ground blue. The original plain Turn 3
  wording remains red only when prior assistant red descriptions are retained.
- This artifact records RSS snapshots from `ps`, but it still does not include
  Activity Monitor physical footprint. That memory gate remains partial.
- This run did not include video because current source gates ZAYA1-VL as
  image-only. Video remains N-A until a real ZAYA video processor exists.

## Consequence

This is a better diagnostic artifact than the 15:04 run because it proves the
fresh app build, source-fixed Responses route path, resident-model health, and
cache counters. It is still not production proof for ZAYA-VL. The live app/API
row remains partial until the VLM turn contract is unambiguous and rerun with
cache, timing, memory, and output review. No sampler clamp, prompt guard, forced
reasoning closure, or parser repair is allowed as a substitute for that proof.
