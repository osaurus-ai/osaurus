# Keep sampling defaults bound to the loaded bundle

## Reproduction

Native development app3ac01d845a93441648a7da1e39fbb3221701f5f1,
engine6c4fee39fd10284dcefb8115d79b163ec7ca329c, binary SHA256
50e35c5041d19e5725d9774cd348a135d2ee660af1ac75a3e1c28576a657051c.
Catalog contains both JANGQ-AI/Bonsai-2-27B-1.75bit-JANG and
OsaurusAI/Bonsai-2-27B-1.75bit-JANG. Native Chat selected the latter by full ID.
The loader opened its correct local directory, but the adapter re-resolved
`bonsai-2-27b-1.75bit-jang` to obtain sampling defaults. The intentional
ambiguous-short-alias rejection returned nil. The app silently sampled with
engine defaultsT.6/P1/K0 instead of the selected bundle'sT1/P.95/K20.
Both admin readouts repeated the short-name lookup and showed null defaults.

## Change

- Capture the existing JANG-over-HF defaults resolver from the actual load
  directory into SessionHolder. No model, template or engine change.
- Use that snapshot for every generation using the holder, preserving
  request > explicit user settings > bundle > engine fallback precedence.
- Carry the bundle snapshot into effective-generation diagnostics; cache
  status reads the resident holder's snapshot. Neither readout re-resolves
  an ambiguous catalog alias. Pending-preload diagnostics use the full ID.
- Keep ambiguous-alias refusal and existing model/cache identity behavior.
- Pass the same loaded snapshot through the existing MTP load warmup, rather
  than giving that internal generation a separate defaults lookup.

## Verification status

PARTIAL — implementation and regression cases prepared; fresh build, focused
tests and corrected native sampler/image/tool/multiturn evidence pending.
Regression cases exercise two orgs with different defaults, full-ID selection,
ambiguous short-name refusal, snapshot lifetime and explicit request precedence.
Existing LocalGenerationDefaults and MLXBatchAdapter suites cover JANG/HF merge,
user-setting precedence and do_sample behavior.

The first integration build (34b8a746b) failed because the MTP warmup also calls
the now-explicit generation entrypoint. That consumer is now wired from the
same holder; the failed build is retained, not counted as a test pass.

Failure artifacts: private runtime-followup-2026-09-18/BONSAI-RUN5.md,
run5-launch.json/run5.oslog/run5.measurements.jsonl and
live-captures/run5-packed-long-media/admin-generation-settings.json.
Native9878-token image-history/tool turn completed correctly at29.8tok/s;
this is failure-reproduction evidence for defaults, not corrected proof or
a causal speed comparison. No release, tag, installation or dispatch.
