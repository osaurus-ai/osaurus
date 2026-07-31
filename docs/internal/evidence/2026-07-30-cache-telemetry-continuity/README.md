# Cache telemetry continuity and explicit model unload — 2026-07-30

Status: `LOCAL VERIFIED` for the source, automated, real Release-app, and
model-backed acceptance gates recorded below. The authoritative integrated
runtime source is `58a3d35792df352556c0355ce06bc1759b9c9080`, which merges
current `main` at `11239f4079bd8f3f5410cd55869561eaebefb323` into the fix
branch. This evidence-only update does not change that tested runtime. GitHub
final-head checks and merge state remain separate external gates and must be
reported on the PR without converting the non-perfect model scores below into
passes.

## Result

Both defects retained from the PR #2235 campaign are fixed at the owning
lifecycle boundary:

- Explicit per-model unload now shuts down admission, cancels and drains only
  that model's tracked generation wrapper, and then waits up to five seconds
  for its lease. The UI owns per-row `Unloading…` state, consumes the runtime's
  Boolean result, refreshes from residency notifications, removes a successful
  row, and shows a fail-closed actionable error when a lease remains held.
- Process-lifetime cache and engine counters are retained when their live
  engine/container leaves the resident registry. Occupancy, capacity, loaded
  models, and topology remain live-only. Nonnegative inputs are clamped and
  additions saturate at `Int.max`, so model handoff cannot wrap or subtract
  counters into impossible negative deltas.

The isolated Release app visibly proved idle unload, active-stream unload and
recovery, bounded held-lease failure, retry-after-release success, two-turn
reasoning, two-model delegation, parent continuation, and a coherent follow-up.
The exact mixed-local eval row passed twice and reported no negative cache or
SSM counter.

## Authoritative post-main integration proof

This round was run after merging the then-current `osaurus/main`, including PR
#2244, into the fix branch. It supersedes the initial runtime round below for
merge gating while retaining that earlier round as independent reproduction.

### Exact integrated source and environment

- Integrated Osaurus runtime:
  `58a3d35792df352556c0355ce06bc1759b9c9080`.
- Integrated `main` parent:
  `11239f4079bd8f3f5410cd55869561eaebefb323`.
- Fix commit:
  `49132a96e73a759708e8ae056c50b8d3ab7f2675`.
- Pinned vMLX in every resolved package graph:
  `958eb6bed2e2fd4fde30574141e17a1dce773895`.
- Host: Apple M5 Max, 128 GiB unified memory, macOS 26.4.
- Fresh Release app:
  `/Users/eric/osaurus-cache-telemetry-final-20260730/build/DerivedData-cache-unload-release-58a3d357/Build/Products/Release/osaurus.app`.
- Release executable SHA-256:
  `6f8498c65d26152bd37675da9eb828632da6ec994ec8d5dba5f30a70b0465104`.
- Isolated bundle/defaults domain:
  `com.dinoki.osaurus.cacheunload58a3d357`.
- Isolated test root:
  `/private/tmp/osaurus-cache-telemetry-ui-58a3d357-root`.
- Model root: `/Users/eric/models`.
- Live process during proof: PID `98500`, HTTP server
  `127.0.0.1:1337`.
- Paged RAM KV: off. Disk block L2 and prefix cache: on. SSM rederive:
  on. Continuous batching: on with two configured sequences.

The exact Nanbeige and Ornith bundle identities, generation defaults, and
bundle hashes are unchanged from the retained initial-round table below. The
integrated app persisted:

- `config/agent-delegation.json`, SHA-256
  `4e46a6dc77387149e41dacfc3307b14cda11acd9ba8b7e388f25812c6fe7ca2b`;
- `config/server-runtime.json`, SHA-256
  `916df043a4e0446591820aaea437ed406528d7f234d9dc0bad796451c0719dfa`;
- `config/default-agent.json`, SHA-256
  `ceb1253079dbe918b2a61d39264f6635fa17d32e5f56d28d0e499c78f8896cb0`.

### Integrated automated and model-backed proof

