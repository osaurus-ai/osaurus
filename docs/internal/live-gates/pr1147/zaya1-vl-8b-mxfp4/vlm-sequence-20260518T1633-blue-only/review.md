# ZAYA1-VL 8B MXFP4 Blue-Only Diagnostic

Status: **PASS diagnostic / NOT production-clear**

Artifact folder:
`docs/internal/live-gates/pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1633-blue-only/`

This row used the rebuilt PR #1147 debug app on `127.0.0.1:4242` and sent only
the verified blue PNG fixture. It intentionally omitted snapshots so it is a
grounding diagnostic, not a cache/memory production row.

## Results

- Chat T1: `The image features a blue square with a black shadow.`
- Responses T1: `The image predominantly features blue, with no additional colors present.`
- Chat text-only follow-up stayed in blue-image context.
- Responses text-only follow-up stayed blue, though it called the fixture a
  plain/placeholder background.
- Repeat-image rows stayed blue/blue-rectangle.

## Consequence

The model and route can see blue in isolation. The red answer in the full
red-to-blue sequence is therefore not a basic PNG decode, VLM processor, or
image tensor failure. It must be investigated at the multi-turn history,
prompt/template, media binding, or cache/session boundary.
