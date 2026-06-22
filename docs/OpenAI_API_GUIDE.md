# API Endpoints Guide

This guide explains how to use the API endpoints in Osaurus, including OpenAI-compatible, Anthropic-compatible, and Open Responses formats.

## Available Endpoints

### 1. List Models - `GET /models` (also available at `GET /v1/models`)

Returns a list of available models that are currently downloaded and ready to use.

```bash
curl http://127.0.0.1:1337/models
```

Example response:

```json
{
  "object": "list",
  "data": [
    {
      "id": "llama-3.2-3b-instruct",
      "object": "model",
      "created": 1738193123,
      "owned_by": "osaurus"
    },
    {
      "id": "qwen2.5-7b-instruct",
      "object": "model",
      "created": 1738193123,
      "owned_by": "osaurus"
    }
  ]
}
```

### 2. Chat Completions - `POST /chat/completions` (also available at `POST /v1/chat/completions`)

Generate chat completions using the specified model.

> **Tool calling:** `/chat/completions` follows **strict OpenAI semantics** — when the model emits `tool_calls`, the response (or final SSE chunk) returns those calls and the **client is expected to execute them and POST the results back** in the next request. Osaurus deliberately does **not** auto-execute tools on this endpoint so it can serve as a drop-in backend for harnesses that already manage their own tool loop.
>
> If you want server-side autonomous loops, use `POST /agents/{id}/run` (it executes tools, manages iteration budget, and streams hint/done frames). If you want to expose Osaurus tools to a remote model harness, use the MCP endpoints (`GET /mcp/tools`, `POST /mcp/call`).

#### Non-streaming Request

```bash
curl http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello, how are you?"}
    ],
    "session_id": "my-session-1",
    // Optional: groups history + session tool state across turns
    // (KV cache reuse is automatic and content-addressed)
    "temperature": 0.7,
    "max_tokens": 150
  }'
```

Example response:

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1738193123,
  "model": "llama-3.2-3b-instruct",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "I'm doing well, thank you for asking! How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 20,
    "completion_tokens": 15,
    "total_tokens": 35
  }
}
```

#### Streaming Request

```bash
curl http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "messages": [
      {"role": "user", "content": "Tell me a short story"}
    ],
    "stream": true,
    "temperature": 0.8,
    "max_tokens": 200
  }'
```

Streaming responses use Server-Sent Events (SSE) format:

```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1738193123,"model":"llama-3.2-3b-instruct","choices":[{"index":0,"delta":{"content":"Once"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1738193123,"model":"llama-3.2-3b-instruct","choices":[{"index":0,"delta":{"content":" upon"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1738193123,"model":"llama-3.2-3b-instruct","choices":[{"index":0,"delta":{"content":" a"},"finish_reason":null}]}

data: [DONE]
```

### Function/Tool Calling

Osaurus implements OpenAI‑compatible function calling via the `tools` array and optional `tool_choice` in the request. Local model templates receive the active tool schema; a named `tool_choice` narrows that schema to the requested function instead of adding a generic prompt directive. The server parses assistant outputs for top-level `tool_calls`, tolerating minor formatting (e.g., code fences).

Supported tool type: `function`.

Request with tools (non‑stream):

```bash
curl http://localhost:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "messages": [
      {"role": "user", "content": "Weather in SF?"}
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get weather by city name",
          "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"]
          }
        }
      }
    ],
    "tool_choice": "auto"
  }'
```

Example non‑streaming response (simplified):

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1738193123,
  "model": "llama-3.2-3b-instruct",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "",
        "tool_calls": [
          {
            "id": "call_1",
            "type": "function",
            "function": {
              "name": "get_weather",
              "arguments": "{\"city\":\"SF\"}"
            }
          }
        ]
      },
      "finish_reason": "tool_calls"
    }
  ]
}
```

