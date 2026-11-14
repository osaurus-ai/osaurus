# FLUX 3 composer feedback — 2026-10-20

Current delivery status and build/test receipts: [PR #3149](https://github.com/osaurus-ai/osaurus/pull/3149).
The table records the reproduced defects and the acceptance checks for each fix.

Scope: reported long-prompt display, pasted prompts, edited/regenerated prompts,
and the steps control. No engine, seed, sampling, model weights, or release changes.

| Item | Reproduction and cause | Fix | Verification |
| --- | --- | --- | --- |
| F01 Long multiline prompt appears as raw Markdown | Reproduced in the isolated Release app at 1024px / 16 steps. Generation produced a PNG, but interpolating paragraphs into `![prompt](url)` broke the block parser. | Use a generated-image label independent of prompt syntax; retain the full prompt in the user turn and generation request. | Before screenshot and AX captured. Acceptance: the full prompt produces a rendered image in the rebuilt app. |
| F02 Pasted prompt says “Enter a prompt…” | Reproduced by pasting the reporter's full prompt. The composer created a Pasted content attachment; image generation read only the empty composer text. | Resolve pasted-content attachments, including persisted blob references, before local/remote image dispatch. Preserve order and paragraph breaks; unavailable content reports a read error rather than generating a partial prompt. | Before AX captured. Acceptance: pasted text produces an image, with prompt/parser regressions covered by ImageComposerFeedbackTests. |
| F03 Regenerate loses prompt | Reproduced with the actual Regenerate control. Chat regeneration intentionally calls `send("")`, while image dispatch incorrectly used that empty argument. | Capture the retained latest user turn and its attachments before asynchronous dispatch. | Before AX captured. Acceptance: the corresponding control completes generation from the retained user turn. |
| F04 Edit and regenerate loses prompt | Reproduced by editing the user turn to a blue-teapot prompt, then Save & Regenerate. Same empty-send defect. | Same retained-turn fix; source-image attachments remain attached for image edits. | Before AX captured. Acceptance: the corresponding control completes generation from the retained user turn. |
| F05 Steps label and minus hit target | Screenshot reproduced clipped “st”; button label has a 14×14 frame and the FLUX text field uses default bezel styling. | Plain centered numeric field, uncompressed steps label, 28×28 rectangular plus/minus targets. | Acceptance: full label visible; field editing and plus/minus edge clicks change the value. |

The comparison to another image provider is not a controlled quality comparison:
image dimensions/aspect ratio, prompt, model, and sampling were not matched. No
engine-quality conclusion follows from those screenshots. The reproduced F01 is
a display failure after successful generation, not proof of a prompt-length limit.

Pasted content is distinguished from arbitrary attached documents using the
existing Attachment.isPastedContent contract. Image references are retained for
edit routing. Ordinary chat and the video dispatch path are unchanged.

Private evidence: `~/vmlx-private-evidence/flux3-feedback-20261020/` contains the
exact reported prompt, before/after AX observations, screenshots, and build/test
logs. Do not publish private paths or screenshots containing unrelated history.

Historical malformed Markdown is not rewritten in stored conversations; regenerating
uses the corrected result format. The phone image formatter already sanitizes its
labels and is unchanged. Remote-provider billing and video generation are outside
this local image-composer reproduction.
