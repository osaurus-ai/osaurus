# D3 runtime integration

Work in progress, not qualified or merge-ready.

- Metadata-driven local detection: decision_config plus generates_text=false.
- Dedicated System One execution, not chat/tool/subagent generation.
- Picker and service routes exclude decision bundles from chat selection.
- Uses the app's compatibility, shard, deletion lease, memory plan and exclusive GPU producer gate.
- Request-owned weights unload on success/error; no retained conversational KV checkpoint.
- Prompt throughput, input/output tokens, active and allocator pool bytes are logged.

Remaining: compile, full model/quant parity, image/video API transport, turbo Box/track, app visual proof, cancellation/repeated-request memory, PR/pin and CI. Do not infer runtime correctness from this source checklist.
