# Eval Matrix

- Generated: 2026-06-20T00:12:24.986Z

| Domain | foundation | Qwen3-4B-4bit | grok-4.3 |
| --- | --- | --- | --- |
| agent_loop | 0/0 (skip 58) | 27/45 (skip 13) | 43/45 (skip 13) |
| argument_coercion | — | 6/6 | — |
| capability_claims | 0/6 (skip 2) | 4/8 | 5/8 |
| capability_search | 10/11 (skip 2) | — | — |
| computer_use | — | 16/16 | — |
| computer_use_loop | 5/5 (skip 11) | 14/16 | 14/16 |
| prefix_hash | — | 4/4 | — |
| request_validation | — | 4/4 | — |
| sandbox_diagnostics | — | 8/8 | — |
| schema | — | 5/5 | — |
| streaming_hint | — | 4/4 | — |
| tool_envelope | — | 5/5 | — |
| **total** | **15/22** | **97/121** | **62/69** |

## Performance

| Metric | foundation | Qwen3-4B-4bit | grok-4.3 |
| --- | --- | --- | --- |
| decode tok/s (mean) | — | 60.4 | — |
| TTFT ms (mean) | — | 179 | 570 |
| peak RAM MB | 141 | 10712 | 142 |
