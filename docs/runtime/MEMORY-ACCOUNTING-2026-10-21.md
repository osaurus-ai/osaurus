# RAM accounting and lifecycle investigation

Status: partial. This change aligns the host capacity gauge with load/delegation admission; it does not change allocation, pinning, kernels or samplers.

## Confirmed problems

1. The system gauge used free + inactive + speculative + purgeable pages, while normal loads and delegation used physical RAM minus wired, compressed and non-purgeable internal pages. A simultaneous host sample differed by 19,532,005,376 bytes of available capacity. The gauge now calls the shared arithmetic.
2. A process's physical-footprint ledger is not the full system cost of GPU-resident mapped model weights. In the actual app, Ornith H2 showed roughly 2.3–2.75 GB in Activity Monitor's process row while host wired memory rose from roughly 8 to 50 GB. That residency released on idle unload. MiniCPM 35B affine also showed about 2.9 GB process memory with about 34.6 GB host wired. Do not characterize either model as using only the process-row value.
3. RunBench's PERF peak fields were maxima of after-load/after-generation samples, missing transient workspaces. Engine PR #633 separates these observed values from OS process-lifetime high-water counters and reports host wired/compressed values separately. Neither is a complete model-attributed total; do not add overlapping counters.

## Actual app evidence for the underlying removal build

App 961453d4720c40d2c99e6af687e445cd9f4e4302, engine 0e73bbcfc7f01def6cab2b522acabbfed8131dff; Release binary SHA256 a9aad9b4e0665c1d58a00658e809cb4413461d40be8d217baba23584bfd8fe34. In the isolated app, Ornith H2 continued a stored calculator conversation correctly, and MiniCPM 35B JANG_4M completed two connected calculator turns correctly with SSD restore on follow-up. These are not the new gauge build's visual validation.

The process sampler and Activity Monitor agree on the small process ledger. Host wired growth is separately recorded, not hidden or attributed entirely to the app without qualification. The new gauge Release build and visual comparison remain pending.

## Remaining investigations

- Compare the gauge and admission value with the same host sample; show units and distinguish reclaimable capacity from Activity Monitor's own Memory Used definition.
- Trace mapped Metal residency and live/cache/workspace ownership across H2, affine, Qwen/Ornith GDN, Nemotron SSM, MiniCPM DSpark and LFM conv/cache paths. No all-family pass from these two models.
- Same-model parent/children: one weight owner, independent state, actual simultaneous batching or explicitly reported serialization. A batch ceiling of two with one request is not concurrency proof.
- Swap enabled: unload exact parent, load/run/release child, restore parent and cache; cover failure/cancellation. Swap disabled: co-resident models, aggregate capacity and ownership without silent eviction.
- Compare effective settings across chat, spawned agents, API and evals. The TextSubagentKind modelOverride eval seam bypasses residency handoff; those results cannot prove production swap behavior.
- Track host baseline/peak/settled, process footprint/RSS, MLX active/cache, queued SSD payloads and final references, actual restore boundaries, wired/compressed/swap and helper processes. Log before and after idle unload.
- Trace long-context cache copies and aggregate write-behind budgets; preserve required rollback/media/recurrent state. No hidden clamps, forced depth, sampler changes or speed-breaking copies to inflate process accounting.
- Label cache-effective prompt throughput separately from new-token prefill throughput. Logical prompt token count divided by incremental prefill time is not new-token kernel throughput.

Private raw evidence: ssd-quota-20261021/turns/M01–M03, press-memory-ui, host-formula-baseline.json, MEMORY-LIFECYCLE-INVESTIGATION.md (M01–M18). Runtime proof comments are on #3156 and engine #632. No release or tag.

## Executed app qualification

The isolated Release app at 793059f7 (production gauge change ebbec8ac), pinned to engine 0e73bbcfc7f01def6cab2b522acabbfed8131dff, displayed 75 GB available on a 128 GB Mac. A near-simultaneous sample using the shared VM calculation gave 75.602 GiB. Binary SHA256: 594f35ed98e51e0435349e54200c102ed146190b42715e66a8cd5f34d6c7c034. The gauge is whole-host reclaimable capacity, not model ownership.

Actual composer delegation from MiniCPM 35B JANG_4M to Helper using Ornith 122B JANGH2 completed with the shared swap setting toggled through Settings both ways. Swap On released the parent, loaded/released the child and restored the parent; Swap Off retained both leases during the child job. Both returned correct calculator results and correct prior-chat recall. The restored parent reused SSD state. Step decode rates and exact restore counts are in PR #3157's evidence comment.

The co-resident run peaked at 81,581,850,624 bytes of whole-host wired memory versus 7,590,138,872 bytes of sampled process footprint. These overlapping counters must not be added or substituted for one another. No all-family or long-context duplicate-cache clearance follows from these short runs. Same-model concurrency and failure/cancellation lifecycle checks remain open in the investigation ledger.
