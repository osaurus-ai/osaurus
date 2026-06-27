# Eval Matrix

- Generated: 2026-06-27T22:17:38.296Z

| Domain | foundation | Qwen3.5-4B-OptiQ-4bit | grok-4.3 |
| --- | --- | --- | --- |
| computer_use_loop | 5/5 (skip 11) | 10/16 | 16/16 |
| subagent | 15/15 (skip 5) | 17/17 (skip 3) | 17/17 (skip 3) |
| **total** | **20/20** | **27/33** | **33/33** |

## Performance

| Metric | foundation | Qwen3.5-4B-OptiQ-4bit | grok-4.3 |
| --- | --- | --- | --- |
| decode tok/s (mean) | — | — | — |
| TTFT ms (mean) | — | — | — |
| peak RAM MB | 16 | 3305 | 3395 |
| CPU % (mean) | 106 | 100 | 77 |
| CPU % (peak) | 13 | 274 | 375 |
| ctx tok/task (mean) | — | — | — |
| total tok/task (mean) | — | — | — |

## Environment

- `foundation` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=27b38f6092df0fe3
- `Qwen3.5-4B-OptiQ-4bit` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=xai/grok-4.3 · catalog=27b38f6092df0fe3
- `grok-4.3` — Apple M4 Pro · 48GB · macOS 26.2.0 · judge=self-judge · catalog=27b38f6092df0fe3
