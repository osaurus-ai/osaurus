# Completed-file cache restore proof

The existing three-session longest-prefix case restores the longer boundary,
but its final read can come from `diskPending`: the previous coordinator still
owns an in-flight writer payload in RAM. Rotating the chat/session id does not
close that coordinator. The strict `tier=disk` gate correctly fails; accepting
`diskPending` as disk would weaken the proof.

`reloadModelOnNewSession` is an explicit eval fixture option, default false.
For the partial restore, longest-prefix and settings-revision disk cases it
drains/unloads the selected model before the listed fresh-session turns. The
next request loads normally with a new cache coordinator. Failure to prepare
the boundary retains earlier turn evidence and stops before another request.
Scoring still requires the original structured disk/partial-restore/progress
events and counts. Reload rows include model load in TTFT and do not measure
cold physical-drive bandwidth: filesystem-cache state is separate.

There is no normal app/chat/tool-loop caller of this option. Ordinary fresh
chats and per-tool continuations keep nonblocking write-behind. Generation
budgets, samplers, reasoning behavior, cache tier names and all numeric gates
are unchanged. This is not a user-facing setting or a new settings catalog.

## Validation and remaining work

- Baseline E4B MXFP4 q6 longest-prefix proof failed on `diskPending` in the
  original run and all three repeats. Other original scored rows remain
  recorded: 10 passed, 1 failed, 2 capped errors out of 13.
- Core typed Responses regressions pass: 13 tests in one suite, including
  requested-boundary ordering, preparation failure preserving the earlier
  turn, and ordinary fresh-session behavior without reload. Build/test session
  71546 exits zero; `durable-session-core-tests/run.log` is retained.
- Full OsaurusEvals unit tests are running. Rebuilt real-model disk cases,
  complete applicable cache lanes and fresh Release app smoke remain pending.
  This change is not merge-ready from unit results alone.

Separate memory diagnostics on the preceding consumer source attribute this
E4B path's growth predominantly to its bounded reusable allocator pool:
settled live MLX bytes are 5,221,957,476 after every turn; the configured cache
limit is 1,476,922,109 bytes (weight bytes / 4). Explicit diagnostic pressure
trims free 151–1001 MiB with unchanged live bytes and memory/cache limits.
The original 1024 MiB growth-gate failures remain failures. No per-turn trim,
memory-limit change, sampler change or low-RAM certification is proposed.

Source/config/binary identities, full outputs, typed progress and resource
samples are bound by `E4B-MXFP4-FOOTPRINT-CAUSAL-DIAGNOSTIC-RECEIPT.json` under
`/Users/eric/vmlx-private-evidence/goal-storage-cache-resume-20261104/`.
`ProcessMemoryProbe` fields named MB divide by 1024 squared and represent
MiB. The earlier commentary's GiB label was corrected; raw values are retained.
No release or tag is authorized by this work.
