# ZAYA1-VL 8B MXFP4 Live Sequence Review

Status: **FAIL / PARTIAL**

Artifact folder:
`docs/internal/live-gates/pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1504/`

This run used the keychain-safe debug Osaurus app on `127.0.0.1:4242` and
called both `/v1/chat/completions` and `/v1/responses` with red image,
text-only follow-up, blue image, red image repeat, and video rows.

## What Passed

- `/v1/chat/completions` accepted the red PNG on turn 1 and produced visible
  image-grounded text describing a red rectangle.
- The text-only chat follow-up preserved prior red-image context.
- The live sequence harness now keeps Responses history in Responses media
  shape (`input_text` / `input_image`), fixing the pre-fix 400 rows from
  `vlm-sequence-20260518T1458/`.
- Per-turn route bodies, request bodies, `/health`, `/admin/cache-stats`, and
  process memory snapshots were written.

## What Failed

- The chat route did not ground the different-image turn correctly. Turn 3 sent
  the blue PNG request body, but the model still answered as if the image was a
  red rectangle.
- The Responses route returned HTTP 200 after the harness fix, but every
  Responses media row produced a generic definition of "media" rather than a
  grounded image answer.
- The video chat row returned HTTP 500 with
  `ZAYA1-VL video input is not implemented`. ZAYA1-VL video controls must not
  be promoted unless runtime support is implemented or the UI/API marks video
  unsupported cleanly.
- `/health` still reported `current_model: null`, `resident_models: []`, and
  `loaded: []` throughout the sequence.
- `/admin/cache-stats` still reported `models: []` and zero prefix, paged,
  block-L2, and SSM counters throughout the sequence.

Source trace for the empty health/cache snapshots:
`ServerConfiguration.default.modelIdleResidencyPolicy` is `.immediately`, and
`ModelRuntime.generateEventStream` schedules idle unload when the generation
lease is released. This can legitimately empty `ModelRuntime.modelCache`
between non-streaming requests, so this artifact cannot prove cache reuse.
The next cache-proof rerun must either set a non-immediate idle residency
policy through the app/settings path or capture stream-time snapshots while
the model lease is still held.

## Consequence

This artifact is useful proof that the live app/API path is being exercised,
but it is not production proof for ZAYA-VL. The row remains red until the media
switch grounding, Responses media handling, unsupported-video capability, and
loaded-model/cache-stats proof path are root-caused and fixed without sampler
or prompt guards.
