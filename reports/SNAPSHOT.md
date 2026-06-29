# Eval Matrix

- Generated: 2026-06-28T13:44:20.390Z

| Domain | foundation | Qwen3.5-4B-OptiQ-4bit | grok-4.3 |
| --- | --- | --- | --- |
| agent_loop | 0/0 (skip 88) | 58/70 (skip 18) | 64/67 (skip 18) (err 3) |
| argument_coercion | — | 11/11 | — |
| capability_claims | 2/11 | 9/11 | 11/11 |
| capability_search | 15/16 (skip 2) | — | — |
| computer_use | — | 21/21 | — |
| computer_use_loop | 7/7 (skip 15) | 14/22 | 22/22 |
| default_agent | 1/10 (skip 27) (err 1) | 31/38 | 25/38 |
| prefix_hash | — | 9/9 | — |
| request_validation | — | 9/9 | — |
| sandbox_diagnostics | — | 12/12 | — |
| schema | — | 11/11 | — |
| screen_context | — | 21/22 | — |
| streaming_hint | — | 9/9 | — |
| subagent | 20/20 (skip 6) | 21/22 (skip 4) | 22/22 (skip 4) |
| tool_envelope | — | 10/10 | — |
| **total** | **45/64** | **246/277** | **144/160** |

## Performance

| Metric | foundation | Qwen3.5-4B-OptiQ-4bit | grok-4.3 |
| --- | --- | --- | --- |
| decode tok/s (mean) | — | 45.6 | — |
| TTFT ms (mean) | — | 128 | 929 |
| peak RAM MB | 140 | 7869 | 25969 |
| CPU % (mean) | 128 | 70 | 37 |
| CPU % (peak) | 17 | 426 | 404 |
| ctx tok/task (mean) | — | 28106 | 24197 |
| total tok/task (mean) | — | 28577 | 24383 |

## Environment

- `foundation` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=41cd9ca379a603a2
- `Qwen3.5-4B-OptiQ-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=2598627c7daaaba7
- `grok-4.3` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=137408f3cdba4838
