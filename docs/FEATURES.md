# Osaurus Feature Inventory

Canonical reference for all Osaurus features, their status, and documentation.

**This file is the source of truth.** When adding or modifying features, update this inventory to keep documentation in sync.

---

## Feature Matrix

| Feature                          | Status    | README Section     | Documentation                 | Code Location                                                                         |
| -------------------------------- | --------- | ------------------ | ----------------------------- | ------------------------------------------------------------------------------------- |
| Local LLM Server (MLX)           | Stable    | "Key Features"     | OpenAI_API_GUIDE.md           | Services/Inference/MLXService.swift, Services/ModelRuntime/                                     |
| Remote Providers                 | Stable    | "Key Features"     | REMOTE_PROVIDERS.md           | Managers/RemoteProviderManager.swift, Services/Provider/RemoteProviderService.swift            |
| Remote MCP Providers             | Stable    | "Key Features"     | REMOTE_MCP_PROVIDERS.md       | Managers/MCPProviderManager.swift, Tools/MCPProviderTool.swift                        |
| MCP Server                       | Stable    | "MCP Server"       | (in README)                   | Networking/OsaurusServer.swift, Services/MCP/MCPServerManager.swift                       |
| Tools & Plugins                  | Stable    | "Tools & Plugins"  | PLUGIN_AUTHORING.md           | Tools/, Managers/Plugin/PluginManager.swift, Services/Plugin/PluginHostAPI.swift, Storage/PluginDatabase.swift, Models/Plugin/PluginHTTP.swift, Views/Plugin/PluginConfigView.swift |
| Skills                           | Stable    | "Skills"           | SKILLS.md                     | Managers/SkillManager.swift, Views/Skill/SkillsView.swift, Services/Skill/SkillSearchService.swift |
| Methods                          | Stable    | "Skills & Methods" | SKILLS.md                     | Models/Method/Method.swift, Services/Method/MethodService.swift, Services/Method/MethodSearchService.swift, Storage/MethodDatabase.swift |
| Context Management               | Stable    | -                  | SKILLS.md                     | Services/Context/PreflightCapabilitySearch.swift, Tools/CapabilityTools.swift, Services/Tool/ToolSearchService.swift, Services/Tool/ToolIndexService.swift |
| Memory                           | Stable    | "Key Features"     | MEMORY.md                     | Services/Memory/MemoryService.swift, Services/Memory/MemorySearchService.swift, Services/Memory/MemoryContextAssembler.swift |
| Agents                         | Stable    | "Agents"         | (in README)                   | Managers/AgentManager.swift, Models/Agent/Agent.swift, Views/Agent/AgentsView.swift         |
| Schedules                        | Stable    | "Schedules"        | (in README)                   | Managers/ScheduleManager.swift, Models/Schedule/Schedule.swift, Views/Schedule/SchedulesView.swift      |
| Watchers                         | Stable    | "Watchers"         | WATCHERS.md                   | Managers/WatcherManager.swift, Models/Watcher/Watcher.swift, Views/Watcher/WatchersView.swift         |
| Agent Loop & Folder Context      | Stable    | "Agent Loop"       | AGENT_LOOP.md                 | Folder/, Tools/AgentLoopTools.swift, Tools/FolderToolManager.swift, Models/Chat/AgentTodo.swift, Models/Chat/AgentTodoStore.swift, Models/Chat/SharedArtifact.swift |
| Developer Tools: Insights        | Stable    | "Developer Tools"  | DEVELOPER_TOOLS.md            | Views/Insights/InsightsView.swift, Managers/InsightsService.swift                              |
| Developer Tools: Server Explorer | Stable    | "Developer Tools"  | DEVELOPER_TOOLS.md            | Views/Settings/ServerView.swift                                                                |
| Apple Foundation Models          | macOS 26+ | "What is Osaurus?" | (in README)                   | Services/Inference/FoundationModelService.swift                                                 |
| Menu Bar Chat                    | Stable    | "Highlights"       | (in README)                   | Views/Chat/ChatView.swift, Views/ChatOverlayView.swift                                     |
| Chat Session Management          | Stable    | "Highlights"       | (in README)                   | Managers/Chat/ChatSessionsManager.swift, Models/Chat/ChatSessionData.swift                      |
| Custom Themes                    | Stable    | "Highlights"       | (in README)                   | Views/Theme/ThemesView.swift, Views/Theme/ThemeEditorView.swift                        |
| Model Manager                    | Stable    | "Highlights"       | (in README)                   | Views/Model/ModelDownloadView.swift, Services/HuggingFaceService.swift                      |
| Shared Configuration             | Stable    | -                  | SHARED_CONFIGURATION_GUIDE.md | Services/SharedConfigurationService.swift                                             |
| OpenAI API Compatibility         | Stable    | "API Endpoints"    | OpenAI_API_GUIDE.md           | Networking/HTTPHandler.swift, Models/API/OpenAIAPI.swift                                  |
| Anthropic API Compatibility      | Stable    | "API Endpoints"    | (in README)                   | Networking/HTTPHandler.swift, Models/API/AnthropicAPI.swift                               |
| Open Responses API               | Stable    | "API Endpoints"    | OpenAI_API_GUIDE.md           | Networking/HTTPHandler.swift, Models/API/OpenResponsesAPI.swift                           |
| Ollama API Compatibility         | Stable    | "API Endpoints"    | (in README)                   | Networking/HTTPHandler.swift                                                          |
| Voice Input (FluidAudio)         | Stable    | "Voice Input"      | VOICE_INPUT.md                | Managers/SpeechService.swift, Managers/Model/SpeechModelManager.swift                  |
| VAD Mode                         | Stable    | "Voice Input"      | VOICE_INPUT.md                | Services/Voice/VADService.swift, Views/ContentView.swift (VAD controls)                     |
| Transcription Mode               | Stable    | "Voice Input"      | VOICE_INPUT.md                | Services/Voice/TranscriptionModeService.swift, Views/Voice/TranscriptionOverlayView.swift         |
| Sandbox                          | macOS 26+ | "Sandbox"          | SANDBOX.md                    | Services/Sandbox/SandboxManager.swift, Tools/BuiltinSandboxTools.swift, Managers/Plugin/SandboxPluginManager.swift, Views/Sandbox/SandboxView.swift |
| CLI                              | Stable    | "CLI Reference"    | (in README)                   | Packages/OsaurusCLI/                                                                  |

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
│  │   ├── ToolsManagerView (Tools & Plugin Config)                        │
│  │   ├── AgentsView (Agents)                                         │
│  │   ├── SkillsView (Skills)                                             │
│  │   ├── MemoryView (Memory)                                             │
│  │   ├── SchedulesView (Schedules)                                       │
│  │   ├── WatchersView (Watchers)                                         │
│  │   ├── ThemesView (Themes)                                             │
│  │   ├── SandboxView (Sandbox Container & Plugins)                       │
│  │   ├── InsightsView (Developer: Insights)                              │
│  │   ├── ServerView (Developer: Server Explorer)                         │
│  │   ├── VoiceView (Voice Input & VAD Settings)                          │
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
│  │   ├── PluginHostAPI (v2 host callbacks: config, db, log)              │
│  │   ├── PluginDatabase (Sandboxed per-plugin SQLite)                    │
│  │   └── MCPProviderTool (Wrapped remote MCP tools)                      │
│  ├── Agents                                                            │
│  │   └── AgentManager (Agent lifecycle and active agent)           │
│  ├── Skills                                                              │
│  │   ├── SkillManager (Skill CRUD and loading)                           │
│  │   ├── SkillSearchService (RAG-based skill search)                     │
│  │   └── GitHubSkillService (GitHub import)                              │
│  ├── Methods                                                             │
│  │   ├── MethodService (Method CRUD and scoring)                         │
│  │   └── MethodSearchService (RAG-based method search)                   │
│  ├── Context                                                             │
│  │   ├── PreflightCapabilitySearch (Automated pre-flight RAG search)     │
│  │   ├── ToolSearchService (RAG-based tool search)                       │
│  │   └── ToolIndexService (Tool registry sync and indexing)              │
│  ├── Scheduling                                                          │
│  │   └── ScheduleManager (Schedule lifecycle and execution)              │
│  ├── Watchers                                                            │
│  │   ├── WatcherManager (FSEvents monitoring and convergence loop)       │
│  │   ├── WatcherStore (Watcher persistence)                              │
│  │   └── DirectoryFingerprint (Change detection via Merkle hashing)      │
│  ├── Folder Tools                                                        │
│  │   ├── FolderContextService (Working folder + security-scoped bookmarks) │
│  │   ├── FolderToolManager (Registers folder tools when folder selected) │
│  │   ├── FolderToolFactory (Builds file/coding/git tools per project)    │
│  │   └── FileOperationLog (Logs writes/exec for undo support)            │
│  ├── Sandbox                                                             │
│  │   ├── SandboxManager (Container lifecycle and exec)                   │
│  │   ├── SandboxPluginManager (Per-agent plugin install/uninstall)       │
│  │   ├── SandboxToolRegistrar (Tool registration on status change)       │
│  │   ├── HostAPIBridgeServer (Vsock bridge to host services)             │
│  │   ├── SandboxLogBuffer (Ring buffer for container logs)               │
│  │   └── SandboxSecurity (Path sanitization, network, rate limiting)     │
│  ├── Voice/Audio                                                         │
│  │   ├── SpeechService (Speech-to-text transcription)                    │
│  │   ├── SpeechModelManager (Parakeet model downloads)                    │
│  │   ├── VADService (Voice activity detection, wake-word)                │
│  │   ├── TranscriptionModeService (Global dictation into any app)        │
│  │   └── AudioInputManager (Microphone/system audio selection)           │
│  ├── Memory                                                              │
│  │   ├── MemoryService (Buffer-and-distill pipeline)                     │
│  │   ├── MemoryRelevanceGate (Decides whether memory is needed)          │
│  │   ├── MemoryPlanner (Picks one section under budget)                  │
│  │   ├── MemoryConsolidator (Background decay + merge + evict)           │
│  │   ├── MemorySearchService (Hybrid BM25 + vector search)               │
│  │   ├── MemoryContextAssembler (Gate + planner facade)                  │
│  │   └── MemoryDatabase (SQLite storage with migrations)                 │
│  └── Utilities                                                           │
│      ├── InsightsService (Request logging)                               │
│      ├── HuggingFaceService (Model downloads)                            │
│      └── SharedConfigurationService                                      │
├─────────────────────────────────────────────────────────────────────────┤
│  Networking Layer                                                        │
│  ├── OsaurusServer (HTTP + MCP server)                                   │
│  ├── Router (Request routing)                                            │
│  └── HTTPHandler (OpenAI/Anthropic/Ollama API handlers)                  │
├─────────────────────────────────────────────────────────────────────────┤
│  CLI (OsaurusCLI Package)                                                │
│  └── Commands: serve, stop, status, ui, list, show, run, mcp, tools (install, dev, ...), version │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Feature Details

