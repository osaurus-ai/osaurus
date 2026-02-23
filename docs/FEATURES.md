# Osaurus Feature Inventory

Canonical reference for all Osaurus features, their status, and documentation.

**This file is the source of truth.** When adding or modifying features, update this inventory to keep documentation in sync.

---

## Feature Matrix

| Feature                          | Status    | README Section     | Documentation                 | Code Location                                                                         |
| -------------------------------- | --------- | ------------------ | ----------------------------- | ------------------------------------------------------------------------------------- |
| Local LLM Server (MLX)           | Stable    | "Key Features"     | OpenAI_API_GUIDE.md           | Services/MLXService.swift, Services/ModelRuntime/                                     |
| Remote Providers                 | Stable    | "Key Features"     | REMOTE_PROVIDERS.md           | Services/RemoteProviderManager.swift, Services/RemoteProviderService.swift            |
| Remote MCP Providers             | Stable    | "Key Features"     | REMOTE_MCP_PROVIDERS.md       | Services/MCPProviderManager.swift, Tools/MCPProviderTool.swift                        |
| MCP Server                       | Stable    | "MCP Server"       | (in README)                   | Networking/OsaurusServer.swift, Services/MCPServerManager.swift                       |
| Tools & Plugins                  | Stable    | "Tools & Plugins"  | PLUGIN_AUTHORING.md           | Tools/, Managers/PluginManager.swift                                                  |
| Skills                           | Stable    | "Skills"           | SKILLS.md                     | Managers/SkillManager.swift, Views/SkillsView.swift, Services/CapabilityService.swift |
| Memory                           | Stable    | "Key Features"     | MEMORY.md                     | Services/MemoryService.swift, Services/MemorySearchService.swift, Services/MemoryContextAssembler.swift |
| Agents                         | Stable    | "Agents"         | (in README)                   | Managers/AgentManager.swift, Models/Agent.swift, Views/AgentsView.swift         |
| Schedules                        | Stable    | "Schedules"        | (in README)                   | Managers/ScheduleManager.swift, Models/Schedule.swift, Views/SchedulesView.swift      |
| Watchers                         | Stable    | "Watchers"         | WATCHERS.md                   | Managers/WatcherManager.swift, Models/Watcher.swift, Views/WatchersView.swift         |
| Agents                           | Stable    | "Agents"           | WORK.md                     | Agent/, Services/WorkEngine.swift, Views/WorkView.swift                             |
| Developer Tools: Insights        | Stable    | "Developer Tools"  | DEVELOPER_TOOLS.md            | Views/InsightsView.swift, Services/InsightsService.swift                              |
| Developer Tools: Server Explorer | Stable    | "Developer Tools"  | DEVELOPER_TOOLS.md            | Views/ServerView.swift                                                                |
| Apple Foundation Models          | macOS 26+ | "What is Osaurus?" | (in README)                   | Services/FoundationModelService.swift                                                 |
| Menu Bar Chat                    | Stable    | "Highlights"       | (in README)                   | Views/ChatView.swift, Views/ChatOverlayView.swift                                     |
| Chat Session Management          | Stable    | "Highlights"       | (in README)                   | Managers/ChatSessionsManager.swift, Models/ChatSessionData.swift                      |
| Custom Themes                    | Stable    | "Highlights"       | (in README)                   | Views/ThemesView.swift, Views/Components/ThemeEditorView.swift                        |
| Model Manager                    | Stable    | "Highlights"       | (in README)                   | Views/ModelDownloadView.swift, Services/HuggingFaceService.swift                      |
| Shared Configuration             | Stable    | -                  | SHARED_CONFIGURATION_GUIDE.md | Services/SharedConfigurationService.swift                                             |
| OpenAI API Compatibility         | Stable    | "API Endpoints"    | OpenAI_API_GUIDE.md           | Networking/HTTPHandler.swift, Models/OpenAIAPI.swift                                  |
| Anthropic API Compatibility      | Stable    | "API Endpoints"    | (in README)                   | Networking/HTTPHandler.swift, Models/AnthropicAPI.swift                               |
| Open Responses API               | Stable    | "API Endpoints"    | OpenAI_API_GUIDE.md           | Networking/HTTPHandler.swift, Models/OpenResponsesAPI.swift                           |
| Ollama API Compatibility         | Stable    | "API Endpoints"    | (in README)                   | Networking/HTTPHandler.swift                                                          |
| Voice Input (WhisperKit)         | Stable    | "Voice Input"      | VOICE_INPUT.md                | Services/WhisperKitService.swift, Managers/WhisperModelManager.swift                  |
| VAD Mode                         | Stable    | "Voice Input"      | VOICE_INPUT.md                | Services/VADService.swift, Views/ContentView.swift (VAD controls)                     |
| Transcription Mode               | Stable    | "Voice Input"      | VOICE_INPUT.md                | Services/TranscriptionModeService.swift, Views/TranscriptionOverlayView.swift         |
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
│  ├── WorkView (Work Mode)                                              │
│  ├── ManagementView                                                      │
│  │   ├── ModelDownloadView (Models)                                      │
│  │   ├── RemoteProvidersView (Providers)                                 │
│  │   ├── ToolsManagerView (Tools)                                        │
│  │   ├── AgentsView (Agents)                                         │
│  │   ├── SkillsView (Skills)                                             │
│  │   ├── MemoryView (Memory)                                             │
│  │   ├── SchedulesView (Schedules)                                       │
│  │   ├── WatchersView (Watchers)                                         │
│  │   ├── ThemesView (Themes)                                             │
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
│  │   └── MCPProviderTool (Wrapped remote MCP tools)                      │
│  ├── Agents                                                            │
│  │   └── AgentManager (Agent lifecycle and active agent)           │
│  ├── Skills                                                              │
│  │   ├── SkillManager (Skill CRUD and loading)                           │
│  │   ├── CapabilityService (Two-phase capability selection)              │
│  │   └── GitHubSkillService (GitHub import)                              │
│  ├── Scheduling                                                          │
│  │   └── ScheduleManager (Schedule lifecycle and execution)              │
│  ├── Watchers                                                            │
│  │   ├── WatcherManager (FSEvents monitoring and convergence loop)       │
│  │   ├── WatcherStore (Watcher persistence)                              │
│  │   └── DirectoryFingerprint (Change detection via Merkle hashing)      │
│  ├── Agents                                                              │
│  │   ├── WorkEngine (Task execution coordinator)                        │
│  │   ├── WorkExecutionEngine (Plan generation and execution)            │
│  │   └── IssueManager (Issue lifecycle management)                       │
│  ├── Voice/Audio                                                         │
│  │   ├── WhisperKitService (Speech-to-text transcription)                │
│  │   ├── WhisperModelManager (Whisper model downloads)                   │
│  │   ├── VADService (Voice activity detection, wake-word)                │
│  │   ├── TranscriptionModeService (Global dictation into any app)        │
│  │   └── AudioInputManager (Microphone/system audio selection)           │
│  ├── Memory                                                              │
│  │   ├── MemoryService (Conversation processing and extraction)          │
│  │   ├── MemorySearchService (Hybrid BM25 + vector search)              │
│  │   ├── MemoryContextAssembler (Context injection with budgets)        │
│  │   └── MemoryDatabase (SQLite storage with migrations)                │
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
│  └── Commands: serve, stop, status, ui, list, show, run, mcp, tools, version │
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
| Anthropic | api.anthropic.com | 443 (HTTPS) | API Key |
| OpenAI | api.openai.com | 443 (HTTPS) | API Key |
| xAI | api.x.ai | 443 (HTTPS) | API Key |
| OpenRouter | openrouter.ai | 443 (HTTPS) | API Key |
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

