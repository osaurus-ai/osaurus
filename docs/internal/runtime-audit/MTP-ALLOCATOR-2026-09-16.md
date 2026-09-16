# Native MTP opt-in and allocator enforcement

Status: PARTIAL pending post-change Release, full tests and API/UI reproduction.

Pre-change source: app 604608f699965099daebe0e4b9a54645e9f30dcd,
vMLX 91dffa4b4eaa5ebbc3b11c370ebc9d18e0471b18.
Release SHA256: 369f3bddba3524599b5cddac91f90e8863521875094eb5048a1fe31c9fc13b34.

## Reproduced failures

- A user-entered 128 MiB allocator maximum remained 128 MiB with MTP Off,
  but manual D2 raised the active limit to 3,887,611,941 bytes. The generation
  helper used max(persistent, dynamic), treating the explicit maximum as a floor.
- Settings Force On without usable production tuning returned ordinary text
  through the API, despite the engine resolving the launch as blocked.
  The load bridge ignored that state. Warm mode changes also need revalidation.

## Changes and intended contracts

- Native MTP defaults Off. Selection-time controls require model configuration
  and actual MTP tensor/tuning evidence; explicit saved selections persist.
- Explicit allocator maxima cap active reuse across all resident holders.
  Nil retains dynamic reuse; profile defaults do not become user overrides.
  Resident-child admission uses the same prospective allocator calculation.
- Immutable bundle evidence accompanies a loaded holder. Cold loads and warm
  requests enforce the engine's launch policy before GPU submission. Errors
  map to invalid_request_error across supported HTTP protocol envelopes.
  DFlash remains an independent explicit selection.
- New regressions cover cold/warm refusals, Off/Auto, manual depths, missing
  heads, external drafter independence, cross-resident caps and bounded math.

## Live evidence and limits

Private root: /Users/eric/vmlx-private-evidence/runtime-audit-2026-09-16.
Raw API: live/allocator128-{off,force-on,d2}/result.json and *-fast.jsonl.
UI: ui-current-d2-complete.png/.ax.txt; ui-current-d3-followup.png/.ax.txt.
Supervisor: live/SWIFTTEST_RuntimeAuditUI0916__034644.{log,mem,procs}.
D2 chat: 364 tokens, 28.1 tok/s, TTFT 0.70 s + 1.7 s load.
D3 follow-up: 496 tokens, 27.8 tok/s, TTFT 0.81 s + 1.8 s load.
Both produced visible complete answers with native bundle sampling.
Peak owned physical footprint 6.93 GiB; existing swap 2.96 GiB unchanged;
normal pressure; cleanup left zero owned processes. No 16 GiB host emulation
or causal attribution of the reporter's historical 13.8 GiB swap is claimed.

Full model/video/audio/performance results and failures are retained privately
in README.md, live-results.json and UPSTREAM-CROSSCHECK.md. These tests do not
establish a general MTP speedup. Video temporal fidelity remains a failed row.
