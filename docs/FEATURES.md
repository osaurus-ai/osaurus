# Osaurus Feature Inventory

Canonical reference for all Osaurus features, their status, and documentation.

**This file is the source of truth.** When adding or modifying features, update this inventory to keep documentation in sync.

---

## Feature Matrix

| Feature                          | Status    | README Section     | Documentation                 | Code Location                                                                         |
| -------------------------------- | --------- | ------------------ | ----------------------------- | ------------------------------------------------------------------------------------- |
| Local LLM Server (MLX)           | Stable    | "Key Features"     | OpenAI_API_GUIDE.md           | Services/Inference/MLXService.swift, Services/ModelRuntime/                                     |
| Remote Providers                 | Stable    | "Key Features"     | REMOTE_PROVIDERS.md           | Managers/RemoteProviderManager.swift, Services/Provider/RemoteProviderService.swift            |
| Secure Channel (Agent E2E Encryption) | Stable | "Key Features"   | SECURE_CHANNEL.md             | Identity/SecureChannel.swift, Identity/SecureSessionStore.swift, Networking/SecureChannelResponseEncryptor.swift, Services/Provider/SecureChannelClient.swift, Networking/HTTPHandler.swift |
| Remote MCP Providers             | Stable    | "Key Features"     | REMOTE_MCP_PROVIDERS.md       | Managers/MCPProviderManager.swift, Tools/MCPProviderTool.swift                        |
| MCP Server                       | Stable    | "MCP Server"       | (in README)                   | Networking/OsaurusServer.swift, Services/MCP/MCPServerManager.swift, CLI MCPCommand.swift |
| Structured Document IO           | Foundation | "Tools & Plugins"  | (in README)                   | Services/Documents/, Models/Documents/, Managers/Documents/DocumentAdaptersBootstrap.swift |
| Tools & Plugins                  | Stable    | "Tools & Plugins"  | plugins/README.md             | Tools/, Managers/Plugin/PluginManager.swift, Services/Plugin/PluginHostAPI.swift, Storage/PluginDatabase.swift, Models/Plugin/PluginHTTP.swift, Views/Plugin/PluginConfigView.swift |
| Skills                           | Stable    | "Skills"           | SKILLS.md                     | Managers/SkillManager.swift, Views/Skill/SkillsView.swift, Services/Skill/SkillSearchService.swift |
| Claude Plugin Import             | Stable    | "Plugins"          | CLAUDE_PLUGINS.md             | Services/GitHubSkillService.swift, Services/Skill/ClaudePluginInstaller.swift, Services/Skill/ClaudePluginManifestStore.swift, Services/Skill/ClaudePluginVariableExpander.swift, Services/Plugin/InstalledClaudePluginsAggregator.swift, Views/Plugin/GitHubImportSheet.swift, Views/Plugin/ClaudePluginCard.swift, Views/Plugin/ClaudePluginDetailView.swift, Views/Plugin/ClaudePluginUserConfigSheet.swift |
| Methods                          | Stable    | "Skills & Methods" | SKILLS.md                     | Models/Method/Method.swift, Services/Method/MethodService.swift, Services/Method/MethodSearchService.swift, Storage/MethodDatabase.swift |
| Context Management               | Stable    | -                  | SKILLS.md                     | Services/Context/CapabilitySearch.swift, Tools/CapabilityTools.swift, Services/Tool/ToolSearchService.swift, Services/Tool/ToolIndexService.swift |
| Memory                           | Stable    | "Key Features"     | MEMORY.md                     | Services/Memory/MemoryService.swift, Services/Memory/MemorySearchService.swift, Services/Memory/MemoryContextAssembler.swift |
| Privacy Filter                   | Experimental | "Key Features"  | PRIVACY_FILTER.md             | PrivacyFilter/Core/PrivacyFilterPipeline.swift, PrivacyFilter/Core/PrivacyFilterEngine.swift, PrivacyFilter/Core/RegexEntityDetector.swift, PrivacyFilter/Store/PrivacyFilterStore.swift, PrivacyFilter/Views/PrivacyView.swift, PrivacyFilter/Views/RedactionReviewSheet.swift, Services/Provider/WireTransportProbe.swift, Views/Chat/RedactionHighlighter.swift, Views/Chat/RedactionHoverController.swift |
| Agents                         | Stable    | "Agents"         | (in README)                   | Managers/AgentManager.swift, Models/Agent/Agent.swift, Views/Agent/AgentsView.swift         |
| Agent DB & Self-Scheduling       | Stable    | "Agents"           | AGENT_DB.md                   | Storage/AgentDatabase.swift, Storage/SchedulerDatabase.swift, Managers/NextRunScheduler.swift, Tools/Database/, Views/Agent/AgentDBTabViews.swift, Views/Agent/NextRunPanelView.swift |
| Schedules                        | Stable    | "Schedules"        | (in README)                   | Managers/ScheduleManager.swift, Models/Schedule/Schedule.swift, Views/Schedule/SchedulesView.swift      |
| Watchers                         | Stable    | "Watchers"         | WATCHERS.md                   | Managers/WatcherManager.swift, Models/Watcher/Watcher.swift, Views/Watcher/WatchersView.swift         |
| Agent Loop & Folder Context      | Stable    | "Agent Loop"       | AGENT_LOOP.md                 | Services/Chat/AgentToolLoop.swift, Services/Chat/AgentTaskState.swift, Folder/, Tools/AgentLoopTools.swift, Tools/FolderToolManager.swift, Models/Chat/AgentTodo.swift, Models/Chat/AgentTodoStore.swift, Models/Chat/SharedArtifact.swift |
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
| Computer Use                     | Experimental | -               | COMPUTER_USE.md               | ComputerUse/ (Tool, Loop, Policy, Perception, Recipes, Driver), Views/Settings/ComputerUseSettingsView.swift, Views/Chat/ComputerUseFeedView.swift |
| Storage (plaintext default, opt-in encryption) | Stable | -          | STORAGE.md                    | Storage/StorageFileFormat.swift, Storage/StorageEncryptionPolicy.swift, Storage/OsaurusStorageOpener.swift, Storage/StorageMigrationCoordinator.swift, Storage/StorageRecoveryService.swift, Storage/StorageFile.swift, Storage/PersistenceHealth.swift, Identity/StorageKeyManager.swift, Storage/EncryptedSQLiteOpener.swift, Storage/StorageDatabaseCatalog.swift, Storage/StorageMutationGate.swift, Storage/StorageExportService.swift, Storage/EncryptedFileStore.swift, Storage/AttachmentBlobStore.swift, Storage/StorageMaintenance.swift, Views/Settings/StorageSettingsView.swift, SQLCipher/ |
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
│  │   ├── StorageSettingsView (Encryption opt-in, backup, recovery)       │
│  │   ├── InsightsView (Developer: Insights)                              │
│  │   ├── ServerView (Developer: Server Explorer)                         │
│  │   ├── VoiceView (Voice Input & VAD Settings)                          │
│  │   ├── PrivacyView (Privacy Filter: 4 sub-tabs; opt-in model)          │
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
│  │   └── MCPProviderManager (HTTP/SSE remote MCP client connections)     │
│  ├── Documents                                                           │
│  │   ├── DocumentAdaptersBootstrap (built-in adapter registration)        │
│  │   ├── PDF/CSV/XLSX/PPTX/RichDocument adapters                         │
│  │   └── ExternalOfficeRuntimeDetector (optional runtime discovery only)  │
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
│  │   ├── GitHubSkillService (Plugin discovery + marketplace parsing)     │
│  │   └── ClaudePluginInstaller (Full Claude plugin install/uninstall)    │
│  ├── Methods                                                             │
│  │   ├── MethodService (Method CRUD and scoring)                         │
│  │   └── MethodSearchService (RAG-based method search)                   │
│  ├── Context                                                             │
│  │   ├── CapabilitySearch (Index search for capabilities_discover)       │
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
│  ├── Privacy Filter                                                      │
│  │   ├── PrivacyFilterPipeline (Outbound scrub + inbound unscrub)        │
│  │   ├── PrivacyFilterEngine (Regex + classifier detection ensemble)     │
│  │   ├── RegexEntityDetector (Built-in + preset + custom patterns)       │
│  │   ├── RedactionMap (Per-conversation original ↔ placeholder intern)   │
│  │   ├── SessionRedactionStore (Per-session RedactionMap + auto-approve) │
│  │   ├── PrivacyReviewService (Modal review presenter registry)          │
│  │   ├── StreamingUnscrubber (Splices inbound stream + rewrites tokens)  │
│  │   ├── PrivacyFilterModelDownloader (HF bundle install + verify)       │
│  │   ├── PrivacyFilterStore (Synchronous JSON config persistence)        │
│  │   └── WireTransportProbe (Captures post-scrub bytes for Insights)     │
│  ├── Computer Use                                                        │
│  │   ├── ComputerUseTool (computer_use entry tool, nested loop)          │
│  │   ├── ComputerUseLoop (perceive-decide-gate-act-verify)               │
│  │   ├── NativeMacDriver (AX / SOM / Vision capture + input)             │
│  │   ├── CaptureRouter / FrameScrubber / CloudVisionConsent              │
│  │   └── EffectClassifier + AutonomyPolicy/Gate + AppRecipes             │
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
- `Services/ModelRuntime/` — Single MLX entry point (`MLXBatchAdapter`) wrapping vmlx-swift's `BatchEngine`, plus the `GenerationEventMapper` bridge to typed runtime events
- `Services/Inference/ModelService.swift` — Model lifecycle management
- Native Swift image generation is not wired as a supported local MLX feature
  yet. See `NATIVE_SWIFT_IMAGE_GENERATION_INTEGRATION.md` for the pending
  `vMLXFlux` lane and release gate.