### Anthropic API Compatibility

**Purpose:** Provide Anthropic Messages API compatibility for Claude Code and other Anthropic SDK clients.

**Components:**

- `Models/AnthropicAPI.swift` — Anthropic request/response models
- `Models/ResponseWriters.swift` — SSE streaming for Anthropic format
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

- `Models/OpenResponsesAPI.swift` — Open Responses request/response models and streaming events
- `Models/ResponseWriters.swift` — SSE streaming for Open Responses format
- `Networking/HTTPHandler.swift` — `/responses` endpoint handler
- `Services/RemoteProviderService.swift` — Remote Open Responses provider support

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

- `Views/ThemesView.swift` — Theme gallery and management
- `Views/Components/ThemeEditorView.swift` — Full theme editor
- `Models/CustomTheme.swift` — Theme data model
- `Models/ThemeConfigurationStore.swift` — Theme persistence
- `Theme/Theme.swift` — Theme protocol and built-in themes

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

- `Models/Agent.swift` — Agent data model with export/import support
- `Models/AgentStore.swift` — Agent persistence (JSON files)
- `Managers/AgentManager.swift` — Agent lifecycle and active agent management
- `Views/AgentsView.swift` — Agent gallery and management UI

**Features:**

- **Custom System Prompts** — Define unique instructions for each agent
- **Tool Configuration** — Enable or disable specific tools per agent
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
| `enabledTools` | Map of tool name → enabled/disabled |
| `themeId` | Optional custom theme to apply |
| `defaultModel` | Optional model ID for this agent |
| `temperature` | Optional temperature override |
| `maxTokens` | Optional max tokens override |

