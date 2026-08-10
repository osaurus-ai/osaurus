# Agent-loop and cache-proof regression gates — 2026-07-27

Status: **VERIFIED-LIVE for the stale-session Todo control-flow fix and
disk-only longest-prefix cache rows; PARTIAL for independent Bonsai/Ornith
model-quality consistency.**

This follow-up starts from Osaurus
`12c6de27b4291fc542d61499ec132ddc4cba0ed7` and pins merged vMLX PR
[#190](https://github.com/osaurus-ai/vmlx-swift/pull/190) at
`d2f6f98265fabe2f017a9eb4af237b962154228a`. The final Osaurus source
under test is `78e12abe23fa2df735796adac78a25f3d8cc19be`.

The root defect was a scope mismatch: the Todo UI is intentionally
session-persistent, but `CompleteTool` could treat a checklist from an earlier
user turn as terminal state for an unrelated later AgentToolLoop run. This PR
adds one TaskLocal Todo marker per logical run, binds it around serial and
batched tool execution, and rejects stale-session `complete` calls with typed
reason `stale_session_todo`; the loop then recovers to one ordinary final
answer. Direct/bare tool callers retain their historical behavior. No sampler,
reasoning tag, close token, model-family rule, or synthetic generation default
is changed.

The eval additions strengthen the no-repeat regression gate and add typed
cache-progress scoring. The vMLX pin adds a topology-scoped runtime fix:
standalone rotating/SWA caches capture an exact prompt-minus-one SSD seed while
real prefill crosses that boundary, instead of attempting unsafe post-hoc
trimming of disk-backed heterogeneous cache state.

No screenshots or other binary evidence belong in this directory or the PR.
Local UI captures are ephemeral operator evidence only.

## Reported failures in scope

| Row | Failure to catch | Owning proof gap | Current status |
|---|---|---|---|
| A | Successful Reminder/tool side effect followed by repeated confirmation until the step cap | AgentLoop must terminate on the first ordinary final even with pending Todo | Current-source Gemma 3/3; Bonsai 2/3 and Ornith 1/3 are strict-output FLAKY. Their recorded failures are pre-action Todo/tool-choice loops or wrong final prose, not the reported post-success repeated terminal confirmation |
| B | A stale prior-turn Todo makes a later `complete` call falsely BLOCKED | Todo terminal semantics were session-scoped instead of run-scoped | Current Release UI directly produced `stale_session_todo`, recovered to one exact final, unlocked input, and remained idle without repetition |
| C | Task finishes while the pinned Todo remains `0/N` or partially checked | Existing scorer only required any one `[x]` | New opt-in final-checklist scorer covered by deterministic tests; the live Gemma row still printed a prose checklist instead of updating the Todo tool, so strict model-quality status remains PARTIAL |
| D | SSD cache appears warm but UI/proof cannot show a complete restore → prefill → complete counter lifecycle | CacheProof kept only the largest restore count | Typed lifecycle scored 3/3 on Laguna, Gemma, and Bonsai with paged RAM off |
| E | Multiple SSD candidates exist but proof does not show that the longest valid prefix wins | Existing case used only two fresh sessions | Three-session longest-match row scored 3/3 on all three available families |
| F | Disk-only full-attention rows fail legacy RAM-prefix-counter assertions | Three general fixtures required raw `kvPrefixHits` | Per-turn typed disk-restore gates scored on full-attention and hybrid-SSM rows |

## Source contracts

- `Packages/OsaurusCore/Services/Chat/AgentToolLoop.swift`: an ordinary final
  response is authoritative; one Todo scope is created per run and bound around
  serial, deferred, and batched tool dispatch.
- `Packages/OsaurusCore/Tools/AgentLoopTools.swift`: a valid Todo call marks
  only the current logical run; `complete` rejects an older session checklist
  with typed reason `stale_session_todo`.
- `Packages/OsaurusCore/Folder/ChatExecutionContext.swift`: the run marker is a
  lock-protected TaskLocal reference inherited safely by batch child tasks.
- `Packages/OsaurusEvals/Sources/OsaurusEvalsKit/EvalRunnerAgentLoop.swift`:
  `todoCompletedBeforeFinal` parses the last successful Todo before terminal
  completion and requires every real checklist item checked.
- `Packages/OsaurusCore/Services/Context/CacheProofEvaluator.swift`: every
  production `StreamingPrefillProgressHint` frame is retained per turn.
- `Packages/OsaurusEvals/Sources/OsaurusEvalsKit/EvalRunnerCacheProof.swift`:
  typed progress must keep one total, bounded and monotonic completed counts,
  preserve the restore baseline into prefill, and end at `complete == total`.
- `Packages/OsaurusEvals/Suites/CacheProof/cross-session-longest-disk-prefix.json`:
  three independent sessions create a short cache candidate, extend it, then
  require the final session to restore the longer disk candidate by a scored
  token gain.
- vMLX `Libraries/MLXLMCommon/Evaluate.swift`: captures a safe SSD seed only
  for text-only, persistable, standalone rotating/SWA topology during actual
  prefill; the fail-closed post-hoc disk rederive guard remains intact.

## Required proof before merge

Record exact report paths, run identifiers, case totals, and per-model scores
below. Every GitHub status comment must repeat the exact OsaurusEval scores;
never substitute “green” or screenshots for numbers.

| Suite / model | Score | Key telemetry | Evidence |
|---|---:|---|---|
| Focused current-source Xcode suites | 115/115 PASS | Todo tool/run scope, stale-session recovery, ordinary final authority, cancellation, tool failure, parallel batch, over-budget, compaction watermark, Computer Use, AppleScript, and reasoning terminal paths | `/private/tmp/osaurus-agentloop-cache-evals-xcode-derived-20260727/Logs/Test/Test-OsaurusCoreTests-2026.07.27_09-02-41--0700.xcresult` |
| vMLX growing-chat cache source | 18/18 PASS | rotating seed capture and growing-chat source behavior | `BatchEngineGrowingChatCacheSourceTests`; PR head `a4b3258c`, identical source tree merged at `d2f6f982` |
| vMLX topology-focused cache tests | 42/42 PASS | mixed-SWA TurboQuant RAM→disk, paged-off hybrid restore, eviction fallback, media/reasoning isolation, typed companion state | `CacheCoordinatorTopologyFocusedTests`; PR head `a4b3258c`, identical source tree merged at `d2f6f982` |
| vMLX restore-progress tests | 1/1 PASS | restore/prefill progress contract | `TokenIteratorCacheRestoreProgressTests`; PR head `a4b3258c`, identical source tree merged at `d2f6f982` |
| vMLX canonical cache-boundary tests | 7/7 PASS | exact prompt/cache boundary behavior | `CanonicalChatCacheBoundariesTests`; PR head `a4b3258c`, identical source tree merged at `d2f6f982` |
| AgentLoop — Gemma 4 26B A4B JANG_4M | 3/3 PASS | `finalResponse`; 4 model steps; 35.3 tok/s; TTFT 211 ms; L2 +3 hits/+10 stores | `/private/tmp/osaurus-evals-final-20260727/gemma26/combined-rerun.json` |
| AgentLoop — Bonsai 27B Ternary JANG | 2/3 FLAKY | two trials pass once; failed trial loops on Todo/tool choice before writing; aggregate passing trial exits `finalResponse`; 18.4 tok/s | `/private/tmp/osaurus-evals-final-20260727/bonsai27/combined-rerun.json` |
| AgentLoop — Ornith 9B JANG_4M | 1/3 FLAKY | recorded strict failures end with wrong/extra final prose despite correct `file_write`, not repeated terminal confirmations; the aggregate passing trial exits `finalResponse`; 31.3 tok/s | `/private/tmp/osaurus-evals-final-20260727/ornith9/agentloop-rerun.json` |
| AgentLoopFrontier broad model-quality rows | NOT RUN | not substituted for the scoped deterministic and live no-loop gates; requires a separate model-quality campaign | No current artifact |
| CacheProof disk-only — Gemma 4 26B A4B JANG_4M | 3/3 PASS | 293/705 → 704/705 restored; +411 gain; L2 +2 hits/+13 stores; 33.5 tok/s | `/private/tmp/osaurus-evals-final-20260727/gemma26/combined-rerun.json` |
| CacheProof disk-only — Bonsai 27B Ternary JANG | 3/3 PASS | hybrid: 295/716 → 709/716; +414 gain; SSM +2 hits; L2 +2 hits/+4 stores; 18.5 tok/s | `/private/tmp/osaurus-evals-final-20260727/bonsai27/combined-rerun.json` |
| CacheProof disk-only — Laguna S 2.1 JANG_4M | 3/3 PASS | 291/713 → 712/713 restored; +421 gain; L2 +2 hits/+11 stores; 27.8 tok/s | `/private/tmp/osaurus-evals-final-20260727/laguna/cacheproof-rerun.json` |
| Isolated Release app live UI | PASS for stale-Todo scope/finalization | exact stale-session rejection, ordinary-final recovery, input unlock, follow-up, 10-second no-repeat dwell, visible external-model configuration | source `78e12abe`; test root and SQLite session below |

Rows without current live evidence remain `PARTIAL`; one sibling quant or
architecture never proves another.

The model rows above use deterministic exit/tool/file/cache assertions. No
strong external judge key was configured; the CLI emitted its self-judge
warning, so no subjective rubric score is represented as authoritative. The
reported Bonsai and Ornith flakes remain failures in their strict quality rows;
they are not relabeled as passes merely because the control-flow fix terminated
the run.

## Current-source Release live UI

The isolated app was built from exact Osaurus source
`78e12abe23fa2df735796adac78a25f3d8cc19be` and exact vMLX pin
`d2f6f98265fabe2f017a9eb4af237b962154228a`:

- Release app:
  `/private/tmp/osaurus-agentloop-cache-release-derived-20260727/Build/Products/Release/osaurus.app`
- bundle identifier: `com.dinoki.osaurus.agentloopcacheproof20260727`
- signed executable SHA-256:
  `718d27db85740e4e6b97029e1fba2a777dcdbc4eecb4202ca23f52d55b0f98b3`
- test root:
  `/private/tmp/osaurus-agentloop-cache-live-root-postfix-20260727-0914`
- SQLite session: `498181EE-A8FB-4285-8609-177FB05F255D`

Through the real Settings UI, Storage → External models was set to
`/Users/eric/models`, the app visibly rescanned 61 models, and exact
`OsaurusAI Gemma 4 26B A4B it qat JANG_4M` was selected with Thinking visible.
The app reached “Chat prefix warm — ready for a fast next response.”

The first live task called Todo and `osaurus_status`, then returned one final
ending `STATUS_AUDIT_DONE` (TTFT 0.60 s, 101.0 tok/s). The model printed its
checked list in prose instead of calling Todo again, so the pinned card remained
`0/3`; that is retained as a separate model-quality failure, not hidden by the
control-flow result. The Stop control disappeared and input unlocked.

The immediate follow-up returned exactly `STALE_TODO_FOLLOWUP_OK` (TTFT
1.03 s, 80.7 tok/s), closed its reasoning/status card, unlocked input, and
remained idle for ten seconds without repeating. SQLite sequences 5 and 9
record `terminal_stop_reason=stop`. Runtime trace on the same session showed
disk restores at boundaries 2474 and 2943 with only 204 and 1347 tokens left to
prefill, respectively; stores remained within the memory budget.

Finally, the live chat called `complete` while only the earlier turn's Todo
existed. The first short summary failed normal schema validation. A valid retry
then returned the exact owning-layer rejection with reason
`stale_session_todo` and message that the current run had not called Todo. The
model recovered to one exact `STALE_COMPLETE_PROBE_OK` final (TTFT 0.76 s,
80.8 tok/s); Stop disappeared and input unlocked. SQLite sequence 15 records a
terminal `stop`. The app then quit cleanly through the UI.

No screenshot, model output binary, app binary, or cache tensor is committed
as evidence.