### Local LLM Server (MLX)

**Purpose:** Run language models locally with optimized Apple Silicon inference.

**Components:**

- `Services/Inference/MLXService.swift` — MLX model loading, warm-up orchestration
- `Services/ModelRuntime/` — Single MLX entry point (`MLXBatchAdapter`) wrapping vmlx-swift-lm's `BatchEngine`, plus the `GenerationEventMapper` bridge to typed runtime events
- `Services/Inference/ModelService.swift` — Model lifecycle management

**Runtime behavior:**

- **Window-scoped warm-up** — Models are loaded and prefix-cached when a chat window opens, not at app launch. Each window warms its own model independently, using the window's agent context (system prompt, memory, tools) for the prefix cache.
- **Smart unloading** — When a user switches to a remote model or closes a window, a GC pass checks all open windows and unloads any local model no longer referenced. The warm-up indicator (yellow dot) signals when a model is loading.
- **Continuous batching** — `BatchEngine` shares a single forward pass across overlapping requests for the same model. The default `mlxBatchEngineMaxBatchSize` is `4`; tune with `defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize -int 8`.
- **Library-managed KV cache** — vmlx-swift-lm's `CacheCoordinator` owns KV cache geometry (paged for global attention, rotating for sliding-window, SSM state for Mamba) sized per-model. Multi-turn KV reuse, mediaSalt for VLMs, and sliding-window correctness are all handled inside the engine — osaurus configures only `modelKey`, `diskCacheDir`, and a writability fallback.
- **Model eviction policy** — Configurable in Settings > Local Inference > Model Management. "Strict (One Model)" keeps only one model loaded (default). "Flexible (Multi Model)" allows concurrent models for high-RAM systems.

**Configuration:**

- Model storage: `~/MLXModels` (override with `OSU_MODELS_DIR`)
- Default port: `1337` (override with `OSU_PORT`)
- KV cache disk storage: `~/.osaurus/cache/kv/`
- Settings: Top P, eviction policy, allowed origins.
- One advanced tunable, exposed via `defaults` only: `ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize` (default `4`, clamped to `[1, 32]`).

See [INFERENCE_RUNTIME.md](./INFERENCE_RUNTIME.md) for the full runtime architecture.

---

### Remote Providers

**Purpose:** Connect to OpenAI-compatible APIs to access cloud models.

**Components:**

- `Models/Configuration/RemoteProviderConfiguration.swift` — Provider config model
- `Managers/RemoteProviderManager.swift` — Connection management
- `Services/Provider/RemoteProviderService.swift` — Per-provider API client
- `Services/Provider/RemoteProviderKeychain.swift` — Secure credential storage
- `Views/Settings/RemoteProvidersView.swift` — UI for managing providers
- `Views/Settings/RemoteProviderEditSheet.swift` — Add/edit provider UI

**Presets:**
| Preset | Host | Default Port | Auth |
|--------|------|--------------|------|
| Anthropic | api.anthropic.com | 443 (HTTPS) | API Key |
| OpenAI | api.openai.com | 443 (HTTPS) | API Key |
| xAI | api.x.ai | 443 (HTTPS) | API Key |
| OpenRouter | openrouter.ai | 443 (HTTPS) | API Key |
| Custom | (user-defined) | (user-defined) | Optional |

---

### Remote MCP Providers

**Purpose:** Connect to external MCP servers and aggregate their tools.

**Components:**

- `Models/Configuration/MCPProviderConfiguration.swift` — Provider config model
- `Managers/MCPProviderManager.swift` — Connection and tool discovery
- `Services/MCP/MCPProviderKeychain.swift` — Secure token storage
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

