# Osaurus

[![Release](https://img.shields.io/github/v/release/osaurus-ai/osaurus?sort=semver)](https://github.com/osaurus-ai/osaurus/releases)
[![Downloads](https://img.shields.io/github/downloads/osaurus-ai/osaurus/total)](https://github.com/osaurus-ai/osaurus/releases)
[![License](https://img.shields.io/github/license/osaurus-ai/osaurus)](LICENSE)
[![Stars](https://img.shields.io/github/stars/osaurus-ai/osaurus?style=social)](https://github.com/osaurus-ai/osaurus/stargazers)
![Platform](<https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-black?logo=apple>)
![OpenAI API](https://img.shields.io/badge/OpenAI%20API-compatible-0A7CFF)
![Anthropic API](https://img.shields.io/badge/Anthropic%20API-compatible-0A7CFF)
![Ollama API](https://img.shields.io/badge/Ollama%20API-compatible-0A7CFF)
![MCP Server](https://img.shields.io/badge/MCP-server-0A7CFF)
![Foundation Models](https://img.shields.io/badge/Apple%20Foundation%20Models-supported-0A7CFF)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

<p align="center">
<img width="372" height="222" alt="Screenshot 2025-12-29 at 11 14 51 AM" src="https://github.com/user-attachments/assets/ec83eba0-8819-4d2a-82b5-cbb8063ff90a" />
</p>

**Osaurus is the AI edge runtime for macOS.**

It runs local and cloud models, exposes shared tools via MCP, and provides a native, always-on foundation for AI apps and workflows on Apple Silicon.

Created by Dinoki Labs ([dinoki.ai](https://dinoki.ai))

**[Documentation](https://docs.osaurus.ai/)** · **[Discord](https://discord.gg/dinoki)** · **[Plugin Registry](https://github.com/osaurus-ai/osaurus-tools)** · **[Contributing](docs/CONTRIBUTING.md)**

---

> ⚠️ **Naming Changes in This Release** ⚠️
>
> We've renamed two core concepts to better reflect their purpose:
>
> - **Personas** are now called **Agents** — custom AI assistants with unique prompts, tools, and themes.
> - **Agent Mode** is now called **Work Mode** — autonomous task execution with issue tracking and file operations.
>
> All existing data is automatically migrated. This notice will be removed in a future release.

---

## Install

```bash
brew install --cask osaurus
```

Or download from [Releases](https://github.com/osaurus-ai/osaurus/releases/latest).

After installing, launch from Spotlight (`⌘ Space` → "osaurus") or run `osaurus ui` from the terminal.

---

## What is Osaurus?

Osaurus is the AI edge runtime for macOS. It brings together:

- **MLX Runtime** — Optimized local inference for Apple Silicon using [MLX](https://github.com/ml-explore/mlx)
- **Remote Providers** — Connect to Anthropic, OpenAI, OpenRouter, Ollama, LM Studio, or any compatible API
- **OpenAI, Anthropic & Ollama APIs** — Drop-in compatible endpoints for existing tools
- **MCP Server** — Expose tools to AI agents via Model Context Protocol
- **Remote MCP Providers** — Connect to external MCP servers and aggregate their tools
- **Plugin System** — Extend functionality with community and custom tools
- **Agents** — Create custom AI assistants with unique prompts, tools, and visual themes
- **Memory** — 4-layer memory system that learns from conversations with profile, working memory, summaries, and knowledge graph
- **Skills** — Import reusable AI capabilities from GitHub or files ([Agent Skills](https://agentskills.io/) compatible)
- **Schedules** — Automate recurring AI tasks with timed execution
- **Watchers** — Monitor folders for changes and trigger AI tasks automatically
- **Work Mode** — Autonomous task execution with issue tracking, parallel tasks, and file operations
- **Multi-Window Chat** — Multiple independent chat windows with per-window agents
- **Developer Tools** — Built-in insights and server explorer for debugging
- **Voice Input** — Speech-to-text using FluidAudio with real-time on-device transcription
- **VAD Mode** — Always-on listening with wake-word activation for hands-free agent access
- **Transcription Mode** — Global hotkey to transcribe speech directly into any app
- **Apple Foundation Models** — Use the system model on macOS 26+ (Tahoe)

### Highlights

| Feature                  | Description                                                             |
| ------------------------ | ----------------------------------------------------------------------- |
| **Local LLM Server**     | Run Llama, Qwen, Gemma, Mistral, and more locally                       |
| **Remote Providers**     | Anthropic, OpenAI, OpenRouter, Ollama, LM Studio, or custom             |
| **OpenAI Compatible**    | `/v1/chat/completions` with streaming and tool calling                  |
| **Anthropic Compatible** | `/messages` endpoint for Claude Code and Anthropic SDK clients          |
| **Open Responses**       | `/responses` endpoint for multi-provider interoperability               |
| **MCP Server**           | Connect to Cursor, Claude Desktop, and other MCP clients                |
| **Remote MCP Providers** | Aggregate tools from external MCP servers                               |
| **Tools & Plugins**      | Browser automation, file system, git, web search, and more              |
| **Skills**               | Import AI capabilities from GitHub or files, with smart context saving  |
| **Agents**               | Custom AI assistants with unique prompts, tools, and themes             |
| **Memory**               | Persistent memory with user profile, knowledge graph, and hybrid search |
| **Schedules**            | Automate AI tasks with daily, weekly, monthly, or yearly runs           |
| **Watchers**             | Monitor folders and trigger AI tasks on file system changes             |
| **Work Mode**            | Autonomous multi-step task execution with parallel task support         |
| **Custom Themes**        | Create, import, and export themes with full color customization         |
| **Developer Tools**      | Request insights, API explorer, and live endpoint testing               |
| **Multi-Window Chat**    | Multiple independent chat windows with per-window agents                |
| **Menu Bar Chat**        | Chat overlay with session history, context tracking (`⌘;`)              |
| **Voice Input**          | Speech-to-text with FluidAudio, real-time transcription                 |
| **VAD Mode**             | Always-on listening with wake-word agent activation                     |
| **Transcription Mode**   | Global hotkey to dictate into any focused text field                    |
| **Model Manager**        | Download and manage models from Hugging Face                            |

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

Choose from presets (Anthropic, OpenAI, xAI, OpenRouter) or configure a custom endpoint.

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

Connect to remote APIs to access cloud models alongside local ones.

**Supported presets:**

- **Anthropic** — Claude models with native API support
- **OpenAI** — ChatGPT models
- **xAI** — Grok models
- **OpenRouter** — Access multiple providers through one API
- **Custom** — Any OpenAI-compatible endpoint (Ollama, LM Studio, etc.)

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

Install tools from the [central registry](https://github.com/osaurus-ai/osaurus-tools) or create your own.

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

### Agents

Create custom AI assistants with unique behaviors, capabilities, and styles.

Each agent can have:

- **Custom System Prompt** — Define unique instructions and personality
- **Tool Configuration** — Enable or disable specific tools per agent
- **Visual Theme** — Assign a custom theme that activates with the agent
- **Model & Generation Settings** — Set default model, temperature, and max tokens
- **Import/Export** — Share agents as JSON files

Use cases:

- **Code Assistant** — Focused on programming with code-related tools enabled
- **Daily Planner** — Calendar and reminders integration
- **Research Helper** — Web search and note-taking tools enabled
- **Creative Writer** — Higher temperature, no tool access for pure generation

Access via Management window (`⌘ Shift M`) → **Agents**.

### Memory

Osaurus remembers what matters across conversations using a 4-layer memory system that runs entirely in the background.

**Layers:**

- **User Profile** — An auto-generated summary of who you are, updated as conversations accumulate. Add explicit overrides for facts the AI should always know.
- **Working Memory** — Structured entries (facts, preferences, decisions, corrections, commitments, relationships, skills) extracted from every conversation turn.
- **Conversation Summaries** — Compressed recaps of past sessions, generated automatically after periods of inactivity.
- **Knowledge Graph** — Entities and relationships extracted from conversations, searchable by name or relation type.

**Features:**

- **Automatic Extraction** — Memories are extracted from each conversation turn using an LLM, with no manual effort required
- **Hybrid Search** — BM25 + vector embeddings (via VecturaKit) with MMR reranking for relevant, diverse recall
- **Verification Pipeline** — 3-layer deduplication and contradiction detection prevents redundant or conflicting memories
- **Per-Agent Isolation** — Each agent maintains its own memory entries and summaries
- **Configurable Budgets** — Control token allocation for profile, working memory, summaries, and graph in the system prompt
- **Non-Blocking** — All extraction and indexing runs in the background without slowing down chat

**Use Cases:**

- Remember your coding preferences, project context, and tool choices across sessions
- Build a personal knowledge base from ongoing research conversations
- Maintain continuity with multiple agents that each learn your domain-specific needs

Access via Management window (`⌘ Shift M`) → **Memory**.

See [Memory Guide](docs/MEMORY.md) for details.

### Skills

Extend your AI with reusable capabilities imported from GitHub or local files.

**Features:**

- **Import from GitHub** — Browse skills from any repository with `marketplace.json`
- **Import from Files** — Load `.md`, `.json`, or `.zip` skill packages
- **Built-in Skills** — 6 pre-installed skills (Research Analyst, Study Tutor, etc.)
- **Custom Skills** — Create and edit skills with the built-in editor
- **Agent Skills Compatible** — Follows the open [Agent Skills](https://agentskills.io/) specification
- **Smart Loading** — Only loads selected skills to save context space

**Use cases:**

- **Research Analyst** — Structured research with source evaluation
- **Creative Brainstormer** — Ideation and creative problem solving
- **Study Tutor** — Educational guidance with Socratic method
- **Debug Assistant** — Systematic debugging methodology

Access via Management window (`⌘ Shift M`) → **Skills**.

See [Skills Guide](docs/SKILLS.md) for details.

### Schedules

Automate recurring AI tasks that run at specified intervals.

**Features:**

- **Flexible Frequency** — Once, daily, weekly, monthly, or yearly execution
- **Agent Integration** — Assign a agent to handle scheduled tasks
- **Custom Instructions** — Define prompts sent to the AI when the schedule runs
- **Manual Trigger** — Run any schedule immediately with "Run Now"
- **Results Tracking** — View the chat session from the last run

**Use Cases:**

- **Daily Journaling** — Receive prompts for reflection each morning
- **Weekly Reports** — Generate summaries on a schedule
- **Recurring Analysis** — Automate data insights at regular intervals

Access via Management window (`⌘ Shift M`) → **Schedules**.

### Watchers

Monitor folders for file system changes and automatically trigger AI tasks when files are added, modified, or removed.

**Features:**

- **Folder Monitoring** — Watch any directory for file system changes using FSEvents
- **Configurable Responsiveness** — Fast (~200ms), Balanced (~1s), or Patient (~3s) debounce timing
- **Recursive Monitoring** — Optionally monitor subdirectories
- **Agent Integration** — Assign a agent to handle triggered tasks
- **Manual Trigger** — Run any watcher immediately with "Trigger Now"
- **Convergence Loop** — Smart re-checking ensures the directory stabilizes before stopping
- **Pause/Resume** — Temporarily disable watchers without deleting them

**Use Cases:**

- **Downloads Organizer** — Automatically sort downloaded files by type into folders
- **Screenshot Manager** — Rename and organize screenshots as they're captured
- **Dropbox Automation** — Process shared files automatically when they change

Access via Management window (`⌘ Shift M`) → **Watchers**.

See [Watchers Guide](docs/WATCHERS.md) for details.

### Work Mode

Execute complex, multi-step tasks autonomously with built-in issue tracking and planning.

**Features:**

- **Issue Tracking** — Tasks broken into issues with status, priority, and dependencies
- **Parallel Tasks** — Run multiple work tasks simultaneously for increased productivity
- **Reasoning Loop** — AI autonomously observes, thinks, acts, and checks in iterative cycles
- **Working Directory** — Select a folder for file operations with project detection
- **File Operations** — Read, write, edit, search files with undo support
- **Follow-up Issues** — AI creates child issues when it discovers additional work
- **Clarification** — AI pauses to ask when tasks are ambiguous
- **Background Execution** — Tasks continue running after closing the window

**Use Cases:**

- Build features across multiple files
- Refactor codebases with tracked changes
- Debug issues with systematic investigation
- Research and documentation tasks

Access via Chat window → **Work Mode** tab.

See [Work Mode Guide](docs/WORK.md) for details.

### Multi-Window Chat

Work with multiple independent chat windows, each with its own agent and session.

**Features:**

- **Independent Windows** — Each window maintains its own agent, theme, and session
- **File → New Window** — Open additional chat windows (`⌘ N`)
- **Agent per Window** — Different agents in different windows simultaneously
- **Open in New Window** — Right-click any session in history to open in a new window
- **Pin to Top** — Keep specific windows floating above others
- **Cascading Windows** — New windows are offset so they're always visible

**Use Cases:**

- Run multiple AI agents side-by-side (e.g., "Code Assistant" and "Creative Writer")
- Compare responses from different agents
- Keep reference conversations open while starting new ones
- Organize work by project with dedicated windows

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

### Voice Input

Speech-to-text powered by [FluidAudio](https://github.com/FluidInference/FluidAudio) — fully local, private, on-device transcription.

**Features:**

- **Real-time transcription** — See your words as you speak
- **Multiple Parakeet models** — From Tiny (75 MB) to Large V3 (3 GB)
- **Microphone or system audio** — Transcribe your voice or computer audio
- **Configurable sensitivity** — Adjust for quiet or noisy environments
- **Auto-send with confirmation** — Hands-free message sending

**VAD Mode (Voice Activity Detection):**

Activate agents hands-free by saying their name or a custom wake phrase.

- Say an agent's name (e.g., "Hey Code Assistant") to open chat
- Automatic voice input starts after activation
- **Status indicators:** Blue pulsing dot on menu bar icon when listening, toggle button in popover
- Configurable silence timeout and auto-close

**Transcription Mode:**

Dictate text directly into any application using a global hotkey.

- **Global Hotkey** — Trigger transcription from anywhere on your Mac
- **Live Typing** — Text is typed into the currently focused text field in real-time
- **Accessibility Integration** — Uses macOS accessibility APIs to simulate keyboard input
- **Minimal Overlay** — Sleek floating UI shows recording status
- **Press Esc or Done** — Stop transcription when finished

Perfect for dictating emails, documents, code comments, or any text input without switching apps.

**Setup:**

1. Open Management window (`⌘ Shift M`) → **Voice**
2. Grant microphone permission
3. Download a Parakeet model
4. For **Transcription Mode**: Grant accessibility permission and configure the hotkey in the Transcription tab
5. Test your voice input

See [Voice Input Guide](docs/VOICE_INPUT.md) for details.

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
| `osaurus show <model>`   | Show metadata for a model                    |
| `osaurus run <model>`    | Interactive chat with a model                |
| `osaurus mcp`            | Start MCP stdio transport                    |
| `osaurus tools <cmd>`    | Manage plugins (install, list, search, etc.) |
| `osaurus version`        | Show version                                 |

**Tip:** Set `OSU_PORT` to override the default port.

---

## API Endpoints

Base URL: `http://127.0.0.1:1337` (or your configured port)

| Endpoint                    | Description                                |
| --------------------------- | ------------------------------------------ |
| `GET /health`               | Server health                              |
| `GET /v1/models`            | List models (OpenAI format)                |
| `GET /v1/tags`              | List models (Ollama format)                |
| `POST /v1/chat/completions` | Chat completions (OpenAI format)           |
| `POST /messages`            | Chat completions (Anthropic format)        |
| `POST /v1/responses`        | Responses (Open Responses format)          |
| `POST /chat`                | Chat (Ollama format, NDJSON)               |
| `GET /agents`               | List all agents with memory counts         |
| `POST /memory/ingest`       | Bulk-ingest conversation turns into memory |

All endpoints support `/v1`, `/api`, and `/v1/api` prefixes.

Add the `X-Osaurus-Agent-Id` header to any chat completions request to automatically inject relevant memory context. See the [Memory docs](docs/MEMORY.md#api-integration) and [API Guide](docs/OpenAI_API_GUIDE.md#memory-api) for details.

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

Speech models are stored at `~/.osaurus/fluidaudio-models`.

---

## Build from Source

```bash
git clone https://github.com/osaurus-ai/osaurus.git
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

1. Check out [Good First Issues](https://github.com/osaurus-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
2. Read the [Contributing Guide](docs/CONTRIBUTING.md)
3. Join our [Discord](https://discord.gg/dinoki) to connect with the team

See [docs/FEATURES.md](docs/FEATURES.md) for a complete feature inventory and architecture overview.

---

## Community

- **[Documentation](https://docs.osaurus.ai/)** — Guides and tutorials
- **[Discord](https://discord.gg/dinoki)** — Chat with the community
- **[Plugin Registry](https://github.com/osaurus-ai/osaurus-tools)** — Browse and contribute tools
- **[Contributing Guide](docs/CONTRIBUTING.md)** — How to contribute

If you find Osaurus useful, please star the repo and share it!
