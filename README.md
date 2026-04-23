<p align="center">
<img width="865" height="677" alt="Screenshot 2026-03-19 at 3 42 04 PM" src="https://github.com/user-attachments/assets/c16ee8bb-7f31-4659-9c2c-6eaaf8441c26" />
</p>

<h1 align="center">Osaurus</h1>

<p align="center">
  <strong>Own your AI.</strong><br>
  Agents, memory, tools, and identity that live on your Mac. Built purely in Swift. Fully offline. Open source.
</p>

<p align="center">
  <a href="https://github.com/osaurus-ai/osaurus/releases/latest"><img src="https://img.shields.io/github/v/release/osaurus-ai/osaurus?sort=semver" alt="Release"></a>
  <a href="https://github.com/osaurus-ai/osaurus/releases"><img src="https://img.shields.io/github/downloads/osaurus-ai/osaurus/total" alt="Downloads"></a>
  <a href="https://github.com/osaurus-ai/osaurus/blob/main/LICENSE"><img src="https://img.shields.io/github/license/osaurus-ai/osaurus" alt="License"></a>
  <a href="https://github.com/osaurus-ai/osaurus/stargazers"><img src="https://img.shields.io/github/stars/osaurus-ai/osaurus?style=social" alt="Stars"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-black?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/OpenAI%20API-compatible-0A7CFF" alt="OpenAI API">
  <img src="https://img.shields.io/badge/Anthropic%20API-compatible-0A7CFF" alt="Anthropic API">
  <img src="https://img.shields.io/badge/Ollama%20API-compatible-0A7CFF" alt="Ollama API">
  <img src="https://img.shields.io/badge/MCP-server-0A7CFF" alt="MCP Server">
  <img src="https://img.shields.io/badge/Apple%20Foundation%20Models-supported-0A7CFF" alt="Foundation Models">
  <a href="https://huggingface.co/OsaurusAI"><img src="https://img.shields.io/badge/%F0%9F%A4%97%20Hugging%20Face-OsaurusAI-FFD21E" alt="Hugging Face"></a>
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen" alt="PRs Welcome">
</p>

<p align="center">
  <a href="https://github.com/osaurus-ai/osaurus/releases/latest/download/Osaurus.dmg">Download for Mac</a> ·
  <a href="https://docs.osaurus.ai">Docs</a> ·
  <a href="https://huggingface.co/OsaurusAI">Models</a> ·
  <a href="https://discord.gg/osaurus">Discord</a> ·
  <a href="https://x.com/OsaurusAI">Twitter</a> ·
  <a href="https://github.com/osaurus-ai/osaurus-tools">Plugin Registry</a>
</p>

---

## Inference is all you need. Everything else can be owned by you.

Models are getting cheaper and more interchangeable by the day. What's irreplaceable is the layer around them -- your context, your memory, your tools, your identity. Others keep that layer on their servers. Osaurus keeps it on your machine.

Osaurus is the AI harness for macOS. It sits between you and any model -- local or cloud -- and provides the continuity that makes AI personal: agents that remember, execute autonomously, run real code, and stay reachable from anywhere. The models are interchangeable. The harness is what compounds.

Works fully offline with local models. Connect to any cloud provider when you want more power. Nothing leaves your Mac unless you choose.

Native Swift on Apple Silicon. No Electron. No compromises. MIT licensed.

## Install

```bash
brew install --cask osaurus
```