- `Services/MCP/MCPServerManager.swift` — MCP server lifecycle
- `Networking/OsaurusServer.swift` — HTTP MCP endpoints
- `Tools/ToolRegistry.swift` — Tool registration and lookup
- `Tools/ToolEnvelope.swift` — Canonical success/failure envelope every tool returns (see [Tool Contract](TOOL_CONTRACT.md))
- `Tools/SchemaValidator.swift` — Argument validator with `additionalProperties` enforcement

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

- `Managers/InsightsService.swift` — Request/response logging
- `Views/Insights/InsightsView.swift` — Insights UI

**Features:**

- Real-time request logging
- Filter by method (GET/POST) and source (Chat UI/HTTP API)
- Aggregate stats: requests, success rate, avg latency, errors
- Inference metrics: tokens, speed, model, finish reason

#### Server Explorer

**Components:**

- `Views/Settings/ServerView.swift` — Server explorer UI

**Features:**

- Live server status
- Interactive endpoint catalog
- Test endpoints with editable payloads
- Formatted response viewer

---

### Anthropic API Compatibility

**Purpose:** Provide Anthropic Messages API compatibility for Claude Code and other Anthropic SDK clients.

**Components:**

- `Models/API/AnthropicAPI.swift` — Anthropic request/response models
- `Models/Chat/ResponseWriters.swift` — SSE streaming for Anthropic format
- `Networking/HTTPHandler.swift` — `/messages` endpoint handler

**Features:**

- Full Messages API support (`/messages` endpoint)
- Streaming and non-streaming responses
- Tool use (function calling) support
- Converts internally to OpenAI format for unified processing

---

### Open Responses API

