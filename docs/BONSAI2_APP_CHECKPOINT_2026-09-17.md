# Bonsai2 app integration — PARTIAL

Base: current main `0901780ccccc3fc598f67e3d7a2a69f712bbbf95` in isolated
`/Users/eric/osaurus-bonsai2`, branch `feat/bonsai2-app`. No edits to the Gemma
PR or dirty coordination checkout. No app is built/launched at this checkpoint.

## Source-bound correction and TODO

- [x] Trace the separate app-owned tokenizer bridge: it applies Gemma schema
  normalization globally and can replace native Qwen validation errors with
  another template. The engine macro change alone cannot correct this path.
- [x] Add matching native Qwen XML routing before sentinel-based fallbacks.
  Configured schemas and native render errors stay intact. Existing Gemma and
  MiniCPM behavior remains in its current branch; no sampler/prompt coercion.
- [x] Author actual-artifact tests for both27B Bonsai2 storages: native default,
  Off/low/medium/xhigh, options Codable representation, adapter transport,
  text/VLM tool history, canonical cache-boundary rendering and invalid inputs.
- [x] Repin development source to enginecfc6af29 (production identical to tested
  4c6bec46) and align all three tracked lockfiles. Final merged pin remains open.
- [ ] Execute app-owned tests and surrounding reasoning/schema/parser tests.
- [ ] Build isolated development app; test real selectors, persistence, both
  model loads, native reasoning and tool round trips, real media, cache reuse,
  physical footprint, token/s, cancellation and natural-stop multi-turn.
- [ ] Review full diff and exact-head CI, document all failures, then PR/merge.

The current tests are unexecuted. They opt in with
`BONSAI2_PROTOCOL_BUNDLE_ROOT=/Users/eric/models/OsaurusAI`, load no model weights,
and deliberately separate artifact/transport from cold UI discovery and live
persistence. Those separate gates are not waived. No release/install/publish.

Engine retained evidence and the active cross-repo TODO are in
`/Users/eric/vmlx-private-evidence/bonsai2-swift-2026-09-17/STATUS.md`.
Full Bonsai model proof on Max2 still awaits the explicit named-run answer.
# App fixture compilation follow-up

The first app compile at10cd02984 stopped at Bonsai2AppTokenizerTests:62:
`JSONValue` is exported by both OsaurusCore and MLXLMCommon. No test executed.
The fixture now qualifies the MLX history/JSON types; runtime code is unchanged.
Guard receipt21:13:01: exit65, zero owned survivors, peak8.48GiB,
unchanged swap1.81GiB. Exact log and xcresult are in APP-RUN.md's attempt2.
