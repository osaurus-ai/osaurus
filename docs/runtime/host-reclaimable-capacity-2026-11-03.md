# Host reclaimable-capacity accounting

The bounded host-capacity fix landed in [PR3306](https://github.com/osaurus-ai/osaurus/pull/3306). Model-family quality, low physical footprint and broader cache qualification remain separate from host-capacity accounting.

The host gauge and delegation capacity use the same estimate. Deriving it by subtracting wired, compressed and non-purgeable internal pages from physical RAM reported zero on a 128 GiB host whose HOST_VM_INFO64 internal aggregate exceeded physical RAM. The native Activity Monitor display remained around43GiB used. Both standalone C and Swift controls reproduced the counter discrepancy, so it was not limited to the app pointer binding. The running kernel was Darwin27; the precise kernel-side reason remains unproven.

Compute reclaimable bytes from the reported page classes instead:

`(free + file-backed + purgeable - speculative) * host page size`

Apple's vm_statistics header includes speculative pages in free_count. The kernel's vm_page_speculate path also adds them to pageable external pages, so subtract that overlap once. Purgeable volatile pages exclude wired pages; they are anonymous, separate from file-backed pages. Count file-backed pages regardless of active/inactive queue; do not treat inactive anonymous pages as reclaimable or infer capacity from an oversized internal aggregate. Dirty file-backed pages may require writeback, so available capacity does not imply instantaneous allocation or no I/O.

The shared function preserves overflow/invalid-snapshot handling. No new model budget, percentage limit, sampler, cache setting, or load policy is introduced. The gauge remains an estimate including reclaimable file/purgeable pages, distinct from Activity Monitor Memory Used and from a process phys_footprint ledger. Counter snapshots can lag allocations.

A native control physically touched2GiB, held it15seconds, then released it. Process phys_footprint rose0.0013 to2.0023GiB and returned0.0013. The candidate available estimate moved85.8948 to83.8728GiB during the hold, then85.8670 on release. The immediate post-allocation host snapshot was stale and is retained as such. This validates a diagnostic allocation response, not model loading, decode, cache, speed or memory-pressure behavior.

Qualification included 4 KiB/16 KiB arithmetic and overlap/error cases, actual app gauge plus native Activity Monitor, allocation/release response, coherent multi-turn production handoff, same-model reuse, direct Stop/recovery and editor persistence. PR3306 retains the exact-source Release, 218 focused tests across 17 suites, all nine CI jobs, native receipts and unfavorable auxiliary quality row. This does not establish universal model readiness or every large-load/delegation cancellation phase.

Primary source contracts:
- https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h
- https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/host.c
- https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_resident.c (vm_page_speculate)
- https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_object.c (vm_object_purgable_control)

Public kernel source is older than the running kernel; these references establish page-class accounting, not the exact cause of the observed new-kernel aggregate.
