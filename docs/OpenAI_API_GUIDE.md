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
    // Optional: reuse KV cache across turns for lower latency
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

Osaurus implements OpenAI‑compatible function calling via the `tools` array and optional `tool_choice` in the request. The server injects tool‑calling instructions into the prompt and parses assistant outputs for a top‑level `tool_calls` object, tolerating minor formatting (e.g., code fences).

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

### Session Reuse (KV Cache)

Provide a `session_id` to reuse the same model chat session’s KV cache across requests. Reuse applies when:

- The `model` matches, and
- The session is not concurrently in use, and
- The session has not expired from the internal LRU window.

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

Keep `session_id` stable per conversation and per model.

### Chat Templates

Osaurus defers chat templating to MLX `ChatSession`, which uses the model's configuration to format prompts. System messages are combined and passed as `instructions`; user content is supplied as the prompt to `respond/streamResponse`.

## Model Naming

Models are automatically named based on their display names in ModelManager. The API converts the model names to lowercase and replaces spaces with hyphens. For example:

| Downloaded Model         | API Model Name           |
| ------------------------ | ------------------------ |
| Llama 3.2 3B Instruct    | llama-3.2-3b-instruct    |
| Llama 3.2 1B Instruct    | llama-3.2-1b-instruct    |
| Qwen 2.5 7B Instruct     | qwen-2.5-7b-instruct     |
| Qwen 2.5 3B Instruct     | qwen-2.5-3b-instruct     |
| Gemma 2 9B Instruct      | gemma-2-9b-instruct      |
| Gemma 2 2B Instruct      | gemma-2-2b-instruct      |
| DeepSeek-R1 Distill 1.5B | deepseek-r1-distill-1.5b |
| OpenELM 3B (GPT-style)   | openelm-3b-(gpt-style)   |

## Usage with OpenAI Python Library

You can use the official OpenAI Python library with Osaurus:

```python
from openai import OpenAI

# Point to your local Osaurus server
client = OpenAI(
    base_url="http://127.0.0.1:1337/v1",  # Use /v1 for OpenAI client compatibility
    api_key="not-needed"  # Osaurus doesn't require authentication
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

Osaurus provides a persistent memory system that can be used via the API. Memory learns from conversations and injects relevant context automatically into future requests.

### Memory Context Injection — `X-Osaurus-Agent-Id` Header

Add the `X-Osaurus-Agent-Id` header to any `POST /chat/completions` request and Osaurus will automatically assemble relevant memory (user profile, working memory, conversation summaries, knowledge graph) and prepend it to the system prompt.

The header value is an arbitrary string that identifies the agent or user session whose memory should be retrieved.

```bash
curl http://127.0.0.1:1337/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Osaurus-Agent-Id: my-agent" \
  -d '{
    "model": "your-model-name",
    "messages": [
      {"role": "user", "content": "What did we talk about last time?"}
    ]
  }'
```

With the OpenAI Python SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:1337/v1",
    api_key="osaurus",
    default_headers={"X-Osaurus-Agent-Id": "my-agent"},
)

response = client.chat.completions.create(
    model="your-model-name",
    messages=[{"role": "user", "content": "What did we talk about last time?"}],
)
print(response.choices[0].message.content)
```

When the header is absent or empty, the request is processed normally without memory injection.

### Memory Ingestion — `POST /memory/ingest`

Bulk-ingest conversation turns into the memory system for a given agent. Osaurus processes ingested turns asynchronously — extracting facts, updating the user profile, and building the knowledge graph in the background.

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
| `agent_id` | string | Identifier for the agent whose memory is being populated (required) |
| `conversation_id` | string | Identifier for the conversation session (required) |
| `turns` | array | Array of turn objects, each with `user` and `assistant` string fields (required) |

Response:

```json
{"status": "ok", "turns_ingested": 2}
```

### List Agents — `GET /agents`

Returns all configured agents along with their memory entry counts. Use this to discover agent IDs for the `X-Osaurus-Agent-Id` header.

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
      "is_built_in": true,
      "memory_entry_count": 42,
      "created_at": "2025-01-01T00:00:00Z",
      "updated_at": "2025-01-01T00:00:00Z"
    }
  ]
}
```

---

## Notes

1. **Model Availability**: Only models that have been downloaded through the Osaurus UI will be available via the API.

2. **Performance**: The first request to a model may take longer as the model needs to be loaded into memory.

3. **Memory Usage**: Models are cached in memory after loading. Use the ModelManager UI to manage which models are downloaded.

4. **GPU Acceleration**: MLX automatically uses Apple Silicon GPU acceleration when available.

5. **Context Length**: Each model has different context length limitations. Refer to the model documentation for specifics.