Streaming with tool calls: Osaurus emits OpenAI‑style deltas. First a role delta, then for each tool call: an id/type delta, a function name delta, and one or more argument deltas (chunked). The final chunk has `finish_reason: "tool_calls"`, followed by `[DONE]`.

```
data: {"id":"chatcmpl-xyz","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"}}]}

data: {"id":"chatcmpl-xyz","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function"}]}}]}

data: {"id":"chatcmpl-xyz","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"get_weather"}}]}}]}

data: {"id":"chatcmpl-xyz","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":\"SF\"}"}}]}}]}

data: {"id":"chatcmpl-xyz","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]
```

Tool execution loop: After receiving tool calls, execute them client‑side and continue the conversation by sending the tool results as `role: tool` messages with the corresponding `tool_call_id`.

```python
import json
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:1337/v1", api_key="osaurus")

tools = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        }
    }
}]

resp = client.chat.completions.create(
    model="llama-3.2-3b-instruct",
    messages=[{"role": "user", "content": "Weather in SF?"}],
    tools=tools,
    tool_choice="auto",
)

tool_calls = resp.choices[0].message.tool_calls or []
for call in tool_calls:
    args = json.loads(call.function.arguments)
    # Execute your function
    result = {"tempC": 18, "conditions": "Foggy"}
    followup = client.chat.completions.create(
        model="llama-3.2-3b-instruct",
        messages=[
            {"role": "user", "content": "Weather in SF?"},
            {"role": "assistant", "content": "", "tool_calls": tool_calls},
            {"role": "tool", "tool_call_id": call.id, "content": json.dumps(result)}
        ]
    )
    print(f"Answer: {followup.choices[0].message.content}")
```

Notes and limitations:

1. Only `function` tools are supported.
2. Assistant must return arguments as a JSON‑escaped string. The server also tolerates a nested `parameters` object and normalizes it.
3. The parser accepts common wrappers like code fences and an `assistant:` prefix.
4. `tool_choice` supports `"auto"`, `"none"`, and a specific function target object.
5. **Strict OpenAI semantics**: `/chat/completions` returns the model's `tool_calls` and stops — it does not execute them server-side. The client must run the tools and POST the results back in the next request. For autonomous server-side tool loops, use `POST /agents/{id}/run` instead.

### Server-side autonomous tool loops: `POST /agents/{id}/run`

When you want Osaurus to execute tools on your behalf (manage the iteration budget, stream tool-execution hints, and only return when the model is done), use the agent run endpoint. This is the path the in-app chat UI uses.

