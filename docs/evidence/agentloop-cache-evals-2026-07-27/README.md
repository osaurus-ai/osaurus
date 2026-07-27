# Agent-loop and cache-proof regression gates — 2026-07-27

Status: **PARTIAL — scoped source/model gates pass except the explicitly
reported Bonsai model-execution flake; the rebased Release-app UI refresh is
still pending.**

This follow-up starts from Osaurus
`12c6de27b4291fc542d61499ec132ddc4cba0ed7` and pins merged vMLX PR
[#190](https://github.com/osaurus-ai/vmlx-swift/pull/190) at
`d2f6f98265fabe2f017a9eb4af237b962154228a`. Osaurus source already
returns immediately from an ordinary `AgentToolLoop.finalResponse`, even when
a current Todo remains unchecked. This PR strengthens that regression gate and
adds typed cache-progress scoring. The vMLX pin adds a topology-scoped runtime
fix: standalone rotating/SWA caches capture an exact prompt-minus-one SSD seed
while real prefill crosses that boundary, instead of attempting unsafe
post-hoc trimming of disk-backed heterogeneous cache state.

No screenshots or other binary evidence belong in this directory or the PR.
Local UI captures are ephemeral operator evidence only.

## Reported failures in scope

| Row | Failure to catch | Owning proof gap | Current status |
|---|---|---|---|
| A | Successful Reminder/tool side effect followed by repeated confirmation until the step cap | AgentLoop must terminate on the first ordinary final even with pending Todo | Gemma 3/3; Ornith 9B 3/3; Bonsai 2/3 FLAKY, but its failed trial still exited `finalResponse` without repetition |
| B | Task finishes while the pinned Todo remains `0/N` or partially checked | Existing scorer only required any one `[x]` | New opt-in final-checklist scorer covered by deterministic tests; strict live-model quality row remains separate |
| C | SSD cache appears warm but UI/proof cannot show a complete restore → prefill → complete counter lifecycle | CacheProof kept only the largest restore count | Typed lifecycle scored 3/3 on Laguna, Gemma, and Bonsai with paged RAM off |
| D | Multiple SSD candidates exist but proof does not show that the longest valid prefix wins | Existing case used only two fresh sessions | Three-session longest-match row scored 3/3 on all three available families |
| E | Disk-only full-attention rows fail legacy RAM-prefix-counter assertions | Three general fixtures required raw `kvPrefixHits` | Per-turn typed disk-restore gates scored on full-attention and hybrid-SSM rows |

## Source contracts

- `Packages/OsaurusCore/Services/Chat/AgentToolLoop.swift`: an ordinary final
  response is authoritative; Todo is advisory and does not reopen the run.
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
| Focused deterministic Swift tests | 12/12 PASS | schema, Todo parsing, progress accounting | `swift test --package-path Packages/OsaurusEvals --filter AgentLoopCacheProofCampaignTests` |
| Core Todo tool tests | 28/28 PASS | first run exposed one stale exact-wording assertion at 27/28; corrected source rerun passed all 28 | `swift test --package-path Packages/OsaurusCore --filter AgentLoopToolsTests` |
| Production AgentToolLoop tests | 84/84 PASS | ordinary final is authoritative; pending/stale Todo, cancellation, tool failure, parallel batch, Computer Use, AppleScript, and reasoning-only terminal paths | `swift test --package-path Packages/OsaurusCore --filter AgentToolLoopTests` |
| vMLX growing-chat cache source | 18/18 PASS | rotating seed capture and growing-chat source behavior | `BatchEngineGrowingChatCacheSourceTests`; PR head `a4b3258c`, identical source tree merged at `d2f6f982` |
| vMLX topology-focused cache tests | 42/42 PASS | mixed-SWA TurboQuant RAM→disk, paged-off hybrid restore, eviction fallback, media/reasoning isolation, typed companion state | `CacheCoordinatorTopologyFocusedTests`; PR head `a4b3258c`, identical source tree merged at `d2f6f982` |
| vMLX restore-progress tests | 1/1 PASS | restore/prefill progress contract | `TokenIteratorCacheRestoreProgressTests`; PR head `a4b3258c`, identical source tree merged at `d2f6f982` |
| vMLX canonical cache-boundary tests | 7/7 PASS | exact prompt/cache boundary behavior | `CanonicalChatCacheBoundariesTests`; PR head `a4b3258c`, identical source tree merged at `d2f6f982` |
| AgentLoop — Gemma 4 26B A4B JANG_4M | 3/3 PASS | `finalResponse`; 4 model steps; 36.0 tok/s; TTFT 173 ms; L2 +3 hits/+10 stores | `/private/tmp/osaurus-evals-postseed-20260727/agentloop-gemma26/gemma26-final-after-success.json` |
| AgentLoop — Bonsai 27B Ternary JANG | 2/3 FLAKY | passed trials exit once; failed trial also exited once but used `share_artifact` and wrote `REMAINDER_CREATED`; 16.6 tok/s | `/private/tmp/osaurus-evals-postseed-20260727/agentloop-bonsai27/bonsai27-final-after-success.json` |
| AgentLoop — Ornith 9B JANG_4M | 3/3 PASS | `finalResponse`; 5 model steps; 37.2 tok/s; TTFT 236 ms; L2 +4 hits/+6 stores | `/private/tmp/osaurus-evals-postseed-20260727/agentloop-ornith9/ornith9-final-after-success.json` |
| AgentLoopFrontier broad model-quality rows | NOT RUN | not substituted for the scoped deterministic and live no-loop gates; requires a separate model-quality campaign | No current artifact |
| CacheProof disk-only — Gemma 4 26B A4B JANG_4M | 3/3 PASS | 292/704 → 703/704 restored; +411 gain; L2 +2 hits/+13 stores; 36.0 tok/s | `/private/tmp/osaurus-evals-postseed-20260727/gemma26/gemma26-postseed-cacheproof.json` |
| CacheProof disk-only — Bonsai 27B Ternary JANG | 3/3 PASS | hybrid: 295/716 → 709/716; +414 gain; SSM +2 hits; L2 +2 hits/+4 stores; 18.7 tok/s | `/private/tmp/osaurus-evals-postseed-20260727/bonsai27/bonsai27-postseed-cacheproof.json` |
| CacheProof disk-only — Laguna S 2.1 JANG_4M | 3/3 PASS | pre-fix 0/3 with +0 gain; post-fix 293/715 → 714/715; +421 gain; L2 +2 hits/+11 stores; 27.9 tok/s | `/private/tmp/osaurus-evals-postseed-20260727/laguna/laguna-postseed-cacheproof.json` |
| Isolated Release app live UI | PENDING | terminal UI, input unlock, follow-up turn, visible cache settings | PENDING |

Rows without current live evidence remain `PARTIAL`; one sibling quant or
architecture never proves another.

The model rows above use deterministic exit/tool/file/cache assertions. No
strong external judge key was configured; the CLI emitted its self-judge
warning, so no subjective rubric score is represented as authoritative.

## Superseded live-UI checkpoint

Before rebasing, an isolated Release app built from the same two campaign
commits on Osaurus base `a8a78ecb81aa80011e24645e991ac60eb711a3f4`
visibly completed the direct pending-Todo regression with Gemma 4 26B:

- Todo remained intentionally advisory at `2/3`;
- the `osaurus_status` tool card completed;
- one final answer ended in `STATUS_AUDIT_DONE`;
- the Stop control disappeared and input unlocked;
- a ten-second idle dwell produced no repeated final or reopened turn;
- a follow-up returned `STALE_TODO_FOLLOWUP_OK` and also finalized.

SQLite preserved the same lifecycle in session
`3C1A11C0-1252-46BC-B943-1F608A7C34BE` under
`/private/tmp/osaurus-agentloop-cache-live-root-20260727-2`: terminal turns 5
and 7 both recorded `terminal_stop_reason=stop`. This is retained as useful
regression history, not current-source proof: Osaurus `main` advanced to
`12c6de27b4291fc542d61499ec132ddc4cba0ed7`, so the exact rebased Release app
must repeat the row before the UI gate can be marked live.
