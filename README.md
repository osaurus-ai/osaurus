<p align="center">
<img width="1920" height="1080" alt="osaurus-techcrunch-1" src="https://github.com/user-attachments/assets/d7905005-71fe-41ba-b69f-e8968af29b5c" />
</p>

<h1 align="center">Osaurus</h1>

<p align="center">
  <strong>Own your AI.</strong><br>
  Agents, memory, tools, and identity that live on your Mac. Built purely in Swift. Fully offline. Open source.
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/22454?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-22454" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/22454" alt="osaurus-ai%2Fosaurus | Trendshift" width="250" height="55"/></a>
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
  <img src="https://img.shields.io/badge/Open%20Responses-compatible-0A7CFF" alt="Open Responses">
  <img src="https://img.shields.io/badge/Anthropic%20API-compatible-0A7CFF" alt="Anthropic API">
  <img src="https://img.shields.io/badge/Ollama%20API-compatible-0A7CFF" alt="Ollama API">
  <img src="https://img.shields.io/badge/MCP-server-0A7CFF" alt="MCP Server">
  <img src="https://img.shields.io/badge/Apple%20Foundation%20Models-supported-0A7CFF" alt="Foundation Models">
  <a href="https://huggingface.co/OsaurusAI"><img src="https://img.shields.io/badge/%F0%9F%A4%97%20Hugging%20Face-OsaurusAI-FFD21E" alt="Hugging Face"></a>
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen" alt="PRs Welcome">
</p>

<p align="center">
  <a href="https://github.com/osaurus-ai/osaurus/releases/latest/download/Osaurus.dmg">Download for Mac</a> ·
  <a href="https://huggingface.co/datasets/OsaurusAI/osaurus-releases/resolve/main/Osaurus-full.dmg">Download with Raptor 0.7 bundled (~4 GB)</a> ·
  <a href="https://docs.osaurus.ai">Docs</a> ·
  <a href="https://huggingface.co/OsaurusAI">Models</a> ·
  <a href="https://discord.gg/osaurus">Discord</a> ·
  <a href="https://x.com/OsaurusAI">Twitter</a> ·
  <a href="https://github.com/osaurus-ai/osaurus-tools">Plugin Registry</a>
</p>

---

## Why Osaurus

Models are getting cheaper, better, and more interchangeable every month. The model you use today will not be the one you use next year.

What doesn't get replaced is everything around the model: what your assistant knows about you, the tools it can use, the work it has learned to do, and the identity it acts under. That layer is what makes AI useful to you personally, and it compounds over time. Most AI products keep it on their servers, tied to their model.

Osaurus keeps it on your Mac. Your agents, memory, tools, and keys live locally, work fully offline with local models, and stay intact when you switch to a different local or cloud model. Nothing leaves your Mac unless you choose a cloud model or turn on a feature that connects out. Native Swift on Apple Silicon, no Electron, MIT licensed.

## What it does

You talk to one assistant, the **Orchestrator**. Ask in your own words and it decides how to handle the request:

- **Answers** questions directly, from what it knows or what's already in the chat.
- **Changes Osaurus for you**, like "switch my default model" or "add a provider", showing an approval card first. Nothing changes until you confirm.
- **Hands work to your team.** A fresh install comes with a small team of agents, each bound to one app or folder: **Planner** (Calendar and Reminders), **Courier** (Mail), **Keeper** (Downloads and Notes), **Scout** (the web), and, on a Mac set up for development, **Builder** (a project folder). You can rename them or create your own.
- **Uses built-in helpers** for hands-on work: **Research** (web search with sources), **Files** (your chat's working folder), **Browser** (sites you're signed in to), and **Code** (an isolated sandbox).
- **Runs workflows.** It starts one of your saved workflows when a request matches, or sketches a small one on the spot and offers to keep it if it worked.

When you first launch Osaurus, you choose how it runs: a private model on this Mac, Osaurus Cloud (nothing to download), or an AI account you already have. You can change that at any time, and your agents and memory carry over.

## What you get