- Each pending `tool_call` is executed against the registered `ToolRegistry` (sandbox, folder, MCP, plugin tools — everything the agent has access to).
- Independent tool calls within a single model turn run **in parallel**.
- The loop is capped at 30 iterations; if the budget is exhausted while still requesting tools, a notice is appended to the stream so the client sees a clear reason rather than a silent stop.
- Honors client-supplied `tools` (merged with the agent's always-loaded set) and `tool_choice` (defaults to `"auto"` when tools are present).
- **Authenticated remote callers** (Osaurus [Secure Channel](SECURE_CHANNEL.md), agent-scoped) that drive an agent whose owner granted a **host workspace folder** also get host file tools (`file_read` / `file_write` / `file_edit`) confined to that folder. `shell_run` / `git_commit` / `file_undo` stay denied (see the deny list below), and loopback callers never mount it.

### Aggregating Osaurus tools through MCP

The Model Context Protocol endpoints let any MCP-aware harness connect and discover Osaurus tools without committing to the agent endpoint:

- `GET /mcp/tools` — list registered tools as MCP `Tool` definitions
- `POST /mcp/call` — invoke a tool by name with structured arguments

Combine `/chat/completions` (your harness's own tool loop) with `/mcp/tools` + `/mcp/call` (Osaurus tool surface) to keep both sides authoritative.

#### External surface deny list

Folder write and shell tools are **denied to external surfaces by default** — neither `/mcp/call` nor the `/agents/{id}/run` loop will execute `file_write`, `file_edit`, `file_undo`, `shell_run`, or `git_commit`, even while a working folder is open in the app and those tools are registered process-wide. `/mcp/call` returns `403` with `{"error": "tool_not_exposable"}`, the agent loop hands the model a structured `rejected` envelope, and the denied names are hidden from `GET /mcp/tools` listings. Rationale: loopback connections skip Bearer auth, so an external caller could otherwise rewrite the user's files or run arbitrary shell commands through the open folder session. Write access from outside the app otherwise goes through the sandbox (`sandbox_*` tools on sandboxed agents), which is isolated by construction.

**One narrow exception — per-agent host workspace.** When an **authenticated remote** caller (Osaurus [Secure Channel](SECURE_CHANNEL.md), agent-scoped key — never loopback, plaintext, `/mcp/call`, or a cross-agent key) drives an agent whose owner granted a **host workspace folder** (Agent → Configure → Features → Host Files), the `/agents/{id}/run` loop may execute `file_write` and `file_edit`, confined to that folder by the folder tools' own root. `file_read` is always permitted; `shell_run`, `git_commit`, and `file_undo` stay denied even then. The folder root is bound (as a task-local) only after the secure-transport, built-in, and agent-scope gates pass, so the relaxation is unreachable from any untrusted surface.

### Session Grouping (`session_id`)

Provide a `session_id` to group requests into one logical conversation. It is **not** a cache key — KV cache reuse is automatic and content-addressed (see the next section). What `session_id` does control:

- Persisted conversation history for agent-backed requests.
- Per-session tool state: the system-prompt prefix (manifest, SOUL, always-loaded tool names) is frozen on the first compose for a session, and tools loaded mid-session via `capabilities_load` are re-included on later requests with the same `session_id`. This keeps the prompt prefix byte-stable, which is what lets the content-addressed cache hit.

Example follow-up turn using the same `session_id`:

```bash
curl http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "session_id": "my-session-1",
    "messages": [
      {"role": "user", "content": "And one more detail, please."}
    ]
  }'
```

Keep `session_id` stable per conversation and per model. Omitting it never disables KV reuse — identical prompt prefixes still share cached blocks — but session tool bookkeeping (frozen prefix, `capabilities_load` persistence) won't apply.

### Prefix Caching and `prefix_hash`

KV cache reuse across requests is **automatic and content-addressed** — Osaurus delegates prefix cache management to vmlx-swift's `CacheCoordinator`. Two requests that share the same prefix tokens (system prompt, tools, prior turns) automatically share the cached KV blocks. There is no client-side opt-in or cache key to manage.

For visibility, every response carries a `prefix_hash` field — a stable hash of the system prompt + canonical tool schemas that produced this generation. Clients can use it to detect when the system prefix changed across requests:

```json
{ "prefix_hash": "a1b2c3d4e5f67890..." }
```

`prefix_hash` is informational only — passing it back to the server has no effect. Keep `session_id` stable per conversation so chat history and session tool bookkeeping group correctly; cache reuse itself does not depend on it.

### Chat Templates

Osaurus defers chat templating to MLX `ChatSession`, which uses the model's configuration to format prompts. System messages are combined and passed as `instructions`; user content is supplied as the prompt to `respond/streamResponse`.

## Model Naming

Models are automatically named based on their display names in ModelManager. The API converts the model names to lowercase and replaces spaces with hyphens. For example:

| Downloaded Model                 | API Model Name                     |
| -------------------------------- | ---------------------------------- |
| Gemma 4 E2B it 4bit              | gemma-4-e2b-it-4bit                |
| Gemma 4 E4B it 4bit              | gemma-4-e4b-it-4bit                |
| Gemma 4 26B A4B it JANG 2L       | gemma-4-26b-a4b-it-jang_2l         |
| Gemma 4 31B it JANG 4M           | gemma-4-31b-it-jang_4m             |
| Qwen3.5 35B A3B JANG 2S          | qwen3.5-35b-a3b-jang_2s            |
| Qwen3.5 122B A10B JANG 4K        | qwen3.5-122b-a10b-jang_4k          |
| gpt oss 20b MLX 8bit             | gpt-oss-20b-mlx-8bit               |

## Usage with OpenAI Python Library

You can use the official OpenAI Python library with Osaurus:

```python
from openai import OpenAI

# Point to your local Osaurus server
client = OpenAI(
    base_url="http://127.0.0.1:1337/v1",  # Use /v1 for OpenAI client compatibility
    # Local-only loopback accepts a placeholder. Use a real Settings access key
    # when network exposure or relay access is enabled.
    api_key="osaurus-local"
)

# List available models
models = client.models.list()
for model in models.data:
    print(model.id)

# Create a chat completion
response = client.chat.completions.create(
    model="llama-3.2-3b-instruct",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "What is the capital of France?"}
    ],
    temperature=0.7,
    max_tokens=100
)

print(response.choices[0].message.content)

# Stream a response
stream = client.chat.completions.create(
    model="llama-3.2-3b-instruct",
    messages=[
        {"role": "user", "content": "Write a haiku about coding"}
    ],
    stream=True
)

for chunk in stream:
    if chunk.choices[0].delta.content is not None:
        print(chunk.choices[0].delta.content, end="")
```

## Open Responses API

Osaurus supports the [Open Responses](https://www.openresponses.org) specification, providing a semantic, item-based API format for multi-provider interoperability.

### 3. Responses - `POST /responses` (also available at `POST /v1/responses`)

Generate responses using the Open Responses format.

#### Non-streaming Request

```bash
curl http://127.0.0.1:1337/v1/responses \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "input": "Hello, how are you?",
    "instructions": "You are a helpful assistant."
  }'
```

Example response:

```json
{
  "id": "resp_abc123",
  "object": "response",
  "created_at": 1738193123,
  "status": "completed",
  "model": "llama-3.2-3b-instruct",
  "output": [
    {
      "type": "message",
      "id": "item_xyz789",
      "status": "completed",
      "role": "assistant",
      "content": [
        {
          "type": "output_text",
          "text": "I'm doing well, thank you for asking! How can I help you today?"
        }
      ]
    }
  ],
  "usage": {
    "input_tokens": 20,
    "output_tokens": 15,
    "total_tokens": 35
  }
}
```

#### Streaming Request

```bash
curl http://127.0.0.1:1337/v1/responses \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "input": "Tell me a short story",
    "stream": true
  }'
```

Streaming responses use Server-Sent Events with semantic event types:

```
event: response.created
data: {"type":"response.created","sequence_number":1,"response":{...}}

event: response.in_progress
data: {"type":"response.in_progress","sequence_number":2,"response":{...}}

event: response.output_item.added
data: {"type":"response.output_item.added","sequence_number":3,"output_index":0,"item":{...}}

event: response.output_text.delta
data: {"type":"response.output_text.delta","sequence_number":4,"item_id":"item_xyz","delta":"Once"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","sequence_number":5,"item_id":"item_xyz","delta":" upon"}

event: response.output_text.done
data: {"type":"response.output_text.done","sequence_number":10,"item_id":"item_xyz","text":"Once upon a time..."}

event: response.output_item.done
data: {"type":"response.output_item.done","sequence_number":11,"output_index":0,"item":{...}}

event: response.completed
data: {"type":"response.completed","sequence_number":12,"response":{...}}

data: [DONE]
```

#### Structured Input

For multi-turn conversations, use structured input items:

```bash
curl http://127.0.0.1:1337/v1/responses \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "input": [
      {"type": "message", "role": "user", "content": "What is 2+2?"},
      {"type": "message", "role": "assistant", "content": "2+2 equals 4."},
      {"type": "message", "role": "user", "content": "And 3+3?"}
    ]
  }'
```

#### Tool Calling with Open Responses

```bash
curl http://127.0.0.1:1337/v1/responses \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "input": "What is the weather in San Francisco?",
    "tools": [
      {
        "type": "function",
        "name": "get_weather",
        "description": "Get weather by city name",
        "parameters": {
          "type": "object",
          "properties": {"city": {"type": "string"}},
          "required": ["city"]
        }
      }
    ]
  }'
```

Tool call response:

```json
{
  "id": "resp_abc123",
  "object": "response",
  "status": "completed",
  "output": [
    {
      "type": "function_call",
      "id": "item_xyz",
      "status": "completed",
      "call_id": "call_123",
      "name": "get_weather",
      "arguments": "{\"city\":\"San Francisco\"}"
    }
  ]
}
```

To continue after a tool call, include the function output:

```bash
curl http://127.0.0.1:1337/v1/responses \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct",
    "input": [
      {"type": "message", "role": "user", "content": "What is the weather in SF?"},
      {"type": "function_call_output", "call_id": "call_123", "output": "{\"temp\": 65, \"conditions\": \"Foggy\"}"}
    ]
  }'
```

### Open Responses Request Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `model` | string | Model identifier (required) |
| `input` | string or array | Input text or array of input items (required) |
| `stream` | boolean | Enable streaming (default: false) |
| `instructions` | string | System prompt |
| `tools` | array | Available tools/functions |
| `tool_choice` | string/object | Tool selection mode ("auto", "none", "required") |
| `temperature` | float | Sampling temperature |
| `max_output_tokens` | integer | Maximum tokens to generate |
| `top_p` | float | Top-p sampling parameter |

---

## Memory API

Osaurus provides a persistent memory system that can be used by the app chat and agent APIs. The v2 system distills sessions in the background, then composed agent context can include at most one compact memory section (~800 tokens by default) when the user's query actually needs it. See [docs/MEMORY.md](MEMORY.md) for the full architecture.

### Agent Context and `/chat/completions`

`POST /chat/completions` is a strict OpenAI-compatible inference endpoint. It does not inject Osaurus agent prompts, memory, skills, or tools into the request. Client-supplied `messages`, `tools`, and `tool_choice` are passed through as the server-side inference contract.

Use these surfaces when you want Osaurus-composed agent context:

- App chat windows: system prompt, memory, folder/sandbox context, selected skills, and tools are composed by the app before inference.
- `POST /agents/{id}/run`: runs a server-side autonomous agent loop with that agent's context and tool execution.
- Plugin host inference APIs: carry the plugin's active agent context by design.

`X-Osaurus-Agent-Id` on `/chat/completions` may still be used to associate persisted HTTP chat history with an agent/session, but it is not a prompt/context injection switch.

Strict pass-through example:

```bash
curl http://127.0.0.1:1337/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [
      {"role": "user", "content": "Answer using only these messages."}
    ]
  }'
```

With the OpenAI Python SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:1337/v1",
    api_key="osaurus",
)

response = client.chat.completions.create(
    model="your-model-name",
    messages=[{"role": "user", "content": "Answer using only these messages."}],
)
print(response.choices[0].message.content)
```

### Memory Ingestion — `POST /memory/ingest`

Bulk-ingest conversation turns. Osaurus inserts each turn into the transcript and then, unless `skip_extraction` is set, **distills synchronously and waits for the result** before responding: it forces an on-demand cold load of the core model if it isn't already resident, runs the single distillation LLM call, and reports the outcome. A cold load can take tens of seconds for a larger core model, so allow a long client timeout (the server applies no idle cutoff on this path). Distillation produces an episode and (when warranted) a small set of pinned facts.

```bash
curl http://127.0.0.1:1337/memory/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "my-agent",
    "conversation_id": "session-1",
    "turns": [
      {"user": "Hi, my name is Alice", "assistant": "Hello Alice! Nice to meet you."},
      {"user": "I work at Acme Corp", "assistant": "Got it, you work at Acme Corp."}
    ]
  }'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `agent_id` | string | Identifier for the agent whose memory is being populated (required). A UUID is canonicalized (uppercased) to match the agent's recall key. |
| `conversation_id` | string | Identifier for the conversation session (required) |
| `turns` | array | Array of turn objects, each with `user` and `assistant` string fields (required) |
| `session_date` | string | Optional ISO 8601 date for the whole batch (used as the episode timestamp) |
| `skip_extraction` | bool | When `true`, only insert transcript rows; skip distillation (and the synchronous wait) |

Response:

```json
{"status": "ok", "turns_ingested": 2, "distillation": "distilled", "episode_id": 42}
```

`distillation` is the outcome token (omitted when `skip_extraction` is set): `distilled`, `no_signals`, `skipped:<reason>`, `empty:<reason>`, `dead_letter:<attempts>`, or `error:<message>`. `episode_id` is present only when an episode was written. Re-ingesting the same `conversation_id` is idempotent (prior pending signals + episodes for that conversation are cleared first), so re-runs yield exactly one active episode instead of duplicates. See [docs/MEMORY.md](MEMORY.md#memory-ingestion--post-memoryingest) for the full outcome table.

### List Agents — `GET /agents`

Returns all configured agents along with their `memory_entry_count`. Use this to discover agent IDs for the `X-Osaurus-Agent-Id` header. The count reflects stored memory (distilled episodes + active pinned facts), so it is non-zero once an agent has any distilled sessions even when no pinned facts were promoted.

```bash
curl http://127.0.0.1:1337/agents
```

Example response:

```json
{
  "agents": [
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "name": "Osaurus",
      "description": "Default assistant",
      "default_model": null,
      "supports_vision": false,
      "is_built_in": true,
      "memory_entry_count": 42,
      "created_at": "2025-01-01T00:00:00Z",
      "updated_at": "2025-01-01T00:00:00Z"
    }
  ]
}
```

`supports_vision` reflects whether the agent's effective model is a VLM, so clients can show or hide image-attach UI without round-tripping the model registry.

---

## Notes

1. **Model Availability**: Only models that have been downloaded through the Osaurus UI will be available via the API.

2. **Performance**: The first request to a model loads it; subsequent requests skip this step. Concurrent same-model requests share a single forward pass via vmlx-swift's `BatchEngine` continuous batching. Multi-turn KV cache reuse is automatic and content-addressed via vmlx's `CacheCoordinator` — repeated prefixes (system prompt, tools, prior turns) are matched without any client opt-in. The `prefix_hash` response field is informational; `session_id` groups history but is not a cache key.

3. **Memory Management**: Models are loaded into memory on demand and governed by Settings > Local Inference > Model Management. The eviction policy controls strict one-model versus flexible multi-model residency; "Keep model loaded after use" controls idle unload timing after the final request/window lease drops. Idle unload releases weights and runtime buffers only — downloaded models and disk KV cache entries remain intact. `/health` keeps `loaded`, `current_model`, and `inflight`, and adds `resident_models[]` entries with `idle_unload_at` and `idle_seconds_remaining`. KV cache geometry (paged for global attention, rotating for sliding-window, SSM state for hybrid models) is owned by vmlx-swift's `CacheCoordinator`, which sizes each tier per model.

4. **GPU Acceleration**: MLX uses Apple Silicon unified memory for GPU-accelerated inference.

5. **Context Length**: Each model has its own architectural context limit (the engine respects per-layer sliding windows, e.g. Gemma-4's 1024-position windows, automatically). Osaurus does not expose a user-facing global KV cache cap any more — vmlx-swift picks model-aware defaults per release.
