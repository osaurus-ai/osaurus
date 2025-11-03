## OpenAI Chat Completions Streaming Compatibility
- **Server**: http://localhost:1337
- **Model**: 
`foundation`

### Results
| Area | Status | Notes |
|---|---:|---|
| Text generation (SSE) | ✅ | Headers, SSE framing, role, finish_reason=stop |
| Tool calling (SSE deltas) | ✅ | id/name/arguments; finish_reason=tool_calls |

### Artifacts
- `results/text_stream_headers.txt`, `results/text_stream_raw.txt`, `results/text_stream_chunks.jsonl`
- `results/tool_stream_headers.txt`, `results/tool_stream_raw.txt`, `results/tool_stream_chunks.jsonl`