**Runtime behavior:**

- **Window-scoped warm-up** — Models are loaded and prefix-cached when a chat window opens, not at app launch. Each window warms its own model independently, using the window's agent context (system prompt, memory, tools) for the prefix cache.
- **Smart unloading** — The "Keep model loaded after use" setting controls whether a local model unloads immediately after use, stays warm for 5/15/30/60 minutes, or stays resident until an explicit unload/cleanup. Strict single-model switches still unload the replaced model immediately, and idle unload never deletes downloaded models or disk KV cache entries. The warm-up indicator (yellow dot) signals when a model is loading.
- **Continuous batching** — `BatchEngine` shares a single forward pass across overlapping requests for the same model. The default `mlxBatchEngineMaxBatchSize` is `1` so vmlx compiled decode stays eligible for single-user chat; tune with `defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize -int 8` for server-style concurrency. Takes effect on the next inference call — the registry hot-resizes the cached engine via vmlx's `BatchEngine.updateMaxBatchSize(_:)`.
- **Library-managed KV cache** — vmlx-swift's `CacheCoordinator` owns KV cache geometry (paged for global attention, rotating for sliding-window, SSM state for Mamba) sized per-model. Multi-turn KV reuse, mediaSalt for VLMs, and sliding-window correctness are all handled inside the engine — osaurus configures only `modelKey`, `diskCacheDir`, and a writability fallback.
- **Model eviction policy** — Configurable in Settings > Local Inference > Model Management. "Strict (One Model)" keeps only one model loaded (default). "Flexible (Multi Model)" allows concurrent models for high-RAM systems. `/health` exposes additive `resident_models[]` diagnostics with in-flight counts and idle-unload timing for each loaded model.

**Configuration:**

- Model storage: `~/MLXModels` (override with `OSU_MODELS_DIR`)
- Default port: `1337` (override with `OSU_PORT`)
- KV cache disk storage: `~/.osaurus/cache/kv/`
- Settings: Top P, eviction policy, model idle residency, allowed origins.
- One advanced tunable, exposed via `defaults` only: `ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize` (default `1`, clamped to `[1, 32]`; hot-resized via `BatchEngine.updateMaxBatchSize(_:)` on the next inference call).

See [INFERENCE_RUNTIME.md](./INFERENCE_RUNTIME.md) for the full runtime architecture.

#### Local model compatibility matrix

Research notes for the next local-runtime compatibility wave live in
[MODEL_COMPATIBILITY_RESEARCH.md](./MODEL_COMPATIBILITY_RESEARCH.md).

| Request | User-visible status | Next implementation step | Runtime owner |
| --- | --- | --- | --- |
| Hugging Face cache import | Implemented as read-only discovery for verified MLX snapshots; Settings now shows skipped candidate reasons. | Add manifest/digest verification before load if cache mutation protection becomes required. | Osaurus host discovery/storage. |
| Hunyuan `hunyuan_v1_dense` | Blocked with an explicit unsupported-family diagnostic until vmlx has a native Hunyuan Dense factory. | Enable only after real-model validation lands upstream. | vmlx model factory and Osaurus diagnostics. |
| DFlash speculative decoding | Research-only; no draft/target local generation contract exists today. | Define a feature-flagged draft-model API and benchmark harness. | vmlx or dedicated MLX speculative adapter. |
| LongCat Flash/Next | Blocked with an explicit unsupported-family diagnostic; current public repos require custom LongCat code paths and large multimodal runtimes. | Wait for native runtime support and multimodal proof before local picker enablement. | vmlx model family support. |
| Tensor parallelism | Future hook only; local runtime remains single-host. | Design authenticated cluster policy before any peer execution code. | Distributed runtime plus Osaurus identity/network policy. |

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

