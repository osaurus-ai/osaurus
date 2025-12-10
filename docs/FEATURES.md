# Osaurus Feature Inventory

Canonical reference for all Osaurus features, their status, and documentation.

**This file is the source of truth.** When adding or modifying features, update this inventory to keep documentation in sync.

---

## Feature Matrix

| Feature                          | Status    | README Section     | Documentation                 | Code Location                                                              |
| -------------------------------- | --------- | ------------------ | ----------------------------- | -------------------------------------------------------------------------- |
| Local LLM Server (MLX)           | Stable    | "Key Features"     | OpenAI_API_GUIDE.md           | Services/MLXService.swift, Services/ModelRuntime/                          |
| Remote Providers                 | Stable    | "Key Features"     | REMOTE_PROVIDERS.md           | Services/RemoteProviderManager.swift, Services/RemoteProviderService.swift |
| Remote MCP Providers             | Stable    | "Key Features"     | REMOTE_MCP_PROVIDERS.md       | Services/MCPProviderManager.swift, Tools/MCPProviderTool.swift             |
| MCP Server                       | Stable    | "MCP Server"       | (in README)                   | Networking/OsaurusServer.swift, Services/MCPServerManager.swift            |
| Tools & Plugins                  | Stable    | "Tools & Plugins"  | PLUGIN_AUTHORING.md           | Tools/, Managers/PluginManager.swift                                       |
| Developer Tools: Insights        | Stable    | "Developer Tools"  | DEVELOPER_TOOLS.md            | Views/InsightsView.swift, Services/InsightsService.swift                   |
| Developer Tools: Server Explorer | Stable    | "Developer Tools"  | DEVELOPER_TOOLS.md            | Views/ServerView.swift                                                     |
| Apple Foundation Models          | macOS 26+ | "What is Osaurus?" | (in README)                   | Services/FoundationModelService.swift                                      |
| Menu Bar Chat                    | Stable    | "Highlights"       | (in README)                   | Views/ChatOverlayView.swift                                                |
| Model Manager                    | Stable    | "Highlights"       | (in README)                   | Views/ModelDownloadView.swift, Services/HuggingFaceService.swift           |
| Shared Configuration             | Stable    | -                  | SHARED_CONFIGURATION_GUIDE.md | Services/SharedConfigurationService.swift                                  |
| OpenAI API Compatibility         | Stable    | "API Endpoints"    | OpenAI_API_GUIDE.md           | Networking/HTTPHandler.swift, Models/OpenAIAPI.swift                       |
| Ollama API Compatibility         | Stable    | "API Endpoints"    | (in README)                   | Networking/HTTPHandler.swift                                               |
| CLI                              | Stable    | "CLI Reference"    | (in README)                   | Packages/OsaurusCLI/                                                       |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Osaurus App                                 │
├─────────────────────────────────────────────────────────────────────────┤
│  Views Layer                                                             │
│  ├── ContentView (Menu Bar)                                              │
│  ├── ChatOverlayView (Global Hotkey Chat)                                │
│  ├── ManagementView                                                      │
│  │   ├── ModelDownloadView (Models)                                      │
│  │   ├── RemoteProvidersView (Providers)                                 │
│  │   ├── ToolsManagerView (Tools)                                        │
│  │   ├── InsightsView (Developer: Insights)                              │
│  │   ├── ServerView (Developer: Server Explorer)                         │
│  │   └── ConfigurationView (Settings)                                    │
├─────────────────────────────────────────────────────────────────────────┤
│  Services Layer                                                          │
│  ├── Inference                                                           │
│  │   ├── MLXService (Local MLX models)                                   │
│  │   ├── FoundationModelService (Apple Foundation Models)                │
│  │   ├── RemoteProviderManager (Remote OpenAI-compatible APIs)           │
│  │   └── RemoteProviderService (Per-provider connection handling)        │
│  ├── MCP                                                                 │
│  │   ├── MCPServerManager (Osaurus as MCP server)                        │
│  │   └── MCPProviderManager (Remote MCP client connections)              │
│  ├── Tools                                                               │
│  │   ├── ToolRegistry                                                    │
│  │   ├── PluginManager                                                   │
│  │   └── MCPProviderTool (Wrapped remote MCP tools)                      │
│  └── Utilities                                                           │
│      ├── InsightsService (Request logging)                               │
│      ├── HuggingFaceService (Model downloads)                            │
│      └── SharedConfigurationService                                      │
├─────────────────────────────────────────────────────────────────────────┤
│  Networking Layer                                                        │
│  ├── OsaurusServer (HTTP + MCP server)                                   │
│  ├── Router (Request routing)                                            │
│  └── HTTPHandler (OpenAI/Ollama API handlers)                            │
├─────────────────────────────────────────────────────────────────────────┤
│  CLI (OsaurusCLI Package)                                                │
│  └── Commands: serve, stop, status, ui, list, run, mcp, tools            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Feature Details

### Local LLM Server (MLX)

**Purpose:** Run language models locally with optimized Apple Silicon inference.

**Components:**

- `Services/MLXService.swift` — MLX model loading and management
- `Services/ModelRuntime/` — Generation engine, streaming, tool detection
- `Services/ModelService.swift` — Model lifecycle management

**Configuration:**

- Model storage: `~/MLXModels` (override with `OSU_MODELS_DIR`)
- Default port: `1337` (override with `OSU_PORT`)

---

### Remote Providers

**Purpose:** Connect to OpenAI-compatible APIs to access cloud models.

