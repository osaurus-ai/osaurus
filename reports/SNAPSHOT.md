# Eval Matrix

- Generated: 2026-07-04T06:45:20.841Z

| Domain | gemma-4-12B-it-MXFP8 | gemma-4-E4B-it-4bit | foundation | grok-4.3 |
| --- | --- | --- | --- | --- |
| agent_loop | 79/92 (skip 3) | — | — | 90/92 (skip 3) |
| apple_script | 28/35 | — | — | 30/35 |
| argument_coercion | — | — | 11/11 | — |
| capability_claims | 10/11 | — | — | 11/11 |
| capability_search | — | — | 15/16 (skip 2) | — |
| computer_use | — | — | 21/21 | — |
| computer_use_loop | 23/23 | — | — | 21/23 |
| default_agent | 37/38 | — | — | 38/38 |
| judge_calibration | — | 11/11 | — | — |
| micro_perf | 3/3 | — | — | 3/3 |
| prefix_hash | — | — | 9/9 | — |
| request_validation | — | — | 9/9 | — |
| sandbox_diagnostics | — | — | 12/12 | — |
| schema | — | — | 11/11 | — |
| screen_context | — | — | 22/22 | — |
| streaming_hint | — | — | 9/9 | — |
| subagent | 43/45 (skip 2) | — | — | 45/45 (skip 2) |
| tool_envelope | — | — | 10/10 | — |
| **total** | **223/247** | **11/11** | **129/130** | **238/247** |
| **chat-model** | 211/228 | 11/11 | 129/130 | 224/228 |
| **subsystem** | 12/19 | 0/0 | 0/0 | 14/19 |

## Performance

| Metric | gemma-4-12B-it-MXFP8 | gemma-4-E4B-it-4bit | foundation | grok-4.3 |
| --- | --- | --- | --- | --- |
| decode tok/s (mean) | 13.5 | — | — | 8.2 |
| TTFT ms (mean) | 87 | — | — | 704 |
| peak RAM MB | 20536 | — | 157 | 19823 |
| CPU % (mean) | 67 | — | 106 | 30 |
| CPU % (peak) | 525 | — | — | 506 |
| ctx tok/task (mean) | 25350 | — | — | 32182 |
| total tok/task (mean) | 21929 | — | — | 27332 |

## Comparability

- ⚠ columns graded DIFFERENT case catalogs (gemma-4-12B-it-MXFP8=137408f3cdba4838, gemma-4-E4B-it-4bit=47bc36714bbf8db1, foundation=2598627c7daaaba7, grok-4.3=137408f3cdba4838) — totals mix denominators; only same-catalog columns compare 1:1
- ⚠ self-judged column(s): grok-4.3 — LLM-rubric rows were graded by the run model itself (weaker grade)

## Environment

- `gemma-4-12B-it-MXFP8` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=137408f3cdba4838 · thermal=fair
- `gemma-4-E4B-it-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=47bc36714bbf8db1
- `foundation` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=2598627c7daaaba7
- `grok-4.3` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=137408f3cdba4838 · thermal=fair