---

### Schedules

**Purpose:** Automate recurring AI tasks that run at specified intervals.

**Components:**

- `Models/Schedule.swift` — Schedule data model with frequency types
- `Models/ScheduleStore.swift` — Schedule persistence (JSON files)
- `Managers/ScheduleManager.swift` — Schedule lifecycle, timer management, and execution
- `Views/SchedulesView.swift` — Schedule management UI

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

- `Models/Watcher.swift` — Watcher data model
- `Models/WatcherStore.swift` — Watcher persistence (JSON files)
- `Managers/WatcherManager.swift` — FSEvents monitoring, debouncing, and convergence loop
- `Services/DirectoryFingerprint.swift` — Merkle hash-based change detection
- `Views/WatchersView.swift` — Watcher management UI

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

**Storage:** `~/Library/Application Support/com.dinoki.osaurus/watchers/{uuid}.json`

---

### Agents

**Purpose:** Execute complex, multi-step tasks autonomously with built-in issue tracking, planning, and file operations.

**Components:**

- `Agent/WorkFolderContext.swift` — Folder context models and project detection
- `Agent/WorkFolderContextService.swift` — Folder selection and security-scoped bookmarks
- `Agent/AgentFolderTools.swift` — File and shell operation tools
- `Agent/WorkFileOperation.swift` — File operation models
- `Agent/WorkFileOperationLog.swift` — Operation logging with undo support
- `Models/WorkModels.swift` — Core data models (Issue, WorkTask, LoopState, etc.)
- `Services/WorkEngine.swift` — Main task execution coordinator
- `Services/WorkExecutionEngine.swift` — Reasoning loop execution engine
- `Managers/IssueManager.swift` — Issue lifecycle and dependency management
- `Storage/WorkDatabase.swift` — SQLite storage for issues, tasks, and conversation turns
- `Tools/WorkTools.swift` — Agent-specific tools (complete_task, create_issue, generate_artifact, etc.)
- `Views/WorkView.swift` — Main Work Mode UI
- `Views/WorkSession.swift` — Observable session state manager

**Features:**

- **Issue Tracking** — Tasks broken into issues with status, priority, type, and dependencies
- **Parallel Tasks** — Run multiple agent tasks simultaneously for increased productivity
- **Reasoning Loop** — AI autonomously iterates through observe-think-act-check cycles (max 30 iterations)
- **Working Directory** — Select a folder for file operations with project type detection
- **File Operations** — Read, write, edit, search, move, copy, delete files with undo support
- **Follow-up Issues** — Agent creates child issues via `create_issue` tool when it discovers additional work
- **Clarification** — Agent pauses to ask when tasks are ambiguous
- **Background Execution** — Tasks continue running after closing the window
- **Token Usage Tracking** — Monitor cumulative input/output tokens per task

**Issue Properties:**

| Property      | Description                                     |
| ------------- | ----------------------------------------------- |
| `status`      | `open`, `in_progress`, `blocked`, `closed`      |
| `priority`    | P0 (critical), P1 (high), P2 (medium), P3 (low) |
| `type`        | `task`, `bug`, `discovery`                      |
| `title`       | Brief description of the work                   |
| `description` | Detailed explanation and context                |
| `result`      | Outcome after completion                        |

**Available Tools:**

