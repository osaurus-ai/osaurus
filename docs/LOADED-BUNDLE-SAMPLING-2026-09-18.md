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

PARTIAL — corrected native sampler/image/tool/multiturn evidence below;
current-head focused unit tests and ordinary PR CI are still pending.
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

## Corrected native run, September 18

SOURCE EVIDENCE: production changes through
`05da5c9c55d1a37dbe771af3af4911822c1098e2`; integration app
`1643da66eb63fa625978016145ee97da0b69439e`, engine
`6c4fee39fd10284dcefb8115d79b163ec7ca329c` (packed-load/media-prefill
candidates, not this PR's production pin). Binary SHA256
`e762a0b4657aba2331adb1cebf89df6e0fdd3e3f3e086baa16dbcb06177ca380`.
The isolated Release development build completed; it was neither installed nor
published. Earlier failed warmup-consumer build remains recorded above.

LIVE EVIDENCE: private `runtime-followup-2026-09-18/BONSAI-RUN6.md`,
`run6-launch.json`, `run6.oslog`, `run6-prefill-full.log`, `run6-prompts/`,
`run6-measurements.jsonl` and `live-captures/run6-*`. Native Settings/Chat controls
and complete visual results were inspected. Both org aliases remained installed.

- Loaded OsaurusAI Bonsai-2-27B-1.75bit-JANG and Ternary-JANG sequentially.
  Both admin readouts retained the correct loaded snapshot: temperature 1,
  topP .95, topK 20. Thirteen submits used it without overrides; the other two
  honored the explicit override below. No bundle/template/sampler constants changed.
- In real Settings, saved temperature 0/topK 5, navigated away/back, and ran
  the packed image-history/file_read turn. Effective sampler changed to 0/.95/5
  while diagnostics retained bundle defaults 1/.95/20. Cleared both fields,
  saved, and subsequent submits returned to bundle defaults.
- Five packed turns completed (eight natural-stop generations): image-to-file,
  another real file read, long image/history, Extra High changed to None during
  active prefill, then a no-thinking follow-up. Actual current turn retained
  xhigh; next turn used None. Final rates 30.3/29.9/22.4/20.2/22.3 tok/s.
- Four ternary turns (seven natural-stop generations) included image-to-file,
  read-back, 9,233-token image/history and real cached continuations. Full-task
  score 3/4: one follow-up answered the prior log-entry question instead of the
  requested file line count. Filename-specific follow-up returned six lines.
  Final rates 22.2/22.0/24.5/25.9 tok/s. No loops or protocol-marker leaks;
  the incomplete answer is not a passing row or attributed to this fix.
- Actual topology: 16 KV + 48 Mamba/SSM layers, FP16, paged RAM off, TQ0,
  full-hybrid disk restores. Tool-result continuations restored up to 9,480
  tokens; long prefill is still slow. Not a model speedup or all-quality claim.
- Normal Quit exit 0; no owned survivors; swap unchanged at 1.67 GiB.
  Sampled app peak 15,860,452,064 bytes (kernel lifetime 16,082,587,920), under
  the 20 GiB guard. This is not low-RAM or 16GB-machine qualification.

One separate measured latency issue remains: a tool-result recall explicitly
saying "do not run another tool" was classified as required by the existing
chat tool-intent heuristic and therefore bypassed disk restore (23.3s fresh
prefill). This PR does not alter that policy or its cache-safety guard.
