# Buffered tool-stream cancellation

NOW: One-line bridge correction and a regression test added. Source-extracted
contrast reproduced the race. Current full-module CI and native Stop/follow-up
proof are still required; this is not merge-ready.

DO NOT: Revert the complete-tool-batch fix, cancel normal terminal cache drain,
attribute the reporter's RAM refusal to this race without live evidence, or
create a release/tag/publishing workflow.

BATCH OWNER: Tool-stream cancellation observed in PR #2798 CI, independent of
the handoff implementation.

NEXT: Run the current-source bridge/component regressions and CI, then verify
native Stop, complete tool batches, settled UI, and a subsequent turn in the
authorized isolated development app. Preserve per-turn cache/throughput receipts.

## Why this changes the prior fix

PR #2792 (`ebabfb72ad1fd9b1a37b542e1c276d2961e620f8`) correctly preserved
multiple calls through logical completion and kept the upstream cleanup drain.
Its per-event cancellation check can nevertheless return after a buffered
`next()` delivers an event but before another `next()` observes cancellation.
An upstream stream retained by its caller then need not receive `.cancelled`.

PR #2798 at `dca80f84ba8ef837ecb79c43c1193704c813c343` failed
`LocalToolCompletionContractTests.completeResponseCancellationCancelsUpstream`
in CI run `35332635317`, job `105560205646`. Six other functions in that suite
passed. The same test had passed on the parent PR; that does not erase the race.

The correction changes only the canceled-event `return` to `continue`. It
discards that event and reaches the upstream iterator's cancellation path.
Normal completion, all-call collection, stats, preview, error propagation and
the cache-owning terminal drain are unchanged. No timer, parser/sampler change,
new task, or production test hook is introduced.

## Reproduction evidence

Evidence directory:
`/Users/eric/vmlx-private-evidence/runtime-followup-2026-09-18/`.

`run-bridge-cancellation.sh` ran under the existing bounded supervisor,
`SWIFTTEST_ToolBridgeCancelRace1__041834.log`, 04:18:34–04:18:42 PDT.
The baseline bridge was extracted byte-for-byte from app
`9000c9e5e96e06163a21ee3ff2bef49a20ccbacf`; it is identical to the affected
main/PR bridge. Event and telemetry type scaffolding was supplied; no parser,
model, MLX, UI, or full application was linked.

| Bridge | Ordinary cancellation trials | Forced race window | Normal two-call drain cases |
| --- | --- | --- | --- |
| Baseline | 771/800 propagated; 29 missed | 0/2 propagated | 4/4 retained |
| Private one-line candidate | 800/800 propagated | 2/2 propagated | 4/4 retained |

Ordinary trials cover native and complete-response modes, each with
0/1/8/128 queued events and 100 repetitions. The forced-window variants add a
test-only scheduling gate between upstream `next()` and the cancellation check;
they are not represented as unmodified production executions. Cancellation is
observed before explicit fixture cleanup. `identity.json` files and plain/gated
logs reside under `bridge-{baseline,candidate}-9000c9e5/`.

The new repository regression repeats buffered cancellation in both modes and
retains the upstream stream until after checking its termination. Existing tests
still cover delayed second calls, errors, EOF, Stop between calls, and normal
terminal drain. Full-module execution of the new regression remains pending.

## Limits

This demonstrates a bridge cancellation race, not a measured model leak, RAM
admission bug, speed improvement, or low-RAM hardware result. Current native
Stop/follow-up and applicable agent-loop evaluation evidence remain missing.
The exact tested app/engine identity and any future live evidence must be added
to the PR before promotion. No model bundle or generation defaults apply to
the model-free contrast above.