| Lane | Integrated result |
| --- | ---: |
| Focused unload/telemetry source and behavior regressions | `4/4` passed in 2 suites |
| Complete `OsaurusEvals` Swift package test harness | 299 tests in 36 suites, 0 failures; 3 host resource-sampler tests explicitly skipped |
| Deterministic eval lanes | `101/101` passed across 8 suites |
| Exact affected mixed-local row, isolated run | `1/1` passed |
| Full model-backed `AgentLoop` | `32/40` passed, 5 failed, 3 skipped, 0 errored |
| Full model-backed `AgentLoopFrontier` | `22/39` passed, 17 failed, 0 skipped, 0 errored |
| Fresh isolated Release build | passed |

The exact affected
`agent_loop.spawn-batch-two-different-local-workers` row passed both times:

| Trial | Result | Latency | Decode | TTFT | Prefill | Peak physical footprint | Disk L2 delta | SSM delta |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Isolated | pass; 2/2 children, one `spawn_batch`, parent final | 27.257 s | 32.2777 tok/s | 3846.022 ms | 9383.9551 tok/s | 3697.127 MB | `+1/+14/+10` hit/miss/store | `+1` hit, `+0` rederive |
| Full AgentLoop | pass; 2/2 children, one `spawn_batch`, parent final | 31.005 s | 32.3313 tok/s | 3763.604 ms | 9330.4722 tok/s | 3698.627 MB | `+2/+53/+9` hit/miss/store | `+2` hit, `+0` rederive |

The full integrated AgentLoop failures were
`clarify-before-destructive`, `compaction-stress`,
`no-clarify-when-default-obvious`, `search-then-multi-file-edit`, and
`todo-discipline-multistep`. Suite telemetry totaled disk L2
`+88/+1155/+172`, SSM `+88/+0`, peak physical footprint 4965.127 MB, and
decode 16.9841–35.6475 tok/s.

The full integrated AgentLoopFrontier failures were `audit-file-write`,
`code-review-findings`, `compaction-under-load`,
`constraint-retention-carry-token`, `constraint-retention-do-not-touch`,
`constraint-retention-format-marker`, `constraint-retention-no-redo`,
`constraint-retention-ordering-rule`, `csv-aggregate-by-region`,
`data-analysis-artifact`, `exact-bytes-version-contract`,
`fix-failing-tests`, `kitchen-sink`, `multi-file-refactor-with-todo`,
`no-false-clarify`, `ordered-sort-count-pipeline`, and
`self-schedule-followup`. Suite telemetry totaled disk L2
`+232/+1167/+318`, SSM `+232/+0`, peak physical footprint 7687.894 MB, and
decode 22.2499–29.4055 tok/s.

No strong external judge key was available, so rubric-dependent rows used the
run model as self-judge. The deterministic tool, disk, exit, cache, and exact
marker assertions remain authoritative. Every cache/SSM delta in both full
reports was nonnegative. The non-perfect broad scores remain model-quality
evidence and are not described as passes.

### Integrated live Release-app visual proof

Every row below was inspected to terminal state in the fresh integrated
Release app. A side effect without finalization was not counted as a pass.

