# Image progress transcript invalidation

Report: generation appears to stop at 10/N while the image job continues.

The engine emits a step callback after each completed denoise step. ChatView replaces the assistant status text and requests a block rebuild, but BlockMemoizer's fast path uses text length. Equal-length replacements therefore return the previous blocks. The single-digit steps share one length, and 10–16 share another.

The change adds an O(1) content revision to ChatTurn and includes it in the memoizer key. Direct replacement, append and existing cleanup mutation advance the revision; storage compaction does not change content. Unchanged calls still use the fast path. No full-transcript text comparison, timer-based progress, generation schedule, seed, sampler or model changes.

Regression coverage: steps 1–16, equal-length replacements, appending, and unchanged repeat calls. Execution and rebuilt-app proof are pending; this document does not claim a live fix yet. Required live check: actual FLUX generation beyond ten steps, visible status updates after ten, terminal image and follow-up. The reported 512px 8-bit face distortion is a separate open investigation, not addressed by this PR.