**Purpose:** Provide [Open Responses](https://www.openresponses.org) API compatibility for multi-provider interoperability.

**Components:**

- `Models/API/OpenResponsesAPI.swift` — Open Responses request/response models and streaming events
- `Models/Chat/ResponseWriters.swift` — SSE streaming for Open Responses format
- `Networking/HTTPHandler.swift` — `/responses` endpoint handler
- `Services/Provider/RemoteProviderService.swift` — Remote Open Responses provider support

**Features:**

- Full Responses API support (`/responses` endpoint)
- Streaming with semantic events (`response.output_text.delta`, `response.completed`, etc.)
- Non-streaming responses
- Tool/function calling support
- Input as simple string or structured items
- Instructions (system prompt) support
- Connect to remote Open Responses-compatible providers

**Streaming Events:**

| Event                                    | Description                                |
| ---------------------------------------- | ------------------------------------------ |
| `response.created`                       | Response object created                    |
| `response.in_progress`                   | Generation started                         |
| `response.output_item.added`             | New output item (message or function call) |
| `response.output_text.delta`             | Text content delta                         |
| `response.output_text.done`              | Text content completed                     |
| `response.function_call_arguments.delta` | Function arguments delta                   |
| `response.output_item.done`              | Output item completed                      |
| `response.completed`                     | Response finished                          |

---

### Custom Themes

**Purpose:** Customize the chat interface appearance with custom color schemes and styling.

**Components:**

- `Views/Theme/ThemesView.swift` — Theme gallery and management
- `Views/Theme/ThemeEditorView.swift` — Full theme editor
- `Models/Theme/CustomTheme.swift` — Theme data model
- `Models/Theme/ThemeConfigurationStore.swift` — Theme persistence
- `Models/Theme/Theme.swift` — Theme protocol and built-in themes

**Features:**

- Built-in light and dark themes
- Create custom themes with full color customization
- Import/export themes as JSON files
- Live preview while editing
- Background options: solid, gradient, or image

---

### Agents

**Purpose:** Create custom AI assistants with unique behaviors, capabilities, and visual styles.

**Components:**

- `Models/Agent/Agent.swift` — Agent data model with export/import support
- `Models/Agent/AgentStore.swift` — Agent persistence (JSON files)
- `Managers/AgentManager.swift` — Agent lifecycle and active agent management
- `Views/Agent/AgentsView.swift` — Agent gallery and management UI

**Features:**

- **Custom System Prompts** — Define unique instructions for each agent
- **Automated Capabilities** — Tools, skills, and methods are automatically selected via RAG search based on the task
- **Visual Themes** — Assign a custom theme that activates with the agent
- **Generation Settings** — Configure default model, temperature, and max tokens
- **Import/Export** — Share agents as JSON files for backup or sharing
- **Live Switching** — Click to activate a agent, theme updates automatically

**Agent Properties:**
| Property | Description |
|----------|-------------|
| `name` | Display name (required) |
| `description` | Brief description of the agent |
| `systemPrompt` | Instructions prepended to all chats |
| `themeId` | Optional custom theme to apply |
| `defaultModel` | Optional model ID for this agent |
| `temperature` | Optional temperature override |
| `maxTokens` | Optional max tokens override |

---

### Schedules

**Purpose:** Automate recurring AI tasks that run at specified intervals.

**Components:**

- `Models/Schedule/Schedule.swift` — Schedule data model with frequency types
- `Models/Schedule/ScheduleStore.swift` — Schedule persistence (JSON files)
- `Managers/ScheduleManager.swift` — Schedule lifecycle, timer management, and execution
- `Views/Schedule/SchedulesView.swift` — Schedule management UI

**Features:**

- **Frequency Options** — Once (specific date/time), Daily, Weekly, Monthly, Yearly
- **Agent Integration** — Optionally assign a agent to handle the scheduled task
- **Custom Instructions** — Define the prompt sent to the AI when the schedule runs
- **Enable/Disable** — Toggle schedules on or off without deleting
- **Manual Trigger** — "Run Now" option to execute a schedule immediately
- **Results Tracking** — Links to the chat session from the last run
- **Next Run Display** — Shows when the schedule will next execute
- **Timezone Aware** — Automatically adjusts for system timezone changes

**Schedule Properties:**

| Property            | Description                                  |
| ------------------- | -------------------------------------------- |
| `name`              | Display name (required)                      |
| `instructions`      | Prompt sent to the AI when the schedule runs |
| `agentId`         | Optional agent to use for the chat         |
| `frequency`         | When and how often to run                    |
| `isEnabled`         | Whether the schedule is active               |
| `lastRunAt`         | When the schedule last ran                   |
| `lastChatSessionId` | Chat session ID from the last run            |

**Frequency Types:**

| Type    | Description                          | Example                          |
| ------- | ------------------------------------ | -------------------------------- |
| Once    | Run once at a specific date and time | "Jan 15, 2025 at 9:00 AM"        |
| Daily   | Run every day at a specific time     | "Daily at 8:00 AM"               |
| Weekly  | Run on a specific day each week      | "Every Monday at 9:00 AM"        |
| Monthly | Run on a specific day each month     | "Monthly on the 1st at 10:00 AM" |
| Yearly  | Run on a specific date each year     | "Yearly on Jan 1st at 12:00 PM"  |

---

### Watchers

**Purpose:** Monitor folders for file system changes and automatically trigger AI agent tasks.

**Components:**

- `Models/Watcher/Watcher.swift` — Watcher data model
- `Models/Watcher/WatcherStore.swift` — Watcher persistence (JSON files)
- `Managers/WatcherManager.swift` — FSEvents monitoring, debouncing, and convergence loop
- `Services/DirectoryFingerprint.swift` — Merkle hash-based change detection
- `Views/Watcher/WatchersView.swift` — Watcher management UI

**Features:**

- **Folder Monitoring** — Watch any directory using FSEvents with a single shared stream
- **Configurable Responsiveness** — Fast (~200ms), Balanced (~1s), or Patient (~3s) debounce
- **Recursive Monitoring** — Optionally monitor subdirectories
- **Agent Integration** — Assign a agent to handle triggered tasks
- **Enable/Disable** — Toggle watchers on or off without deleting
- **Manual Trigger** — "Trigger Now" option to run a watcher immediately
- **Convergence Loop** — Re-checks directory fingerprint after agent completes; loops until stable (max 5 iterations)
- **Smart Exclusion** — Automatically excludes nested watched folders to prevent conflicts

**Watcher Properties:**

| Property         | Description                                        |
| ---------------- | -------------------------------------------------- |
| `name`           | Display name (required)                            |
| `instructions`   | Prompt sent to the AI when changes are detected    |
| `watchedFolder`  | Directory to monitor (security-scoped bookmark)    |
| `agentId`      | Optional agent to use for the task               |
| `isEnabled`      | Whether the watcher is active                      |
| `recursive`      | Whether to monitor subdirectories (default: false) |
| `responsiveness` | Debounce timing: fast, balanced, or patient        |
| `lastTriggeredAt`| When the watcher last ran                          |
| `lastChatSessionId` | Chat session ID from the last run               |

**Responsiveness Options:**

| Option   | Debounce Window | Best For                                  |
| -------- | --------------- | ----------------------------------------- |
| Fast     | ~200ms          | Screenshots, single-file drops            |
| Balanced | ~1s             | General use (default)                     |
| Patient  | ~3s             | Downloads, batch operations               |

**Change Detection:**

- FSEvents detects file system events across all enabled watchers
- Directory fingerprinting uses a Merkle hash of file metadata (path + size + modification time)
- Only stat() calls are used — no file content is read during detection
- Convergence loop ensures the agent doesn't run unnecessarily after self-caused changes

**State Machine:**

| State       | Description                                     |
| ----------- | ----------------------------------------------- |
| `idle`      | Waiting for file system changes                 |
| `debouncing`| Coalescing rapid events within the debounce window |
| `processing`| Agent task is running                           |
| `settling`  | Waiting for self-caused FSEvents to flush       |

**Storage:** `~/.osaurus/watchers/{uuid}.json`

---

### Agent Loop & Folder Context

**Purpose:** Drive every chat as an agent loop. The model writes a markdown todo, calls tools (file, sandbox, MCP, plugin), and ends the loop with a verified `complete` summary or pauses with `clarify`. Selecting a working folder turns on file/git tools; toggling the sandbox swaps in Linux exec.

**Components:**

- `Tools/AgentLoopTools.swift` — The three chat-layer-intercepted loop tools (`todo`, `complete`, `clarify`); registered as global built-ins
- `Tools/FolderToolManager.swift` — Registers folder tools when a working folder is selected; unregisters on clear. `share_artifact` is no longer registered here — it lives as a global built-in alongside the loop tools.
- `Folder/FolderContext.swift` — Project type, file tree, manifest, git status, optional `AGENTS.md`/`CLAUDE.md`/`.cursorrules`
- `Folder/FolderContextService.swift` — `NSOpenPanel`, security-scoped bookmark persistence, MainActor service
- `Folder/FolderTools.swift` — File/coding/git tool implementations + `FolderToolFactory`
- `Folder/BatchTool.swift` — Generic `batch` tool that fans out up to 30 registered ops in one call
- `Folder/ChatExecutionContext.swift` — TaskLocal session/agent/batch IDs read by tools at execution time
- `Folder/ExecutionMode.swift` — First-class `.hostFolder | .sandbox | .none` enum
- `Folder/FileOperation.swift`, `Folder/FileOperationLog.swift` — Per-op log used for undo
- `Models/Chat/AgentTodo.swift`, `Models/Chat/AgentTodoStore.swift` — Markdown checklist parser + per-session store
- `Models/Chat/SharedArtifact.swift` — Artifact model surfaced via `share_artifact`

**Features:**

- **Unified loop** — One chat is one task; no separate Agent/Work tab
- **`todo` / `complete` / `clarify`** — Three minimal-schema global built-in tools whose results the chat layer intercepts to drive the inline UI (not a pre-dispatch hook — the registry runs them like any other tool)
- **Single mode resolver** — `ToolRegistry.resolveExecutionMode(folderContext:autonomousEnabled:)` decides sandbox > host folder > none for chat, plugin, and HTTP entry points
- **Working folder picker** — Per-chat folder via `FolderContextService`, with security-scoped bookmark persistence
- **Project-aware tools** — File/coding/git tools registered automatically when a folder is selected; tool kit varies by project type and git status
- **Sandbox toggle** — Mutually exclusive with the working-folder backend; selecting a folder disables sandbox autonomous exec and vice versa
- **`batch` tool** — Up to 30 ops per call, continues on error, denies `shell_run` / `git_commit` / nested `batch`
- **`share_artifact`** — Only path for the user to see files the agent produced
**Loop Tools (engine-intercepted):**

| Tool       | Required field | Behavior                                                                                |
| ---------- | -------------- | --------------------------------------------------------------------------------------- |
| `todo`     | `markdown`     | Replace the per-session checklist (markdown `- [ ]` / `- [x]`). No merging.             |
| `complete` | `summary`      | End the loop with a verified one-paragraph summary. Placeholders / short text rejected. |
| `clarify`  | `question` (+ optional `options[]`, `allowMultiple`) | Pause and surface a single critical question in a bottom-pinned overlay; user's answer (typed or chip-tap) dispatches as the next user turn. |

**Folder Tool Inventory:**

| Tool              | Category | Description                                                       |
| ----------------- | -------- | ----------------------------------------------------------------- |
| `file_tree`       | Core     | Directory structure with project-aware ignore patterns            |
| `file_read`       | Core     | Read with line ranges or tail mode                                |
| `file_write`      | Core     | Create or overwrite                                               |
| `file_edit`       | Coding   | Surgical exact-string replacement                                 |
| `file_search`     | Coding   | ripgrep-style search                                              |
| `file_move`       | Core     | Move or rename                                                    |
| `file_copy`       | Core     | Duplicate                                                         |
| `file_delete`     | Core     | Remove                                                            |
| `dir_create`      | Core     | Create directories                                                |
| `batch`           | Core     | Run up to 30 ops in sequence; reports per-op results              |
| `shell_run`       | Coding   | Run a shell command (requires approval). Registered when project type detected. |
| `git_status`      | Git      | Repository status. Registered when `.git` present.                |
| `git_diff`        | Git      | Show diffs                                                        |
| `git_commit`      | Git      | Stage + commit (requires approval)                                |

**Workflow:**

1. User opens or focuses a chat; selects a working folder or sandbox via the input bar (optional).
2. System prompt composer assembles base prompt + memory + folder context + tool guidance using the active `ExecutionMode`.
3. Agent calls `todo` to publish the plan, then calls tools to execute.
4. Each tool result feeds back into the next iteration (max iterations governed by `chatConfig.maxToolAttempts`).
5. Agent calls `complete(summary)` to end the loop, or `clarify(question)` to pause for input.

**Storage:**

- Folder bookmark — UserDefaults (`FolderContextBookmark`)
- Artifacts — `~/.osaurus/artifacts/<sessionId>/`
- Per-session todo and file-op log — in-memory keyed by chat session ID

See [AGENT_LOOP.md](AGENT_LOOP.md) for the full guide.

---

### Sandbox

**Purpose:** Run agent code in an isolated Linux virtual machine with full dev environment capabilities, per-agent isolation, and an extensible plugin system — safely and locally on Apple Silicon.

**Why it matters:**

- **Safe execution** — Agents run code in a disposable VM with zero risk to the host macOS system
- **Real dev environment** — Full Linux with shell, Python (pip), Node.js (npm), system packages (apk), compilers, and POSIX tools
- **Multi-agent isolation** — Each agent gets its own Linux user and home directory, preventing cross-contamination
- **Lightweight plugins** — JSON recipe plugins require no compilation, no Xcode, no code signing
- **Local-first** — Apple Virtualization framework with native Apple Silicon performance; no Docker or cloud VMs
- **Seamless host bridge** — Agents in the VM access Osaurus inference, memory, secrets, and events via vsock

**Components:**

- `Services/Sandbox/SandboxManager.swift` — Container lifecycle (provision, start, stop, reset, exec)
- `Services/Sandbox/SandboxLogBuffer.swift` — Ring buffer for container log entries
- `Services/Sandbox/SandboxToolRegistrar.swift` — Registers/unregisters tools on status and agent changes
- `Services/Sandbox/SandboxSecurity.swift` — Path sanitization, network policy, rate limiting
- `Managers/Plugin/SandboxPluginManager.swift` — Per-agent plugin install, uninstall, and update tracking
- `Managers/Plugin/SandboxPluginLibrary.swift` — Plugin library storage and discovery
- `Tools/BuiltinSandboxTools.swift` — Built-in tools for file ops, shell, package management, secrets, and plugin creation
- `Tools/SandboxPluginTool.swift` — Wraps plugin tool specs as OsaurusTool instances
- `Tools/SandboxSecretTools.swift` — Secret check and set tools with direct-value and secure-prompt paths
- `Tools/SandboxPluginRegisterTool.swift` — Hot-registers agent-created plugins with file auto-packaging
- `Tools/ToolRegistry.swift` — Sandbox tool registration and namespace management
- `Views/Chat/PromptCard.swift` — Shared chrome (header pill, markdown description, glass background, layered shadow + accent halo, spring entry/exit) used by every in-chat prompt overlay
- `Views/Chat/PromptQueue.swift` — Single-slot FIFO queue for in-chat prompts so secrets and clarify never stack on top of each other
- `Views/Chat/SecretPromptOverlay.swift` — Secure overlay for collecting secrets in chat (renders through `PromptCard`)
- `Views/Chat/ClarifyPromptOverlay.swift` — Bottom-pinned overlay for the agent's `clarify` tool, with optional one-tap option chips and a free-form text input
- `Networking/HostAPIBridgeServer.swift` — HTTP server over vsock for host service access
- `Models/SandboxPlugin.swift` — Plugin model with tool specs, MCP, daemon, events, and permissions
- `Models/Plugin/SandboxConfiguration.swift` — Container config (CPUs, memory, network, auto-start)
- `Models/Plugin/SandboxAgentMap.swift` — Linux username to agent UUID mapping
- `Views/Sandbox/SandboxView.swift` — Container dashboard, log console, diagnostics, plugin management UI

**VM Configuration:**

| Setting | Range | Default |
|---------|-------|---------|
| CPUs | 1–8 | 2 |
| Memory | 1–8 GB | 2 GB |
| Network | outbound / none | outbound |
| Auto-Start | on / off | on |
| Rootfs | — | 8 GiB |

**Built-in Tools:**

| Tool | Category | Description |
|------|----------|-------------|
| `sandbox_read_file` | Read-only | Read file contents (supports line ranges and log tails) |
| `sandbox_list_directory` | Read-only | List files and directories |
| `sandbox_search_files` | Read-only | Search file contents with ripgrep (regex, context lines, case-insensitive) |
| `sandbox_find_files` | Read-only | Find files by name glob pattern (e.g. `*.py`, `test_*`) |
| `sandbox_write_file` | Write | Write content to a file (creates parent directories) |
| `sandbox_edit_file` | Write | Edit a file by exact string replacement (old_string/new_string) |
| `sandbox_move` | Write | Move or rename |
| `sandbox_delete` | Write | Delete files or directories |
| `sandbox_exec` | Exec | Run shell command (timeout, rate limited) |
| `sandbox_exec_background` | Exec | Start background process |
| `sandbox_install` | Package | Install via apk (root) |
| `sandbox_pip_install` | Package | Install via pip |
| `sandbox_npm_install` | Package | Install via npm |
| `sandbox_run_script` | Exec | Run a script file (Python, Node, Bash, etc.) |
| `sandbox_secret_check` | Secret | Check whether a secret exists (never reveals value) |
| `sandbox_secret_set` | Secret | Store a secret directly or prompt the user |
| `sandbox_plugin_register` | Plugin | Register an agent-created plugin (requires `pluginCreate`) |

`share_artifact` is a global built-in (registered in `ToolRegistry`, available in plain chat / folder / sandbox alike) so it does not appear in this sandbox-specific table.

Read-only tools are always available. Write/exec/package/secret tools require `autonomous_exec.enabled` on the agent. `sandbox_plugin_register` additionally requires `pluginCreate` to be enabled.

**Plugin Format (JSON recipe):**

| Property | Description |
|----------|-------------|
| `name` | Display name |
| `description` | Brief description |
| `dependencies` | System packages via `apk add` |
| `setup` | Setup command as agent user |
| `files` | Seed files into plugin directory |
| `tools` | Custom tool definitions (shell commands with `$PARAM_` env vars) |
| `secrets` | Required secret names |
| `permissions` | Network and inference access |

**Host API Bridge Services:**

| Service | Routes |
|---------|--------|
| Secrets | `GET /api/secrets/{name}` |
| Config | `GET/POST /api/config/{key}` |
| Inference | `POST /api/inference/chat` |
| Agent | `POST /api/agent/dispatch`, `POST /api/agent/memory` |
| Events | `POST /api/events/emit` |
| Plugin | `POST /api/plugin/create` |
| Log | `POST /api/log` |

**Storage:**

| Path | Purpose |
|------|---------|
| `~/.osaurus/container/` | Container root |
| `~/.osaurus/container/kernel/vmlinux` | Linux kernel |
| `~/.osaurus/container/workspace/` | Mounted as `/workspace` |
| `~/.osaurus/container/workspace/agents/{name}/` | Per-agent home |
| `~/.osaurus/container/output/` | Mounted as `/output` |
| `~/.osaurus/sandbox-plugins/` | Plugin library |
| `~/.osaurus/config/sandbox.json` | Configuration |
| `~/.osaurus/config/sandbox-agent-map.json` | Agent map |

---

### Chat Session Management

**Purpose:** Persist, audit, and manage chat conversations regardless of how they were started — UI, plugin (Telegram/Slack/etc.), HTTP API, schedule, or file-system watcher.

**Components:**

- `Managers/Chat/ChatSessionsManager.swift` — Session list management
- `Models/Chat/ChatSessionData.swift` — Session data model (carries `source`, `sourcePluginId`, `externalSessionKey`, `dispatchTaskId`)
- `Models/Chat/SessionSource.swift` — Origin tag enum + shared UI helpers (badge icon, "via X" label)
- `Models/Chat/ChatSessionStore.swift` — Session persistence facade
- `Storage/ChatHistoryDatabase.swift` — SQLite store with indices on `source` and `(source_plugin_id, external_session_key)` for fast filtering and find-or-create
- `Views/Chat/ChatSessionSidebar.swift` — Session history sidebar with source badge + filter rail

**Features:**

- Automatic session persistence
- Session history with sidebar navigation
- Per-session model selection
- Context token estimation display
- Auto-generated titles from first message
- **Audit dimension** — every session is tagged with its origin (`chat` / `plugin` / `http` / `schedule` / `watcher`); the sidebar shows a colored badge with plugin name in the tooltip
- **Source filter rail** — chip-style filter above the list, auto-hidden when a single source is present
- **Conversation grouping** — plugins that pass `external_session_key` (e.g. Telegram chat id) reattach to the same session on subsequent dispatches instead of creating a new row each time; see [Plugin Authoring Guide](PLUGIN_AUTHORING.md#conversation-grouping)

---

### Tools & Plugins

**Purpose:** Extend Osaurus with custom functionality including tools, HTTP routes, storage, configuration UI, and web apps.

**Components:**

- `Tools/OsaurusTool.swift` — Tool protocol
- `Tools/ExternalTool.swift` — External plugin wrapper
- `Tools/ToolRegistry.swift` — Tool registration
- `Tools/SchemaValidator.swift` — JSON schema validation
- `Managers/Plugin/PluginManager.swift` — Plugin discovery, loading, unloading
- `Services/Plugin/PluginHostAPI.swift` — v2 host API callbacks (config, db, log)
- `Storage/PluginDatabase.swift` — Sandboxed per-plugin SQLite database
- `Models/Plugin/PluginHTTP.swift` — HTTP request/response models, rate limiter, MIME types
- `Models/Plugin/ExternalPlugin.swift` — C ABI wrapper with v1/v2 support
- `Views/Plugin/PluginConfigView.swift` — Native SwiftUI config UI renderer
- `Views/Plugin/PluginsView.swift` — Plugin detail view (README, Settings, Changelog, Routes)

**Plugin Types:**

- **v1 plugins** — Tools only, via `osaurus_plugin_entry`
- **v2 plugins** — Tools + routes + storage + config, via `osaurus_plugin_entry_v2`
- **System plugins** — Built-in tools (filesystem, browser, git, etc.)
- **MCP provider tools** — Tools from remote MCP servers

**Plugin Capabilities (v2):**

| Capability | Manifest Key          | Description                                          |
| ---------- | --------------------- | ---------------------------------------------------- |
| Tools      | `capabilities.tools`  | AI-callable functions                                |
| Routes     | `capabilities.routes` | HTTP endpoints (OAuth, webhooks, APIs)               |
| Config     | `capabilities.config` | Native settings UI with validation                   |
| Web        | `capabilities.web`    | Static frontend serving with context injection       |
| Docs       | `docs`                | README, changelog, and external links                |

See [PLUGIN_AUTHORING.md](PLUGIN_AUTHORING.md) for the full reference.

---

### Skills

**Purpose:** Import and manage reusable AI capabilities following the Agent Skills specification.

**Components:**

- `Managers/SkillManager.swift` — Skill CRUD, persistence, and loading
- `Services/Skill/SkillSearchService.swift` — RAG-based skill search
- `Services/GitHubSkillService.swift` — GitHub repository import
- `Models/Agent/Skill.swift` — Skill data model
- `Views/Skill/SkillsView.swift` — Skill management UI
- `Views/Skill/SkillEditorSheet.swift` — Skill editor

**Features:**

- **GitHub Import** — Import from repositories with `.claude-plugin/marketplace.json`
- **File Import** — Load `.md` (Agent Skills), `.json`, or `.zip` packages
- **Built-in Skills** — 6 pre-installed skills for common use cases
- **Reference Files** — Attach text files loaded into skill context
- **Asset Files** — Support files for skills
- **Categories** — Organize skills by type
- **Automated Selection** — Skills are automatically selected via RAG-based preflight search

**Skill Properties:**

| Property       | Description                        |
| -------------- | ---------------------------------- |
| `name`         | Display name (required)            |
| `description`  | Brief description                  |
| `instructions` | Full AI instructions (markdown)    |
| `category`     | Optional category for organization |
| `version`      | Skill version                      |
| `author`       | Skill author                       |
| `references/`  | Text files loaded into context     |
| `assets/`      | Supporting files                   |

**Storage:** `~/.osaurus/skills/{skill-name}/SKILL.md`

---

### Methods

**Purpose:** Reusable, scored workflows that agents save and learn from over time.

Methods are YAML sequences of tool-call steps that represent learned procedures. When an agent discovers an effective approach, it saves the workflow as a method. Methods are indexed for RAG search and scored based on success rate and recency, so high-quality procedures surface automatically in future tasks.

**Components:**

- `Models/Method/Method.swift` — Method data model with scoring and event tracking
- `Storage/MethodDatabase.swift` — SQLite storage (methods, events, scores)
- `Services/Method/MethodService.swift` — CRUD orchestrator, YAML extraction, scoring
- `Services/Method/MethodSearchService.swift` — VecturaKit hybrid search (BM25 + vector)
- `Utils/MethodLogger.swift` — Structured logging

**Features:**

- **YAML Workflows** — Methods store step-by-step tool-call sequences as YAML
- **Auto-Extraction** — Tool and skill references are automatically extracted from the YAML body
- **Scoring System** — Each method tracks success rate and recency; a composite score ranks methods in search results
- **RAG Search** — Methods are indexed by description and trigger text for hybrid BM25 + vector search
- **Trigger Text** — Optional phrases that activate a method (e.g., "deploy to staging")

**Method Properties:**

| Property       | Description                                   |
| -------------- | --------------------------------------------- |
| `name`         | Display name (required)                       |
| `description`  | Brief description of what the method does     |
| `triggerText`  | Optional phrases that trigger this method     |
| `body`         | YAML steps (the workflow definition)          |
| `toolsUsed`    | Auto-extracted tool references from YAML      |
| `skillsUsed`   | Auto-extracted skill references from YAML     |
| `tokenCount`   | Estimated token count for context budgeting   |
| `version`      | Incremented on each update                    |

**Scoring:**

Methods are scored using a recency-weighted success rate:

```
score = successRate × recencyWeight
recencyWeight = 1.0 / (1.0 + daysSinceUsed / 30.0)
```

Each time a method is used, a `MethodEvent` is recorded (`loaded`, `succeeded`, `failed`), and the score is recalculated.

**Agent Tools:** Methods are loaded by the agent indirectly via `capabilities_search` / `capabilities_load` (loading a method auto-loads its referenced tools and skills). The dedicated `methods_save` / `methods_report` tools were removed from the schema — recording method outcomes is now an internal observation, not an agent-facing concern.

**Storage:** `~/.osaurus/methods/methods.db` (SQLite with WAL mode)

---

### Context Management

**Purpose:** Automatically select and inject relevant capabilities (methods, tools, and skills) into each agent session via RAG search.

Context management replaces manual per-agent tool and skill configuration with a fully automated system. Before each agent loop, a preflight RAG search runs across all indexed methods, tools, and skills, injecting relevant context and tool definitions based on the user's query.

**Components:**

- `Services/Context/PreflightCapabilitySearch.swift` — Pre-flight RAG search orchestrator
- `Services/Tool/ToolSearchService.swift` — VecturaKit hybrid search over tools
- `Services/Tool/ToolIndexService.swift` — Syncs ToolRegistry into searchable index
- `Storage/ToolDatabase.swift` — SQLite storage for tool index
- `Tools/CapabilityTools.swift` — Runtime capability search and load tools

**Preflight Search Modes:**

| Mode        | Methods | Tools | Skills | Use Case                              |
| ----------- | ------- | ----- | ------ | ------------------------------------- |
| `off`       | 0       | 0     | 0      | Disable automatic selection           |
| `narrow`    | 1       | 2     | 1      | Minimal context, fastest responses    |
| `balanced`  | 3       | 5     | 2      | Default — good coverage, moderate cost|
| `wide`      | 5       | 8     | 4      | Maximum coverage, larger prompts      |

The preflight search produces a `PreflightResult` containing:

- **Tool specs** — Tool definitions merged into the active tool set (direct matches + tools cascaded from matched methods)
- **Context snippet** — Markdown-formatted method bodies and skill instructions injected into the system prompt

**Runtime Capability Tools:**

For on-demand discovery during a session, agents can use:

| Tool                  | Description                                                       |
| --------------------- | ----------------------------------------------------------------- |
| `capabilities_search` | Search methods, tools, and skills across all indexes in parallel  |
| `capabilities_load`   | Load a capability by ID into the active session (hot-loads tools) |

When `capabilities_load` is called, new tool specs are queued in a `CapabilityLoadBuffer` and drained into the active tool set after each invocation, allowing the agent to dynamically expand its capabilities mid-session.

**Search Infrastructure:**

All three search services use VecturaKit (hybrid BM25 + vector search):

| Service               | Indexes                            |
| --------------------- | ---------------------------------- |
| `MethodSearchService` | Method descriptions + trigger text |
| `ToolSearchService`   | Tool names + descriptions          |
| `SkillSearchService`  | Skill names + descriptions         |

---

### Voice Input (FluidAudio)

**Purpose:** Provide speech-to-text transcription using on-device FluidAudio models.

**Components:**

- `Managers/SpeechService.swift` — Core transcription service with streaming support
- `Managers/Model/SpeechModelManager.swift` — Model download and selection
- `Models/Voice/SpeechConfiguration.swift` — Voice input settings
- `Views/Voice/VoiceView.swift` — Voice settings UI
- `Views/Voice/VoiceSetupTab.swift` — Guided setup wizard
- `Views/Voice/VoiceInputOverlay.swift` — Voice input UI in chat

**Features:**

- **Real-time streaming transcription** — See words as you speak
- **Multiple Parakeet models** — Tiny (75 MB) to Large V3 (3 GB)
- **English-only and multilingual** — Choose based on your needs
- **Microphone input** — Built-in or external device selection
- **System audio capture** — Transcribe computer audio (macOS 12.3+)
- **Configurable sensitivity** — Low, Medium, High thresholds
- **Auto-send with confirmation** — Hands-free message sending
- **Pause duration control** — Adjust silence detection timing

**Configuration:**

| Setting               | Description                                   |
| --------------------- | --------------------------------------------- |
| `defaultModel`        | Selected Parakeet model ID                    |
| `languageHint`        | ISO 639-1 language code (e.g., "en", "es")    |
| `sensitivity`         | Voice detection sensitivity (low/medium/high) |
| `pauseDuration`       | Seconds of silence before auto-send           |
| `confirmationDelay`   | Seconds to show confirmation before sending   |
| `selectedInputSource` | Microphone or system audio                    |

**Model Storage:** `~/Library/Application Support/FluidAudio/Models/`

---

### VAD Mode (Voice Activity Detection)

**Purpose:** Enable hands-free agent activation through wake-word detection.

**Components:**

- `Services/Voice/VADService.swift` — Always-on listening and wake-word detection
- `Models/Voice/VADConfiguration.swift` — VAD settings and enabled agents
- `Views/ContentView.swift` — VAD toggle button in popover
- `AppDelegate.swift` — VAD status indicator in menu bar icon
- `Services/Chat/AgentNameDetector.swift` — Agent name matching logic

**Features:**

- **Wake-word activation** — Say a agent's name to open chat
- **Custom wake phrase** — Set a phrase like "Hey Osaurus"
- **Per-agent enablement** — Choose which agents respond to voice
- **Menu bar indicator** — Shows listening status with audio level
- **Auto-start voice input** — Begin recording after activation
- **Silence timeout** — Auto-close chat after inactivity
- **Background listening** — Continues when chat is closed

**Configuration:**

| Setting                 | Description                                  |
| ----------------------- | -------------------------------------------- |
| `vadModeEnabled`        | Master toggle for VAD mode                   |
| `enabledAgentIds`     | UUIDs of agents that respond to wake-words |
| `customWakePhrase`      | Optional phrase like "Hey Osaurus"           |
| `wakeWordSensitivity`   | Detection sensitivity level                  |
| `autoStartVoiceInput`   | Start recording after activation             |
| `silenceTimeoutSeconds` | Auto-close timeout (0 = disabled)            |

**Workflow:**

1. VAD listens in background using FluidAudio
2. Transcription is checked for agent names or wake phrase
3. On match, chat opens with the detected agent
4. Voice input starts automatically (if enabled)
5. After chat closes, VAD resumes listening

---

### Transcription Mode

**Purpose:** Enable global speech-to-text dictation directly into any focused text field using accessibility APIs.

**Components:**

- `Services/Voice/TranscriptionModeService.swift` — Main orchestration service
- `Services/Voice/KeyboardSimulationService.swift` — Simulates keyboard input via CGEventPost
- `Services/Voice/TranscriptionOverlayWindowService.swift` — Floating overlay panel management
- `Managers/TranscriptionHotKeyManager.swift` — Global hotkey registration
- `Models/Voice/TranscriptionConfiguration.swift` — Configuration and persistence
- `Views/Voice/TranscriptionOverlayView.swift` — Minimal floating UI
- `Views/Voice/TranscriptionModeSettingsTab.swift` — Settings UI in Voice tab

**Features:**

- **Global Hotkey** — Configurable hotkey to trigger transcription from anywhere
- **Live Typing** — Transcribed text is typed directly into the focused text field
- **Accessibility Integration** — Uses macOS accessibility APIs (requires permission)
- **Minimal Overlay** — Sleek floating UI shows recording status with waveform
- **Esc to Cancel** — Press Escape or click Done to stop transcription
- **Real-time Feedback** — Audio level visualization during recording

**Configuration:**

| Setting                    | Description                             |
| -------------------------- | --------------------------------------- |
| `transcriptionModeEnabled` | Master toggle for transcription mode    |
| `hotkey`                   | Global hotkey to activate transcription |

**Requirements:**

- Microphone permission (for audio capture)
- Accessibility permission (for keyboard simulation)
- Parakeet model downloaded

**Workflow:**

1. User presses the configured hotkey
2. Overlay appears showing recording status
3. FluidAudio transcribes speech in real-time
4. Text is typed into the currently focused text field via accessibility APIs
5. User presses Esc or clicks Done to stop
6. Overlay disappears and transcription ends

---

### Memory

**Purpose:** Persistent, on-device memory that distills conversations at session boundaries, scores facts by salience, and surfaces at most one compact slice per request based on what the user is actually asking. Replaces the v1 four-layer / per-turn-extraction system. See [MEMORY.md](MEMORY.md) for the full architecture.

**Components:**

- `Services/Memory/MemoryService.swift` — Buffer-and-distill pipeline (`bufferTurn`, `distillSession`, `flushSession`, `syncNow`)
- `Services/Memory/MemoryRelevanceGate.swift` — Heuristic gate that decides whether memory is needed for a query
- `Services/Memory/MemoryPlanner.swift` — Picks one section (identity / pinned / episode / transcript) under a single token budget
- `Services/Memory/MemoryContextAssembler.swift` — Thin facade over gate + planner + identity overrides
- `Services/Memory/MemoryConsolidator.swift` — Background actor: salience decay, episode merge, pinned promotion, eviction, retention pruning
- `Services/Memory/MemorySearchService.swift` — Hybrid search (BM25 + vector) with shingle-MMR; lazy reverse maps
- `Storage/MemoryDatabase.swift` — SQLite with WAL mode; v5 schema with light carry-over from v1
- `Models/Memory/MemoryModels.swift` — `Identity`, `PinnedFact`, `Episode`, `TranscriptTurn`, `PendingSignal`
- `Models/Memory/MemoryConfiguration.swift` — User-configurable settings with validation
- `Views/Memory/MemoryView.swift` — Identity, overrides, agents, statistics, "Run Consolidation Now"

**Three Layers + Transcript:**

| Layer | Type | Purpose | Retention |
|-------|------|---------|-----------|
| Identity | Single row | Stable user facts: explicit overrides + auto-derived narrative | Permanent |
| Pinned Facts | Per-agent pool | Salience-scored facts promoted from session distillations | Decayed + evicted by consolidator |
| Episodes | Per-session digests | Summary, topics, entities, decisions, action items, salience | `episodeRetentionDays` (default 365) |
| Transcript | Raw turns | Fallback retrieval only; never default-injected | `episodeRetentionDays` |

**Write Path (deferred, debounced):**

1. Each turn → `bufferTurn` → single SQL insert into `pending_signals` + debounce arm
2. Debounce expires (default 60s) or `flushSession` is called → ONE LLM call distills the whole session
3. Distillation emits an episode + entity list + pinned candidates + identity delta in one schema-constrained JSON
4. Pinned candidates pass a Jaccard-dedup check before being persisted
5. Identity facts are appended to overrides only when distinct (case-insensitive)

No per-turn LLM call. No verification pipeline. Most chitchat sessions produce zero pinned facts.

**Read Path (gated, single-section):**

1. `MemoryRelevanceGate` (heuristic) classifies the user's query: `none | identity | pinned | episode | transcript`
   - Identity-curious phrases ("what's my name") → identity
   - Temporal markers / prior-context pronouns ("yesterday", "remember when") → episode
   - Entity-name hits / explicit recall verbs → pinned
   - "Exact words", "verbatim" → transcript
2. `MemoryPlanner` fetches the chosen section under `memoryBudgetTokens` (default 800)
3. Identity overrides are always prepended (tiny, user-authored)
4. Block is injected before the latest user message — keeps system prefix byte-stable for KV-cache reuse

**Consolidation (background):**

`MemoryConsolidator` runs every `consolidationIntervalHours` (default 24h):

| Step | What it does |
|------|--------------|
| Decay | `salience *= 0.5 ^ (Δdays / halfLife)` for pinned facts and episodes (halfLife=30d) |
| Merge | Collapse near-duplicate episodes (shingle-Jaccard ≥ 0.9) within the same agent |
| Promote | Boost salience on pinned facts whose content overlaps ≥ 3 recent episodes |
| Evict | Delete pinned facts below `salienceFloor` and idle for 30+ days |
| Prune | Drop episodes / transcript older than `episodeRetentionDays` |

**Search & Retrieval:**

| Method | Backend | Fallback |
|--------|---------|----------|
| Hybrid search | VecturaKit (BM25 + vector) | SQLite LIKE queries |
| MMR reranking | 4-char shingle Jaccard (cheap; replaces v1's O(K²) tokenized Jaccard) | N/A |

Reverse maps from VecturaKit UUIDs to episode/transcript composite keys are built lazily on first miss instead of eagerly at startup, so opening a database with thousands of turns no longer paid the full scan cost.

**Configuration:**

| Setting | Default | Range |
|---------|---------|-------|
| `enabled` | true | true/false |
| `embeddingBackend` | `mlx` | `mlx`, `none` |
| `embeddingModel` | `nomic-embed-text-v1.5` | Any embedding model |
| `extractionMode` | `sessionEnd` | `sessionEnd`, `manual` |
| `relevanceGateMode` | `heuristic` | `off`, `heuristic`, `llm` |
| `memoryBudgetTokens` | 800 | 100 -- 4,000 |
| `summaryDebounceSeconds` | 60 | 10 -- 3,600 |
| `consolidationIntervalHours` | 24 | 1 -- 168 |
| `salienceFloor` | 0.2 | 0.0 -- 1.0 |
| `episodeRetentionDays` | 365 | 0 -- 3,650 |

Eight settings total, down from v1's 18. The per-section budget knobs, MMR tuning, verification thresholds, profile regen thresholds, and `maxEntriesPerAgent` are gone.

**Tool API:** `search_memory(scope, query)` with three scopes: `pinned`, `episodes`, `transcript`. Replaces v1's five-scope tool.

**HTTP API:** Same `X-Osaurus-Agent-Id` header for read-side context injection. `POST /memory/ingest` writes transcripts and triggers an immediate distillation flush after the batch (no need to wait for the writer's debounce).

**Storage:** `~/.osaurus/memory/memory.sqlite` (SQLite with WAL mode), `~/.osaurus/memory/vectura/` (vector index)

---

## Documentation Index

| Document                                                       | Purpose                                           |
| -------------------------------------------------------------- | ------------------------------------------------- |
| [README.md](../README.md)                                      | Project overview, quick start, feature highlights |
| [FEATURES.md](FEATURES.md)                                     | Feature inventory and architecture (this file)    |
| [WATCHERS.md](WATCHERS.md)                                     | Watchers and folder monitoring guide              |
| [AGENT_LOOP.md](AGENT_LOOP.md)                                 | Agent loop, folder context, and `todo`/`complete`/`clarify` |
| [REMOTE_PROVIDERS.md](REMOTE_PROVIDERS.md)                     | Remote provider setup and configuration           |
| [REMOTE_MCP_PROVIDERS.md](REMOTE_MCP_PROVIDERS.md)             | Remote MCP provider setup                         |
| [DEVELOPER_TOOLS.md](DEVELOPER_TOOLS.md)                       | Insights and Server Explorer guide                |
| [VOICE_INPUT.md](VOICE_INPUT.md)                               | Voice input, FluidAudio, and VAD mode guide       |
| [SKILLS.md](SKILLS.md)                                         | Skills, methods, and context management guide    |
| [MEMORY.md](MEMORY.md)                                         | Memory system and configuration guide            |
| [SANDBOX.md](SANDBOX.md)                                       | Sandbox VM and plugin guide                       |
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