- **Agents**: custom agents, each with its own prompt, model, tools, memory, working folder, and avatar. They can run on Osaurus's own [agent loop](docs/AGENT_LOOP.md) or on an external harness such as Claude Code ([Agent Runtimes](docs/HARNESS_RUNTIMES.md)). See the [Agents guide](Packages/OsaurusCore/Resources/Guide/guide-agents.md) and the [Orchestrator guide](docs/ORCHESTRATOR.md).
- **Workflows and the Architect**: typed, repeatable multi-step workflows. The built-in Architect agent designs, tests, and fixes them for you. See [Workflows](docs/WORKFLOWS.md).
- **Automations**: run a workflow, an agent, or a model on a schedule, a folder change, a webhook, or a feed. See [Automations](docs/AUTOMATIONS.md).
- **Memory and knowledge**: layered memory that stays small and relevant, plus document libraries agents can search. See [Memory](docs/MEMORY.md) and [Knowledge](docs/KNOWLEDGE.md).
- **Sandbox**: agents run code in an isolated Linux VM, with a per-agent user and home folder, on macOS 26+. See [Sandbox](docs/SANDBOX.md).
- **Browser and computer use**: a per-agent browser session, plus macOS control with per-app autonomy rules. Both are off by default. See [Browser Use](docs/BROWSER.md) and [Computer Use](docs/COMPUTER_USE.md).
- **Apple apps**: Calendar, Reminders, Contacts, Notes, Mail, Messages, Maps, Music, and Shortcuts as native tools, turned on per agent. See [Apple Apps](docs/APPLE_APPS.md).
- **Channels**: agents read and post on Discord, Slack, Telegram, iMessage, WhatsApp, Email, and n8n, with strict allowlists. See [Agent Channels](docs/AGENT_CHANNELS.md).
- **Privacy filter**: before a cloud send, an on-device classifier finds names, emails, keys, and other secrets and swaps them for placeholders. It fails closed if anything leaks. See [Privacy Filter](docs/PRIVACY_FILTER.md).
- **Identity and secure channels**: every agent has a cryptographic address, can be reached through a relay, and talks to other Osaurus agents end-to-end encrypted. See [Identity](docs/IDENTITY.md) and [Secure Channel](docs/SECURE_CHANNEL.md).
- **Devices and Workspaces**: sync chats end-to-end encrypted between your Macs and iPhone, and share agents and workflows with teammates. See [Sync](docs/SYNC.md) and [Workspaces](docs/OSAURUS_WORKSPACES.md).
- **Voice**: on-device transcription, wake word, and a system-wide dictation hotkey. See [Voice Input](docs/VOICE_INPUT.md).
- **Images**: generate and edit images on-device with local image models. See the [Images guide](Packages/OsaurusCore/Resources/Guide/guide-images.md).
- **Skills and plugins**: import [Agent Skills](https://agentskills.io/) and Claude plugins, or install native plugins from the registry. See [Skills](docs/SKILLS.md), [Claude Plugins](docs/CLAUDE_PLUGINS.md), and [Plugin Authoring](docs/plugins/README.md).
- **MCP, both ways**: Osaurus is an MCP server for other clients, and an MCP client that connects to remote MCP services with one-tap OAuth. See [Remote MCP Providers](docs/REMOTE_MCP_PROVIDERS.md).
- **Shortcuts, Spotlight, and Siri**: "Ask Osaurus" and "Run Osaurus Agent" work system-wide. See [App Intents](docs/APP_INTENTS.md).

For the full inventory, see [docs/FEATURES.md](docs/FEATURES.md).

## Models

Osaurus doesn't depend on any one model. Swap models freely and your agents, memory, and tools stay intact.

- **Local**: Gemma, Qwen, GPT-OSS, Llama, LFM, and more, running on Apple Silicon through MLX. Osaurus publishes [curated quantizations on Hugging Face](https://huggingface.co/OsaurusAI) tuned for quality per gigabyte. Models live in `~/MLXModels` (override with `OSU_MODELS_DIR`), and models already in your Hugging Face cache or LM Studio can be used in place.
- **Apple Foundation Models**: on macOS 26+ with Apple Intelligence, Apple's on-device model is available as `foundation`.
- **Cloud**: OpenAI, Anthropic, Gemini, xAI, Venice AI, OpenRouter, Ollama, LM Studio, or any endpoint that speaks the OpenAI, Anthropic, or Open Responses format. See [Remote Providers](docs/REMOTE_PROVIDERS.md).
- **Osaurus Cloud**: pay-as-you-go access through [Osaurus Router](docs/OSAURUS_ROUTER.md), with no separate provider account. Osaurus doesn't store your prompt or response content, only the usage metadata needed for billing.

## Install

```bash
brew install --cask osaurus
```

Or download a `.dmg` from [Releases](https://github.com/osaurus-ai/osaurus/releases/latest). Each release ships two builds:

- **`Osaurus-<version>.dmg`** (~70 MB) is the standard build. You pick a model during setup. Homebrew and in-app updates use this build.
- **`Osaurus-<version>-full.dmg`** (~4 GB, on [Hugging Face](https://huggingface.co/datasets/OsaurusAI/osaurus-releases)) is the same app with [Raptor 0.7](https://huggingface.co/OsaurusAI/Raptor-0.7-4B-JANG_6M) bundled, so you can chat offline right after install. Later updates use the small build. The newest stable one is always at [`Osaurus-full.dmg`](https://huggingface.co/datasets/OsaurusAI/osaurus-releases/resolve/main/Osaurus-full.dmg).

> Requires macOS 15.5+ and Apple Silicon. The sandbox VM and Apple Foundation Models need macOS 26+.

Open the chat window with the global hotkey (default `⌘;`) or from Spotlight. Settings… (`⌘,`) holds everything else. Homebrew installs the CLI; otherwise use Settings → Server → Overview → Command Line Tool → **Install CLI**:

```bash
osaurus ui       # Open the chat UI
osaurus serve    # Start the server (add --expose for LAN access)
osaurus status   # Check status
osaurus stop     # Stop the server
```

## For developers

Osaurus runs a local server with drop-in endpoints for existing tools:

| API       | Endpoint                                      |
| --------- | --------------------------------------------- |
| OpenAI    | `http://127.0.0.1:1337/v1/chat/completions`   |
| Responses | `http://127.0.0.1:1337/v1/responses`          |
| Anthropic | `http://127.0.0.1:1337/v1/messages`           |
| Ollama    | `http://127.0.0.1:1337/api/chat`              |

`/chat/completions` keeps strict OpenAI semantics: it returns `tool_calls` and your client runs them. `/v1/responses` speaks the item-based [Open Responses](https://www.openresponses.org) format, so Responses-only clients such as Codex work too. For server-side autonomous runs, use `POST /agents/{id}/run`. See the [OpenAI API Guide](docs/OpenAI_API_GUIDE.md).

To give any MCP client access to your Osaurus tools:

```json
{
  "mcpServers": {
    "osaurus": { "command": "osaurus", "args": ["mcp"] }
  }
}
```

If network exposure is on, add `"env": { "OSAURUS_MCP_ACCESS_KEY": "osk-v1..." }`.

More for developers:

- [Shared Configuration](docs/SHARED_CONFIGURATION_GUIDE.md): connecting your own macOS app to Osaurus.
- [Osaurus Bundles](docs/OSAURUS_BUNDLES.md): shipping Osaurus with your agents, skills, and MCP servers pre-installed (`osaurus import`).
- [Developer Tools](docs/DEVELOPER_TOOLS.md): Server and API Reference, and Insights.
- [Inference Runtime](docs/INFERENCE_RUNTIME.md): the scheduler, batching, and caches.

## Privacy and telemetry

Your chats, memory, agents, and configuration are stored under `~/.osaurus/` on your Mac. Storage is plaintext by default (protected by FileVault), with opt-in SQLCipher encryption; see [Storage](docs/STORAGE.md).

Osaurus collects **anonymous, aggregated usage analytics** through [Aptabase](https://aptabase.com) to understand how the app is used and where people get stuck. It never includes your chats, prompts, files, model outputs, or keys, and events aren't tied to an account or device profile. Analytics are on by default; turn them off during setup or in Settings → Privacy & Security → **Share Anonymous Usage Data**. Every event and property is listed in [Telemetry](docs/TELEMETRY.md).

### Crash reporting

Crash and app-hang reports go to [Sentry](https://sentry.io). This switch is separate from analytics, on by default, and can be turned off in Settings → Privacy & Security → **Send Crash Reports**. Reports carry crash and hang diagnostics only: no performance tracing, network breadcrumbs, screenshots, user object, or device hostname.

Source builds have both off: with no keys configured, neither SDK starts. To enable them locally, see [Telemetry in local builds](docs/CONTRIBUTING.md#telemetry-in-local-builds).

## Build from source

```bash
git lfs install
git clone https://github.com/osaurus-ai/osaurus.git
cd osaurus
open osaurus.xcworkspace
```

Build and run the `osaurus` scheme. Requires Xcode 26+ and [Git LFS](https://git-lfs.com). See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for the project layout, architecture guide, tests, and git hooks.

## Contributing

We welcome bug fixes, plugins, documentation, UI/UX improvements, and testing. Start with [Good First Issues](https://github.com/osaurus-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22), read the [Contributing Guide](docs/CONTRIBUTING.md), or join us on [Discord](https://discord.gg/osaurus).

> [!NOTE]
> **Help translate Osaurus.** We're looking for contributors to localize the app into **Spanish** and **Japanese**. These locales are already set up in Xcode, so you can start translating right away. See [docs/TRANSLATORS.md](docs/TRANSLATORS.md).

## Community

- [Discord](https://discord.gg/osaurus): chat, feedback, show-and-tell
- [Twitter](https://x.com/OsaurusAI): updates and demos
- [Hugging Face](https://huggingface.co/OsaurusAI): optimized models for Apple Silicon
- [Community Calls](https://lu.ma/osaurus): every two weeks, open to everyone
- [Blog](https://osaurus.ai/blog): long-form thinking on personal AI
- [Docs](https://docs.osaurus.ai): guides and tutorials
- [Plugin Registry](https://github.com/osaurus-ai/osaurus-tools): browse and contribute tools

## License

[MIT](LICENSE)

---

<p align="center">
  Osaurus, Inc. · <a href="https://osaurus.ai">osaurus.ai</a>
</p>