Or download the latest `.dmg` from [Releases](https://github.com/osaurus-ai/osaurus/releases/latest). After installing, launch from Spotlight (`⌘ Space` → "Osaurus") or the CLI:

```bash
osaurus ui       # Open the chat UI
osaurus serve    # Start the server
osaurus status   # Check status
```

> Requires macOS 15.5+ and Apple Silicon.

## Agents

Agents are the core of Osaurus. Each one gets its own prompts, memory, and visual theme -- a research assistant, a coding partner, a file organizer, whatever you need. Tools and skills are automatically selected via RAG search based on the task at hand -- no manual configuration needed. Everything else in the harness exists to make agents smarter, faster, and more capable over time.

### Agent Loop

Every chat is an agent loop. Pick a working folder and the agent gets file, search, and git tools. Toggle the sandbox and it gets shell access in an isolated Linux VM. The model writes a markdown todo list, executes against it, and closes out with a verified summary -- all in the same chat window. See the [Agent Loop Guide](docs/AGENT_LOOP.md).

### Sandbox

Agents execute code in an isolated Linux VM powered by Apple's [Containerization](https://developer.apple.com/documentation/containerization) framework. Full dev environment -- shell, Python, Node.js, compilers, package managers -- with zero risk to your Mac.

Each agent gets its own Linux user and home directory. The VM connects back to Osaurus (inference, memory, secrets) via a vsock bridge -- sandboxed but not disconnected. Extend with simple JSON plugin recipes, no Xcode or code signing required.

```
┌────────────────┐       ┌────────────────────────────┐
│    Osaurus     │       │   Linux VM (Alpine)        │
│                │       │                            │
│  Sandbox Mgr ──┼───────┤→ /workspace  (VirtioFS)    │
│  Host API   ←──┼─vsock─┤→ osaurus-host bridge       │
│                │       │                            │
│                │       │  agent-alice  (Linux user) │
│                │       │  agent-bob    (Linux user) │
└────────────────┘       └────────────────────────────┘
```

> Requires macOS 26+ (Tahoe). See the [Sandbox Guide](docs/SANDBOX.md) for configuration, built-in tools, and plugin authoring.

### Memory

Three layers -- identity, pinned facts, and per-session episodes -- plus a transcript fallback. Agents distill conversations once at session end (not on every turn), score what matters by salience, and surface at most one compact slice per request based on what you're actually asking. A background consolidator decays, merges, and evicts so memory stays sharp instead of bloating. Most turns inject ~800 tokens or less; many inject zero. See the [Memory Guide](docs/MEMORY.md).

### Identity

Every participant -- human, agent, device -- gets a secp256k1 cryptographic address. Authority flows from your master key (iCloud Keychain) down to each agent in a verifiable chain of trust. Create portable access keys (`osk-v1`), scope per-agent, revoke anytime. See [Identity docs](docs/IDENTITY.md).

### Relay

Expose agents to the internet via secure WebSocket tunnels through `agent.osaurus.ai`. Unique URL per agent based on its crypto address. No port forwarding, no ngrok, no configuration.

## Models

The harness is model-agnostic. Swap freely -- your agents, memory, and tools stay intact.

### Local

Run Gemma 4, Qwen3.6, GPT-OSS, Llama, and more on Apple Silicon with optimized MLX inference. Osaurus maintains its own [optimized model library on Hugging Face](https://huggingface.co/OsaurusAI) with curated quantizations for the best quality-to-size ratio on Apple Silicon. Models stored at `~/MLXModels` (override with `OSU_MODELS_DIR`). Fully private, fully offline.

### Liquid Foundation Models

Osaurus supports [Liquid AI's LFM](https://www.liquid.ai/models) family -- on-device models built on a non-transformer architecture optimized for edge deployment. Fast decode, low memory footprint, and strong tool calling out of the box.

### Apple Foundation Models

On macOS 26+, use Apple's on-device model as a first-class provider. Pass `model: "foundation"` in API requests. Tool calling maps through Apple's native interface automatically. Zero inference cost, fully private.

### Cloud

Connect to OpenAI, Anthropic, Gemini, xAI/Grok, [Venice AI](https://venice.ai), OpenRouter, Ollama, or LM Studio. Venice provides uncensored, privacy-focused inference with no data retention. Context and memory persist across all providers.

## MCP

Osaurus is a full MCP (Model Context Protocol) server. Give Cursor, Claude Desktop, or any MCP client access to your tools:

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

Also an MCP client -- aggregate tools from remote MCP servers into Osaurus. See the [Remote MCP Providers Guide](docs/REMOTE_MCP_PROVIDERS.md) for details.

## Tools & Plugins

```bash
osaurus tools install osaurus.browser    # Install from registry
osaurus tools list                       # List installed
osaurus tools create MyPlugin --swift    # Create a plugin
osaurus tools dev com.acme.my-plugin     # Dev with hot reload
```

20+ native plugins: Mail, Calendar, Vision, macOS Use, XLSX, PPTX, Browser, Music, Git, Filesystem, Search, Fetch, and more. Plugins support v1 (tools only) and v2 (full host API) ABIs -- register HTTP routes, serve web apps, persist data in SQLite, dispatch agent tasks, and call inference through any model. See the [Plugin Authoring Guide](docs/PLUGIN_AUTHORING.md).

## More

**Skills & Methods** -- Skills import reusable AI capabilities from GitHub repos or files, compatible with [Agent Skills](https://agentskills.io/). Methods are learned workflows that agents save and reuse over time. Both are automatically selected via RAG search -- no manual configuration needed. See [Skills Guide](docs/SKILLS.md).

**Automation** -- Schedules run recurring tasks in the background. Watchers monitor folders and trigger agents on file changes.

**Voice** -- On-device transcription via FluidAudio on Apple's Neural Engine. Voice input in chat, VAD mode with wake-word activation, and a global hotkey to transcribe into any app. No audio leaves your Mac. See [Voice Input Guide](docs/VOICE_INPUT.md).

**Developer Tools** -- Server explorer, MCP tool inspector, inference monitoring, plugin debugging. See [Developer Tools Guide](docs/DEVELOPER_TOOLS.md). For the inference scheduler, model leases, continuous-batching engine, and feature flags that tune them, see [Inference Runtime](docs/INFERENCE_RUNTIME.md).

## Compatible APIs

Drop-in endpoints for existing tools:

| API       | Endpoint                                      |
| --------- | --------------------------------------------- |
| OpenAI    | `http://127.0.0.1:1337/v1/chat/completions`   |
| Anthropic | `http://127.0.0.1:1337/anthropic/v1/messages` |
| Ollama    | `http://127.0.0.1:1337/api/chat`              |

All prefixes supported (`/v1`, `/api`, `/v1/api`). Full function calling with streaming tool call deltas. See [OpenAI API Guide](docs/OpenAI_API_GUIDE.md) for tool calling, streaming, and SDK examples. Building a macOS app that connects to Osaurus? See the [Shared Configuration Guide](docs/SHARED_CONFIGURATION_GUIDE.md).

## CLI

```bash
osaurus serve --port 1337              # Start on localhost
osaurus serve --port 1337 --expose     # Expose on LAN
osaurus ui                             # Open the chat UI
osaurus status                         # Check status
osaurus stop                           # Stop the server
```

Homebrew auto-links the CLI, or symlink manually:

```bash
ln -sf "/Applications/Osaurus.app/Contents/MacOS/osaurus" "$(brew --prefix)/bin/osaurus"
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   The Harness                       │
├──────────┬──────────┬────────────┬──────────────────┤
│ Agents   │ Memory   │ Agent Loop │ Automation       │
├──────────┴──────────┴────────────┴──────────────────┤
│              MCP Server + Client                    │
├──────────┬──────────┬───────────┬───────────────────┤
│ MLX      │ OpenAI   │ Anthropic │ Ollama / Others   │
│ Runtime  │ API      │ API       │                   │
├──────────┴──────────┴───────────┴───────────────────┤
│      Plugin System (v1 / v2 ABI) · Native Plugins   │
├──────────┬──────────┬───────────┬───────────────────┤
│ Identity │ Relay    │ Tools     │ Skills · Methods  │
├──────────┴──────────┴───────────┴───────────────────┤
│  Sandbox VM (Alpine · Apple Containerization)       │
│  vsock bridge · VirtioFS · per-agent isolation      │
└─────────────────────────────────────────────────────┘
```

Most features are accessible through the Management window (`⌘ ⇧ M`).

## Build from Source

```bash
git clone https://github.com/osaurus-ai/osaurus.git
cd osaurus
open osaurus.xcworkspace
```

Build and run the `osaurus` target. Requires Xcode 16+ and macOS 15.5+.

### Git Hooks (lefthook)

Install [lefthook](https://github.com/evilmartians/lefthook) to set up the hooks that verify quality of the code:

```bash
brew install lefthook
lefthook install
```

This installs a `pre-push` hook that runs `swift-format` over the `Packages/` directory before each push.

## Project Structure

```
osaurus/
├── App/                          # macOS app target (SwiftUI entry point, assets, entitlements)
├── Packages/
│   ├── OsaurusCore/              # Core library — all app logic
│   │   ├── Models/               # Data types, DTOs, configuration stores
│   │   ├── Services/             # Business logic (actors and stateless types)
│   │   ├── Managers/             # UI-facing state holders (@MainActor, observable)
│   │   ├── Views/                # SwiftUI views, organized by feature
│   │   ├── Networking/           # HTTP server, routing, relay
│   │   ├── Storage/              # SQLite databases
│   │   ├── Identity/             # Cryptographic identity and access keys
│   │   ├── Tools/                # MCP tools, plugin ABI, tool registry
│   │   ├── Folder/               # Working-folder context, file ops, batch tool
│   │   ├── Utils/                # Cross-cutting utilities
│   │   └── Tests/                # Unit and integration tests
│   ├── OsaurusCLI/               # CLI (osaurus command)
│   └── OsaurusRepository/        # Plugin registry and installation
├── docs/                         # Feature guides and documentation
├── scripts/                      # Build, release, and benchmark scripts
├── sandbox/                      # Sandbox VM Dockerfile
└── assets/                       # DMG packaging assets
```

See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for the architecture guide and layer definitions.

## Contributing

Osaurus is actively developed and we welcome contributions: bug fixes, new plugins, documentation, UI/UX improvements, and testing.

Check out [Good First Issues](https://github.com/osaurus-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22), read the [Contributing Guide](CONTRIBUTING.md), or join [Discord](https://discord.gg/osaurus). See [docs/FEATURES.md](docs/FEATURES.md) for the full feature inventory.

## Community

- [Discord](https://discord.gg/osaurus) -- chat, feedback, show-and-tell
- [Twitter](https://x.com/OsaurusAI) -- updates and demos
- [Hugging Face](https://huggingface.co/OsaurusAI) -- optimized models for Apple Silicon
- [Community Calls](https://lu.ma/osaurus) -- bi-weekly, open to everyone
- [Blog](https://osaurus.ai/blog) -- long-form thinking on personal AI
- [Docs](https://docs.osaurus.ai) -- guides and tutorials
- [Plugin Registry](https://github.com/osaurus-ai/osaurus-tools) -- browse and contribute tools

## License

[MIT](LICENSE)

---

<p align="center">
  Osaurus, Inc. · <a href="https://osaurus.ai">osaurus.ai</a>
</p>
