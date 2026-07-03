# Eval Matrix

- Generated: 2026-07-03T21:37:18.141Z

| Domain | gemma-4-12B-it-MXFP8 | gemma-4-E4B-it-4bit | grok-4.3 |
| --- | --- | --- | --- |
| agent_loop | 62/75 (skip 17) | 75/92 | 85/92 |
| apple_script | 24/26 | 27/35 | 30/35 |
| argument_coercion | — | 11/11 | — |
| capability_claims | 10/11 | 9/11 | 11/11 |
| capability_search | — | 15/16 (skip 2) | — |
| computer_use | — | 21/21 | — |
| computer_use_loop | 23/23 | 22/23 | 22/23 |
| default_agent | 37/38 | 13/38 | 38/38 |
| judge_calibration | — | 11/11 | — |
| micro_perf | 3/3 | 3/3 | 3/3 |
| prefix_hash | — | 9/9 | — |
| request_validation | — | 9/9 | — |
| sandbox_diagnostics | — | 12/12 | — |
| schema | — | 11/11 | — |
| screen_context | — | 22/22 | — |
| streaming_hint | — | 9/9 | — |
| subagent | 40/41 (skip 6) | 45/45 (skip 2) | — |
| tool_envelope | — | 10/10 | — |
| **total** | **199/217** | **334/388** | **189/202** |

## Performance

| Metric | gemma-4-12B-it-MXFP8 | gemma-4-E4B-it-4bit | grok-4.3 |
| --- | --- | --- | --- |
| decode tok/s (mean) | 14.1 | 23.7 | 22.4 |
| TTFT ms (mean) | 77 | 37 | 725 |
| peak RAM MB | 20450 | 20519 | 19595 |
| CPU % (mean) | 66 | 83 | 21 |
| CPU % (peak) | 519 | 526 | 289 |
| ctx tok/task (mean) | 22620 | 19836 | 31234 |
| total tok/task (mean) | 20112 | 17237 | 26521 |

## Comparability

- ⚠ columns graded DIFFERENT case catalogs (gemma-4-12B-it-MXFP8=137408f3cdba4838, gemma-4-E4B-it-4bit=2598627c7daaaba7, grok-4.3=137408f3cdba4838) — totals mix denominators; only same-catalog columns compare 1:1
- ⚠ self-judged column(s): gemma-4-12B-it-MXFP8, grok-4.3 — LLM-rubric rows were graded by the run model itself (weaker grade)

## Environment

- `gemma-4-12B-it-MXFP8` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=137408f3cdba4838 · thermal=fair
- `gemma-4-E4B-it-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=2598627c7daaaba7
- `grok-4.3` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=137408f3cdba4838 · thermal=fair