| Tool            | Description                                    |
| --------------- | ---------------------------------------------- |
| `file_tree`     | List directory structure with filtering        |
| `file_read`     | Read file contents (supports line ranges)      |
| `file_write`    | Create or overwrite files                      |
| `file_edit`     | Surgical text replacement within files         |
| `file_search`   | Search for text patterns across files          |
| `file_move`     | Move or rename files                           |
| `file_copy`     | Duplicate files                                |
| `file_delete`   | Remove files                                   |
| `file_metadata` | Get file information (size, dates, etc.)       |
| `dir_create`    | Create directories                             |
| `shell_run`     | Execute shell commands (requires permission)   |
| `git_status`    | Show repository status                         |
| `git_diff`      | Display file differences                       |
| `git_commit`    | Stage and commit changes (requires permission) |

**Workflow (Reasoning Loop):**

1. User input creates a task with an initial issue
2. Agent enters a reasoning loop (max 30 iterations per issue)
3. Each iteration: the model observes context, decides on an action, calls a tool, and evaluates progress
4. The model narrates its reasoning and explains actions as it works
5. When additional work is found, the agent creates follow-up issues via `create_issue`
6. When the task is complete, the agent calls `complete_task` with a summary and artifact
7. Clarification pauses execution when the task is ambiguous

**Storage:** `~/.osaurus/agent/agent.db` (SQLite)

---

### Chat Session Management

**Purpose:** Persist and manage chat conversations with per-session configuration.

**Components:**

- `Managers/ChatSessionsManager.swift` — Session list management
- `Models/ChatSessionData.swift` — Session data model
- `Models/ChatSessionStore.swift` — Session persistence
- `Views/Components/ChatSessionSidebar.swift` — Session history sidebar

**Features:**

- Automatic session persistence
- Session history with sidebar navigation
- Per-session model selection
- Per-session tool configuration overrides
- Context token estimation display
- Auto-generated titles from first message

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

### Skills

**Purpose:** Import and manage reusable AI capabilities following the Agent Skills specification.

**Components:**

- `Managers/SkillManager.swift` — Skill CRUD, persistence, and loading
- `Services/CapabilityService.swift` — Two-phase capability selection
- `Services/GitHubSkillService.swift` — GitHub repository import
- `Models/Skill.swift` — Skill data model
- `Models/CapabilityCatalog.swift` — Capability catalog structure
- `Tools/SelectCapabilitiesTool.swift` — AI tool for selecting capabilities
- `Views/SkillsView.swift` — Skill management UI
- `Views/SkillEditorSheet.swift` — Skill editor

**Features:**

- **GitHub Import** — Import from repositories with `.claude-plugin/marketplace.json`
- **File Import** — Load `.md` (Agent Skills), `.json`, or `.zip` packages
- **Built-in Skills** — 6 pre-installed skills for common use cases
- **Reference Files** — Attach text files loaded into skill context
- **Asset Files** — Support files for skills
- **Categories** — Organize skills by type
- **Agent Integration** — Per-agent skill enable/disable

**Two-Phase Capability Selection:**

A context optimization system that reduces token usage by ~80%:

| Phase               | What's Loaded                         | Token Usage             |
| ------------------- | ------------------------------------- | ----------------------- |
| Phase 1 (Selection) | Catalog only (name + description)     | ~10-20 tokens per skill |
| Phase 2 (Execution) | Full instructions for selected skills | Full content            |

**Workflow:**

1. System prompt includes lightweight capability catalog
2. AI calls `select_capabilities` with desired tools/skills
3. Full schemas/instructions loaded for selected items only
4. Subsequent messages use selected capabilities

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

### Voice Input (WhisperKit)

**Purpose:** Provide speech-to-text transcription using on-device WhisperKit models.

**Components:**

- `Services/WhisperKitService.swift` — Core transcription service with streaming support
- `Managers/WhisperModelManager.swift` — Model download and selection
- `Models/WhisperConfiguration.swift` — Voice input settings
- `Views/VoiceView.swift` — Voice settings UI
- `Views/VoiceSetupTab.swift` — Guided setup wizard
- `Views/Components/VoiceInputOverlay.swift` — Voice input UI in chat

**Features:**

