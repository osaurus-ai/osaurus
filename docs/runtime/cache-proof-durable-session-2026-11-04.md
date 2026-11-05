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
- Full OsaurusEvals units pass: 379 tests in 50 suites, including a second
  run against the exact committed fixture/test source. Fresh Release26 builds
  successfully from consumer `8327e0b179b1a2485a53d1dacf8e48e9a9e387ff`,
  still using runtime pin `f1747342d881ba7b8b6a3bed84fd5fd60b99e96c`.
- The real E4B MXFP4 q6 CacheProof run scores 9 passed / 4 errored out of
  13 cases. Errors are longest-prefix turn 3 (256-token cap), five-turn
  growth turn 2 (192), hybrid-named disk case turn 3 (160), and thinking
  toggle turn 2 (256, reasoning without visible text). The non-hybrid Gemma
  cannot qualify hybrid companion state. Original errors remain errors.
- Three SSD cases repeated three times score 8 passed / 1 errored trials;
  longest-prefix is 2/3, partial restore 3/3, settings revision 3/3. Majority
  aggregation labels all three cases passed; that is not 9/9. The initial
  payload observer watched TMPDIR while Foundation used its actual temporary
  directory elsewhere, so it retained zero payloads. Prompt dumps survive.
- Correcting only the observer root preserves 26 published cache payload
  snapshots (624,817,512 logical bytes) and the exact prompt dumps. Three more
  longest-prefix trials meet the structural cache gates, using real disk
  restores of 699–702 tokens. These are **not answer-quality passes**:
  answers include `White`, a list of reference terms, and a paraphrase instead
  of the requested exact checkpoint text. The scorer currently requires
  nonempty visible output, not fixture-specific exact-answer fidelity.
  No sampler, seed, budget or scoring gate was changed to obtain these rows.
- A fresh Release26 ordinary UI smoke passes two workflows: executed
  `calculate({"expression":"43 * 31"})`, final `1333`, followed by
  history-grounded `calculate({"expression":"2 * 1333"})`, final `2666`.
  Four actual model requests are retained (Insights seq 1369, 1370, 1373,
  1374). Both turns settle and unlock input. Saved q6/paged-off/SSD-on settings
  are observed in the real UI. The post-idle API snapshot has zero loaded
  models; it is not evidence of loaded cache topology. Runtime receipts and
  prior setting-toggle/relaunch proofs remain separate. Both owned app and
  collector exit normally.

`DURABLE-SESSION-REAL-CACHEPROOF-RECEIPT.json` and
`BUILD26-ORDINARY-TOOL-UI-RECEIPT.json` bind the complete reports, failed
outputs, typed progress, native requests/screenshots, cache headers, resource
samples and exact input identities under the evidence directory below.
An exact-prompt cold/split/completed-file numerical comparison is the next
root-cause check for the echoed/reference-word answers. A structural cache hit
is not proof of output fidelity. This change remains partial: current runtime
CI is not green, full affected controls/cancellation/eviction and the other
QAT variants remain unqualified, and the consumer still needs the eventual
normal runtime merge commit as its pin. No merge-ready claim.

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

## Follow-up: score answer fidelity separately

The exact 702-token prompt whose native restored answer was `White` now has
a hash-gated logits diagnostic: prefix 699 matches its captured SSD payload.
Cold repeat and fresh-file versus matching split restore are bit-identical
across all 262,144 logits, including the production eager-CPU-read ordering.
Captured native restore versus cold has total variation 0.018387; the top token
remains `LON`. The bundle-filtered first-token probability of `White` is
0.01166 cold and 0.01256 restored. This does not establish cache corruption as
the cause of the sampled answer. Original RNG state is unknown; full-answer
fidelity and other model/cache paths are not certified by first-token evidence.
Two source-bound numerical comparisons agree; the second process completed
before its physical sampler began, so only the first has five resource samples.
The diagnostic receipt preserves these limits and the failed executable-path
attempt, rather than treating either as an inference pass.

`requiredVisibleTextPerTurn` now gives CacheProof fixtures an optional required
phrase for each visible answer. Matching is case-insensitive substring matching,
so punctuation/case changes are allowed; it is a lexical check, not a semantic
judge or an exact whole-answer check. Invalid count or empty phrases fail before
inference. The three completed-file SSD fixtures author checkpoint phrases; a
response of `White` or `Chi` fails even when all cache counters pass. The check
changes only evaluation, never model input, samplers, token budgets or runtime.
Full Evals units pass 382 tests / 50 suites after adding regression coverage for
recorded wrong words, missing turns and fixture opt-ins. A toolchain/cache-path
compile failure and a missing actor annotation in the first helper attempt are
retained in separate logs; the annotation is corrected and the complete suite
passes. New real-model results under this stronger scorer are still pending.
