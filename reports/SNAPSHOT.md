# Eval Matrix

- Generated: 2026-07-06T02:31:41.562Z

| Domain | Ornith-1.0-9B-MXFP4 | gemma-4-E4B-it-4bit | foundation | Qwen3-4B-4bit | Qwen3.5-4B-OptiQ-4bit | grok-4.3 |
| --- | --- | --- | --- | --- | --- | --- |
| agent_loop | 66/92 (skip 3) | 73/92 (skip 3) | — | 66/92 (skip 3) | 83/92 (skip 3) | 89/92 (skip 3) |
| apple_script | 27/35 | 24/33 (skip 2) | — | 29/34 (skip 1) | 29/35 | 26/35 |
| argument_coercion | — | — | 11/11 | — | — | — |
| capability_claims | 10/11 | 9/11 | — | 10/11 | 8/11 | 11/11 |
| capability_search | — | — | 15/16 (skip 2) | — | — | — |
| computer_use | — | — | 21/21 | — | — | — |
| computer_use_loop | 13/23 | 21/23 | — | 21/23 | 15/23 | 22/23 |
| default_agent | 26/38 | 13/38 | — | 24/38 | 31/38 | 34/38 |
| micro_perf | 3/3 | 3/3 | — | 3/3 | 3/3 | 3/3 |
| prefix_hash | — | — | 9/9 | — | — | — |
| request_validation | — | — | 9/9 | — | — | — |
| sandbox_diagnostics | — | — | 12/12 | — | — | — |
| schema | — | — | 11/11 | — | — | — |
| screen_context | — | — | 21/22 | — | — | — |
| streaming_hint | — | — | 9/9 | — | — | — |
| subagent | 43/45 (skip 2) | 45/45 (skip 2) | — | 45/45 (skip 2) | 43/45 (skip 2) | 43/45 (skip 2) |
| tool_envelope | — | — | 10/10 | — | — | — |
| **total** | **188/247** | **188/245** | **128/130** | **198/246** | **212/247** | **228/247** |
| **chat-model** | 177/228 | 180/228 | 128/130 | 185/228 | 199/228 | 218/228 |
| **subsystem** | 11/19 | 8/17 | 0/0 | 13/18 | 13/19 | 10/19 |

## Performance

| Metric | Ornith-1.0-9B-MXFP4 | gemma-4-E4B-it-4bit | foundation | Qwen3-4B-4bit | Qwen3.5-4B-OptiQ-4bit | grok-4.3 |
| --- | --- | --- | --- | --- | --- | --- |
| decode tok/s (mean) | 22.8 | 21.4 | — | 53.1 | 34.9 | 10.3 |
| TTFT ms (mean) | 134 | 39 | — | 124 | 134 | 676 |
| peak RAM MB | 20614 | 19798 | 140 | 20583 | 20487 | 19637 |
| CPU % (mean) | 71 | 78 | 105 | 68 | 72 | 33 |
| CPU % (peak) | 513 | 512 | — | 529 | 520 | 517 |
| ctx tok/task (mean) | 23137 | 21356 | — | 21935 | 22317 | 32287 |
| total tok/task (mean) | 20617 | 18903 | — | 19186 | 19335 | 27458 |

## Comparability

- ⚠ columns graded DIFFERENT case catalogs (Ornith-1.0-9B-MXFP4=137408f3cdba4838, gemma-4-E4B-it-4bit=137408f3cdba4838, foundation=2598627c7daaaba7, Qwen3-4B-4bit=137408f3cdba4838, Qwen3.5-4B-OptiQ-4bit=137408f3cdba4838, grok-4.3=137408f3cdba4838) — totals mix denominators; only same-catalog columns compare 1:1
- ⚠ self-judged column(s): grok-4.3 — LLM-rubric rows were graded by the run model itself (weaker grade)

## Environment

- `Ornith-1.0-9B-MXFP4` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=137408f3cdba4838 · thermal=fair
- `gemma-4-E4B-it-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=137408f3cdba4838 · thermal=fair
- `foundation` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=2598627c7daaaba7
- `Qwen3-4B-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=137408f3cdba4838 · thermal=fair
- `Qwen3.5-4B-OptiQ-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=137408f3cdba4838 · thermal=fair
- `grok-4.3` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=137408f3cdba4838 · thermal=fair
