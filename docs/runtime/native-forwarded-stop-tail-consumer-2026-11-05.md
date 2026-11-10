# Native MTP accepted stop-tail SSD checkpoint

Pin vMLX runtime merge `2f404cdd6c540da6a8a8aed8aef17f232b1c3568` (#739) in four locations and two
contract expectations. Only dependency metadata/tests/docs change here;
AgentLoop, orchestration and in-app tool implementation files are unchanged.

When native MTP stops inside an accepted verifier queue, recurrent state may
already include more than one token past the visible answer. The runtime now
persists the exact accepted-token key when every leaf and queue/count check
agrees, excluding the unforwarded bonus/correction. Exact/one-stop/trimmable
paths and boundary validation remain. No decode math, prompts, model defaults
or adaptive-depth changes.

Actual Release40 from the same Osaurus main base (local consumer `b96359b6`,
runtime `42e77371`) proves two accepted two-token tail entries: 1,734 tokens
restored on the next growing GUI turn and 1,962 restored after clean process
restart. Five short text requests have correct visible answers and expanded
reasoning, with UI observations 56.6/75.7/66.2/69.8/63.3 tok/s. The final runtime
differs only by documentation/log indentation: production nonwhitespace bytes
and quoted literals match the actual app. Both app/sampler pairs exited zero.
The consumer final pin delta is metadata and test expectations only.

Runtime validation: 54 affected functions/four suites pass. Full focused target
1,253 total / 1,207 passed / 9 failed / 37 skipped has the same nine old failing
methods, none new. Seven hosted nonstyle CI checks pass; global advisory format
failure and unavailable self-hosted Mac/CUDA checks are reported separately.
Normal Osaurus CI remains a landing gate for this consumer PR.

Actual cache payloads contain BF16 attention and BF16/F32 recurrent tensors,
12 attention +36 recurrent layers with exact stored recurrent offsets. The
model-key label `kv=fp16` is not a claim that serialized arrays are F16. Paged
RAM is off; prefix/block disk caching is on. No TurboQuant topology claim.
The two writes took 21 ms each in the background; coordinator-store return
1.418/1.484 ms excludes snapshot/other host/load/UI work. No paired speedup claim.

Limits: the metadata-only fixture exposed four tools including sandbox-init
pending, versus the older ten-tool diagnostic. No claim that old reasoning
failures were fixed or that this run executed a new terminal command. Original
real 45-second terminal proof stays separate. Peak physical footprint was
54,765,394,296 / 53,626,853,080 bytes: low RAM unqualified/FAIL under retained
owned loading. All-family/media/settings/batching/speed qualifications remain
partial. No release/tag.

SOURCE EVIDENCE: runtime #739 exact merge-tree readback; four pinned manifests
and two contract expectations in this change. Local source binding:
`native-forwarded-stop-tail/FINAL-HEAD-PROOF-BINDING.json`.
LIVE EVIDENCE: local `goal-storage-cache-resume-20261104/`
`native-forwarded-stop-tail/ACTUAL-GUI-RECEIPT.json`, actual AX/PNG, requests,
SQLite, logs, typed cache headers/payloads and physical samples; full focused
comparison and runtime CI retained. Consumer CI receipt is pending.
