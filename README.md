# Osaurus

[![Release](https://img.shields.io/github/v/release/dinoki-ai/osaurus?sort=semver)](https://github.com/dinoki-ai/osaurus/releases)
[![Downloads](https://img.shields.io/github/downloads/dinoki-ai/osaurus/total)](https://github.com/dinoki-ai/osaurus/releases)
[![License](https://img.shields.io/github/license/dinoki-ai/osaurus)](LICENSE)
[![Stars](https://img.shields.io/github/stars/dinoki-ai/osaurus?style=social)](https://github.com/dinoki-ai/osaurus/stargazers)
![Platform](<https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-black?logo=apple>)
![OpenAI API](https://img.shields.io/badge/OpenAI%20API-compatible-0A7CFF)
![Ollama API](https://img.shields.io/badge/Ollama%20API-compatible-0A7CFF)
![Foundation Models](https://img.shields.io/badge/Apple%20Foundation%20Models-supported-0A7CFF)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

<p align="center">
  <img width="452" height="222" alt="Screenshot 2025-09-22 at 7 02 10 PM" src="https://github.com/user-attachments/assets/6cd07add-2768-4556-ad0c-ed721ebc6596" />
</p>

Native, Apple Silicon–only local LLM server. Built on Apple's MLX for maximum performance on M‑series chips, with Apple Foundation Models integration when available. SwiftUI app + SwiftNIO server with OpenAI‑compatible and Ollama‑compatible endpoints.

Created by Dinoki Labs ([dinoki.ai](https://dinoki.ai)), a fully native desktop AI assistant and companion.

📚 **[View Documentation](https://docs.dinoki.ai/)** - Guides, tutorials, and comprehensive documentation

## Highlights

- **Native MLX runtime**: Optimized for Apple Silicon using MLX/MLXLLM
- **Apple Foundation Models**: Use the system default model via `model: "foundation"` or `model: "default"` on supported macOS versions; accelerated by Apple Neural Engine (ANE) when available
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
- Apple Intelligence features require macOS 26 (Tahoe)

```
osaurus/
├── Core/
│   ├── AppDelegate.swift
│   └── osaurusApp.swift
├── Controllers/
│   ├── ServerController.swift      # NIO server lifecycle
│   └── ModelManager.swift          # Model discovery & downloads (Hugging Face)
├── Models/
│   ├── InternalMessage.swift
│   ├── MLXModel.swift
│   ├── OpenAIAPI.swift             # OpenAI‑compatible DTOs
│   ├── ResponseWriters.swift       # SSE and NDJSON response writers
│   ├── ServerConfiguration.swift
│   ├── ServerConfigurationStore.swift
│   └── ServerHealth.swift
├── Networking/
│   ├── HTTPHandler.swift           # Request parsing & routing entry
│   ├── Router.swift                # Routes → handlers with path normalization
│   └── AsyncHTTPHandler.swift      # Unified streaming handler
├── Services/
│   ├── DirectoryPickerService.swift
│   ├── FoundationModelService.swift
│   ├── HuggingFaceService.swift
│   ├── LoginItemService.swift
│   ├── MLXService.swift            # MLX loading, session caching, generation
│   ├── ModelService.swift
│   ├── PromptBuilder.swift
│   ├── SearchService.swift
│   ├── SharedConfigurationService.swift
│   ├── SystemMonitorService.swift  # Real-time CPU and RAM monitoring
│   └── UpdaterService.swift
├── Theme/
│   └── Theme.swift
├── Views/
│   ├── Components/
│   │   ├── EmptyStateView.swift
│   │   ├── InfoRow.swift
│   │   ├── ModelRowView.swift
│   │   └── SimpleComponents.swift
│   ├── ContentView.swift           # Start/stop server, quick controls
│   ├── DirectoryPickerView.swift
│   ├── ModelDetailView.swift
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
| Osaurus   | llama-3.2-3b-instruct-4bit | 87            | 1237           | 554         | 0%       | 0%        | 0%          | 100%    |
| Ollama    | llama3.2                   | 33            | 1622           | 430         | +63%     | -31%      | -22%        | 100%    |
| LM Studio | llama-3.2-3b-instruct      | 113           | 1221           | 588         | -30%     | +1%       | +6%         | 100%    |

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

### Install with Homebrew

The easiest way to install Osaurus is through Homebrew cask (app bundle):

```bash
brew install --cask osaurus
```

This installs `Osaurus.app`. The CLI (`osaurus`) is embedded inside the app and will be auto-linked by the cask if available. If the `osaurus` command isn't found on your PATH, run one of the following:

```bash
# One-liner: symlink the embedded CLI into your Homebrew bin
ln -sf "/Applications/Osaurus.app/Contents/MacOS/osaurus" "$(brew --prefix)/bin/osaurus" || \
ln -sf "$HOME/Applications/Osaurus.app/Contents/MacOS/osaurus" "$(brew --prefix)/bin/osaurus"

# Or use the helper script (auto-detects paths and Homebrew prefix)
curl -fsSL https://raw.githubusercontent.com/dinoki-ai/osaurus/main/scripts/install_cli_symlink.sh | bash
```

Once installed, you can launch Osaurus from:

- **Spotlight**: Press `⌘ Space` and type "osaurus"
- **Applications folder**: Find Osaurus in `/Applications`
- **Terminal**: Run `osaurus ui` (or `open -a osaurus`)

The app will appear in your menu bar, ready to serve local LLMs on your Mac.

### Build and run

1. Open `osaurus.xcodeproj` in Xcode 16.4+
2. Build and run the `osaurus` target
3. In the UI, configure the port via the gear icon (default `1337`) and press Start
4. Open the model manager to download a model (e.g., "Llama 3.2 3B Instruct 4bit")

Models are stored by default at `~/MLXModels`. Override with the environment variable `OSU_MODELS_DIR`.

### Command-line server management

The CLI lets you start/stop the server and open the UI from your terminal. If `osaurus` isn’t found in your `PATH` after installing the app:

- Run the one-liner above to create the symlink, or
- From a cloned repo, run: `scripts/install_cli_symlink.sh`, or
- For development builds: `make install-cli` (uses DerivedData output)

```bash
# Start on localhost (default)
osaurus serve --port 1337

# Start exposed on your LAN (will prompt for confirmation)
osaurus serve --port 1337 --expose

# Start exposed without prompt (non-interactive)
osaurus serve --port 1337 --expose --yes

# Open the UI (menu bar popover)
osaurus ui

# Check status
osaurus status

# Stop the server
osaurus stop
```

Notes:

- When started via CLI without `--expose`, Osaurus binds to `127.0.0.1` only.
- `--expose` binds to `0.0.0.0` (LAN). There is no authentication; use only on trusted networks.
- Management is local-only via macOS Distributed Notifications; there are no HTTP start/stop endpoints.

### Use the API

Base URL: `http://127.0.0.1:1337` (or your chosen port)

📚 **Need more help?** Check out our [comprehensive documentation](https://docs.dinoki.ai/) for detailed guides, tutorials, and advanced usage examples.

List models:

```bash
curl -s http://127.0.0.1:1337/v1/models | jq
```

If your system supports Apple Foundation Models, you will also see a `foundation` entry representing the system default model. You can target it explicitly with `model: "foundation"` or by passing `model: "default"` or an empty string (the server routes default requests to the system model when available).

Ollama‑compatible models list:

```bash
curl -s http://127.0.0.1:1337/v1/tags | jq
```

Non‑streaming chat completion:

```bash
curl -s http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [{"role":"user","content":"Write a haiku about dinosaurs"}],
        "max_tokens": 200
      }'
```

Non‑streaming with Apple Foundation Models (when available):

```bash
curl -s http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "foundation",
        "messages": [{"role":"user","content":"Write a haiku about dinosaurs"}],
        "max_tokens": 200
      }'
```

Streaming chat completion (SSE format for `/chat/completions`):

```bash
curl -N http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "llama-3.2-3b-instruct-4bit",
        "messages": [{"role":"user","content":"Summarize Jurassic Park in one paragraph"}],
        "stream": true
      }'
```

Streaming with Apple Foundation Models (when available):

```bash
curl -N http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "default",
        "messages": [{"role":"user","content":"Summarize Jurassic Park in one paragraph"}],
        "stream": true
      }'
```

Ollama‑compatible streaming (NDJSON format for `/chat`):

```bash
curl -N http://127.0.0.1:1337/v1/api/chat \
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

Notes on Apple Foundation Models:

- When using `model: "foundation"`/`"default"` on supported systems, tool calls are mapped through Apple Foundation Models' tool interface. In streaming mode, Osaurus emits OpenAI‑style `tool_calls` deltas so your client code works unchanged.

Define tools and let the model decide (`tool_choice: "auto"`):

```bash
curl -s http://127.0.0.1:1337/v1/chat/completions \
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
curl -s http://127.0.0.1:1337/v1/chat/completions \
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

client = OpenAI(base_url="http://127.0.0.1:1337/v1", api_key="osaurus")

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

client = OpenAI(base_url="http://127.0.0.1:1337/v1", api_key="osaurus")

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

## CORS

Osaurus includes built‑in CORS support for browser clients.

- **Disabled by default**: No CORS headers are sent unless you configure allowed origins.
- **Enable via UI**: gear icon → Advanced Settings → CORS Settings → Allowed Origins.
  - Enter a comma‑separated list, for example: `http://localhost:3000, http://127.0.0.1:5173, https://app.example.com`
  - Use `*` to allow any origin (recommended only for local development).
- **Expose to network**: If you need to access from other devices, also enable "Expose to network" in Network Settings.

Behavior when CORS is enabled:

- Requests with an allowed `Origin` receive `Access-Control-Allow-Origin` (either the specific origin or `*`).
- Preflight `OPTIONS` requests are answered with `204 No Content` and headers:
  - `Access-Control-Allow-Methods`: echoes requested method or defaults to `GET, POST, OPTIONS, HEAD`
  - `Access-Control-Allow-Headers`: echoes requested headers or defaults to `Content-Type, Authorization`
  - `Access-Control-Max-Age: 600`
- Streaming endpoints also include CORS headers on their responses.

Quick examples

Configure via UI (persists to app settings). The underlying config includes:

```json
{
  "allowedOrigins": ["http://localhost:3000", "https://app.example.com"]
}
```

Browser fetch from a web app running on `http://localhost:3000`:

```javascript
await fetch("http://127.0.0.1:1337/v1/chat/completions", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    model: "llama-3.2-3b-instruct-4bit",
    messages: [{ role: "user", content: "Hello!" }],
  }),
});
```

Notes

- Leave the field empty to disable CORS entirely.
- `*` cannot be combined with credentials; Osaurus does not use cookies, so this is typically fine for local use.

## Models

- Curated suggestions include Llama, Qwen, Gemma, Mistral, Phi, DeepSeek, etc. (4‑bit variants for speed)
- Discovery pulls from Hugging Face `mlx-community` and computes size estimates
- Required files are fetched automatically (tokenizer/config/weights)
- Change the models directory with `OSU_MODELS_DIR`

Foundation Models:

- On macOS versions that provide Apple Foundation Models, the `/v1/models` list includes a virtual `foundation` entry representing the system default language model. You can select it via `model: "foundation"` or `model: "default"`.

## Notes & Limitations

- Apple Silicon only (requires MLX); Intel Macs are not supported
- Localhost by default; `--expose` enables LAN access. No authentication; use only on trusted networks or behind a reverse proxy.
- `/transcribe` endpoints are placeholders pending Whisper integration
- Apple Foundation Models availability depends on macOS version and frameworks. If unavailable, requests with `model: "foundation"`/`"default"` will return an error. Use `/v1/models` to detect support.
- Apple Intelligence requires macOS 26 (Tahoe).

## Dependencies

- SwiftNIO (HTTP server)
- SwiftUI/AppKit (UI)
- MLX‑Swift, MLXLLM (runtime and generation)

## Contributors

- [wizardeur](https://github.com/wizardeur) — first PR creator

## Community

- 📚 Browse our [Documentation](https://docs.dinoki.ai/) for guides and tutorials
- 💬 Join us on [Discord](https://discord.gg/dinoki)
- 📖 Read the [Contributing Guide](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md)
- 🔒 See our [Security Policy](SECURITY.md) for reporting vulnerabilities
- ❓ Get help in [Support](SUPPORT.md)
- 🚀 Pick up a [good first issue](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) or [help wanted](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)

If you find Osaurus useful, please ⭐ the repo and share it!
