# Agent Loop Regression Lab

- Verdict: REGRESSED: 1 regression(s), 1 new failing case(s)
- Generated: 2026-06-18T12:00:00Z
- Baseline: fixture baseline (foundation, 2026-06-17T00:00:00Z)
- Current: fixture current (foundation, 2026-06-18T00:00:00Z)

## Totals

| Bucket | Baseline | Current |
| --- | ---: | ---: |
| total | 5 | 6 |
| passed | 3 | 3 |
| failed | 2 | 2 |
| errored | 0 | 1 |
| skipped | 0 | 0 |

## Blocking Regressions

| Case | Baseline | Current | Latency | Tools | Notes |
| --- | --- | --- | ---: | ---: | --- |
| agent_loop.search-then-multi-file-edit | passed | failed | +200ms | calls -2, errors +1 | command exit mismatch: grep fetchDataV1 exited 0 / finalText missing 'updated imports' |

## New Failing Cases

| Case | Baseline | Current | Latency | Tools | Notes |
| --- | --- | --- | ---: | ---: | --- |
| agent_loop.write-new-file | missing | errored | - | - | agent loop error: tool schema unavailable |

## Fixed Cases

| Case | Baseline | Current | Latency | Tools | Notes |
| --- | --- | --- | ---: | ---: | --- |
| agent_loop.compaction-stress | failed | passed | -500ms | calls +0, errors +0 | finalText missing 'log4' |

## Persistent Failures

| Case | Baseline | Current | Latency | Tools | Notes |
| --- | --- | --- | ---: | ---: | --- |
| agent_loop.legacy-case | failed | failed | +300ms | calls +0, errors +0 | still fails: stale summary |

## Suite Drift

| Case | Baseline | Current | Latency | Tools | Notes |
| --- | --- | --- | ---: | ---: | --- |
| agent_loop.new-stable | missing | passed | - | - | - |
| agent_loop.removed-case | passed | missing | - | - | - |
