# Gemma unified vision normalization consumer — 2026-11-04

Status: candidate, native qualification pending. No release tags or publishing.

This consumer pins vmlx54c6c5b9faeee7d1b9739114a5b4eeba84672396 in all four resolution locations and two source-test expectations. The runtime corrects three unified vision LayerNorm epsilons from1e-6 to the upstream1e-5 contract, with a unified-only cache identity version to reject image-conditioned snapshots from the old math. Other model settings and sampling are unchanged.

Baseline693Osaurus/runtime983 native evidence remains intact: the two synthetic audit-slip images yielded3of6 correct fields; both approval codes and one amount were wrong. Same-media follow-up restored5814tokens but repeated the wrong amount. The source mismatch is numerically reproduced and the corrected runtime tests pass7XCTest plus28SwiftTesting tests/3suites; native image quality is not yet claimed fixed. A first expanded test used a small custom metallib and lacked rope_freqs_float32; the full bundled Cmlx artifact corrected that harness input and the original failure is retained.

Next gates: fresh isolated Release app; independent baseline/candidate profile identity; real image A/B plus growing/fresh-process disk restore, text/tool continuation, native selector/editor reasoning controls and effective cache telemetry, rates and physical footprint. Record every wrong answer and natural/cancelled/length ending. Relevant host pin/bridge tests and full CI/normal merges remain pending. No source/BF16 Gemma, audio, raw-speed runs, sampler masking or protocol coercion.

The existing owned-loading physical-footprint gate failed and stays failed; user chose to retain owned loading and qualify RAM honestly. This is not a low-RAM or full-family readiness claim. Other QAT JANG_4M/MXFP4 bundles, scoredAgentLoop and relevant media/cancellation/eviction rows remain open. Earlier terminal/wiring receipts and the unexplained adaptive-mode cold user-turn row remain separately scoped.

SOURCE EVIDENCE: upstream runtime54c6c5b9, changed resolver/test paths and runtime `docs/GEMMA4_UNIFIED_VISION_NORM_CORRECTNESS_2026_11_04.md`.
LIVE EVIDENCE: baseline `GEMMA-QAT-MEDIA-BASELINE-FAILURE-RECEIPT.json` under `/Users/eric/vmlx-private-evidence/osaurus-cache-wiring-20261103/`; candidate proof pending.
