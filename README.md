# Osaurus

[![Release](https://img.shields.io/github/v/release/dinoki-ai/osaurus?sort=semver)](https://github.com/dinoki-ai/osaurus/releases)
[![Downloads](https://img.shields.io/github/downloads/dinoki-ai/osaurus/total)](https://github.com/dinoki-ai/osaurus/releases)
[![License](https://img.shields.io/github/license/dinoki-ai/osaurus)](LICENSE)
[![Stars](https://img.shields.io/github/stars/dinoki-ai/osaurus?style=social)](https://github.com/dinoki-ai/osaurus/stargazers)
![Platform](<https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-black?logo=apple>)
![OpenAI API](https://img.shields.io/badge/OpenAI%20API-compatible-0A7CFF)
![Ollama API](https://img.shields.io/badge/Ollama%20API-compatible-0A7CFF)
![MCP Server](https://img.shields.io/badge/MCP-server-0A7CFF)
![Foundation Models](https://img.shields.io/badge/Apple%20Foundation%20Models-supported-0A7CFF)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

<p align="center">
<img width="372" height="222" alt="Screenshot 2025-12-10 at 2 50 04 PM" src="https://github.com/user-attachments/assets/a144d08d-5179-4cb1-9a01-29a8fb0b5493" />
</p>

**Native macOS LLM server with MCP support.** Run local language models on Apple Silicon with OpenAI-compatible APIs, tool calling, and a built-in plugin ecosystem.

Created by Dinoki Labs ([dinoki.ai](https://dinoki.ai))

**[Documentation](https://docs.osaurus.ai/)** · **[Discord](https://discord.gg/dinoki)** · **[Plugin Registry](https://github.com/dinoki-ai/osaurus-tools)**

---

## Install

```bash
brew install --cask osaurus
```

Or download from [Releases](https://github.com/dinoki-ai/osaurus/releases/latest).

After installing, launch from Spotlight (`⌘ Space` → "osaurus") or run `osaurus ui` from the terminal.

---

## What is Osaurus?

Osaurus is an all-in-one local LLM server for macOS. It combines:

- **MLX Runtime** — Optimized inference for Apple Silicon using [MLX](https://github.com/ml-explore/mlx)
- **OpenAI & Ollama APIs** — Drop-in compatible endpoints for existing tools
- **MCP Server** — Expose tools to AI agents via Model Context Protocol
- **Plugin System** — Extend functionality with community and custom tools
- **Apple Foundation Models** — Use the system model on macOS 26+ (Tahoe)

### Highlights

| Feature               | Description                                                |
| --------------------- | ---------------------------------------------------------- |
| **Local LLM Server**  | Run Llama, Qwen, Gemma, Mistral, and more locally          |
| **OpenAI Compatible** | `/v1/chat/completions` with streaming and tool calling     |
| **MCP Server**        | Connect to Cursor, Claude Desktop, and other MCP clients   |
| **Tools & Plugins**   | Browser automation, file system, git, web search, and more |
| **Menu Bar Chat**     | Built-in chat overlay with global hotkey (`⌘;`)            |
| **Model Manager**     | Download and manage models from Hugging Face               |

---

## MCP Server

Osaurus is a full MCP (Model Context Protocol) server. Connect it to any MCP client to give AI agents access to your installed tools.

### Setup for MCP Clients

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

The CLI proxies MCP over stdio to the running server. If Osaurus isn't running, it auto-launches.

### HTTP Endpoints

MCP is also available over HTTP on the same port:

| Endpoint          | Description            |
| ----------------- | ---------------------- |
| `GET /mcp/health` | Check MCP availability |
| `GET /mcp/tools`  | List active tools      |
| `POST /mcp/call`  | Execute a tool         |

---

## Tools & Plugins

Osaurus has a plugin system for extending functionality. Install tools from the [central registry](https://github.com/dinoki-ai/osaurus-tools) or create your own.

### Official System Tools

| Plugin               | Tools                                                                     |
| -------------------- | ------------------------------------------------------------------------- |
| `osaurus.filesystem` | `read_file`, `write_file`, `list_directory`, `search_files`, and more     |
| `osaurus.browser`    | `browser_navigate`, `browser_click`, `browser_type`, `browser_screenshot` |
| `osaurus.git`        | `git_status`, `git_log`, `git_diff`, `git_branch`                         |
| `osaurus.search`     | `search`, `search_news`, `search_images` (DuckDuckGo)                     |
| `osaurus.fetch`      | `fetch`, `fetch_json`, `fetch_html`, `download`                           |
| `osaurus.time`       | `current_time`, `format_date`                                             |

### Install Tools

```bash
# Install from registry
osaurus tools install osaurus.browser
osaurus tools install osaurus.filesystem

# Search available tools
osaurus tools search browser

# List installed tools
osaurus tools list
```

### Create Your Own

```bash
# Scaffold a new plugin
osaurus tools create MyPlugin --language swift

# Build and install locally
cd MyPlugin && swift build -c release
osaurus tools install .
```

See the [Plugin Authoring Guide](docs/PLUGIN_AUTHORING.md) for details.

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

| Endpoint                    | Description                      |
| --------------------------- | -------------------------------- |
| `GET /health`               | Server health                    |
| `GET /v1/models`            | List models (OpenAI format)      |
| `GET /v1/tags`              | List models (Ollama format)      |
| `POST /v1/chat/completions` | Chat completions (OpenAI format) |
| `POST /chat`                | Chat (Ollama format, NDJSON)     |

All endpoints support `/v1`, `/api`, and `/v1/api` prefixes.

### Quick Example

```bash
curl http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.2-3b-instruct-4bit",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

For streaming, add `"stream": true`. For Apple Foundation Models, use `"model": "foundation"`.

See the [full documentation](https://docs.osaurus.ai/) for more examples including tool calling, CORS configuration, and SDK integration.

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

## Benchmarks

20-run averages from our batch benchmark suite:

| Server      | Model                      | TTFT (ms) | Total (ms) | Chars/s | Success |
| ----------- | -------------------------- | --------- | ---------- | ------- | ------- |
| **Osaurus** | llama-3.2-3b-instruct-4bit | 87        | 1237       | 554     | 100%    |
| Ollama      | llama3.2                   | 33        | 1622       | 430     | 100%    |
| LM Studio   | llama-3.2-3b-instruct      | 113       | 1221       | 588     | 100%    |

TTFT = time to first token. See `results/` for raw data.

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

## Community

- **[Documentation](https://docs.osaurus.ai/)** — Guides and tutorials
- **[Discord](https://discord.gg/dinoki)** — Chat with the community
- **[Plugin Registry](https://github.com/dinoki-ai/osaurus-tools)** — Browse and contribute tools
- **[Contributing Guide](docs/CONTRIBUTING.md)** — How to contribute
- **[Good First Issues](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)** — Start here

If you find Osaurus useful, please star the repo and share it!