| Row | Integrated result and visible evidence |
| --- | --- |
| Nanbeige turn 1, thinking on | PASS — reasoning visibly opened with Stop present and closed as `Thought for 4.0s`; final contained `TOKEN-ALPHA` and `2 + 3 = 5`; 78.7 tok/s, 0.62 s TTFT, 380 tokens; Stop disappeared and input unlocked. One irrelevant time-resolution sentence is retained as a quality note. |
| Nanbeige turn 2 | PASS — remembered `TOKEN-ALPHA` exactly; reasoning closed after 1.5 s; 77.2 tok/s, 0.28 s TTFT, 114 tokens; terminal UI. |
| Idle unload | PASS — inspector showed Nanbeige Active at 2.88 GB and count 1. Clicking Unload removed the row, changed the badge to 0, and displayed no cached models. |
| Post-unload reload | PASS — selected-model reload returned exact `POST-UNLOAD-OK`; reasoning closed after 464 ms; 87.3 tok/s, 0.28 s TTFT, 40 tokens; terminal UI. |
| Active-stream unload | PASS — a repeated integer stream was visibly active with Nanbeige resident. Unload cancelled/drained it at integer 176; final stats were 838 tokens, 30.7 tok/s, 0.31 s TTFT. Stop disappeared and input unlocked. The selected-chat prewarm then reloaded Nanbeige, as expected. |
| Active-unload recovery | PASS — immediate follow-up returned exact `ACTIVE-UNLOAD-RECOVERED`; reasoning closed after 569 ms; 77.6 tok/s, 0.32 s TTFT, 44 tokens; terminal UI. |
| Two-model delegation settings | PASS — Settings visibly stored Nanbeige and Ornith as allowed local models, permission `Always Allow`, local handoff on, RAM safety on, and max parallel spawns 2. |
| Mixed-local delegation | PASS — Ornith parent made exactly one `spawn_batch`; both jobs succeeded; final was exact `PARENT-CONTINUED CHILD-NANBEIGE CHILD-ORNITH`; 52.8 tok/s, 4.52 s TTFT, 51 tokens; tool card settled, Stop disappeared, input unlocked. |
| Expanded delegation telemetry | PASS — Nanbeige returned `CHILD-NANBEIGE`, handoff true, 6.829 s, 66.3 tok/s. Ornith returned `CHILD-ORNITH`, handoff false, 0.277 s, 43.9 tok/s. Disk L2 moved `17/116/44` to `17/120/48`, delta `+0/+4/+4`; SSM delta stayed `0/0/0`. The models ran in two admitted local waves and process high watermark was 2. |
| Delegation follow-up | PASS — exact `FOLLOWUP CHILD-NANBEIGE CHILD-ORNITH`; 52.4 tok/s, 2.23 s TTFT, 12 tokens; terminal UI. |
| Held-lease failure | PASS — a test-only lease held Ornith resident at 6.23 GB. Clicking Unload visibly entered disabled `Unloading…`; after the five-second deadline the row remained with the actionable still-in-use error. |
| Retry after lease release | PASS — releasing the test lease and clicking the same row's Unload removed it and displayed no cached models. |
| Zero-residency telemetry | PASS — final `/health` was healthy with `loaded=[]`, `resident_models=[]`, `inflight={}`, HTTP/chat active 0, and live capacity 0, while retired counters remained disk L2 `19/130/51`, SSM `2/0/0`, and high watermark 2. |

The held-lease path used Xcode 26 LLDB against PID `98500` and the production
`ModelLease` actor, first calling `acquire("ornith-1.0-9b-jang_4m")` and then
`release("ornith-1.0-9b-jang_4m")`. No runtime source, timeout, UI
implementation, database, or bundle defaults were modified during live proof.

### Integrated local evidence and hashes

Screenshots are local-only and must not be committed or uploaded to GitHub.

| Artifact | SHA-256 |
| --- | --- |
| Release executable | `6f8498c65d26152bd37675da9eb828632da6ec994ec8d5dba5f30a70b0465104` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-focused-4.log` | `ee847660a2560aa046d3694aed7b9b8b7422d74cb0f7e41d02ed8abefd33fb6f` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-evals-harness.log` | `86efadaf5d25c2e734caa64d9a0db002dd090f3b7c967b86891bec2a9ab5bc66` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-evals-deterministic.log` | `29a8a0b6cccd41d61062de4b1a74bc8752815d7791a61395dc28ac586033660e` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-exact-row.log` | `ddf989c006ffabd8b92b0a303f204cdce0e22d14b05886a24a99242fc2702a0d` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-agentloop-full.log` | `cfb40a1376635f381b47b91b196b51bbd4469a04d973b6a6f2ff1f625264a1e3` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-agentloop/different-local-58a3d357.json` | `aa7d8698428ca714ed76ef8500b8c15dc6812b965f3287725586c0431826ed83` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-agentloop/integrated-AgentLoop.json` | `7aba96fa43af87e59a06c5c7cc4383f6391d5f77d8061c7ba495bcf3ba14eb97` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-agentloop/integrated-AgentLoopFrontier.json` | `59e51ebb6b54e9cea87e24878abd34f666e3215a17007c0125ec8e03a07d0811` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357-release-build.log` | `73504ca6c73554a6721425ebb486260ca5aab276aca9e6aeb134cde79b33dc14` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357/live-ui/health-final.json` | `ebd025f0c32cc6c19e6755181d3648a09274c1d84ae1b1fd5c0e732c3af2ae20` |
| `/private/tmp/osaurus-cache-telemetry-final-58a3d357/live-ui-evidence-58a3d357.tar` (22 PNGs plus final health) | `ba103b0dd9c2f01dadf2239655de5871d1132e2bc1ac2fb188eddbacab4a5510` |

The local-only archive includes open/closed reasoning, both multi-turn terminal
rows, idle and active unload, active recovery, delegation settings, running and
settled tool cards, expanded child/cache telemetry, delegation follow-up, and
the held-lease pending/failure/retry sequence.

