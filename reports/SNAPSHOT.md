# Eval Matrix

- Generated: 2026-07-04T01:38:41.320Z

| Domain | gemma-4-12B-it-MXFP8 | gemma-4-E4B-it-4bit | foundation | grok-4.3 |
| --- | --- | --- | --- | --- |
| agent_loop | 73/92 | 77/92 | — | 87/92 |
| apple_script | 28/35 | 27/35 | — | 30/35 |
| argument_coercion | — | 11/11 | — | — |
| capability_claims | 10/11 | 9/11 | — | 11/11 |
| capability_search | — | 15/16 (skip 2) | — | — |
| computer_use | — | 21/21 | — | — |
| computer_use_loop | 23/23 | 22/23 | — | 22/23 |
| default_agent | 37/38 | 13/38 | — | 38/38 |
| judge_calibration | — | — | 11/11 | — |
| micro_perf | 3/3 | 3/3 | — | 3/3 |
| prefix_hash | — | 9/9 | — | — |
| request_validation | — | 9/9 | — | — |
| sandbox_diagnostics | — | 12/12 | — | — |
| schema | — | 11/11 | — | — |
| screen_context | — | 22/22 | — | — |
| streaming_hint | — | 9/9 | — | — |
| subagent | 47/47 | 47/47 | — | 47/47 |
| tool_envelope | — | 10/10 | — | — |
| **total** | **221/249** | **327/379** | **11/11** | **238/249** |

## Performance

| Metric | gemma-4-12B-it-MXFP8 | gemma-4-E4B-it-4bit | foundation | grok-4.3 |
| --- | --- | --- | --- | --- |
| decode tok/s (mean) | 15.0 | 23.8 | — | 22.4 |
| TTFT ms (mean) | 80 | 37 | — | 729 |
| peak RAM MB | 19666 | 20519 | — | 36579 |
| CPU % (mean) | 62 | 83 | — | 31 |
| CPU % (peak) | 523 | 526 | — | 532 |
| ctx tok/task (mean) | 23717 | 19834 | — | 31260 |
| total tok/task (mean) | 20519 | 17234 | — | 26543 |

## Comparability

- ⚠ columns graded DIFFERENT case catalogs (gemma-4-12B-it-MXFP8=137408f3cdba4838, gemma-4-E4B-it-4bit=2598627c7daaaba7, foundation=47bc36714bbf8db1, grok-4.3=137408f3cdba4838) — totals mix denominators; only same-catalog columns compare 1:1
- ⚠ self-judged column(s): grok-4.3 — LLM-rubric rows were graded by the run model itself (weaker grade)

## Environment

- `gemma-4-12B-it-MXFP8` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=137408f3cdba4838 · thermal=fair
- `gemma-4-E4B-it-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=2598627c7daaaba7
- `foundation` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=47bc36714bbf8db1
- `grok-4.3` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=137408f3cdba4838 · thermal=fair