**Components:**

- `Models/RemoteProviderConfiguration.swift` — Provider config model
- `Services/RemoteProviderManager.swift` — Connection management
- `Services/RemoteProviderService.swift` — Per-provider API client
- `Services/RemoteProviderKeychain.swift` — Secure credential storage
- `Views/RemoteProvidersView.swift` — UI for managing providers
- `Views/Components/RemoteProviderEditSheet.swift` — Add/edit provider UI

**Presets:**
| Preset | Host | Default Port | Auth |
|--------|------|--------------|------|
| OpenAI | api.openai.com | 443 (HTTPS) | API Key |
| OpenRouter | openrouter.ai | 443 (HTTPS) | API Key |
| Ollama | localhost | 11434 | None |
| LM Studio | localhost | 1234 | None |
| Custom | (user-defined) | (user-defined) | Optional |

---

### Remote MCP Providers

**Purpose:** Connect to external MCP servers and aggregate their tools.

**Components:**

- `Models/MCPProviderConfiguration.swift` — Provider config model
- `Services/MCPProviderManager.swift` — Connection and tool discovery
- `Services/MCPProviderKeychain.swift` — Secure token storage
- `Tools/MCPProviderTool.swift` — Wrapper for remote MCP tools

**Features:**

- Automatic tool discovery on connect
- Configurable discovery and execution timeouts
- Tool namespacing (prefixed with provider name)
- Streaming support (optional)

---

### MCP Server

**Purpose:** Expose Osaurus tools to AI agents via Model Context Protocol.

**Components:**

- `Services/MCPServerManager.swift` — MCP server lifecycle
- `Networking/OsaurusServer.swift` — HTTP MCP endpoints
- `Tools/ToolRegistry.swift` — Tool registration and lookup

**Endpoints:**
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/mcp/health` | GET | Health check |
| `/mcp/tools` | GET | List available tools |
| `/mcp/call` | POST | Execute a tool |

---

### Developer Tools

**Purpose:** Built-in debugging and development utilities.

#### Insights

**Components:**

- `Services/InsightsService.swift` — Request/response logging
- `Views/InsightsView.swift` — Insights UI

**Features:**

- Real-time request logging
- Filter by method (GET/POST) and source (Chat UI/HTTP API)
- Aggregate stats: requests, success rate, avg latency, errors
- Inference metrics: tokens, speed, model, finish reason

#### Server Explorer

**Components:**

- `Views/ServerView.swift` — Server explorer UI

**Features:**

- Live server status
- Interactive endpoint catalog
- Test endpoints with editable payloads
- Formatted response viewer

---

### Tools & Plugins

**Purpose:** Extend Osaurus with custom functionality.

**Components:**

- `Tools/OsaurusTool.swift` — Tool protocol
- `Tools/ExternalTool.swift` — External plugin wrapper
- `Tools/ToolRegistry.swift` — Tool registration
- `Tools/SchemaValidator.swift` — JSON schema validation
- `Managers/PluginManager.swift` — Plugin lifecycle

**Plugin Types:**

- **System plugins** — Built-in tools (filesystem, browser, git, etc.)
- **External plugins** — Compiled binaries communicating via stdin/stdout
- **MCP provider tools** — Tools from remote MCP servers

---

## Documentation Index

| Document                                                       | Purpose                                           |
| -------------------------------------------------------------- | ------------------------------------------------- |
| [README.md](../README.md)                                      | Project overview, quick start, feature highlights |
| [FEATURES.md](FEATURES.md)                                     | Feature inventory and architecture (this file)    |
| [REMOTE_PROVIDERS.md](REMOTE_PROVIDERS.md)                     | Remote provider setup and configuration           |
| [REMOTE_MCP_PROVIDERS.md](REMOTE_MCP_PROVIDERS.md)             | Remote MCP provider setup                         |
| [DEVELOPER_TOOLS.md](DEVELOPER_TOOLS.md)                       | Insights and Server Explorer guide                |
| [PLUGIN_AUTHORING.md](PLUGIN_AUTHORING.md)                     | Creating custom plugins                           |
| [OpenAI_API_GUIDE.md](OpenAI_API_GUIDE.md)                     | API usage, tool calling, streaming                |
| [SHARED_CONFIGURATION_GUIDE.md](SHARED_CONFIGURATION_GUIDE.md) | Shared configuration for teams                    |
| [CONTRIBUTING.md](CONTRIBUTING.md)                             | Contribution guidelines                           |
| [SECURITY.md](SECURITY.md)                                     | Security policy                                   |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)                       | Community standards                               |
| [SUPPORT.md](SUPPORT.md)                                       | Getting help                                      |

---

## Updating This Inventory

When adding a new feature:

1. Add a row to the **Feature Matrix** with status, README section, documentation, and code location
2. Add a **Feature Details** section if the feature is significant
3. Update the **Architecture Overview** if the feature adds new components
4. Update the **Documentation Index** if new docs are created
5. Update the README if the feature should be highlighted

When modifying an existing feature:

1. Update the relevant row in the Feature Matrix
2. Update any affected documentation files
3. Note breaking changes in the feature's documentation

---

## Feature Status Definitions

| Status       | Meaning                             |
| ------------ | ----------------------------------- |
| Stable       | Production-ready, fully documented  |
| Beta         | Functional but API may change       |
| Experimental | Work in progress, use with caution  |
| Deprecated   | Scheduled for removal, migrate away |
| macOS 26+    | Requires macOS 26 (Tahoe) or later  |
