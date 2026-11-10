# Gemma QAT loaded head precision

This candidate consumes runtime `f1747342d881ba7b8b6a3bed84fd5fd60b99e96c`
in all four dependency pins and both source-contract expectations. It moves
optional tied-head conversion after the existing parameter dtype materialisation.
Actual loaded codec, group size and output dtype now join the model's runtime
cache computation identity in both topology and coordinator paths. Affected
old state remains in its previous namespace. Unrelated host cache contract
tags remain unchanged to avoid a blanket cache invalidation.

The existing passthrough enum/config value is preserved. Its UI label becomes
**Passthrough (model load dtype)** because the effective dtype is not always
FP16. The control is registered in settings search, anchored at the picker,
and documented in the settings guide. This changes no codec defaults or
sampler settings. Legacy key `kv=fp16` denotes the requested mode; typed KV and
loaded-head telemetry must establish effective payload precision.

Runtime baseline: unchanged app18 E4B MXFP4 native cold q6 stored F32 KV while
passthrough stored BF16. Both correctly executed 83 * 19 = 1577, starting with
zero of 2069 tokens restored and then restoring 2069 of 2125 from disk.
The production loader regression was red for MXFP4 and green for affine
controls. The candidate passes 24 loader parameter cases, three other Swift
Testing checks and eight related XCTest checks. See the runtime correctness
document for scope and retained failed diagnostic attempts.

This consumer is not yet native-qualified or merge-ready. Required gates:
fresh Release development app; actual MXFP4 and JANG QAT multi-turn, image,
terminal/tool wait, effective settings, typed SSD and restart checks; preserved
old cache isolation and new cache reuse; source and native receipts; CI and
normal runtime merge, then exact merged-runtime consumer pin. Earlier OCR,
tool compliance, reasoning and full-model footprint failures remain open.
Owned loading remains by explicit user choice. No benchmark, source/BF16
bundle, audio, release tag or publication.