- **Real-time streaming transcription** — See words as you speak
- **Multiple Whisper models** — Tiny (75 MB) to Large V3 (3 GB)
- **English-only and multilingual** — Choose based on your needs
- **Microphone input** — Built-in or external device selection
- **System audio capture** — Transcribe computer audio (macOS 12.3+)
- **Configurable sensitivity** — Low, Medium, High thresholds
- **Auto-send with confirmation** — Hands-free message sending
- **Pause duration control** — Adjust silence detection timing

**Configuration:**

| Setting               | Description                                   |
| --------------------- | --------------------------------------------- |
| `defaultModel`        | Selected Whisper model ID                     |
| `languageHint`        | ISO 639-1 language code (e.g., "en", "es")    |
| `sensitivity`         | Voice detection sensitivity (low/medium/high) |
| `pauseDuration`       | Seconds of silence before auto-send           |
| `confirmationDelay`   | Seconds to show confirmation before sending   |
| `selectedInputSource` | Microphone or system audio                    |

**Model Storage:** `~/.osaurus/whisper-models/`

---

### VAD Mode (Voice Activity Detection)

**Purpose:** Enable hands-free agent activation through wake-word detection.

**Components:**

- `Services/VADService.swift` — Always-on listening and wake-word detection
- `Models/VADConfiguration.swift` — VAD settings and enabled agents
- `Views/ContentView.swift` — VAD toggle button in popover
- `AppDelegate.swift` — VAD status indicator in menu bar icon
- `Models/AgentNameDetector.swift` — Agent name matching logic

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

1. VAD listens in background using WhisperKit
2. Transcription is checked for agent names or wake phrase
3. On match, chat opens with the detected agent
4. Voice input starts automatically (if enabled)
5. After chat closes, VAD resumes listening

---

### Transcription Mode

**Purpose:** Enable global speech-to-text dictation directly into any focused text field using accessibility APIs.

**Components:**

- `Services/TranscriptionModeService.swift` — Main orchestration service
- `Services/KeyboardSimulationService.swift` — Simulates keyboard input via CGEventPost
- `Services/TranscriptionOverlayWindowService.swift` — Floating overlay panel management
- `Managers/TranscriptionHotKeyManager.swift` — Global hotkey registration
- `Models/TranscriptionConfiguration.swift` — Configuration and persistence
- `Views/TranscriptionOverlayView.swift` — Minimal floating UI
- `Views/TranscriptionModeSettingsTab.swift` — Settings UI in Voice tab

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
- Whisper model downloaded

**Workflow:**

1. User presses the configured hotkey
2. Overlay appears showing recording status
3. WhisperKit transcribes speech in real-time
4. Text is typed into the currently focused text field via accessibility APIs
5. User presses Esc or clicks Done to stop
6. Overlay disappears and transcription ends

---

### Memory

**Purpose:** Persistent, multi-layer memory system that extracts, stores, and retrieves knowledge from conversations to provide personalized, context-aware AI interactions.

**Components:**

- `Services/MemoryService.swift` — Core actor for conversation processing, extraction, and summarization
- `Services/MemorySearchService.swift` — Hybrid search (BM25 + vector) with MMR reranking
- `Services/MemoryContextAssembler.swift` — Assembles memory context for system prompt injection
- `Storage/MemoryDatabase.swift` — SQLite database with WAL mode and schema migrations
- `Models/MemoryModels.swift` — Data types for all 4 memory layers
- `Models/MemoryConfiguration.swift` — User-configurable settings with validation
- `Views/MemoryView.swift` — Memory management UI (profile, overrides, agents, statistics, config)

**4-Layer Architecture:**

| Layer | Type | Purpose | Retention |
|-------|------|---------|-----------|
| Layer 1 | User Profile | Auto-generated user summary with version tracking | Permanent |
| Layer 2 | Working Memory | Structured entries (facts, preferences, decisions, etc.) | Per-agent limit (default 500) |
| Layer 3 | Conversation Summaries | Compressed session recaps | Configurable (default 7 days) |
| Layer 4 | Conversation Chunks | Raw conversation turns | Permanent |

**Memory Entry Types:**

| Type | Description |
|------|-------------|
| `fact` | Factual information about the user or their environment |
| `preference` | User preferences and likes/dislikes |
| `decision` | Decisions made during conversations |
| `correction` | Corrections to previous information |
| `commitment` | Promises or plans the user mentioned |
| `relationship` | Relationships between people, projects, or concepts |
| `skill` | Skills, expertise, or knowledge areas |

