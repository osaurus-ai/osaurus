# Osaurus

[![Release](https://img.shields.io/github/v/release/dinoki-ai/osaurus?sort=semver)](https://github.com/dinoki-ai/osaurus/releases)
[![Downloads](https://img.shields.io/github/downloads/dinoki-ai/osaurus/total)](https://github.com/dinoki-ai/osaurus/releases)
[![License](https://img.shields.io/github/license/dinoki-ai/osaurus)](LICENSE)
[![Stars](https://img.shields.io/github/stars/dinoki-ai/osaurus?style=social)](https://github.com/dinoki-ai/osaurus/stargazers)
![Platform](<https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-black?logo=apple>)
![OpenAI API](https://img.shields.io/badge/OpenAI%20API-compatible-0A7CFF)
![Anthropic API](https://img.shields.io/badge/Anthropic%20API-compatible-0A7CFF)
![Ollama API](https://img.shields.io/badge/Ollama%20API-compatible-0A7CFF)
![MCP Server](https://img.shields.io/badge/MCP-server-0A7CFF)
![Foundation Models](https://img.shields.io/badge/Apple%20Foundation%20Models-supported-0A7CFF)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

<p align="center">
<img width="372" height="222" alt="Screenshot 2025-12-15 at 4 17 47 PM" src="https://github.com/user-attachments/assets/c0fe3a6a-9d5b-4afe-886f-19077218dcc5" />
</p>

**Native macOS LLM server with MCP support.** Run local and remote language models on Apple Silicon with OpenAI-compatible APIs, tool calling, and a built-in plugin ecosystem.

Created by Dinoki Labs ([dinoki.ai](https://dinoki.ai))

**[Documentation](https://docs.osaurus.ai/)** · **[Discord](https://discord.gg/dinoki)** · **[Plugin Registry](https://github.com/dinoki-ai/osaurus-tools)** · **[Contributing](docs/CONTRIBUTING.md)**

---

## Install

```bash
brew install --cask osaurus
```

Or download from [Releases](https://github.com/dinoki-ai/osaurus/releases/latest).

After installing, launch from Spotlight (`⌘ Space` → "osaurus") or run `osaurus ui` from the terminal.

---

## What is Osaurus?

Osaurus is an all-in-one LLM server for macOS. It combines:

- **MLX Runtime** — Optimized local inference for Apple Silicon using [MLX](https://github.com/ml-explore/mlx)
- **Remote Providers** — Connect to OpenAI, OpenRouter, Ollama, LM Studio, or any OpenAI-compatible API
- **OpenAI, Anthropic & Ollama APIs** — Drop-in compatible endpoints for existing tools
- **MCP Server** — Expose tools to AI agents via Model Context Protocol
- **Remote MCP Providers** — Connect to external MCP servers and aggregate their tools
- **Plugin System** — Extend functionality with community and custom tools
- **Developer Tools** — Built-in insights and server explorer for debugging
- **Apple Foundation Models** — Use the system model on macOS 26+ (Tahoe)

### Highlights

| Feature                  | Description                                                     |
| ------------------------ | --------------------------------------------------------------- |
| **Local LLM Server**     | Run Llama, Qwen, Gemma, Mistral, and more locally               |
| **Remote Providers**     | OpenAI, OpenRouter, Ollama, LM Studio, or custom endpoints      |
| **OpenAI Compatible**    | `/v1/chat/completions` with streaming and tool calling          |
| **Anthropic Compatible** | `/messages` endpoint for Claude Code and Anthropic SDK clients  |
| **MCP Server**           | Connect to Cursor, Claude Desktop, and other MCP clients        |
| **Remote MCP Providers** | Aggregate tools from external MCP servers                       |
| **Tools & Plugins**      | Browser automation, file system, git, web search, and more      |
| **Custom Themes**        | Create, import, and export themes with full color customization |
| **Developer Tools**      | Request insights, API explorer, and live endpoint testing       |
| **Menu Bar Chat**        | Chat overlay with session history, context tracking (`⌘;`)      |
| **Model Manager**        | Download and manage models from Hugging Face                    |

---

## Quick Start

### 1. Start the Server

Launch Osaurus from Spotlight or run:

```bash
osaurus serve
```

The server starts on port `1337` by default.

### 2. Connect an MCP Client

Add to your MCP client configuration (e.g., Cursor, Claude Desktop):

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

### 3. Add a Remote Provider (Optional)

Open the Management window (`⌘ Shift M`) → **Providers** → **Add Provider**.

Choose from presets (OpenAI, Ollama, LM Studio, OpenRouter) or configure a custom endpoint.

---

## Key Features

### Local Models (MLX)

Run models locally with optimized Apple Silicon inference:

```bash
# Download a model
osaurus run llama-3.2-3b-instruct-4bit

# Use via API
curl http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "llama-3.2-3b-instruct-4bit", "messages": [{"role": "user", "content": "Hello!"}]}'
```

### Remote Providers

Connect to any OpenAI-compatible API to access cloud models alongside local ones.

**Supported presets:**

- **OpenAI** — GPT-4o, o1, and other OpenAI models
- **OpenRouter** — Access multiple providers through one API
- **Ollama** — Connect to a local or remote Ollama instance
- **LM Studio** — Use LM Studio as a backend
- **Custom** — Any OpenAI-compatible endpoint

Features:

- Secure API key storage (macOS Keychain)
- Custom headers for authentication
- Auto-connect on launch
- Connection health monitoring

See [Remote Providers Guide](docs/REMOTE_PROVIDERS.md) for details.

### MCP Server

Osaurus is a full MCP (Model Context Protocol) server. Connect it to any MCP client to give AI agents access to your installed tools.

| Endpoint          | Description            |
| ----------------- | ---------------------- |
| `GET /mcp/health` | Check MCP availability |
| `GET /mcp/tools`  | List active tools      |
| `POST /mcp/call`  | Execute a tool         |

### Remote MCP Providers

Connect to external MCP servers and aggregate their tools into Osaurus:

- Discover and register tools from remote MCP endpoints
- Configurable timeouts and streaming
- Tools are namespaced by provider (e.g., `provider_toolname`)
- Secure token storage

See [Remote MCP Providers Guide](docs/REMOTE_MCP_PROVIDERS.md) for details.

### Tools & Plugins

Install tools from the [central registry](https://github.com/dinoki-ai/osaurus-tools) or create your own.

**Official System Tools:**

| Plugin               | Tools                                                                     |
| -------------------- | ------------------------------------------------------------------------- |
| `osaurus.filesystem` | `read_file`, `write_file`, `list_directory`, `search_files`, and more     |
| `osaurus.browser`    | `browser_navigate`, `browser_click`, `browser_type`, `browser_screenshot` |
| `osaurus.git`        | `git_status`, `git_log`, `git_diff`, `git_branch`                         |
| `osaurus.search`     | `search`, `search_news`, `search_images` (DuckDuckGo)                     |
| `osaurus.fetch`      | `fetch`, `fetch_json`, `fetch_html`, `download`                           |
| `osaurus.time`       | `current_time`, `format_date`                                             |

```bash
# Install from registry
osaurus tools install osaurus.browser

# List installed tools
osaurus tools list

# Create your own plugin
osaurus tools create MyPlugin --language swift
```

See the [Plugin Authoring Guide](docs/PLUGIN_AUTHORING.md) for details.

### Developer Tools

Built-in tools for debugging and development:

**Insights** — Monitor all API requests in real-time:

- Request/response logging with full payloads
- Filter by method (GET/POST) and source (Chat UI/HTTP API)
- Performance stats: success rate, average latency, errors
- Inference metrics: tokens, speed (tok/s), model used

**Server Explorer** — Interactive API reference:

- Live server status and health
- Browse all available endpoints
- Test endpoints directly with editable payloads
- View formatted responses

Access via Management window (`⌘ Shift M`) → **Insights** or **Server**.

See [Developer Tools Guide](docs/DEVELOPER_TOOLS.md) for details.

---

## CLI Reference

| Command                  | Description                                  |
| ------------------------ | -------------------------------------------- |
| `osaurus serve`          | Start the server (default port 1337)         |
| `osaurus serve --expose` | Start exposed on LAN                         |
| `osaurus stop`           | Stop the server                              |
| `osaurus status`         | Check server status                          |
| `osaurus ui`             | Open the menu bar UI                         |
| `osaurus list`           | List downloaded models                       |
| `osaurus run <model>`    | Interactive chat with a model                |
| `osaurus mcp`            | Start MCP stdio transport                    |
| `osaurus tools <cmd>`    | Manage plugins (install, list, search, etc.) |

**Tip:** Set `OSU_PORT` to override the default port.

---

## API Endpoints

Base URL: `http://127.0.0.1:1337` (or your configured port)

| Endpoint                    | Description                         |
| --------------------------- | ----------------------------------- |
| `GET /health`               | Server health                       |
| `GET /v1/models`            | List models (OpenAI format)         |
| `GET /v1/tags`              | List models (Ollama format)         |
| `POST /v1/chat/completions` | Chat completions (OpenAI format)    |
| `POST /messages`            | Chat completions (Anthropic format) |
| `POST /chat`                | Chat (Ollama format, NDJSON)        |

All endpoints support `/v1`, `/api`, and `/v1/api` prefixes.

See the [OpenAI API Guide](docs/OpenAI_API_GUIDE.md) for tool calling, streaming, and SDK examples.

---

## Use with OpenAI SDKs

Point any OpenAI-compatible client at Osaurus:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:1337/v1", api_key="osaurus")

response = client.chat.completions.create(
    model="llama-3.2-3b-instruct-4bit",
    messages=[{"role": "user", "content": "Hello!"}]
)
print(response.choices[0].message.content)
```

---

## Requirements

- macOS 15.5+ (Apple Foundation Models require macOS 26)
- Apple Silicon (M1 or newer)
- Xcode 16.4+ (to build from source)

Models are stored at `~/MLXModels` by default. Override with `OSU_MODELS_DIR`.

---

## Build from Source

```bash
git clone https://github.com/dinoki-ai/osaurus.git
cd osaurus
open osaurus.xcworkspace
# Build and run the "osaurus" target
```

---

## Contributing

**We're looking for contributors!** Osaurus is actively developed and we welcome help in many areas:

- Bug fixes and performance improvements
- New plugins and tool integrations
- Documentation and tutorials
- UI/UX enhancements
- Testing and issue triage

### Get Started

1. Check out [Good First Issues](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
2. Read the [Contributing Guide](docs/CONTRIBUTING.md)
3. Join our [Discord](https://discord.gg/dinoki) to connect with the team

See [docs/FEATURES.md](docs/FEATURES.md) for a complete feature inventory and architecture overview.

---

## Community

- **[Documentation](https://docs.osaurus.ai/)** — Guides and tutorials
- **[Discord](https://discord.gg/dinoki)** — Chat with the community
- **[Plugin Registry](https://github.com/dinoki-ai/osaurus-tools)** — Browse and contribute tools
- **[Contributing Guide](docs/CONTRIBUTING.md)** — How to contribute

If you find Osaurus useful, please star the repo and share it!
