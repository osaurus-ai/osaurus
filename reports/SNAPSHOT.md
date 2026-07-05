# Eval Matrix

- Generated: 2026-07-05T22:57:01.018Z

| Domain | Ornith-1.0-9B-MXFP4 | gemma-4-E4B-it-4bit | foundation | grok-4.3 |
| --- | --- | --- | --- | --- |
| agent_loop | 66/92 (skip 3) | — | — | 89/92 (skip 3) |
| apple_script | 27/35 | — | — | 26/35 |
| argument_coercion | — | — | 11/11 | — |
| capability_claims | 10/11 | — | — | 11/11 |
| capability_search | — | — | 15/16 (skip 2) | — |
| computer_use | — | — | 21/21 | — |
| computer_use_loop | 13/23 | — | — | 22/23 |
| default_agent | 26/38 | — | — | 34/38 |
| judge_calibration | — | 11/11 | — | — |
| micro_perf | 3/3 | — | — | 3/3 |
| prefix_hash | — | — | 9/9 | — |
| request_validation | — | — | 9/9 | — |
| sandbox_diagnostics | — | — | 12/12 | — |
| schema | — | — | 11/11 | — |
| screen_context | — | — | 21/22 | — |
| streaming_hint | — | — | 9/9 | — |
| subagent | 43/45 (skip 2) | — | — | 43/45 (skip 2) |
| tool_envelope | — | — | 10/10 | — |
| **total** | **188/247** | **11/11** | **128/130** | **228/247** |
| **chat-model** | 177/228 | 11/11 | 128/130 | 218/228 |
| **subsystem** | 11/19 | 0/0 | 0/0 | 10/19 |

## Performance

| Metric | Ornith-1.0-9B-MXFP4 | gemma-4-E4B-it-4bit | foundation | grok-4.3 |
| --- | --- | --- | --- | --- |
| decode tok/s (mean) | 22.8 | — | — | 10.3 |
| TTFT ms (mean) | 134 | — | — | 676 |
| peak RAM MB | 20614 | — | 140 | 19637 |
| CPU % (mean) | 71 | — | 103 | 33 |
| CPU % (peak) | 513 | — | — | 517 |
| ctx tok/task (mean) | 23137 | — | — | 32287 |
| total tok/task (mean) | 20617 | — | — | 27458 |

## Comparability

- ⚠ columns graded DIFFERENT case catalogs (Ornith-1.0-9B-MXFP4=137408f3cdba4838, gemma-4-E4B-it-4bit=47bc36714bbf8db1, foundation=2598627c7daaaba7, grok-4.3=137408f3cdba4838) — totals mix denominators; only same-catalog columns compare 1:1
- ⚠ self-judged column(s): grok-4.3 — LLM-rubric rows were graded by the run model itself (weaker grade)

## Environment

- `Ornith-1.0-9B-MXFP4` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=137408f3cdba4838 · thermal=fair
- `gemma-4-E4B-it-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=47bc36714bbf8db1
- `foundation` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=2598627c7daaaba7
- `grok-4.3` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=137408f3cdba4838 · thermal=fair
