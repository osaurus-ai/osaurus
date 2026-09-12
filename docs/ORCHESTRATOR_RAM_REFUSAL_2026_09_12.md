# 0.25.1 same-model admission follow-up

Status: **PARTIAL — investigation and candidate correction, not reporter-qualified.**

Source base: Osaurus `4680ce594` (current `live/main` fetched September 12).
Runtime pin: `74103982a292a5037e82acca6f35b72dc1e75ea7`.
Worktree: `/Users/eric/osaurus-resident-child-ram`.

## Report and acceptance boundary

M4 Mac mini, 16 GB, Gemma 4 E2B 8-bit for Coordinator and every child;
RAM-Safety ON, Handoff ON, Coexistence OFF, batch size and same-model ceiling 1.
Both the first trivial child and a second sequential child can fail with
`stable_memory_refusal` / `refreshed_capacity: 0`. A restart sometimes permits
one child. Research task expansion is also reported, but admission refuses
before the child runs. These facts do not establish a leaked reservation.

## Recent changes checked against current source

| Change | Shipped behavior / relevance |
| --- | --- |
| #2498 | Agent dispatch uses the real target chat session. |
| #2533 | Admission prices the enforced delegated context and output contract. |
| #2535 | Normal load and delegation share physical-minus-unreclaimable host memory accounting. The previous 128 GB UI proof was not 16 GB proof. |
| #2595 | KV estimates distinguish sliding, full and recurrent layer state. |
| #2592 | Delegated reasoning uses the child model's settings. |
| #2639 | Different local models use the handoff sequence; same-model reuse stays in place. |
| #2643, #2646, #2647 | Watcher folder resolution, knowledge paging and tool-result history do not release allocator buffers or bypass spawn admission. |
| #2688, #2692, #2695 | Admitted model forwarding reaches local/workspace dispatched agents. |
| #2720 | Sibling spawn calls execute as a wave, so recovery must cover both direct and batch memory-fact consumers. |
| #2718 (open) | Separates original task intent from the delegated delivery footer for tool-choice inference. It is not shipped in 0.25.1 and does not establish causality for arbitrary task expansion. Keep that candidate separate. |

## Source-confirmed reclamation gap

`SubagentSession.localInPlaceSlotCapacity` obtains memory facts after admission;
`SpawnBatchTool` uses the same `ModelRuntime.subagentBatchMemoryFacts` boundary.
The host estimator subtracts non-purgeable anonymous/wired pages. MLX's freed
buffer reuse pool is still allocated memory at that boundary. It can retain
parent/previous-child intermediates even though the next child could reuse
or release them. Ordinary generation restores the configured dynamic reuse
ceiling, not necessarily an empty pool.

`trimFreedBufferCacheUnderMemoryPressure` releases only freed MLX buffers under
the exclusive Metal gate. Before this candidate its only caller was the OS
memory-pressure responder. An admission refusal does not imply macOS emitted
that notification. Thus a final refusal can precede an available reclamation
operation. This is a concrete missing lifecycle step, **not yet proof that
the reporter's zero capacity has this cause**: the report lacks the numeric
admission log and allocator-pool measurements.

## Candidate contract

Before rejecting an otherwise affordable single child, attempt one guarded
freed-buffer trim and resample the complete memory facts. No arithmetic credit
for hypothetical reclamation. No forced slot, model exception, smaller hidden
context, sampler change, parent unload, or altered persisted allocator limit.
An active producer, unavailable estimate, explicit budget that cannot fit the
child, cancellation, or still-insufficient fresh memory remains fail-closed.
Direct spawns and batches share this step through ModelRuntime.

## Evidence and remaining work

- New deterministic recovery tests are being run with an empty model store.
  Eric explicitly authorized local app/model proof during this task.
- Runtime host reachable: `erics-m5-max.local`. It has a Gemma E2B QAT JANG_4M
  bundle on `/Volumes/EricsLLMDrive`; it is not the reporter's 8-bit bundle.
- Real 16 GB/8-bit first-child, sequential, stop/error/timeout, restart and
  numeric pre/post-trim proof remain required to close the reported defect.
- No release or merge has been performed.

## Reporter evidence added during investigation

Terminal snapshot after the failure: 16 GiB physical, 13,819.81 MiB swap used
(about 13.50 GiB), 231,956 wired pages (3.54 GiB), 173,737 compressor pages
(2.65 GiB), with 16 KiB pages. It does not include the internal/file-backed
page split used by admission, nor allocator cache bytes, so the precise RAM
inequality still cannot be reconstructed. Swap usage alone is not admission
capacity and does not establish a leak.

Screenshots downloaded and inspected:
`/private/tmp/osaurus-resident-child-ram-evidence/reporter-1.webp` shows a
~6.1 GB predicted load/cache allowance and the explicit warning that Use Anyway
does not disable runtime safety. `reporter-2.png` shows an observed 1.7 GB swap
increase while Gemma E2B 8-bit is running. The correction must preserve actual
insufficient-memory refusal, not convert either warning into permission to
ignore the gate.

Local store search, including `~/.cache/huggingface/hub` and mounted models,
found Gemma E2B QAT JANG_4M/MXFP4, but no E2B 8-bit snapshot. No weights were
downloaded or converted. The local host also has 128 GiB, not 16 GiB.

## Automated checkpoint

The pre-correction implementation (sampling once without recovery) failed the
new regression: 2 failed tests / 3 tests, 11 assertions, including both
sequential zero-capacity results. After correction, 15/15 tests in the recovery
and SubagentSession admission suites passed. This is deterministic injected
memory evidence, not a captured reproduction of the reporter's host state.
Logs: `/private/tmp/osaurus-resident-child-ram-red-xcode.log` and
`/private/tmp/osaurus-resident-child-ram-green.log`. Earlier setup attempts used
a relocated Clang module cache and then the CLT toolchain without Preview
macros; those were build setup failures, not test scores. Xcode's toolchain
was used for the executed tests.

A further cancellation regression and the wider related test matrix are now
running in `/private/tmp/osaurus-resident-child-ram-matrix.log`. The isolated
Release build log is `/private/tmp/osaurus-resident-child-ram-release.log`.

Refusal metadata now includes the original decision's model/resident status,
actual bounded child charge, cap charge, reclaimable bytes, releasable parent
bytes, OS reserve, load budget, RAM slots and limiting factors. It does not
resample after refusal to manufacture a reason. The rejected-plan headroom
field also reports the effective bounded cost rather than the larger cap cost.

## Expanded verification

- 281/281 tests in 23 suites passed in the broader matrix. Includes the added
  Stop-during-capacity-recovery regression, direct two-child lifecycle,
  batching, RAM toggles, handoff, model/budget forwarding, watcher paths, and
  Metal gate ownership/cancellation. No models loaded in this test matrix.
- Opt-in real Metal allocator test passed 1/1: cache bytes 67,108,864 -> 0;
  live allocation remained 12 bytes and its contents survived. Host reclaimable
  bytes were 94,158,159,872 -> 94,224,482,304. This validates actual freed-buffer
  reclamation, not the reporter's memory state.
  `/private/tmp/osaurus-resident-child-ram-allocator-ready.log`.
- The first opt-in setup attempt could not locate the metallib. The executed
  row colocated the matching Release-build metallib as `mlx.metallib` beside
  the xctest executable; no source or kernel fallback was introduced.