**Osaurus peers (paired / discovered):** a native Osaurus peer is added as an `.osaurus` provider and can be used either as a plain OpenAI-compatible inference backend (**Mode 1**, `/chat/completions`, local tool loop) or run fully server-side as a **remote agent** (**Mode 2**, `/agents/{address}/run`, the remote agent's own model/context/tools). Mode 2 pins the model chip to the agent's live effective model and gates the first send on connect. See [REMOTE_PROVIDERS.md](REMOTE_PROVIDERS.md) and [SECURE_CHANNEL.md](SECURE_CHANNEL.md).

---

### Remote MCP Providers

**Purpose:** Connect to URL-reachable external MCP servers and aggregate their tools, with one-tap setup for ~25 well-known vendors.

**Components:**

- `Models/Configuration/MCPProviderConfiguration.swift` — Provider config model (HTTP URL or stdio command, none / bearer / OAuth)
- `Models/Configuration/MCPProviderTemplate.swift` — Hardcoded catalog of well-known providers
- `Managers/MCPProviderManager.swift` — HTTP/SSE and stdio connection, tool discovery, OAuth refresh & 401 retry
- `Services/MCP/MCPProviderKeychain.swift` — Secure token, refresh-token, and client-secret storage
- `Services/MCP/Stdio/MCPStdioHostTransport.swift` — Host stdio subprocess runner with PATH / `~` command resolution
- `Services/MCP/Stdio/SandboxStdioRunner.swift` — Sandbox stdio subprocess runner for plugin-imported local MCP servers
- `Services/MCP/OAuth/MCPOAuthService.swift` — End-to-end OAuth sign-in orchestration
- `Services/MCP/OAuth/MCPOAuthDiscovery.swift` — RFC 9728 PRM + RFC 8414 ASM discovery (with OIDC fallback)
- `Services/MCP/OAuth/MCPOAuthRegistration.swift` — RFC 7591 Dynamic Client Registration
- `Services/MCP/OAuth/MCPWWWAuthenticate.swift` — `WWW-Authenticate: Bearer` challenge parser
- `Services/MCP/OAuth/MCPOAuthCanonicalURL.swift` — RFC 8707 canonical resource URL normalization
- `Services/Auth/OAuthLoopbackServer.swift` — Shared RFC 8252 loopback callback server (also used by Codex)
- `Services/Auth/PKCE.swift` — PKCE S256 challenge/verifier generator
- `Services/Auth/OAuthFormEncoding.swift` — `application/x-www-form-urlencoded` helper
- `Tools/MCPProviderTool.swift` — Wrapper for remote MCP tools
- `Views/Settings/ProvidersView.swift` — Two-step add flow: catalog grid + connect screen

**Features:**

- Provider catalog with search/filter for quick discovery
- One-tap OAuth 2.1 sign-in via PKCE + Dynamic Client Registration (no client ID/secret to configure)
- Manual-credentials OAuth 2.1 + PKCE for confidential-client vendors that don't publish DCR (HubSpot's MCP Auth Apps), with a fixed-port loopback redirect URI and Keychain-stored client secret
- API-key templates for vendors without DCR (GitHub, Atlassian, Zapier)
- Self-hosting templates (Google Workspace) that deeplink to setup docs
- Custom Server fallback for any HTTP/SSE URL or local stdio command not in the catalog
- HTTP/SSE transport for remote providers plus local stdio command launching on host or in the sandbox
- Automatic tool discovery on connect, with namespaced tool names (`provider_toolname`)
- Proactive OAuth token refresh + bounded 401-retry-with-refresh
- Configurable discovery and execution timeouts
- Streaming support (optional)
- Backwards-compatible `mcp.json` migration (legacy records default to bearer-token)

---

### MCP Server

**Purpose:** Expose Osaurus tools to AI agents via Model Context Protocol, either through local HTTP endpoints or through the `osaurus mcp` stdio command bridge.

**Components:**

- `Services/MCP/MCPServerManager.swift` — MCP server lifecycle
- `Networking/OsaurusServer.swift` — HTTP MCP endpoints
- `Packages/OsaurusCLI/Sources/OsaurusCLICore/Commands/MCPCommand.swift` — stdio MCP bridge for command-based clients
- `Tools/ToolRegistry.swift` — Tool registration and lookup
- `Tools/ToolEnvelope.swift` — Canonical success/failure envelope every tool returns (see [Tool Contract](TOOL_CONTRACT.md))
- `Tools/SchemaValidator.swift` — Argument validator with `additionalProperties` enforcement

