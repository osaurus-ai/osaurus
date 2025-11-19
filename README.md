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
  <img width="372" height="222" alt="Screenshot 2025-11-04 at 3 15 54 PM" src="https://github.com/user-attachments/assets/9f0e9122-6092-4a63-9421-d9abb898c75b" />
</p>

Native, Apple Silicon–only local LLM server. Built on Apple's MLX for maximum performance on M‑series chips, with Apple Foundation Models integration when available. SwiftUI app + SwiftNIO server with OpenAI‑compatible and Ollama‑compatible endpoints.

Created by Dinoki Labs ([dinoki.ai](https://dinoki.ai)), a fully native desktop AI assistant and companion.

📚 **[View Documentation](https://docs.osaurus.ai/)** - Guides, tutorials, and comprehensive documentation

## Highlights

- **Native MLX runtime**: Optimized for Apple Silicon using MLX/MLXLLM
- **Apple Foundation Models**: Use the system default model via `model: "foundation"` or `model: "default"` on supported macOS versions; accelerated by Apple Neural Engine (ANE) when available
- **Apple Silicon only**: Designed and tested for M‑series Macs
- **OpenAI API compatible**: `/v1/models` and `/v1/chat/completions` (stream and non‑stream)
- **Ollama‑compatible**: `/chat` endpoint with NDJSON streaming for OllamaKit and other Ollama clients
- **Function/Tool calling**: OpenAI‑style `tools` + `tool_choice`, with `tool_calls` parsing and streaming deltas
- **Fast token streaming**: Server‑Sent Events for low‑latency output
- **In‑app Chat overlay**: Chat directly with your models in a resizable glass window — streaming, Markdown, model picker, and a global hotkey (default ⌘;)
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
├── App/
│   ├── osaurus.xcodeproj
│   └── osaurus/
│       ├── osaurusApp.swift        # Thin app entry point
│       └── Assets.xcassets/
└── Packages/
    ├── OsaurusCore/                # Swift Package (all app logic & deps)
    │   ├── Controllers/            # NIO server lifecycle
    │   ├── Managers/               # Model discovery & downloads (Hugging Face)
    │   ├── Models/                 # DTOs, config, health, etc.
    │   ├── Networking/             # Router, handlers, response writers
    │   ├── Services/               # MLX runtime, Foundation, Hugging Face, etc.
    │   ├── Theme/
    │   └── Views/                  # SwiftUI views (popover, chat, managers)
    └── OsaurusCLI/                 # Swift Package (executable CLI)
```

Notes:

- Dependencies are managed by Swift Package Manager in `Packages/OsaurusCore/Package.swift`.
- The macOS app target depends only on `OsaurusCore`.

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

### In‑app Chat

- Overlay chat UI accessible from the menu bar bubble button or a global hotkey (default ⌘;)
- Foundation‑first model picker, plus any installed MLX models; `foundation` appears when available
- Real‑time token streaming with a Stop button and smooth auto‑scroll
- Rich Markdown rendering with one‑click copy per message
- Input shortcuts: Return or ⌘Return to send; Shift+Return inserts a newline
- Optional global system prompt is prepended to every chat

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

### MCP (Model Context Protocol)

- Stdio transport auto-starts with the app. Connect using an MCP client that supports stdio.
- HTTP endpoints (same port):
  - `GET /mcp/health` → MCP availability probe
  - `GET /mcp/tools` → List active tools (name, description)
  - `POST /mcp/call` → Execute a tool with JSON `{ "name": string, "arguments": object }`

MCP integration uses the official Swift SDK: [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk).

#### MCP via CLI (stdio proxy)

To avoid app restarts when launching from an MCP client, you can run the MCP server via the CLI, which proxies MCP stdio to the running HTTP server:

```bash
osaurus mcp
```

- If the server is already running, the CLI connects immediately (no relaunch).
- If the server is not running, the CLI auto‑launches Osaurus and waits until healthy.

Example MCP client configuration (generic JSON):

```json
{
  "mcpServers": {
    "osaurus": {
      "command": "osaurus",
      "args": ["mcp"]
    }
  }
}
```

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
# One-liner: symlink the embedded CLI into your Homebrew bin (Helpers preferred)
ln -sf "/Applications/Osaurus.app/Contents/Helpers/osaurus" "$(brew --prefix)/bin/osaurus" || \
ln -sf "$HOME/Applications/Osaurus.app/Contents/Helpers/osaurus" "$(brew --prefix)/bin/osaurus"

# Or use the helper script (auto-detects paths and Homebrew prefix)
curl -fsSL https://raw.githubusercontent.com/dinoki-ai/osaurus/main/scripts/install_cli_symlink.sh | bash
```

Once installed, you can launch Osaurus from:

- **Spotlight**: Press `⌘ Space` and type "osaurus"
- **Applications folder**: Find Osaurus in `/Applications`
- **Terminal**: Run `osaurus ui` (or `open -a osaurus`)

The app will appear in your menu bar, ready to serve local LLMs on your Mac.

### Build and run

1. Open `osaurus.xcworkspace` (recommended for editing app + packages), or open `App/osaurus.xcodeproj` to build the app target directly
2. Build and run the `osaurus` target
3. In the UI, configure the port via the gear icon (default `1337`) and press Start
4. Open the model manager to download a model (e.g., "Llama 3.2 3B Instruct 4bit")
5. Open the Chat overlay via the chat bubble icon or press `⌘;` to start chatting

Models are stored by default at `~/MLXModels`. Override with the environment variable `OSU_MODELS_DIR`.

### Chat settings

- Open the configuration popover (gear icon) → Chat
- Global Hotkey: record a shortcut to toggle the Chat overlay (default `⌘;`)
- System Prompt: optional text prepended to all chats
- Settings are saved locally and the hotkey applies immediately

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

# List model IDs
osaurus list

# Interactive chat with a downloaded model (use an ID from `osaurus list`)
osaurus run llama-3.2-3b-instruct-4bit
```

Note: `osaurus serve` will auto-launch Osaurus.app if it isn't already running.

Troubleshooting:

- If you see “Failed to start server on port …”, try a different port, e.g. `osaurus serve --port 1338`.
- Ensure the app launches correctly: `open -b com.dinoki.osaurus`.
- You can also open the UI directly: `osaurus ui`.

Tip: Set OSU_PORT to override the default/auto-detected port for CLI commands.

Notes:

- When started via CLI without `--expose`, Osaurus binds to `127.0.0.1` only.
- `--expose` binds to `0.0.0.0` (LAN). There is no authentication; use only on trusted networks.
- Management is local-only via macOS Distributed Notifications; there are no HTTP start/stop endpoints.

### Use the API

Base URL: `http://127.0.0.1:1337` (or your chosen port)

📚 **Need more help?** Check out our [comprehensive documentation](https://docs.osaurus.ai/) for detailed guides, tutorials, and advanced usage examples.

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
curl -N http://127.0.0.1:1337/v1/chat \
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

Note: Tool‑calling is supported on the OpenAI‑style `/chat/completions` endpoint. The Ollama‑style `/chat` (NDJSON) endpoint streams text only and does not emit `tool_calls` deltas.

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
- Tool‑calling deltas are only available on `/chat/completions` (SSE). The `/chat` (NDJSON) endpoint is text‑only.

## Request parameters & behavior

- **temperature**: Supported on all backends.
- **max_tokens**: Supported on all backends.
- **top_p**: If provided per request, overrides the server default; otherwise the server uses the configured `genTopP`.
- **frequency_penalty / presence_penalty**: Mapped to a repetition penalty on MLX backends (`repetitionPenalty = 1.0 + max(fp, pp)` when positive). If both are missing or ≤ 0, no repetition penalty is applied.
- **stop**: Array of strings. Honored in both streaming and non‑streaming modes on MLX and Foundation backends; output is trimmed before the first stop sequence.
- **n**: Only `1` is supported; other values are ignored.
- **session_id**: Accepted but not currently used for KV‑cache reuse.

## Dependencies

- Managed via Swift Package Manager in `Packages/OsaurusCore/Package.swift`:
  - SwiftNIO (HTTP server)
  - IkigaJSON (fast JSON)
  - Sparkle (updates)
  - MLX‑Swift, MLXLLM, MLXLMCommon (runtime and generation)
  - Hugging Face swift‑transformers (Hub/Tokenizers)

## Contributors

- [wizardeur](https://github.com/wizardeur) — first PR creator

## Community

- 📚 Browse our [Documentation](https://docs.osaurus.ai/) for guides and tutorials
- 💬 Join us on [Discord](https://discord.gg/dinoki)
- 📖 Read the [Contributing Guide](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md)
- 🔒 See our [Security Policy](SECURITY.md) for reporting vulnerabilities
- ❓ Get help in [Support](SUPPORT.md)
- 🚀 Pick up a [good first issue](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) or [help wanted](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)

If you find Osaurus useful, please ⭐ the repo and share it!
