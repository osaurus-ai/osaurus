# Agent-loop and cache-proof regression gates — 2026-07-27

Status: **PARTIAL — source changes authored; live model and UI rows pending.**

This follow-up starts from Osaurus
`74fa06aed48e9740b86d360542b380bf5de89bf8` with vMLX
`64b6ca2433c12af2dd6955f317366f0f9626e061`. It does not claim a new
runtime fix: that Osaurus source already returns immediately from an ordinary
`AgentToolLoop.finalResponse`, even when a current Todo remains unchecked. This
PR strengthens the regression suite so later agent-loop or cache changes cannot
silently reintroduce the reported behaviors.

No screenshots or other binary evidence belong in this directory or the PR.
Local UI captures are ephemeral operator evidence only.

## Reported failures in scope

| Row | Failure to catch | Owning proof gap | Current status |
|---|---|---|---|
| A | Successful Reminder/tool side effect followed by repeated confirmation until the step cap | AgentLoop must terminate on the first ordinary final even with pending Todo | Existing runtime regression fixture retained; live rerun pending |
| B | Task finishes while the pinned Todo remains `0/N` or partially checked | Existing scorer only required any one `[x]` | New opt-in final-checklist scorer authored; model runs pending |
| C | SSD cache appears warm but UI/proof cannot show a complete restore → prefill → complete counter lifecycle | CacheProof kept only the largest restore count | Full typed progress sequence now recorded and scored; live runs pending |
| D | Multiple SSD candidates exist but proof does not show that the longest valid prefix wins | Existing case used only two fresh sessions | Three-session short → extended → longest-match fixture authored; live runs pending |
| E | Disk-only full-attention rows fail legacy RAM-prefix-counter assertions | Three general fixtures required raw `kvPrefixHits` | Converted to per-turn typed restore gates; live runs pending |

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

## Required proof before merge

Record exact report paths, run identifiers, case totals, and per-model scores
below. Every GitHub status comment must repeat the exact OsaurusEval scores;
never substitute “green” or screenshots for numbers.

| Suite / model | Score | Key telemetry | Evidence |
|---|---:|---|---|
| Focused deterministic Swift tests | PENDING | schema, Todo parsing, progress accounting | PENDING |
| AgentLoop — Gemma 4 | PENDING | exit, model steps, Todo final state, tok/s | PENDING |
| AgentLoop — Bonsai/Qwen | PENDING | exit, model steps, Todo final state, tok/s | PENDING |
| AgentLoop — Ornith | PENDING | exit, model steps, Todo final state, tok/s | PENDING |
| AgentLoopFrontier targeted rows | PENDING | outcomes, Todo final state, no loop | PENDING |
| CacheProof disk-only — Gemma 4 | PENDING | restored/remaining, progress sequence, TTFT, disk counters | PENDING |
| CacheProof disk-only — Bonsai/Qwen | PENDING | restored/remaining, companion state, TTFT, disk counters | PENDING |
| CacheProof disk-only — Laguna | PENDING | restored/remaining, progress sequence, TTFT, disk counters | PENDING |
| Isolated Release app live UI | PENDING | terminal UI, input unlock, follow-up turn, visible cache settings | PENDING |

Rows without current live evidence remain `PARTIAL`; one sibling quant or
architecture never proves another.