**Endpoints:**
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/mcp/health` | GET | Health check |
| `/mcp/tools` | GET | List available tools |
| `/mcp/call` | POST | Execute a tool |

**Command bridge:**

```json
{"command": "osaurus", "args": ["mcp"]}
```

This command bridge is for external clients connecting to Osaurus. If Server > Network exposure is enabled, provide an access key with `OSAURUS_MCP_ACCESS_KEY` in the MCP client's environment or pass `--access-key` in the `args` array. It is separate from Remote MCP Providers, which only connect from Osaurus to URL-based HTTP/SSE MCP servers.

---

### Structured Document IO

**Purpose:** Preserve document structure for attachments before agent context assembly instead of flattening every business file into plain text.

**Components:**

- `Managers/Documents/DocumentAdaptersBootstrap.swift` — registers built-in document adapters.
- `Managers/Documents/DocumentFormatRegistry.swift` — routes read/write/stream registrations and exposes role snapshots for adapter compatibility checks.
- `Models/Documents/BusinessDocumentSummary.swift` — stable workbook/table/PDF/slides summary metadata for chat chips and prompt context.
- `Models/Documents/Workbook.swift` — typed workbook, sheet, row, and cell representation.
- `Models/Documents/PDFDocumentRepresentation.swift` — typed PDF pages and heuristic table detections with source anchors.
- `Models/Documents/PresentationDocument.swift` — typed deck, slide, note, table, and relationship representation.
- `Models/Documents/RichDocumentRepresentation.swift` — sections, headings, links, and metadata for rich text sources.
- `Services/Documents/CSVAdapter.swift` — CSV and TSV table parsing with bounded input handling.
- `Services/Documents/CSVEmitter.swift` — explicit CSV/TSV delimited-text export.
- `Services/Documents/CSVTableWorkflowService.swift` — schema previews, bounded samples, and safe CSV/TSV conversion/export validation.
- `Services/Documents/BusinessDocumentStudioService.swift` — one bounded inspect/preview/export orchestration layer across CSV/TSV, XLSX, PDF/PPTX, rich text, and text fallback workflows.
- `Services/Documents/XLSXAdapter.swift` — XLSX workbook parsing from Office Open XML packages.
- `Services/Documents/XLSXEmitter.swift` — XLSX workbook emission for round-trip workflows.
- `Services/Documents/WorkbookWorkflowService.swift` — workbook inspection, export availability, validation issues, and explicit emitter-backed save flow.
- `Services/Documents/PPTXAdapter.swift` — PPTX/POTX deck parsing from Office Open XML packages.
- `Services/Documents/PDFAdapter.swift` — PDF extraction with page-level anchors and layout-aware text-layer table detection.
- `Services/Documents/PDFPPTXWorkflowService.swift` — bounded PDF/PPTX previews plus structured creation availability diagnostics.
- `Services/Documents/RichDocumentAdapter.swift` — DOCX/RTF/HTML-style rich document structure extraction.
- `Services/Documents/ExternalOfficeRuntimeDetector.swift` — optional LibreOffice/OpenOffice discovery for future conversion flows; detection reads version metadata only and does not send document bytes to a runtime.

**Supported format surface:**

- CSV and TSV tables preserve headers, rows, delimiters, and source metadata. Explicit table workflow previews infer schema types from bounded samples, cap large-file reads, and validate CSV/TSV conversion/export before writing.
- XLSX workbooks preserve sheets, cells, formulas, merged ranges, shared strings, relationships, and export availability metadata. Explicit workbook save flows validate bounds, formulas, non-finite numbers, XML-safe text, merged ranges, and emitter availability before writing a minimal valid `.xlsx` package.
- Business Document Studio wraps registry lookup, bounded previews, export availability, safe destination containment, and text-fallback export into one service so UI, plugins, and attachment flows do not reimplement format-specific routing.
- PPTX/POTX decks preserve slide grouping, text runs, notes, slide tables, and relationships.
- PDFs preserve page boundaries, anchors, and simple text-layer tables so citations can point back to pages and detected table cells.
- PDF/PPTX workflow previews expose page/slide/table/notes metadata and report missing structured emitters instead of treating text writes as valid binary output.
- Rich documents preserve section boundaries, headings, links, and metadata.
- Structured attachments keep legacy text fallback compatibility while carrying format kind, structure counts, and security inspection facts into chat chips and `<attached_document>` context attributes.

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

**Purpose:** Provide Anthropic Messages API compatibility for Anthropic SDK-compatible clients.

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
- **Per-Agent Feature Gates** — Configure → Features groups every capability by purpose and keeps extra ones off by default to keep the tool list lean (see below)
- **Visual Themes** — Assign a custom theme that activates with the agent
- **Generation Settings** — Configure default model, temperature, and max tokens
- **Import/Export** — Share agents as JSON files for backup or sharing
- **Live Switching** — Click to activate a agent, theme updates automatically
- **Host Files (per-agent folder grant)** — Optionally grant the agent a real macOS folder it may read and write inside, including over an authenticated remote agent run (Secure Channel). Writes stay inside the folder; shell and git remain disabled. Configure → Features → Host Files; see [SECURITY.md](SECURITY.md) and [OpenAI_API_GUIDE.md](OpenAI_API_GUIDE.md).

**Feature Gates (Configure → Features):** stored on `Agent.settings`; [`SystemPromptComposer.resolveTools`](../Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift) strips the matching tools when a gate is off (auto mode). Capabilities are grouped by purpose; extra ones default **off** to reduce token cost.

| Group | Setting | Toggle | Default | Gates |
|---|---|---|---|---|
| Model Access | `disableTools` (inverted) | Tools | on | All tool use |
| Model Access | `disableMemory` (inverted) | Memory | on | Passive memory injection + recording |
| Output | `renderChartEnabled` | Charts | off | `render_chart` |
| Output | `speakEnabled` | Voice | off | `speak` |
| Memory & Recall | `searchMemoryEnabled` | Memory Recall | off | `search_memory` |
| Autonomy | `selfSchedulingEnabled` | Self-scheduling | off | `schedule_next_run` / `cancel_next_run` / `notify` + scheduling UI |
| Autonomy | `computerUseEnabled` | Computer Use | off | `computer_use` entry tool (custom agents only; plus per-agent autonomy ceiling) |
| Data | `dbEnabled` | Database | off | `db_*` tools + DB tabs |
| Code Execution | sandbox settings | Autonomous Execution / Plugin Creation / Sandbox Network / Read Secret Files | off | Sandbox capabilities (visible but disabled when the container isn't running) |

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
| `hostWorkspaceBookmark` | Machine-local security-scoped bookmark for a host folder the agent may read/write inside; mounted only for authenticated remote agent runs (never sent to a paired peer) |
| `hostWorkspacePath` | Advisory display path for the host workspace folder (source of truth is the bookmark) |

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
- **Configurable Responsiveness** — Six debounce tiers from ~200ms (Fast) to ~10 minutes (Extended) for everything from screenshot capture to "settle then commit" wiki workflows
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
| `responsiveness` | Debounce timing: fast, balanced, patient, relaxed, deferred, or extended |
| `lastTriggeredAt`| When the watcher last ran                          |
| `lastChatSessionId` | Chat session ID from the last run               |

**Responsiveness Options:**

| Option   | Debounce Window | Best For                                                 |
| -------- | --------------- | -------------------------------------------------------- |
| Fast     | ~200ms          | Screenshots, single-file drops                           |
| Balanced | ~1s             | General use (default)                                    |
| Patient  | ~3s             | Downloads, batch operations                              |
| Relaxed  | ~1 minute       | Note-taking, wiki edits, active editing sessions         |
| Deferred | ~5 minutes      | Extended writing sessions, periodic syncs                |
| Extended | ~10 minutes     | End-of-session checkpoints, long-running activity        |

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

- `Services/Chat/AgentToolLoop.swift` — The canonical loop driver shared by chat, HTTP, plugin, and eval surfaces: `AgentLoopPolicy` knobs, exit taxonomy, two-phase parallel batch execution, driver-staged `[System Notice]` lines, and the shared `AgentLoopBudget` window/budget math
- `Services/Chat/AgentTaskState.swift` — Per-task harness state: result classification, fresh-read dedupe, reactive next-step bias
- `Services/Chat/ContextBudgetManager.swift` + `Services/Chat/CompactionWatermark.swift` — Budget reservations and sticky, KV-prefix-stable history compaction (monotonic summarize→drop decisions, byte-stable trim note, `overBudget` signal)
- `Services/Context/AgentLoopEvaluator.swift` — Drives the same loop end-to-end for the OsaurusEvals `agent_loop` proof suite
- `Tools/AgentLoopTools.swift` — The three chat-layer-intercepted loop tools (`todo`, `complete`, `clarify`); registered as global built-ins
- `Tools/FolderToolManager.swift` — Registers folder tools when a working folder is selected; unregisters on clear. `share_artifact` is no longer registered here — it lives as a global built-in alongside the loop tools.
- `Folder/FolderContext.swift` — Project type, file tree, manifest, git status, optional `AGENTS.md`/`CLAUDE.md`/`.cursorrules`
- `Folder/FolderContextService.swift` — `NSOpenPanel`, security-scoped bookmark persistence, MainActor service
- `Folder/FolderTools.swift` — File / shell / git tool implementations + `FolderToolFactory`
- `Folder/ChatExecutionContext.swift` — TaskLocal session/agent/batch IDs read by tools at execution time
- `Folder/ExecutionMode.swift` — First-class `.hostFolder | .sandbox(hostRead:) | .none` enum (the sandbox case carries an optional read-only host folder for combined mode)
- `Folder/FileOperation.swift`, `Folder/FileOperationLog.swift` — Per-op log used for undo
- `Models/Chat/AgentTodo.swift`, `Models/Chat/AgentTodoStore.swift` — Markdown checklist parser + per-session store
- `Models/Chat/SharedArtifact.swift` — Artifact model surfaced via `share_artifact`

**Features:**

- **Unified loop** — One chat is one task; no separate Agent/Work tab
- **One canonical driver** — Chat, HTTP `/v1/chat/completions`, the plugin host, and the eval harness all run `AgentToolLoop`; surface differences are named `AgentLoopPolicy` knobs, not forked loops
- **Parallel tool batches** — Multi-call model steps execute concurrently with serial-equivalent semantics: approvals resolve serially in model order before anything runs, read-duplicates within a batch replay the sibling's result, and `complete`/`clarify` batches fall back to serial so post-intercept siblings never execute
- **KV-stable compaction** — History trimming is sticky and monotonic (`CompactionWatermark`), so the rendered prompt prefix stays byte-stable across iterations and the paged-KV cache keeps its hits; UI and runtime share one budget assessment (`AgentLoopBudget.assess`) so the context chip and the send gate can't disagree with the trimmer
- **`todo` / `complete` / `clarify`** — Three minimal-schema global built-in tools whose results the chat layer intercepts to drive the inline UI (not a pre-dispatch hook — the registry runs them like any other tool)
- **Single mode resolver** — `ToolRegistry.resolveExecutionMode(folderContext:autonomousEnabled:)` decides sandbox > host folder > none for chat, plugin, and HTTP entry points
- **Working folder picker** — Per-chat folder via `FolderContextService`, with security-scoped bookmark persistence
- **Project-aware tools** — Core file tools + `shell_run` registered for every folder mount; git tools layered on when the folder is a git repo. Project type only changes the file-tree ignore patterns (and prompt metadata), not the tool surface.
- **Sandbox toggle** — Composes with the working-folder backend. Sandbox-only keeps current behavior; **combined mode** (sandbox on + folder selected → `.sandbox(hostRead: ctx)`) exposes the host workspace **read-only** (`file_read` / `file_search`, scoped to the folder root, secret files refused; `file_read` also lists directories) while all execution stays in the sandbox VM, which has no mount of the host workspace. Host write/edit/shell/git stay hidden in combined mode. Residual risks (the trusted agent is the read→exec bridge, prompt injection from read content, in-scope secrets) are mitigated by scope enforcement + secret refusal; v1 keeps sandbox network-on, so document the exfiltration residual rather than relying on isolation.
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
| `file_read`       | Core     | Read a file (text ranges, `tail_lines`/`max_chars`, bounded XLSX sheet previews) **or** list a directory (with `max_depth`, project-aware ignore patterns) — the path decides. A directory returns a structured `kind: "listing"` with `entries[]` (each a ready-to-use `path`), not an ASCII tree |
| `file_write`      | Core     | Create or overwrite UTF-8 text files with `dry_run` diff/risk previews; refuses `.xlsx`, `.pdf`, and `.pptx`-family structured targets so package output goes through a structured writer |
| `file_edit`       | Core     | Surgical exact-string replacement with optional `dry_run` diff preview |
| `file_operation_history` | Core | Recent applied file writes/edits for the current chat session |
| `file_search`     | Core     | ripgrep-style content search, or `target="files"` filename-glob find |
| `shell_run`       | Core     | Run a shell command (requires approval). Reserve for `mv`/`cp`/`rm`/`mkdir`, builds, tests, git, installs. |
| `git_status`      | Git      | Repository status. Registered when `.git` present.                |
| `git_diff`        | Git      | Show diffs                                                        |
| `git_commit`      | Git      | Stage + commit (requires approval)                                |

The previously-discrete `file_move`, `file_copy`, `file_delete`, `dir_create`, and `batch` tools were dropped — the same operations go through `shell_run` (`mv`, `cp`, `rm`, `mkdir`) so the model has fewer near-identical tool names to differentiate. The standalone `file_tree` listing tool was likewise folded into `file_read`: pass a directory path and `file_read` returns a listing (the path carries the file-vs-directory decision, so there is no separate tool for the model to mis-select). That listing is a **structured `entries[]` object**, not a prose tree — the model descends by copying an entry's `path` field, and the agent loop's [`AgentTaskState`](../Packages/OsaurusCore/Services/Chat/AgentTaskState.swift) harness classifies the result to de-dupe re-reads and, only if the model is observed wandering (two listings without a read), reactively nudge the next step — so capable models are never backseat-driven. See [Agent Loop — Harness Task State](AGENT_LOOP.md#harness-task-state-agenttaskstate).

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
- **Per-agent SOUL.md** — Each sandboxed agent gets a self-editable `~/SOUL.md` for stable preferences and patterns, persisted across sessions. Seeded on first provision; rendered into the system prompt as a `## SOUL` section between persona and operational directives. See [SANDBOX.md](SANDBOX.md).
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
| `sandbox_read_file` | Read-only | Read file contents (supports line ranges and log tails). Use instead of `cat`/`head`/`tail`. |
| `sandbox_search_files` | Read-only | Search file contents (`target="content"`, ripgrep) **or** find files by name (`target="files"`, glob). Replaces the old `sandbox_search_files` + `sandbox_find_files` + `sandbox_list_directory` trio. |
| `sandbox_write_file` | Write | Write a whole file (`content`, creates parent directories) **or** edit it in place (`old_string`+`new_string`, exact match) — the presence of `old_string` selects the edit path. Use instead of `echo`/`cat` heredoc / `sed` / `awk`. |
| `sandbox_exec` | Exec | Run shell command. Foreground (default) or `background:true` for servers/long jobs. |
| `sandbox_process` | Exec | Manage background jobs from `sandbox_exec(background:true)` — `poll` / `wait` / `kill`. |
| `sandbox_install` | Package | Install packages — one tool, `manager` selects `apk` (system, root), `pip` (Python venv), or `npm` (Node workspace). Replaces the old `sandbox_pip_install` + `sandbox_npm_install`. |
| `sandbox_secret_check` | Secret | Check whether a secret exists (never reveals value) |
| `sandbox_secret_set` | Secret | Store a secret directly or prompt the user |
| `sandbox_plugin_register` | Plugin | Register an agent-created plugin (requires `pluginCreate`) |

