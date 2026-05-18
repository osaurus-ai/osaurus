# ZAYA1-VL 8B MXFP4 History/Media Boundary Probe

Status: **PARTIAL diagnostic / blocker narrowed**

Artifact folder:
`docs/internal/live-gates/pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1638-pruned-history-probe/`

This probe reused the saved Turn 3 request from the fresh-app red-to-blue run.
The app was relaunched keychain-safely first; after the probe, the debug app was
quit and port `4242` was closed.

The embedded image bytes were checked against the fixtures:

- red fixture SHA-256:
  `178af00bfb8b36e30be0a3806f37cc039a6bb4c7ad892019889ad6c3556e1688`
- blue fixture SHA-256:
  `97cbaced36f0b5dd5acad830278c5f7fbce00bf88c52dd6d59d99179a11684ed`
- original Turn 3 chat/responses request contained both red-history and
  current-blue images.
- pruned Turn 3 chat/responses request contained only the current blue image,
  but retained prior assistant text that described red.

## Results

| Variant | Route | Output | Finding |
|---|---|---|---|
| Original T3 body | Chat | `Red square` | Still red. |
| Pruned prior image, keep assistant history | Chat | `Red square dominates the image.` | Still red even with only the blue image attached. |
| Original T3 body | Responses | `A red circle on a white background.` | Still red. |
| Pruned prior image, keep assistant history | Responses | `The image features a striking red circle at the center...` | Still red even with only the blue image attached. |
| Current blue message only | Chat | `A blue rectangle dominates the image.` | Blue grounds correctly. |
| No assistant-history variant | Chat | `The image features a blue rectangle...` | Blue grounds correctly. |
| Explicit latest-image prompt with assistant history | Chat | `Blue square dominates the image.` | Blue grounds correctly. |
| Current blue message only | Responses | `Purple rectangle dominates the image.` | Non-red, route sees current image. |
| No assistant-history variant | Responses | `The dominant color in the image is blue...` | Blue grounds correctly. |
| Explicit latest-image prompt with assistant history | Responses | `A blue square is the dominant shape...` | Blue grounds correctly. |

## Consequence

This is not evidence for a sampler clamp, repetition penalty, forced reasoning
close, parser repair, or image tensor failure. The remaining red row is a
multi-turn semantics problem: when prior assistant text has already asserted
the image is red, the plain prompt `Describe the dominant color and shape in
this image` can follow the prior assistant context instead of the latest
attached image. Removing assistant-history or making the latest-image reference
explicit grounds the verified blue PNG on both Chat Completions and Responses.

The production gate still cannot mark the original red-to-blue row green. The
next real fix is to make the VLM turn contract and UI/API test prompt
unambiguous without adding fake model guards or output rewrites, and then rerun
with cache/memory/timing snapshots.
