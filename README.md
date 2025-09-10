# Osaurus 🦕

[![Release](https://img.shields.io/github/v/release/dinoki-ai/osaurus?sort=semver)](https://github.com/dinoki-ai/osaurus/releases)
[![Downloads](https://img.shields.io/github/downloads/dinoki-ai/osaurus/total)](https://github.com/dinoki-ai/osaurus/releases)
[![License](https://img.shields.io/github/license/dinoki-ai/osaurus)](LICENSE)
[![Stars](https://img.shields.io/github/stars/dinoki-ai/osaurus?style=social)](https://github.com/dinoki-ai/osaurus/stargazers)
![Platform](<https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-black?logo=apple>)
![OpenAI API](https://img.shields.io/badge/OpenAI%20API-compatible-0A7CFF)
![Ollama API](https://img.shields.io/badge/Ollama%20API-compatible-0A7CFF)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

<img width="452" height="206" alt="Screenshot 2025-08-24 at 4 47 41 PM" src="https://github.com/user-attachments/assets/375d52b2-fb68-4fbd-9055-3a25bb9d2651" />

Native, Apple Silicon–only local LLM server. Built on Apple's MLX for maximum performance on M‑series chips. SwiftUI app + SwiftNIO server with OpenAI‑compatible and Ollama‑compatible endpoints.

Created by Dinoki Labs ([dinoki.ai](https://dinoki.ai)), a fully native desktop AI assistant and companion.

## Highlights

- **Native MLX runtime**: Optimized for Apple Silicon using MLX/MLXLLM
- **Apple Silicon only**: Designed and tested for M‑series Macs
- **OpenAI API compatible**: `/v1/models` and `/v1/chat/completions` (stream and non‑stream)
- **Ollama‑compatible**: `/chat` endpoint with NDJSON streaming for OllamaKit and other Ollama clients
- **Function/Tool calling**: OpenAI‑style `tools` + `tool_choice`, with `tool_calls` parsing and streaming deltas
- **Fast token streaming**: Server‑Sent Events for low‑latency output
- **Model manager UI**: Browse, download, and manage MLX models from `mlx-community`
- **System resource monitor**: Real-time CPU and RAM usage visualization
- **Self‑contained**: SwiftUI app with an embedded SwiftNIO HTTP server

## Requirements

- macOS 15.5+
- Apple Silicon (M1 or newer)
- Xcode 16.4+ (to build from source)

```
osaurus/
├── Core/
│   ├── AppDelegate.swift
│   └── osaurusApp.swift
├── Controllers/
│   ├── ServerController.swift      # NIO server lifecycle
│   └── ModelManager.swift          # Model discovery & downloads (Hugging Face)
├── Models/
│   ├── MLXModel.swift
│   ├── OpenAIAPI.swift             # OpenAI‑compatible DTOs
│   ├── ResponseWriters.swift       # SSE and NDJSON response writers
│   ├── ServerConfiguration.swift
│   └── ServerHealth.swift
├── Networking/
│   ├── HTTPHandler.swift           # Request parsing & routing entry
│   ├── Router.swift                # Routes → handlers with path normalization
│   └── AsyncHTTPHandler.swift      # Unified streaming handler
├── Services/
│   ├── MLXService.swift            # MLX loading, session caching, generation
│   ├── SearchService.swift
│   └── SystemMonitorService.swift  # Real-time CPU and RAM monitoring
├── Theme/
│   └── Theme.swift
├── Views/
│   ├── Components/SimpleComponents.swift
│   ├── ContentView.swift           # Start/stop server, quick controls
│   └── ModelDownloadView.swift     # Browse/download/manage models
└── Assets.xcassets/
```

## Features

- Native MLX text generation with model
- Model manager with curated suggestions (Llama, Qwen, Gemma, Mistral, etc.)
- Download sizes estimated via Hugging Face metadata
- Streaming and non‑streaming chat completions
- Multiple response formats: SSE (OpenAI‑style) and NDJSON (Ollama‑style)
- Compatible with OllamaKit and other Ollama client libraries
- OpenAI‑compatible function calling with robust parser for model outputs (handles code fences/formatting noise)
- Auto‑detects stop sequences and BOS token from tokenizer configs
- Health endpoint and simple status UI
- Real-time system resource monitoring
- Path normalization for API compatibility

## Benchmarks

The following are 20-run averages from our batch benchmark suite. See raw results for details and variance.

| Server    | Model                      | TTFT avg (ms) | Total avg (ms) | Chars/s avg | TTFT rel | Total rel | Chars/s rel | Success |
| --------- | -------------------------- | ------------- | -------------- | ----------- | -------- | --------- | ----------- | ------- |
| Osaurus   | llama-3.2-3b-instruct-4bit | 86            | 1314           | 558         | 0%       | 0%        | 0%          | 100%    |
| Ollama    | llama3.2                   | 58            | 1655           | 434         | +32%     | -26%      | -22%        | 100%    |
| LM Studio | llama-3.2-3b-instruct      | 56            | 1203           | 610         | +34%     | +8%       | +9%         | 100%    |

- Metrics: TTFT = time-to-first-token, Total = time to final token, Chars/s = streaming throughput.
- Relative % vs Osaurus baseline: TTFT/Total computed as 1 - other/osaurus; Chars/s as other/osaurus - 1. Positive = better.
- Data sources: `results/osaurus-vs-ollama-lmstudio-batch.summary.json`, `results/osaurus-vs-ollama-lmstudio-batch.results.csv`.
- How to reproduce: `scripts/run_bench.sh` calls `scripts/benchmark_models.py` to run prompts across servers and write results.

## API Endpoints

- `GET /` → Plain text status
- `GET /health` → JSON health info
- `GET /models` → OpenAI‑compatible models list
- `GET /tags` → Ollama‑compatible models list
- `POST /chat/completions` → OpenAI‑compatible chat completions
- `POST /chat` → Ollama‑compatible chat endpoint

**Path normalization**: All endpoints support common API prefixes (`/v1`, `/api`, `/v1/api`). For example:

- `/v1/models` → `/models`
- `/api/chat/completions` → `/chat/completions`
- `/api/chat` → `/chat` (Ollama‑style)

## Getting Started

### Download

Download the latest signed build from the [Releases page](https://github.com/dinoki-ai/osaurus/releases/latest).

### Build and run

1. Open `osaurus.xcodeproj` in Xcode 16.4+
2. Build and run the `osaurus` target
3. In the UI, configure the port via the gear icon (default `8080`) and press Start
4. Open the model manager to download a model (e.g., "Llama 3.2 3B Instruct 4bit")

Models are stored by default at `~/MLXModels`. Override with the environment variable `OSU_MODELS_DIR`.

### Use the API

Base URL: `http://127.0.0.1:8080` (or your chosen port)

List models:

```bash
curl -s http://127.0.0.1:8080/v1/models | jq
```

Ollama‑compatible models list:

```bash
curl -s http://127.0.0.1:8080/v1/tags | jq
```

Non‑streaming chat completion:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [{"role":"user","content":"Write a haiku about dinosaurs"}],
        "max_tokens": 200
      }'
```

Streaming chat completion (SSE format for `/chat/completions`):

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [{"role":"user","content":"Summarize Jurassic Park in one paragraph"}],
        "stream": true
      }'
```

Ollama‑compatible streaming (NDJSON format for `/chat`):

```bash
curl -N http://127.0.0.1:8080/v1/api/chat \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [{"role":"user","content":"Tell me about dinosaurs"}],
        "stream": true
      }'
```

This endpoint is compatible with OllamaKit and other Ollama client libraries.

Tip: Model names are lower‑cased with hyphens (derived from the friendly name), for example: `Llama 3.2 3B Instruct 4bit` → `llama-3.2-3b-instruct-4bit`.

### Integrate with native or Electron apps

If you're building a macOS app (Swift/Objective‑C/SwiftUI/Electron) and want to discover and connect to a running Osaurus instance, see the Shared Configuration guide: [SHARED_CONFIGURATION_GUIDE.md](SHARED_CONFIGURATION_GUIDE.md).

### Function/Tool Calling (OpenAI‑compatible)

Osaurus supports OpenAI‑style function calling. Send `tools` and optional `tool_choice` in your request. The model is instructed to reply with an exact JSON object containing `tool_calls`, and the server parses it, including common formatting like code fences.

Define tools and let the model decide (`tool_choice: "auto"`):

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [
          {"role":"system","content":"You can call functions to answer queries succinctly."},
          {"role":"user","content":"What\'s the weather in SF?"}
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

Non‑stream response will include `message.tool_calls` and `finish_reason: "tool_calls"`. Streaming responses emit OpenAI‑style deltas for `tool_calls` (id, type, function name, and chunked `arguments`), finishing with `finish_reason: "tool_calls"` and `[DONE]`.

After you execute a tool, continue the conversation by sending a `tool` role message with `tool_call_id`:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [
          {"role":"user","content":"What\'s the weather in SF?"},
          {"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}}]},
          {"role":"tool","tool_call_id":"call_1","content":"{\"tempC\":18,\"conditions\":\"Foggy\"}"}
        ]
      }'
```

Notes:

- Only `type: "function"` tools are supported.
- Arguments must be a JSON‑escaped string in the assistant response; Osaurus also tolerates a nested `parameters` object and will normalize.
- Parser accepts minor formatting noise like code fences and `assistant:` prefixes.

### Use with OpenAI SDKs

Point your client at Osaurus and use any placeholder API key.

Python example:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="osaurus")

resp = client.chat.completions.create(
    model="llama-3.2-3b-instruct-4bit",
    messages=[{"role": "user", "content": "Hello there!"}],
)

print(resp.choices[0].message.content)
```

Python with tools (non‑stream):

```python
import json
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="osaurus")

tools = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get weather by city",
            "parameters": {
                "type": "object",
                "properties": {"city": {"type": "string"}},
                "required": ["city"],
            },
        },
    }
]

resp = client.chat.completions.create(
    model="llama-3.2-3b-instruct-4bit",
    messages=[{"role": "user", "content": "Weather in SF?"}],
    tools=tools,
    tool_choice="auto",
)

tool_calls = resp.choices[0].message.tool_calls or []
for call in tool_calls:
    args = json.loads(call.function.arguments)
    result = {"tempC": 18, "conditions": "Foggy"}  # your tool result
    followup = client.chat.completions.create(
        model="llama-3.2-3b-instruct-4bit",
        messages=[
            {"role": "user", "content": "Weather in SF?"},
            {"role": "assistant", "content": "", "tool_calls": tool_calls},
            {"role": "tool", "tool_call_id": call.id, "content": json.dumps(result)},
        ],
    )
    print(followup.choices[0].message.content)
```

## Models

- Curated suggestions include Llama, Qwen, Gemma, Mistral, Phi, DeepSeek, etc. (4‑bit variants for speed)
- Discovery pulls from Hugging Face `mlx-community` and computes size estimates
- Required files are fetched automatically (tokenizer/config/weights)
- Change the models directory with `OSU_MODELS_DIR`

## Notes & Limitations

- Apple Silicon only (requires MLX); Intel Macs are not supported
- Localhost only, no authentication; put behind a proxy if exposing externally
- `/transcribe` endpoints are placeholders pending Whisper integration

## Dependencies

- SwiftNIO (HTTP server)
- SwiftUI/AppKit (UI)
- MLX‑Swift, MLXLLM (runtime and generation)

## Contributors

- [wizardeur](https://github.com/wizardeur) — first PR creator

## Community

- Join us on [Discord](https://discord.gg/dinoki)
- Read the [Contributing Guide](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md)
- See our [Security Policy](SECURITY.md) for reporting vulnerabilities
- Get help in [Support](SUPPORT.md)
- Pick up a [good first issue](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) or [help wanted](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)

If you find Osaurus useful, please ⭐ the repo and share it!