The previously-discrete `sandbox_list_directory`, `sandbox_find_files`, `sandbox_move`, `sandbox_delete`, `sandbox_exec_background`, `sandbox_run_script`, `sandbox_edit_file`, and `sandbox_execute_code` tools were dropped. Their behaviour now comes from a flag (`background:true` on `sandbox_exec`, `target` on `sandbox_search_files`), an argument (`old_string`+`new_string` on `sandbox_write_file` for in-place edits), or a direct shell invocation (`mv` / `rm` in `sandbox_exec`). `sandbox_run_script` and `sandbox_execute_code`'s use case — multi-step scripts/orchestration — is now `sandbox_write_file` the script then `sandbox_exec` to run it (e.g. `python3 script.py`). The `sandbox_pip_install` / `sandbox_npm_install` tools were folded into `sandbox_install` (pick the manager with `manager:"pip"` / `"npm"`); a failed bare `apk add` / `pip install` / `npm install` in `sandbox_exec` surfaces a self-heal hint pointing at `sandbox_install`.

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
| `~/.osaurus/container/workspace/agents/{name}/SOUL.md` | Per-agent SOUL identity layer (seeded on first provision) |
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
- **Conversation grouping** — plugins that pass `session_id` (e.g. Telegram chat id) reattach to the same session on subsequent dispatches instead of creating a new row each time; see [`docs/plugins/HOST_API.md`](plugins/HOST_API.md#dispatch)

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
- **MCP provider tools** — Tools from URL-based remote MCP servers

**Plugin Capabilities (v2):**

| Capability | Manifest Key          | Description                                          |
| ---------- | --------------------- | ---------------------------------------------------- |
| Tools      | `capabilities.tools`  | AI-callable functions                                |
| Routes     | `capabilities.routes` | HTTP endpoints (OAuth, webhooks, APIs)               |
| Config     | `capabilities.config` | Native settings UI with validation                   |
| Web        | `capabilities.web`    | Static frontend serving with context injection       |
| Docs       | `docs`                | README, changelog, and external links                |

See [docs/plugins/README.md](plugins/README.md) for the full reference.

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
- **Automated Discovery** — Skills are listed in the enabled-capabilities manifest and loaded on demand via `capabilities_discover` / `capabilities_load`

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

### Claude Plugin Import

**Purpose:** Import full Claude plugins from GitHub — skills, scheduled agents, slash commands, MCP providers, and shared `CLAUDE.md` context — as a single managed bundle, surfaced as cards in the **Plugins** tab alongside native Osaurus plugins.

**Components:**

- `Services/GitHubSkillService.swift` — Repository discovery, `marketplace.json` parsing, directory-based artifact probing, `.claude-plugin/plugin.json` decoding, version resolver, GitHub rate-limit detection
- `Services/Skill/ClaudePluginInstaller.swift` — Per-plugin install/uninstall orchestrator, idempotent re-install, MCP placeholder-token detection, cron inference, manifest snapshot write + userConfig hookup, `${CLAUDE_PLUGIN_*}` substitution into MCP entries and skill bodies
- `Services/Skill/ClaudePluginManifestStore.swift` — Per-plugin manifest + userConfig persistence under `~/.osaurus/claude-plugins/`; per-plugin data dir lifecycle
- `Services/Skill/ClaudePluginVariableExpander.swift` — `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_DATA}` / `${user_config.KEY}` / allow-listed `${ENV}` substitution; `CLAUDE_PLUGIN_OPTION_*` subprocess env overlay
- `Services/Plugin/InstalledClaudePluginsAggregator.swift` — Card-friendly aggregator that joins manifest snapshots with live manager counts and runs the update probe
- `Views/Plugin/PluginsView.swift` — Plugins tab hosting both native and Claude plugin cards in a single Installed grid
- `Views/Plugin/GitHubImportSheet.swift` — Import UI with concurrent fetch progress and deep-linkable install summary
- `Views/Plugin/ClaudePluginCard.swift`, `Views/Plugin/ClaudePluginDetailView.swift`, `Views/Plugin/ClaudePluginUserConfigSheet.swift` — Claude-specific UI surfaces (Imported badge, Update affordance, Configure sheet, CHANGELOG section)
- `Managers/ManagementStateManager.swift` — Deep-link state for opening a schedule editor from the install summary

**Features:**

- **Unified Plugins tab** — Claude plugins render as cards mixed into the same `Installed` grid as native `PluginCard`s, distinguished by an `Imported` badge; **Skills** tab is now only for user-authored and built-in skills
- **Marketplace + per-plugin manifest** — Reads both `.claude-plugin/marketplace.json` (legacy flat skill arrays, directory-based, external `url` / `git-subdir` shapes) and `<source>/.claude-plugin/plugin.json` (displayName, version, author, homepage, repository, license, keywords, userConfig)
- **Five artifact families** — `SKILL.md`, `agents/*.md`, `commands/*.md`, `CLAUDE.md`, `.mcp.json` (HTTP/SSE and sandbox stdio)
- **Plugin id grouping** — Every artifact tagged `github:<owner>/<repo>/<plugin>` so the bundle reinstalls / uninstalls atomically; manifest snapshot persisted at `~/.osaurus/claude-plugins/manifests/<safe-id>.json`
- **Idempotent re-install + Update flow** — Card and detail view both show an Update capsule when the source's `plugin.json.version` (or marketplace / source SHA) is newer than what's installed; clicking Update calls `ClaudePluginInstaller.install(replaceExisting: true)` to re-fetch and replace the artifact set
- **`userConfig` prompt sheet** — When `plugin.json` declares `userConfig`, an in-app sheet collects values at install. Non-sensitive values land in `~/.osaurus/claude-plugins/userconfig/<safe-id>.json`; sensitive values go to the macOS Keychain (skipped under `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`)
- **Variable substitution** — `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_DATA}` / `${user_config.KEY}` / allow-listed `${ENV}` resolve in MCP command/args/cwd/env and in skill bodies (sensitive values are env-only per spec)
- **Persistent data dir** — `~/.osaurus/claude-plugins/data/<safe-id>/` is created lazily on first `${CLAUDE_PLUGIN_DATA}` reference and removed on uninstall
- **Parallel discovery & fetch** — `withThrowingTaskGroup` + `async let` across plugins and artifact probes
- **Cron inference** — Natural-language frequency text in agent frontmatter is mapped to cron; unmatched schedules land disabled with a deep-link to the editor
- **Placeholder token handling** — MCP env references like `${VAR}`, `$VAR`, `<token>` are detected and the provider is created without a token (surfaced in the install summary)
- **Rate-limit aware** — `403` + `X-RateLimit-Remaining: 0` is mapped to `GitHubSkillError.rateLimited(resetAt:)` and a user-facing relative-time message

**Plugin ID format:**

```
github:<owner>/<repo>/<plugin-name>
```

Stored on each artifact as `Skill.pluginId`, `Schedule.parameters["pluginId"]`, `SlashCommand.pluginId`, and `MCPProvider.pluginId`. Snapshot persisted under the same id (sanitised via `OsaurusPaths.claudePluginSafeId`).

**Not yet honored:** hooks, lspServers, outputStyles, themes/monitors (experimental), channels, bin/ PATH exports, install scopes. The detail view surfaces a "declared but not yet honored" notice so plugin authors aren't blindsided.

**Reference repository:** [`anthropics/claude-for-legal`](https://github.com/anthropics/claude-for-legal)

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

**Agent Tools:** Methods are loaded by the agent indirectly via `capabilities_discover` / `capabilities_load` (loading a method auto-loads its referenced tools and skills). The dedicated `methods_save` / `methods_report` tools were removed from the schema — recording method outcomes is now an internal observation, not an agent-facing concern.

**Storage:** `~/.osaurus/methods/methods.db` (SQLite with WAL mode)

---

### Context Management

**Purpose:** Give the agent a complete, statically-ordered view of every enabled capability (methods, tools, and skills) and let it load the ones it needs on demand.

Context management replaces manual per-turn tool selection with a static, session-frozen design. The system prompt carries an enabled-capabilities manifest that lists every capability the agent is allowed to use; only a fixed "hot set" of tools is loaded into the schema up front. The agent pulls in additional capabilities mid-session with `capabilities_discover` / `capabilities_load`. The manifest and hot set are frozen at session start so the static prompt prefix stays byte-stable across turns (KV-cache reuse), and there is no per-turn LLM picker.

**Components:**

- `Services/Tool/ToolSearchService.swift` — VecturaKit hybrid search over tools
- `Services/Tool/ToolIndexService.swift` — Syncs ToolRegistry into searchable index and exposes named-tool diagnostics
- `Services/Context/CapabilitySearch.swift` — Index-search backend for `capabilities_discover`
- `Storage/ToolDatabase.swift` — SQLite storage for tool index
- `Tools/CapabilityTools.swift` — Runtime capability search and load tools

**Runtime Capability Tools:**

For on-demand discovery during a session, agents can use:

| Tool                  | Description                                                       |
| --------------------- | ----------------------------------------------------------------- |
| `capabilities_discover` | Search methods, tools, and skills across all indexes in parallel  |
| `capabilities_load`   | Load a capability by ID into the active session (tools become callable immediately) |

When `capabilities_load` is called, new tool specs are queued in a `CapabilityLoadBuffer` and drained after the invocation. Loaded tools are callable immediately (the registry dispatches by name), but the rendered tool schema stays frozen until the next user turn — hot-patching it mid-run would rewrite the prompt prefix and bust the KV cache. The loaded names persist on the session's tool state, so the next compose includes their full schemas.

When `capabilities_discover` finds no matches for a query that explicitly names a tool, it appends a typed exposure diagnostic for those names: registry availability, global enablement, index presence, and whether capability search can surface the tool. This distinguishes already-loaded built-ins from disabled, agent-hidden, runtime-managed, unindexed, or missing tools without adding new default tools.

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

**HTTP API:** `POST /memory/ingest` writes transcripts and then distills synchronously after the batch — it forces an on-demand cold load of the core model when it isn't resident, awaits the single distill call, and reports the outcome (`distillation`, `episode_id`) in the response instead of a blind `{"status":"ok"}`. It is idempotent per `conversation_id` (re-ingest clears that conversation's prior pending signals + episodes), canonicalizes a UUID `agent_id`, and dead-letters sessions that keep failing so they stop re-distilling forever. `GET /agents` / `GET /agents/{id}` report `memory_entry_count` as stored memory (episodes + active pinned facts). Strict `/chat/completions` requests do not inject read-side memory; app chat, `POST /agents/{id}/run`, and plugin host inference own composed agent context.

**Storage:** `~/.osaurus/memory/memory.sqlite` (SQLite with WAL mode), `~/.osaurus/memory/vectura/` (vector index)

---

### Privacy Filter

**Purpose:** Scrub sensitive content from cloud-bound requests on the way out and unscrub the placeholders on the way back. Two independent layers: a **deterministic regex** layer (built-ins + presets + custom rules) that ships on and needs **zero download**, and an **opt-in on-device AI classifier** — OpenAI's `openai/privacy-filter` (Apache-2.0, 1.5B / 50M-active sparse-MoE token classifier), served through the MLX conversion `mlx-community/openai-privacy-filter-bf16` (~2.8 GB) — that adds the fuzzy categories (names, addresses, secrets) only when `aiDetectionEnabled` is on. Fail-closed on every write path — no substitutions applied or post-scrub leak detected blocks the send with a typed error; with AI detection on, a missing model also blocks; with it off, detection is regex-only and never blocks on the model. See [PRIVACY_FILTER.md](PRIVACY_FILTER.md) for the full architecture.

**Components:**

- `PrivacyFilter/Core/PrivacyFilterPipeline.swift` — `applyOutbound` / `wrapInboundStream` / `unscrubInbound` orchestration with typed `PrivacyFilterPipelineError`
- `PrivacyFilter/Core/PrivacyFilterEngine.swift` — Ensemble of regex + classifier detection over a message history
- `PrivacyFilter/Core/RegexEntityDetector.swift` — Built-in + preset + custom regex detection, with `safeCompile` validation
- `PrivacyFilter/Core/PrivacyRulePresets.swift` — Ship-list of opt-in preset rules (driver's license, passport, IBAN, AWS keys, GitHub tokens)
- `PrivacyFilter/Core/Placeholder.swift` — `EntityCategory` enum + `[CATEGORY_N]` wire format
- `PrivacyFilter/Core/RedactionMap.swift` — Per-conversation `original ↔ placeholder` intern
- `PrivacyFilter/Core/CodeBlockMasker.swift` — Skip-code-blocks pass for the `skipCodeBlocks` config
- `PrivacyFilter/Core/StreamingUnscrubber.swift` — Splices into the inbound byte stream and rewrites placeholders on the fly
- `PrivacyFilter/Store/SessionRedactionStore.swift` — Actor holding one `RedactionMap` per `sessionId` + auto-approve session set
- `PrivacyFilter/Core/PrivacyReviewService.swift` — Modal review presenter registry + `withTaskCancellationHandler` continuation contract
- `PrivacyFilter/Vendor/PrivacyFilterKit/` — Vendored detection kit (BIOES decoder, Viterbi calibration, label vocabulary)
- `PrivacyFilter/Model/PrivacyFilterModelBundle.swift` — On-disk layout + SHA-256 verifier
- `PrivacyFilter/Model/PrivacyFilterModelDownloader.swift` — Hugging Face streaming download + manifest synthesis
- `PrivacyFilter/Store/PrivacyFilterConfiguration.swift` — Persisted user settings (Codable, hand-rolled decoder for forward-compat defaults)
- `PrivacyFilter/Store/PrivacyFilterStore.swift` — JSON-on-disk persistence + lock-protected in-memory snapshot (synchronous `save`)
- `PrivacyFilter/Views/PrivacyView.swift` — Settings UI: 4 sub-tabs always rendered (no model gate); AI-detection toggle + no-detector note in Overview; dry-run tester in Rules; install hero lives inside the Model tab
- `PrivacyFilter/Views/RedactionReviewSheet.swift` — Modal review with scrubbed preview + hover-reveal
- `PrivacyFilter/Views/RedactionPreviewBuilder.swift` — Pure helper that scrubs text and builds the highlight map for the preview pane
- `PrivacyFilter/Views/RedactionPreviewTextView.swift` — `NSViewRepresentable` that reuses the chat highlighter inside the review sheet
- `PrivacyFilter/Views/PrivacyCustomRuleEditor.swift` — Custom-rule editor sheet: Simple (no-regex builder) / Regex modes, case toggle, custom placeholder label, live test panel
- `Views/Chat/RedactionHighlighter.swift` — Walks `NSTextStorage` and applies underline + accent to placeholder ranges (chat bubbles + preview)
- `Views/Chat/RedactionHoverController.swift` — Hover-tracked `NSPopover` tooltip with direction-aware copy (outbound / inbound / preview)
- `Services/Provider/WireTransportProbe.swift` — Captures the post-scrub HTTP body + pre-unscrub inbound stream for the Insights surface

**Detection layers (run sequentially, union by `(category, range)`):**

| Layer | Source | Default |
|-------|--------|---------|
| Built-in regex | `RegexEntityDetector` | Phone / email / URL / account number — all on, toggled per-category |
| Preset rules | `PrivacyRulePresets.all` | Driver's license, passport, IBAN, AWS keys, GitHub tokens — all opt-in |
| Custom rules | `PrivacyFilterConfiguration.customRules` | User-defined; Simple (no-regex builder) or raw Regex, per-rule case flag + optional custom placeholder label; validated/escaped before save |
| On-device classifier | `PrivacyFilterKit` over OpenAI's `openai/privacy-filter` (MLX BF16 conversion) | **Opt-in (off by default)** via `aiDetectionEnabled`; BIOES decoder + Viterbi calibration; emits 8 categories (`person`, `email`, `phone`, `url`, `address`, `date`, `accountNumber`, `secret`) |

**Placeholder wire format:** `[PERSON_1]`, `[EMAIL_2]`, `[PHONE_1]`, `[URL_1]`, `[ADDR_1]`, `[ACCT_1]`, `[DATE_1]`, `[SECRET_1]`. Per-category, per-conversation indexing. `RedactionMap` interns by original so the same value across turns reuses one placeholder.

**Fail-closed errors:**

| Case | When it fires |
|------|---------------|
| `.reviewCanceled` | User dismissed the review sheet (or task cancelled while suspended on it) |
| `.engineUnavailable(detail)` | AI detection on, model bundle missing / failed to load (regex-only sends never hit this) |
| `.scrubNoOp(approvedCount)` | Approved entities produced zero substitutions (almost certainly a wiring bug) |
| `.scrubLeaked(categoryCounts)` | Post-scrub re-scan found PII the substitution missed; send is blocked |

The post-scrub invariant only re-scans categories whose built-in regex toggle is enabled — same source of truth as detection, so turning a category off in settings turns off both halves.

**Configuration:**

| Setting | Default | Description |
|---------|---------|-------------|
| `enabled` | false | Master toggle (regex layer; no model required; synchronous persistence; survives Cmd-Q) |
| `aiDetectionEnabled` | false | Opt into the on-device AI classifier; on → load model + fail closed if missing, off → regex-only. Legacy files missing the key decode to `true` (preserve existing model users) |
| `skipCodeBlocks` | true | Skip fenced + inline code spans |
| `alwaysApproveByDefault` | false | Skip the review sheet per-session |
| `builtinPatternEnabled` | all on | Per-category regex toggle (controls detection + leak check) |
| `presetRules` | `{}` | Opt-in preset rule map |
| `customRules` | `[]` | User-defined `PrivacyRule` array (`kind`, `caseSensitive`, optional `builder` + `placeholderLabel`) |
| `providerOverrides` | `{}` | Per-`RemoteProvider.id` enable map; missing keys → true |

**Storage:**

- `~/.osaurus/config/privacy-filter.json` — User configuration (plaintext, atomic write)
- `~/.osaurus/aux-models/openai-privacy-filter-bf16-v1/` — Model bundle + locally-generated `osaurus-manifest.json` for SHA-256 re-verify

**Verification surface:** Open **Insights** (`⌘ Shift I`) → pick a request → **Request** / **Response** tabs. The **Server Request** / **Server Response** sub-sections show the exact bytes captured by `WireTransportProbe` (post-scrub on the way out, pre-unscrub on the way in) so users can confirm at a glance that placeholders actually made it onto the wire.

---

### Computer Use

**Purpose:** Let a custom agent operate a macOS app on the user's behalf to accomplish a natural-language goal — working primarily from the **accessibility tree**, with a **screenshot** fallback only when an element can't be resolved. Off by default, enabled **per agent** (custom agents only), with a **safe-by-default autonomy gate** on every action. See [COMPUTER_USE.md](COMPUTER_USE.md) for the full architecture.

**Mental model:** the parent agent calls one tool — `computer_use(goal:)` — exactly once. It spins up a **nested subagent** (the `sandbox_reduce` pattern) that runs a `perceive → decide → gate → act → verify` loop and returns a single summary. The model only proposes the next intent (one `agent_action` per step, forced `tool_choice`); the harness owns every deterministic decision. Inner steps never enter the parent transcript — they surface only through the live `ComputerUseFeed` in the chat row.

**Components:**

- `ComputerUse/Tool/ComputerUseTool.swift` — the `computer_use` entry tool (PermissionedTool: Accessibility preflight; stripped from the schema unless `computerUseEnabled`)
- `ComputerUse/Loop/ComputerUseLoop.swift` — the perceive→decide→gate→act→verify controller (`RunLimits`, `RunOutcome`)
- `ComputerUse/Model/AgentAction.swift` — the single model-facing `agent_action` envelope (constrained verb enum + schema-validated decode + bounded re-ask)
- `ComputerUse/Driver/NativeMacDriver.swift` + `Driver/Mac/*` — AX / SOM / Vision capture and synthetic input
- `ComputerUse/Perception/CaptureRouter.swift`, `FrameScrubber.swift`, `CloudVisionConsent.swift`, `VisionAttachment.swift` — the local-first perception ladder and cloud-vision boundary
- `ComputerUse/Perception/ScreenContextDistiller.swift`, `ScreenContextSnapshot.swift`, `FrontmostAppTracker.swift` + `Services/Chat/SystemPromptComposer.swift` (`injectScreenContextPrefix`) — per-agent frozen **Screen context** injected into chat (gated by `Agent.settings.screenContextEnabled` + Computer Use)
- `ComputerUse/Policy/EffectClassifier.swift`, `AutonomyPolicy.swift`, `ComputerUseGate.swift`, `ComputerUsePolicyStore.swift` — effect classification + strictest-wins autonomy gate
- `ComputerUse/Recipes/AppRecipe.swift` — per-app effect signals + flow hints
- `Views/Settings/ComputerUseSettingsView.swift`, `Views/Chat/ComputerUseFeedView.swift` — settings panel + live activity feed

**Effect → disposition (autonomy presets):** every action is classified as `read` / `navigate` / `edit` / `consequential` (the classifier can only ever escalate), then resolved to `allow` / `confirm` / `deny`.

| Preset | navigate | edit | consequential |
|--------|----------|------|---------------|
| `read_only` | allow | deny | deny |
| `cautious` | confirm | confirm | confirm |
| **`balanced`** (default) | allow | confirm | confirm |
| `trusted` | allow | allow | confirm |
| `autonomous` | allow | allow | allow |

`read` is always `allow`. The effective disposition merges **strictest-wins** across the global preset, an optional per-app override (can only add caution), and an optional per-agent **ceiling**. An optional **allowlist** — when set — is checked first and rejects any app not on it (the `open` verb is gated the same way).

**Perception ladder:** `ax` (accessibility tree, no pixels) → `som` (AX tree + annotated screenshot; the default capture mode) → `vision` (un-annotated screenshot; the AX tree is still gathered for ids). Escalation past `ax` needs **Screen Recording**; without it the loop stays AX-only. A frame reaches a **cloud** model only via a route that requires **explicit consent** (off by default) and a `ScrubbedFrame` (on-device Vision OCR + `RegexEntityDetector` masking) — making an unconsented or unscrubbed cloud send unrepresentable in the type system.

**Screen context (chat):** a **per-agent** option nested under Computer Use (`Agent.settings.screenContextEnabled`, on by default, gated by `computerUseEnabled` — so off for any agent without Computer Use, including the Default agent). On the first send of a chat session it **freezes** a distilled, text-only, Accessibility-only snapshot of the working app, focused draft, and open windows, then injects it onto the **latest user turn** (`SystemPromptComposer.injectScreenContextPrefix`, the same seam as memory) so it rides through the Privacy Filter before any cloud send. New code lives under `ComputerUse/Perception/ScreenContext*` + `FrontmostAppTracker`; the effective gate resolves in `AgentManager.effectiveCapabilities`. See [COMPUTER_USE.md](COMPUTER_USE.md#screen-context-chat).

**Telemetry:** one coarse, privacy-clean `computer_use_run` event per run (outcome, max tier, bucketed step/confirm counts, ax-resolvable + verify-pass rate buckets, dead-end / block / cloud-vision flags) — no goal text, app names, or per-step detail.

**Storage:**

| Path / key | Purpose |
|------------|---------|
| `~/.osaurus/config/computer-use.json` | `AutonomyPolicy` (global preset + per-app overrides + allowlist) via `ComputerUsePolicyStore` |
| `UserDefaults` `ai.osaurus.computeruse.cloudVisionConsent` | Persisted cloud-vision opt-in (default `false`) |
| `Agent.settings.computerUseEnabled` / `computerUseCeiling` / `screenContextEnabled` | Per-agent enablement + autonomy ceiling + screen-context opt-in (in the agent JSON); `screenContextEnabled` defaults `true`, gated by `computerUseEnabled` |

---

## Documentation Index

| Document                                                       | Purpose                                           |
| -------------------------------------------------------------- | ------------------------------------------------- |
| [README.md](../README.md)                                      | Project overview, quick start, feature highlights |
| [FEATURES.md](FEATURES.md)                                     | Feature inventory and architecture (this file)    |
| [MODEL_COMPATIBILITY_RESEARCH.md](MODEL_COMPATIBILITY_RESEARCH.md) | Local model compatibility research and rollout plan |
| [WATCHERS.md](WATCHERS.md)                                     | Watchers and folder monitoring guide              |
| [AGENT_LOOP.md](AGENT_LOOP.md)                                 | Agent loop, folder context, and `todo`/`complete`/`clarify` |
| [REMOTE_PROVIDERS.md](REMOTE_PROVIDERS.md)                     | Remote provider setup and configuration           |
| [REMOTE_MCP_PROVIDERS.md](REMOTE_MCP_PROVIDERS.md)             | Remote MCP provider setup                         |
| [DEVELOPER_TOOLS.md](DEVELOPER_TOOLS.md)                       | Insights and Server Explorer guide                |
| [VOICE_INPUT.md](VOICE_INPUT.md)                               | Voice input, FluidAudio, and VAD mode guide       |
| [SKILLS.md](SKILLS.md)                                         | Skills, methods, and context management guide    |
| [CLAUDE_PLUGINS.md](CLAUDE_PLUGINS.md)                         | Importing Claude plugins from GitHub             |
| [MEMORY.md](MEMORY.md)                                         | Memory system and configuration guide            |
| [PRIVACY_FILTER.md](PRIVACY_FILTER.md)                         | Privacy Filter architecture, detection layers, settings, and verification |
| [SANDBOX.md](SANDBOX.md)                                       | Sandbox VM and plugin guide                       |
| [COMPUTER_USE.md](COMPUTER_USE.md)                             | Computer Use harness, autonomy gate, and cloud-vision boundary |
| [plugins/README.md](plugins/README.md)                         | Creating custom plugins                           |
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
