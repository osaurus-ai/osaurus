# Eval Matrix

- Generated: 2026-07-03T09:17:27.701Z

| Domain | gemma-4-12B-it-MXFP8 | foundation |
| --- | --- | --- |
| agent_loop | 62/75 (skip 17) | — |
| apple_script | 24/26 | — |
| argument_coercion | — | 11/11 |
| capability_claims | 10/11 | — |
| capability_search | — | 15/16 (skip 2) |
| computer_use | — | 21/21 |
| computer_use_loop | 23/23 | — |
| default_agent | 37/38 | — |
| judge_calibration | 11/11 | — |
| micro_perf | 3/3 | — |
| prefix_hash | — | 9/9 |
| request_validation | — | 9/9 |
| sandbox_diagnostics | — | 12/12 |
| schema | — | 11/11 |
| screen_context | — | 22/22 |
| streaming_hint | — | 9/9 |
| subagent | 40/41 (skip 6) | — |
| tool_envelope | — | 10/10 |
| **total** | **210/228** | **129/130** |

## Performance

| Metric | gemma-4-12B-it-MXFP8 | foundation |
| --- | --- | --- |
| decode tok/s (mean) | 14.1 | — |
| TTFT ms (mean) | 77 | — |
| peak RAM MB | 20450 | 141 |
| CPU % (mean) | 66 | 105 |
| CPU % (peak) | 519 | — |
| ctx tok/task (mean) | 22620 | — |
| total tok/task (mean) | 20112 | — |

## Comparability

- ⚠ columns graded DIFFERENT case catalogs (gemma-4-12B-it-MXFP8=47bc36714bbf8db1, foundation=2598627c7daaaba7) — totals mix denominators; only same-catalog columns compare 1:1
- ⚠ self-judged column(s): gemma-4-12B-it-MXFP8, foundation — LLM-rubric rows were graded by the run model itself (weaker grade)

## Environment

- `gemma-4-12B-it-MXFP8` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=47bc36714bbf8db1
- `foundation` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=2598627c7daaaba7