## Initial runtime round — exact source and environment

- Osaurus base: `c81491b4b9d78c846a45ac7adccb6b9227137dbc`
  (merged PR #2235, “four fixes”).
- Tested runtime commit:
  `49132a96e73a759708e8ae056c50b8d3ab7f2675`.
- Pinned vMLX:
  `958eb6bed2e2fd4fde30574141e17a1dce773895`.
- Host: Apple M5 Max, 128 GiB unified memory, macOS 26.4.
- Release app:
  `/Users/eric/osaurus-cache-telemetry-20260730/build/DerivedData-cache-unload-release-49132a96/Build/Products/Release/osaurus.app`.
- Release executable SHA-256:
  `773fb3766ae510c5814142c0899a5e3af92e718090fabd08da1eec62be9a33ff`.
- Isolated bundle/defaults domain:
  `com.dinoki.osaurus.cacheunload49132a96`.
- Isolated test root:
  `/private/tmp/osaurus-cache-telemetry-ui-49132a96-final-root`.
- Model root: `/Users/eric/models`.
- Live process during proof: PID `37233`, HTTP server
  `127.0.0.1:1337`.
- Paged RAM KV: off. Disk block L2 and prefix cache: on. SSM rederive:
  on. Continuous batching: on with two configured sequences.

The app was built as a fresh unsigned Release product and ad-hoc sealed for the
keychain-free proof lane. It was launched with:

```text
scripts/live-proof/open-keychain-free-osaurus.sh \
  /Users/eric/osaurus-cache-telemetry-20260730/build/DerivedData-cache-unload-release-49132a96/Build/Products/Release/osaurus.app \
  com.dinoki.osaurus.cacheunload49132a96 \
  /Users/eric/models \
  /private/tmp/osaurus-cache-telemetry-ui-49132a96-final-root
```

### Exact model identities and defaults

| Model | Exact local identity | Bundle defaults used |
| --- | --- | --- |
| Nanbeige 4.2 3B JANG_4M | `/Users/eric/models/JANGQ-AI/Nanbeige4.2-3B-JANG_4M`; source revision in bundle README `fab06df`; config/index SHA-256 `7d22f298db3c9bf11893de06b66613ef6b7ff7c17020c0de76e72667864bbff9` / `511591f4a1fc9be0d007f0d4fa7df743245297d4795436272237d25a1e44c695` | `do_sample=true`, temperature `0.6`, top-p `0.95`, top-k `20`, EOS `166101`; no min-p or repetition-penalty override. Thinking was explicitly enabled for the two-turn UI row. |
| Ornith 1.0 9B JANG_4M | `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M`; the local bundle has no Hub revision marker, so config/index SHA-256 `2f4828bffc846f5f8e300284addfdebef8ef7a1f9583636a982c0c137449cc63` / `f9144b0b4423c0dcaca2a08fc09c634c89ae0cdd79521c903fd0518f74ece7ac` is the retained identity | The bundle has no temperature, top-p, top-k, min-p, repetition-penalty, or sampling override; EOS is `[248046, 248046]`. Model-backed eval jobs passed nil sampler overrides. Thinking was off for the delegation UI row. |

Full generation-config SHA-256 values are
`68c690ce23efb6caae30c006ff3c1efd826297ff1df4338c04f7ac6f685d8746`
for Nanbeige and
`12a900f4edc6e82f7b03c94b1abaf8763b7fdec971c6e1440809461e21e8eae3`
for Ornith. No prompt coercion, forced thinking tags, hidden sampler override,
or synthetic output cap was added by this change.

## Source trace

### Explicit unload

- `MLXService.unloadRuntimeModel` returns the runtime Boolean and applies a
  five-second default lease-drain deadline.
- `ModelRuntime.unloadClaimed` shuts down the selected engine, cancels and
  awaits only the selected model's tracked generation wrappers, then waits for
  its lease. Idle-policy unload retains its separate wait-without-cancel
  behavior.
- A timeout returns `false` before cache removal or GPU teardown. The model
  remains resident, preserving fail-closed safety.
- `ModelCacheInspectorView` disables only the selected row, displays a progress
  spinner and `Unloading…`, refreshes on authoritative residency changes, and
  reports:
  `Couldn't unload <model> because it is still in use. Stop its active request and try again.`

### Process-lifetime diagnostics

- `ProcessLifetimeBatchCounters` retains only monotonic engine/cache counters.
  It clamps negative inputs and uses saturating addition.
- `MLXBatchAdapter.Registry` folds retired engine high-water/decode/TurboQuant
  counters into the process accumulator.
- `ModelRuntime` samples final cache-coordinator counters after engine shutdown,
  removes the holder from the live dictionary, and only then records the
  retired counters. That live-to-retired ordering represents each value once.
- `snapshotDiagnostics()` merges retired counters with the live snapshot while
  keeping pending, active, capacity, loaded-model, native-MTP, and cache
  topology fields live-only.

## Initial runtime round — automated proof

| Lane | Result |
| --- | ---: |
| Focused unload/telemetry source and behavior regressions | `4/4` passed in 2 suites |
| Complete `OsaurusEvals` Swift package test harness | 299 tests in 36 suites, 0 failures; 3 host resource-sampler tests explicitly skipped |
| Deterministic eval lanes | `101/101` passed across 8 suites |
| Exact affected mixed-local row, isolated run | `1/1` passed |
| Full model-backed `AgentLoop` | `32/40` passed, 5 failed, 3 skipped, 0 errored |
| Full model-backed `AgentLoopFrontier` | `24/39` passed, 15 failed, 0 skipped, 0 errored |
| Partial-failure batch follow-up, 3 trials | majority pass `2/3`, explicitly `FLAKY` |
| Fresh isolated Release build | passed |

The focused tests prove:

- retired values are counted once while live occupancy/topology stay live-only;
- negative diagnostic inputs clamp to zero and additions saturate;
- explicit unload drains the tracked generation wrapper before lease wait; and
- the inspector exposes pending, success, and fail-closed UI contracts.

### Exact affected model-backed row

`agent_loop.spawn-batch-two-different-local-workers` passed in both its isolated
run and the full AgentLoop run.

| Trial | Result | Latency | Decode | TTFT | Prefill | Peak physical footprint | Disk L2 delta | SSM delta |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Isolated | pass; 2/2 children, one `spawn_batch`, parent final | 22.383 s | 32.7949 tok/s | 3423.032 ms | 8993.9097 tok/s | 3681.971 MB | `+1/+14/+10` hit/miss/store | `+1` hit, `+0` rederive |
| Full AgentLoop | pass; 2/2 children, one `spawn_batch`, parent final | 33.295 s | 22.6414 tok/s | 4281.980 ms | 9088.883 tok/s | 3725.049 MB | `+2/+47/+9` hit/miss/store | `+2` hit, `+0` rederive |

Both runs used serialized local model waves, returned
`DIFFERENT_LOCAL_ALPHA` and `DIFFERENT_LOCAL_BETA`, and contained no negative
monotonic delta.

### Broad model-eval attribution

No strong external judge key was available. Rubric-dependent cases therefore
used the run model as self-judge; deterministic disk/tool/exit assertions remain
authoritative. Raw non-perfect scores are preserved instead of summarized as
passing.

The PR #2235 Ornith baseline was `33/40` AgentLoop and `21/39`
AgentLoopFrontier. The current full lanes were:

- AgentLoop `32/40`: failures were `batch-error-isolation`,
  `compaction-stress`, `no-clarify-when-default-obvious`,
  `search-then-multi-file-edit`, and `todo-discipline-multistep`; the three
  AppleScript rows remained skipped because their required capability was
  unavailable. `answer-direct-no-complete` and
  `idempotent-already-satisfied` changed from baseline fail to pass.
  `batch-error-isolation`, `no-clarify-when-default-obvious`, and
  `search-then-multi-file-edit` changed from baseline pass to fail.
- The changed partial-failure batch row was rerun three times. It passed by
  majority `2/3` and the report marks it `FLAKY`. Its successful aggregate had
  a final response, correct `north south` disk state, 33.2705 tok/s,
  239.979 ms TTFT, 19168.1914 prefill tok/s, 4809.096 MB peak physical
  footprint, disk L2 `+4/+18/+6`, and SSM `+4/+0`. The failed trial was a
  model tool-selection miss, not a batch-fatal runtime error.
- `no-clarify-when-default-obvious` completed the correct file change and
  passed both self-judge conditions, but over-called tools and hit its iteration
  cap. `search-then-multi-file-edit` left one old call site while claiming
  completion. These are task-quality misses outside the changed source paths.
- AgentLoopFrontier `24/39`: 15 failures, 0 errors, a net three-row improvement
  over baseline. The newly failing rows were `data-analysis-artifact`,
  `fix-failing-tests`, and `ordered-sort-count-pipeline`; the report also moved
  several baseline failures to pass. These are retained as model-quality
  evidence, not runtime passes.

Across the full lanes, AgentLoop telemetry totaled disk L2
`+92/+1160/+180` and SSM `+92/+0`; AgentLoopFrontier totaled disk L2
`+206/+1115/+290` and SSM `+206/+0`. Every per-case monotonic delta was
nonnegative. There were no errored rows, runtime crashes, unsupported-model
errors, or raw `<think>`/tool-protocol/replacement-character matches in either
report. The exact source diff does not alter prompts, generation, tool choice,
parsers, or scoring.

## Initial runtime round — live Release-app visual proof

Every row below used the exact isolated Release app and was visually inspected
through terminal state: reasoning/card closure, final text, Stop disappearance,
input unlock, and the next action or follow-up.

| Row | Result and visible evidence |
| --- | --- |
| Nanbeige turn 1, thinking on | PASS — reasoning opened and closed as `Thought for 5.6s`; final contained `TOKEN-ALPHA` and `2 + 3 = 5`; 76.0 tok/s, 0.59 s TTFT; Stop disappeared and input unlocked. The answer contained one irrelevant time-resolution sentence, retained as a quality note, but no protocol debris or malformed text. |
| Nanbeige turn 2 | PASS — remembered `TOKEN-ALPHA` exactly; reasoning closed after 2.4 s; 70.7 tok/s, 0.45 s TTFT; terminal UI. |
| Idle unload | PASS — inspector showed Nanbeige Active at 2.88 GB and count 1. Clicking Unload removed the row, changed the badge to 0, and displayed `No models currently cached.` |
| Post-unload reload | PASS — reopening Chat reloaded the selected model and returned exact `POST-UNLOAD-OK`; reasoning closed after 472 ms; 85.7 tok/s, 0.30 s TTFT; terminal UI. |
| Active-stream unload | PASS — a 1–2000 integer stream was visibly generating with one active Nanbeige residency. Unload cancelled/drained the stream around integer 767; final stats were 3045 generated tokens, 48.7 tok/s, 0.29 s TTFT. Stop disappeared and input unlocked. Chat's selected-model prewarm then reloaded Nanbeige, as expected. |
| Active-unload recovery | PASS — immediate follow-up returned exact `ACTIVE-UNLOAD-RECOVERED`; 72.0 tok/s, 0.40 s TTFT; terminal UI. |
| Two-model delegation setup | PASS — Settings stored Nanbeige and Ornith as allowed local models, permission `Always Allow`, local handoff on, RAM safety on, and max parallel spawns 2. The first attempt honestly exposed the default limit of 1 and was not counted as a pass. |
| Corrected mixed-local delegation | PASS — Ornith parent made one `spawn_batch`; 2 jobs succeeded, 0 failed; final was exact `PARENT-CONTINUED CHILD-NANBEIGE CHILD-ORNITH`; 51.6 tok/s, 4.35 s TTFT; card settled, Stop disappeared, input unlocked. |
| Expanded delegation telemetry | PASS — Nanbeige child returned `CHILD-NANBEIGE` with handoff true, 5.381 s and 66.6 tok/s. Ornith returned `CHILD-ORNITH` with handoff false, 0.263 s and 50 tok/s. Disk L2 moved from `16/125/46` to `17/127/50`, delta `+1/+2/+4`; SSM stayed `4/0/0`, delta `0/0/0`. The two different models ran in two admitted local waves and the process high watermark remained 1. |
| Delegation follow-up | PASS — exact `FOLLOWUP CHILD-NANBEIGE CHILD-ORNITH`; 51.5 tok/s, 2.56 s TTFT; terminal UI. |
| Held-lease failure | PASS — a test-only lease held Ornith resident at 6.23 GB. Clicking Unload immediately showed disabled `Unloading…`; after five seconds the row remained and the actionable still-in-use message appeared. The UI did not hang or falsely remove the model. |
| Retry after lease release | PASS — releasing the test lease and clicking Unload again removed the row, changed the badge to 0, and displayed no cached models. |
| Zero-residency telemetry | PASS — final `/health` had `loaded=[]`, `resident_models=[]`, `inflight={}`, live active/capacity 0, while retired counters remained disk L2 `19/131/53`, SSM `6/0/0`, and high watermark 1. |

The held-lease failure path was made deterministic by attaching Xcode 26 LLDB
to the exact Release process and calling the production lease actor:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun lldb \
  --batch -p 37233 \
  -o 'settings set target.swift-module-search-paths /Users/eric/osaurus-cache-telemetry-20260730/build/DerivedData-cache-unload-release-49132a96/Build/Products/Release' \
  -o 'expr -l swift -- import OsaurusCore' \
  -o 'expr -l swift -- Task { await ModelLease.shared.acquire("ornith-1.0-9b-jang_4m") }' \
  -o detach
```

The same actor call with `release` removed the synthetic holder before the
successful retry. No runtime source, timeout, UI implementation, or database
was patched during the proof.

Persisted live-test settings are retained at:

- `/private/tmp/osaurus-cache-telemetry-ui-49132a96-final-root/config/agent-delegation.json`,
  SHA-256
  `4e46a6dc77387149e41dacfc3307b14cda11acd9ba8b7e388f25812c6fe7ca2b`;
- `/private/tmp/osaurus-cache-telemetry-ui-49132a96-final-root/config/server-runtime.json`,
  SHA-256
  `916df043a4e0446591820aaea437ed406528d7f234d9dc0bad796451c0719dfa`;
- `/private/tmp/osaurus-cache-telemetry-ui-49132a96-final-root/config/default-agent.json`,
  SHA-256
  `ceb1253079dbe918b2a61d39264f6635fa17d32e5f56d28d0e499c78f8896cb0`.

## Initial runtime round — local evidence and hashes

Screenshots are local-only and must not be committed or uploaded to GitHub.

| Artifact | SHA-256 |
| --- | --- |
| `/private/tmp/osaurus-cache-telemetry-evidence/focused-unit-final.log` | `20e5d1746828a43ce6e6273e541d9479c25b076da2cdcdb0f5279b445279b674` |
| `/private/tmp/osaurus-cache-telemetry-evidence/release-build-49132a96.log` | `c72c78ab36b63795a5e6d5668a7da06fd762cbae55a0baace7ceb2b335364aa4` |
| `/private/tmp/osaurus-cache-telemetry-final-49132a96/evals-harness-xcode.log` | `8fd9c182b0b9211f155ba7d987615083c8957af66634999733f5a712e87eb747` |
| `/private/tmp/osaurus-cache-telemetry-final-49132a96/evals-deterministic.log` | `b4a036177273e4f4251db467a786a621792116d38bb687d3fcbd58f40adc5fea` |
| `/private/tmp/osaurus-cache-telemetry-final-49132a96/agentloop-full/final-AgentLoop.json` | `450df29aacca57fa44501536386fc1090eebec90bb1710bcc58258c6e36f396d` |
| `/private/tmp/osaurus-cache-telemetry-final-49132a96/agentloop-full/final-AgentLoopFrontier.json` | `c766437710204503e378ee6e08951d9f2d999a00720b9d1ac1cd97d347dc4f8a` |
| `/private/tmp/osaurus-cache-telemetry-final-49132a96/different-local-row-registered-v2.json` | `97bffa4a0b6398b8c496e8c3db27b5f554b8bc25453698ffdc17e94f814ae4a4` |
| `/private/tmp/osaurus-cache-telemetry-final-49132a96/batch-error-isolation-repeat3.json` | `932eb6d061ff733f1e26bc23b93079c419d7decbb396666ec677de66da7cbdc6` |
| `/private/tmp/osaurus-cache-telemetry-final-49132a96/live-ui/health-final.json` | `f2b2ac23bb6d911b98506bcb920cadef8a1e82ab532ef37c7f7d0d24b5ca15ca` |
| `/private/tmp/osaurus-cache-telemetry-final-49132a96/live-ui-evidence-49132a96.tar` (20 PNGs plus final health) | `3f8f76edac37e5dc965f5aa135efb15e0f2b12081ba6c399eaca4f3cacbb8f86` |

The live screenshot archive contains the terminal two-turn rows, idle and
active unload lifecycle, held-lease pending/failure/success sequence,
delegation setup, running and terminal cards, expanded cache telemetry, and the
post-delegation follow-up. It is retained locally only.