**Knowledge Graph:**

- Entities: person, company, place, project, tool, concept, event
- Relationships with confidence scores and temporal validity
- Graph traversal search by entity name or relation type

**Search & Retrieval:**

| Method | Backend | Fallback |
|--------|---------|----------|
| Hybrid search | VecturaKit (BM25 + vector embeddings) | SQLite LIKE queries |
| MMR reranking | Jaccard similarity for diversity | N/A |

- Default MMR lambda: 0.7 (relevance vs. diversity tradeoff)
- Default fetch multiplier: 2.0x over-fetch before reranking

**Verification Pipeline (3 layers, no LLM calls):**

| Layer | Method | Threshold |
|-------|--------|-----------|
| Layer 1 | Jaccard word-overlap deduplication | 0.6 |
| Layer 2 | Contradiction detection (same type + similarity) | 0.3 |
| Layer 3 | Semantic similarity via vector search | 0.85 |

**Context Assembly:**

Memory is injected into system prompts in this order with per-section token budgets:

| Section | Default Budget |
|---------|---------------|
| User Overrides | (always included) |
| User Profile | 2,000 tokens |
| Working Memory | 500 tokens |
| Conversation Summaries | 1,000 tokens |
| Key Relationships | 300 tokens |

Results are cached for 10 seconds per agent.

**Resilience:**

- Circuit breaker: opens after 5 consecutive failures, 60-second cooldown
- Retry logic: exponential backoff (1s, 2s, 4s), max 3 retries, 60-second timeout
- Actor-based concurrency for thread safety
- Non-blocking: all extraction runs in the background

**Configuration:**

| Setting | Default | Range |
|---------|---------|-------|
| `coreModelProvider` | `anthropic` | Any provider |
| `coreModelName` | `claude-haiku-4-5` | Any model |
| `embeddingBackend` | `mlx` | `mlx`, `none` |
| `embeddingModel` | `nomic-embed-text-v1.5` | Any embedding model |
| `summaryDebounceSeconds` | 60 | 10 -- 3,600 |
| `profileMaxTokens` | 2,000 | 100 -- 50,000 |
| `profileRegenerateThreshold` | 10 | 1 -- 100 |
| `workingMemoryBudgetTokens` | 500 | 50 -- 10,000 |
| `summaryRetentionDays` | 7 | 1 -- 365 |
| `summaryBudgetTokens` | 1,000 | 50 -- 10,000 |
| `graphBudgetTokens` | 300 | 50 -- 5,000 |
| `recallTopK` | 10 | 1 -- 100 |
| `mmrLambda` | 0.7 | 0.0 -- 1.0 |
| `mmrFetchMultiplier` | 2.0 | 1.0 -- 10.0 |
| `maxEntriesPerAgent` | 500 | 0 -- 10,000 |
| `enabled` | true | true/false |

**Storage:** `~/.osaurus/memory/memory.db` (SQLite with WAL mode)

---

## Documentation Index

| Document                                                       | Purpose                                           |
| -------------------------------------------------------------- | ------------------------------------------------- |
| [README.md](../README.md)                                      | Project overview, quick start, feature highlights |
| [FEATURES.md](FEATURES.md)                                     | Feature inventory and architecture (this file)    |
| [WATCHERS.md](WATCHERS.md)                                     | Watchers and folder monitoring guide              |
| [WORK.md](WORK.md)                                         | Agents and autonomous task execution guide        |
| [REMOTE_PROVIDERS.md](REMOTE_PROVIDERS.md)                     | Remote provider setup and configuration           |
| [REMOTE_MCP_PROVIDERS.md](REMOTE_MCP_PROVIDERS.md)             | Remote MCP provider setup                         |
| [DEVELOPER_TOOLS.md](DEVELOPER_TOOLS.md)                       | Insights and Server Explorer guide                |
| [VOICE_INPUT.md](VOICE_INPUT.md)                               | Voice input, WhisperKit, and VAD mode guide       |
| [SKILLS.md](SKILLS.md)                                         | Skills and capability selection guide             |
| [MEMORY.md](MEMORY.md)                                         | Memory system and configuration guide            |
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
