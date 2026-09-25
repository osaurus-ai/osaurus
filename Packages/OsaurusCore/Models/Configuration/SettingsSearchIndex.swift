//
//  SettingsSearchIndex.swift
//  osaurus
//
//  Declarative index of searchable settings across every management tab.
//  Phase 1 of global settings search: the sidebar search field queries this
//  index and presents cross-tab results, so a setting like "Transcription"
//  (which lives in the Voice tab) is findable from anywhere — not just the
//  Settings tab. Selecting a result navigates to its tab.
//
//  Each entry is declared once here. Keep it in sync with the UI; the leaf
//  `title`/`section` strings should mirror what the tab actually shows. A
//  future phase can add a deep-link `anchor` so selecting a result also
//  scrolls to and glows the specific control.
//

import Foundation

/// A single searchable setting, addressable by the tab (and human-readable
/// section) it lives in. `keywords` widen matching beyond the visible title
/// (synonyms, related terms) so natural queries land.
public struct SettingsSearchEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let tab: ManagementTab
    /// Human-readable area within the tab, e.g. "Speech to Text". May be empty
    /// for flat tabs.
    public let section: String
    /// The setting's visible title, e.g. "Transcription Model".
    public let title: String
    /// Extra match terms (synonyms, related words) beyond title/section/tab.
    public let keywords: [String]
    /// For tabs with their own inner navigation (e.g. Voice), the raw value of
    /// the sub-tab to open on landing. `nil` for flat tabs.
    public let subTab: String?
    /// Short "not this" note when aliases collide (shown in search + `osaurus_help` find).
    public let disambiguation: String?
    /// `ConfigSectionID.rawValue` when `osaurus_config` can change this setting.
    /// `nil` means Settings UI only.
    public let declarativeSection: String?

    public init(
        id: String,
        tab: ManagementTab,
        section: String = "",
        title: String,
        keywords: [String] = [],
        subTab: String? = nil,
        disambiguation: String? = nil,
        declarativeSection: String? = nil
    ) {
        self.id = id
        self.tab = tab
        self.section = section
        self.title = title
        self.keywords = keywords
        self.subTab = subTab
        self.disambiguation = disambiguation
        self.declarativeSection = declarativeSection
    }

    /// Breadcrumb shown in results, e.g. ["Voice", "Speech to Text", "Transcription Model"].
    /// A section that just repeats the tab label (e.g. the "General" card inside
    /// the General tab) is collapsed so results don't read "General › General".
    public var breadcrumb: [String] {
        section.isEmpty || section == tab.label
            ? [tab.label, title]
            : [tab.label, section, title]
    }

    /// Management path the Orchestrator should quote, e.g. `Server › Cache › Context Window Cap`.
    public var breadcrumbPath: String {
        breadcrumb.joined(separator: " › ")
    }

    public var isSettingsUIOnly: Bool { declarativeSection == nil }
}

public enum SettingsSearchIndex {

    /// Returns entries matching `query`, ranked so title hits come before
    /// section/keyword-only hits. Token/substring matching (no fuzzy
    /// subsequence) keeps results aligned with what the user typed.
    public static func search(_ query: String) -> [SettingsSearchEntry] {
        let prepared = SearchService.PreparedQuery(query)
        guard !prepared.tokens.isEmpty else { return [] }

        func matches(_ text: String) -> Bool {
            SearchService.matches(prepared, in: text, allowFuzzy: false)
        }

        var ranked: [(entry: SettingsSearchEntry, rank: Int)] = []
        for entry in entries {
            if matches(entry.title) {
                ranked.append((entry, 0))
            } else if matches(entry.section) || entry.keywords.contains(where: matches) {
                ranked.append((entry, 1))
            } else if matches(entry.tab.label) {
                ranked.append((entry, 2))
            }
        }
        // Stable sort by rank, preserving declaration order within a rank.
        return
            ranked
            .enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { $0.element.entry }
    }

    /// Index rows that land on a tab (or section) rather than a single control.
    /// Completeness tests allow these to lack a dedicated `settingsLandingAnchor`.
    public static let tabLevelEntryIDs: Set<String> = [
        "models.overview",
        "providers.overview",
        "knowledge.overview",
        "tools.overview",
        "skills.overview",
        "commands.overview",
        "schedules.overview",
        "watchers.overview",
        "sandbox.overview",
        "insights.overview",
        "agents.overview",
        "agents.configure",
        "agents.description",
        "agents.database",
        "imageGeneration.tab",
        "imageGeneration.models",
        "imageGeneration.permission",
        "imageGeneration.loadPolicy",
        "imageGeneration.download",
        "search.providers",
        "search.premium",
        "credits.webSearch",
        "voice.stt.model",
        "voice.stt.vad",
        "voice.models",
        "privacy.tab",
        "server.connection",
        "server.cors",
        "server.auth",
        "server.generation",
        "server.residency",
        "server.concurrency",
        "server.proxy",
        "server.cache",
        "server.memorySafety",
        "server.decode",
        "server.speculative",
        "server.liveActivity",
        "server.multimodal",
        "server.tools",
        "server.power",
        "server.requestLimits",
        "server.peerInference",
        "computerUse.enable",
        "themes.appearance",
        "memory.settings",
        "workspaces.overview",
        "identity.keys",
        "settings.orchestrator.delegation",
        "settings.orchestrator.delegation.mainChat",
        "settings.orchestrator.delegation.handoff",
        "settings.orchestrator.delegation.starterAgents",
        "settings.orchestrator.delegation.permission",
        "settings.orchestrator.delegation.limits",
        "settings.orchestrator.delegation.advanced",
    ]

    /// Every searchable setting, grouped by tab in declaration order.
    public static let entries: [SettingsSearchEntry] = [
        // MARK: Settings (General)
        .init(
            id: "settings.general.hotkey",
            tab: .settings,
            section: "General",
            title: "Global Hotkey",
            keywords: ["shortcut", "keybinding", "hotkey"]
        ),
        .init(
            id: "settings.general.login",
            tab: .settings,
            section: "General",
            title: "Start at Login",
            keywords: ["launch", "startup", "autostart"]
        ),
        .init(
            id: "settings.general.updates",
            tab: .settings,
            section: "General",
            title: "Beta Updates",
            keywords: ["beta", "prerelease", "updates", "channel"]
        ),
        .init(
            id: "settings.general.coreModel",
            tab: .settings,
            section: "General",
            title: "Core Model",
            keywords: ["default model", "core model"]
        ),
        .init(
            id: "settings.general.cli",
            tab: .settings,
            section: "General",
            title: "Command Line Tool",
            keywords: ["cli", "terminal", "symlink", "install"]
        ),
        .init(
            id: "settings.general.reset",
            tab: .settings,
            section: "General",
            title: "Factory Reset",
            keywords: ["reset", "wipe", "erase", "maintenance"]
        ),
        .init(
            id: "settings.general.dock",
            tab: .settings,
            section: "General",
            title: "Hide Dock Icon",
            keywords: ["dock", "menu bar", "menubar", "hide dock"]
        ),

        // MARK: Chat (generation knobs now live in the dedicated Chat tab)
        .init(
            id: "settings.orchestrator.systemPrompt",
            tab: .orchestrator,
            section: "Identity",
            title: "System Prompt",
            keywords: ["persona", "instructions", "system prompt", "orchestrator"],
            declarativeSection: "default_agent"
        ),
        .init(
            id: "settings.orchestrator.name",
            tab: .orchestrator,
            section: "Identity",
            title: "Orchestrator Name",
            keywords: ["name", "rename", "display name", "orchestrator", "default agent", "osaurus"],
            declarativeSection: "default_agent"
        ),
        .init(
            id: "settings.chat.autoGenerateTitles",
            tab: .chat,
            section: "Chat",
            title: "Automatically Name Chats",
            keywords: ["title", "auto title", "rename", "chat name", "summary"]
        ),
        .init(
            id: "settings.chat.generateFollowUps",
            tab: .chat,
            section: "Chat",
            title: "Suggest Follow-Up Questions",
            keywords: ["follow up", "followup", "suggestions", "next question", "prompts", "suggested"]
        ),
        .init(
            id: "settings.chat.cmdNNewChat",
            tab: .chat,
            section: "Chat",
            title: "⌘+N Starts a New Chat in the Current Window",
            keywords: ["cmd n", "new chat", "shortcut", "keyboard", "new window", "hotkey"]
        ),
        .init(
            id: "settings.chat.smoothStreaming",
            tab: .chat,
            section: "Chat",
            title: "Smooth Streaming",
            keywords: ["typewriter", "streaming pace", "token reveal", "smooth tokens"]
        ),
        .init(
            id: "settings.chat.thinkingDisplay",
            tab: .chat,
            section: "Chat",
            title: "Expand Thinking While Streaming",
            keywords: [
                "thinking", "reasoning", "expand thinking", "show thinking",
                "chain of thought",
            ]
        ),
        .init(
            id: "settings.chat.activityRollup",
            tab: .chat,
            section: "Chat",
            title: "Group Thinking & Tool Activity",
            keywords: [
                "group thinking", "tool activity", "rollup", "worked for",
                "collapse tools", "activity row",
            ]
        ),
        .init(
            id: "settings.chat.clipboard",
            tab: .chat,
            section: "Chat",
            title: "Clipboard Monitoring",
            keywords: ["clipboard", "copied text", "grab selection", "paste context"]
        ),
        .init(
            id: "settings.chat.keepAwakeForAgentRuns",
            tab: .chat,
            section: "Agent Sessions",
            title: "Keep Mac Awake While Agents Run",
            keywords: ["sleep", "awake", "caffeinate", "idle sleep", "power", "keep awake"]
        ),
        .init(
            id: "settings.chat.compactionModel",
            tab: .chat,
            section: "Chat",
            title: "Compaction Model",
            keywords: [
                "compaction", "compact", "summarize", "context", "summary model",
                "auto compact", "compact conversation", "fallback", "context full",
            ],
            disambiguation:
                "Which model writes the summary. Unset means the chat's current model. Compaction runs automatically near the limit and from the Compact button in the context budget popover."
        ),
        .init(
            id: "settings.orchestrator.temperature",
            tab: .orchestrator,
            section: "Generation",
            title: "Temperature",
            keywords: ["randomness", "creativity", "sampling"],
            declarativeSection: "default_agent"
        ),
        .init(
            id: "settings.orchestrator.maxTokens",
            tab: .orchestrator,
            section: "Generation",
            title: "Max Output Tokens",
            keywords: [
                "response length", "output tokens", "generation config",
                "max new tokens", "max tokens",
            ],
            disambiguation:
                "Per-response length for the Orchestrator — not the chat context window, KV retention, or Server Sampling Defaults.",
            declarativeSection: "default_agent"
        ),
        .init(
            id: "settings.chat.contextLength",
            tab: .server,
            section: "Cache",
            title: "Context Window Cap (tokens)",
            keywords: [
                "context window", "context", "context length", "context budget",
                "token budget", "model maximum", "context window cap",
                "context cap", "max context", "limit context",
            ],
            subTab: "cache",
            disambiguation:
                "Lowers every model's chat window. Not Memory Budget, not Orchestrator max output tokens, not KV retention."
        ),
        .init(
            id: "settings.server.contextMetadataFallback",
            tab: .server,
            section: "Cache",
            title: "Unknown-Model Metadata Fallback (tokens)",
            keywords: [
                "metadata fallback", "unknown model", "context length fallback",
            ],
            subTab: "cache",
            disambiguation:
                "Used only when a model does not report a maximum. Does not constrain local bundles — use Context Window Cap for that."
        ),
        .init(
            id: "settings.server.kvRetention",
            tab: .server,
            section: "Cache",
            title: "KV Retention Override (tokens)",
            keywords: ["kv retention", "cache window", "kv cap", "retention override"],
            subTab: "cache",
            disambiguation:
                "GPU/SSD KV retention, not the semantic chat context window."
        ),
        .init(
            id: "settings.chat.topP",
            tab: .chat,
            section: "Generation",
            title: "Top P",
            keywords: ["nucleus sampling", "top-p"]
        ),
        .init(
            id: "settings.chat.toolAttempts",
            tab: .chat,
            section: "Generation",
            title: "Max Tool Attempts",
            keywords: ["tool calls", "agent loop", "attempts"]
        ),
        // Had NO index entry at all. Worse than merely missing: searching
        // "tool calls" matched `Max Tool Attempts` above, so the one query
        // that did return something routed the user to a different setting.
        // This is the control that answers "make every tool always allowed" —
        // 83 tools ship `enabled: true` with an EMPTY policy map, and
        // `ToolConfiguration.policy(for:)` defaults to `.ask`, so without this
        // toggle every one of them prompts.
        .init(
            id: "settings.chat.autoAllowAllTools",
            tab: .chat,
            section: "Chat",
            title: "Auto-Allow All Tool Calls",
            keywords: [
                "auto allow", "auto-allow", "allow all tools", "allow tools",
                "tool permission", "tool permissions", "approve tools",
                "approval", "always allow", "never ask", "tool prompt",
            ]
        ),
        .init(
            id: "settings.chat.spellCheck",
            tab: .chat,
            section: "Chat",
            title: "Check Spelling While Typing",
            keywords: [
                "spell", "spelling", "spellcheck", "spell check", "spell checker",
                "grammar", "typo", "typos", "dictionary", "underline", "misspelled",
                "composer", "input",
            ]
        ),

        // MARK: Settings (Notifications / Legal)
        // Usage-analytics + crash-reporting consent now live at the top of the
        // Privacy tab's Overview, so these route there (and glow on landing).
        .init(
            id: "settings.privacy.usage",
            tab: .privacy,
            section: "Data Collection",
            title: "Share Anonymous Usage Data",
            keywords: ["telemetry", "analytics", "tracking"]
        ),
        .init(
            id: "settings.privacy.crash",
            tab: .privacy,
            section: "Data Collection",
            title: "Send Crash Reports",
            keywords: ["crash", "diagnostics", "freeze"]
        ),
        .init(
            id: "settings.notifications.toasts",
            tab: .settings,
            section: "Notifications",
            title: "Toast Notifications",
            keywords: ["toast", "position", "timeout", "alerts"]
        ),
        .init(
            id: "settings.notifications.position",
            tab: .settings,
            section: "Notifications",
            title: "Toast Position",
            keywords: ["position", "corner", "top", "bottom", "placement"]
        ),
        .init(
            id: "settings.notifications.timeout",
            tab: .settings,
            section: "Notifications",
            title: "Toast Timeout",
            keywords: ["timeout", "duration", "auto dismiss", "seconds"]
        ),
        .init(
            id: "settings.notifications.maxVisible",
            tab: .settings,
            section: "Notifications",
            title: "Max Visible Toasts",
            keywords: ["max toasts", "toast stack", "visible toasts"]
        ),
        .init(
            id: "settings.notifications.maxConcurrent",
            tab: .settings,
            section: "Notifications",
            title: "Max Concurrent Tasks",
            keywords: ["concurrent tasks", "background tasks", "task limit"]
        ),
        .init(
            id: "settings.toolPermissions",
            tab: .chat,
            section: "Tool Permissions",
            title: "Folder Tool Permissions",
            keywords: ["folder permissions", "write files", "edit files", "working folder"],
            disambiguation:
                "Chat folder-tool policies (write/edit/shell/git). Not the Tools catalog and not macOS TCC."
        ),
        .init(
            id: "settings.legal",
            tab: .settings,
            section: "Legal",
            title: "Terms & Privacy Policy",
            keywords: ["terms", "privacy policy", "legal", "about"]
        ),

        // MARK: Voice (subTab values are VoiceTab raw values)
        .init(
            id: "voice.stt.model",
            tab: .voice,
            section: "Speech to Text",
            title: "Transcription Model",
            keywords: ["transcription", "parakeet", "whisper", "speech recognition", "dictation"],
            subTab: "Speech To Text"
        ),
        .init(
            id: "voice.stt.hotkey",
            tab: .voice,
            section: "Speech to Text",
            title: "Activation Hotkey",
            keywords: [
                "dictation hotkey", "push to talk", "voice hotkey", "shortcut",
                "global hotkey", "activation hotkey",
            ],
            subTab: "Speech To Text"
        ),
        .init(
            id: "voice.stt.vad",
            tab: .voice,
            section: "VAD Mode",
            title: "Voice Activity Detection",
            keywords: ["vad", "silence", "auto stop", "endpointing"],
            subTab: "VAD Mode"
        ),
        .init(
            id: "voice.stt.pause",
            tab: .voice,
            section: "Speech to Text",
            title: "Pause Detection",
            keywords: ["pause", "auto stop", "auto send", "stop after silence"],
            subTab: "Speech To Text"
        ),
        .init(
            id: "voice.stt.confirmation",
            tab: .voice,
            section: "Speech to Text",
            title: "Confirmation Delay",
            keywords: ["confirmation", "cancel window", "delay before send"],
            subTab: "Speech To Text"
        ),
        .init(
            id: "voice.stt.silence",
            tab: .voice,
            section: "Speech to Text",
            title: "Silence Timeout",
            keywords: ["silence", "timeout", "close voice input", "inactivity"],
            subTab: "Speech To Text"
        ),
        .init(
            id: "voice.tts.voice",
            tab: .voice,
            section: "Text to Speech",
            title: "Spoken Voice",
            keywords: ["tts", "read aloud", "speech synthesis", "voice"],
            subTab: "Text To Speech"
        ),
        .init(
            id: "voice.tts.remote",
            tab: .voice,
            section: "Text to Speech",
            title: "Remote TTS",
            keywords: ["remote tts", "tts endpoint", "openai tts", "speech server"],
            subTab: "Text To Speech"
        ),
        .init(
            id: "voice.tts.temperature",
            tab: .voice,
            section: "Text to Speech",
            title: "Voice Temperature",
            keywords: ["tts temperature", "expressiveness", "variation"],
            subTab: "Text To Speech"
        ),
        .init(
            id: "voice.models",
            tab: .voice,
            section: "Models",
            title: "Voice Models",
            keywords: ["download model", "speech model", "parakeet"],
            subTab: "Models"
        ),

        // MARK: Server (subTab values are ServerSettingsSection raw values)
        .init(
            id: "server.connection",
            tab: .server,
            section: "Connection",
            title: "Port & Network",
            keywords: ["port", "expose", "network", "host", "bind"],
            subTab: "connection"
        ),
        .init(
            id: "server.cors",
            tab: .server,
            section: "Connection",
            title: "Allowed Origins (CORS)",
            keywords: ["cors", "origins", "cross origin"],
            subTab: "connection"
        ),
        .init(
            id: "server.auth",
            tab: .server,
            section: "Authentication",
            title: "API Authentication",
            keywords: ["api key", "auth", "token", "bearer"],
            subTab: "authentication"
        ),
        .init(
            id: "server.generation",
            tab: .server,
            section: "Sampling Defaults",
            title: "Generation Defaults",
            keywords: [
                "top p", "temperature", "sampling", "sampler", "top k", "min p",
                "defaults", "max tokens",
            ],
            subTab: "sampling",
            disambiguation:
                "Server/API sampling defaults. Orchestrator Max Output Tokens and agent Max Tokens are separate."
        ),
        .init(
            id: "server.residency",
            tab: .server,
            section: "Model Memory",
            title: "Model Residency",
            keywords: ["eviction policy", "idle", "keep model loaded", "unload after", "30 seconds", "close window"],
            subTab: "modelMemory"
        ),
        .init(
            id: "server.concurrency",
            tab: .server,
            section: "Concurrency & Batching",
            title: "Concurrency",
            keywords: ["parallel", "batch", "requests", "threads"],
            subTab: "concurrency"
        ),
        .init(
            id: "server.proxy",
            tab: .server,
            section: "Global Proxy",
            title: "Global Proxy",
            keywords: ["proxy", "http proxy", "socks"],
            subTab: "globalProxy"
        ),
        .init(
            id: "server.cache",
            tab: .server,
            section: "Cache",
            title: "Prompt Cache",
            // The controls in this section are labelled "Disk Cache", "SSD
            // Cache (L2)", "Disk Cache Size (% of disk)" and "Clear SSD
            // Cache". None of those phrases resolved, so the section could
            // not be found by any name it shows the user — the same defect
            // D5 fixed for the sampler row.
            keywords: [
                "cache", "kv cache", "prefix",
                "disk cache", "ssd cache", "l2 cache", "disk cache size",
                "clear cache", "clear ssd cache", "disk cache directory",
                "eviction", "evict", "paged kv", "gpu cache",
            ],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.prefixCache",
            tab: .server,
            section: "Cache",
            title: "Prefix Cache",
            keywords: ["prefix reuse", "master reuse switch"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.gpuCache",
            tab: .server,
            section: "Cache",
            title: "Enable GPU Cache",
            keywords: ["paged kv", "hot tier"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.gpuCacheBlockSize",
            tab: .server,
            section: "Cache",
            title: "Block Size (tokens)",
            keywords: ["paged block tokens"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.gpuCacheMaxBlocks",
            tab: .server,
            section: "Cache",
            title: "Max Blocks",
            keywords: ["gpu cache memory"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.diskCache",
            tab: .server,
            section: "Cache",
            title: "Disk Cache",
            keywords: ["ssd reuse", "l2"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.clearDiskCache",
            tab: .server,
            section: "Cache",
            title: "Clear SSD Cache",
            keywords: ["purge cached conversations", "save cache directory before clearing"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.diskCacheDirectory",
            tab: .server,
            section: "Cache",
            title: "Disk Cache Directory",
            keywords: ["ssd path", "cache folder"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.ssmReDerive",
            tab: .server,
            section: "Cache",
            title: "Re-derive SSM State After Generation",
            keywords: ["hybrid", "mamba", "companion"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.diskCacheSize",
            tab: .server,
            section: "Cache",
            title: "Disk Cache Size (% of disk)",
            keywords: ["ssd cache size", "increase cache size", "disk cache limit", "cache capacity"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.diskCacheAutomatic",
            tab: .server,
            section: "Cache",
            title: "Use Automatic Cache Size",
            keywords: ["automatic ssd", "reset cache size", "legacy cache size", "available disk space"],
            subTab: "cache"
        ),
        .init(
            id: "server.memorySafety",
            tab: .server,
            section: "Memory Safety",
            title: "Memory Safety",
            keywords: ["memory", "ram", "guard", "oom", "limits"],
            subTab: "memorySafety"
        ),
        .init(
            id: "server.decode",
            tab: .server,
            section: "Decode Performance",
            title: "Decode Performance",
            keywords: [
                "decode", "throughput", "speed", "tokens per second",
                "deepseek", "dsv4", "activation qat", "graph fidelity",
            ],
            subTab: "decodePerformance"
        ),
        .init(
            id: "server.speculative",
            tab: .server,
            section: "Speculative Decoding",
            title: "Speculative Decoding",
            keywords: [
                "speculative", "mtp", "native mtp", "draft model", "speculative depth", "default off",
                // The drafter picker lives in this card. Someone who has
                // just downloaded a DFlash 2 checkpoint searches for its
                // name, not for "speculative decoding".
                "dflash", "dflash 2", "drafter", "block diffusion",
            ],
            subTab: "speculative"
        ),
        .init(
            id: "server.liveActivity",
            tab: .server,
            section: "Live Activity",
            title: "Live Activity",
            keywords: [
                "live activity", "dynamic island", "status", "sampler", "sampler last used",
            ],
            subTab: "liveActivity"
        ),
        .init(
            id: "server.multimodal",
            tab: .server,
            section: "Multimodal",
            title: "Multimodal",
            keywords: ["vision", "image", "audio", "multimodal"],
            subTab: "multimodal"
        ),
        .init(
            id: "server.tools",
            tab: .server,
            section: "Tools & Templates",
            title: "Tools & Templates",
            // "Reasoning Parser Override" lives in this section, and reasoning
            // was unfindable by ANY of its own words — `reasoning`, `thinking`,
            // `effort` and `preserve thinking` all returned 0 matches while
            // three real controls existed. Same defect D5 fixed for the
            // sampler row.
            keywords: [
                "tool calling", "templates", "chat template",
                "reasoning", "reasoning parser", "reasoning effort", "effort",
                "thinking", "preserve thinking", "think tags",
            ],
            subTab: "tools"
        ),
        .init(
            id: "server.power",
            tab: .server,
            section: "Power",
            title: "Power",
            keywords: ["power", "battery", "low power", "energy"],
            subTab: "power"
        ),
        .init(
            id: "server.requestLimits",
            tab: .server,
            section: "Request Limits",
            title: "Request Limits",
            keywords: ["body size", "request limits", "max body", "advanced http"],
            subTab: "requestLimits"
        ),

        // MARK: Permissions / Computer Use / Privacy tabs
        .init(
            id: "permissions.tools",
            tab: .permissions,
            title: "macOS Permissions",
            keywords: [
                "system permissions", "tcc", "accessibility", "microphone",
                "screen recording", "full disk access", "privacy",
            ],
            disambiguation:
                "macOS grants (TCC). Not the Tools catalog Auto/Ask/Deny policies, and not Chat folder-tool permissions."
        ),
        .init(
            id: "server.peerInference",
            tab: .server,
            title: "Share my models for inference",
            keywords: ["peer inference", "share models", "lan inference", "expose models"]
        ),
        .init(
            id: "server.codexCLI",
            tab: .server,
            title: "Use with Codex CLI",
            keywords: [
                "codex", "codex cli", "openai codex", "config.toml", "model_providers",
                "codex profile", "external client", "coding agent",
            ],
            disambiguation:
                "Points OpenAI's Codex CLI at this Osaurus as a local model provider. Not the \"OpenAI Codex\" remote provider under Providers, which is Osaurus using a ChatGPT subscription."
        ),
        .init(
            id: "computerUse.enable",
            tab: .computerUse,
            title: "Computer Use",
            keywords: [
                "screen control", "cursor", "automation", "accessibility", "per-app",
                "autonomy", "app allowlist", "screen context",
            ]
        ),
        .init(
            id: "browser.enable",
            tab: .browser,
            title: "Browser Use",
            keywords: [
                "browser", "web", "browse", "session", "sign in", "login", "cookies", "webkit",
            ]
        ),
        .init(
            id: "browser.sessions",
            tab: .browser,
            title: "Browser Sessions",
            keywords: ["sessions", "profiles", "signed in", "reset browser", "browsing data"]
        ),

        // MARK: Channels / Integrations
        .init(
            id: "agentChannels.overview",
            tab: .agentChannels,
            title: "Channels",
            keywords: [
                "agent channels", "integrations", "channels", "discord", "slack", "telegram",
                "imessage", "whatsapp", "custom json", "custom http", "remote channel",
            ],
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.globalWrites",
            tab: .agentChannels,
            section: "Sending",
            title: "Allow Agents to Send Messages",
            keywords: [
                "kill switch", "disable writes", "remote writes", "channel writes",
                "sending", "read-only", "pause sending",
            ]
        ),
        .init(
            id: "agentChannels.focusOnInbound",
            tab: .agentChannels,
            section: "Incoming",
            title: "Focus Chat on Incoming Messages",
            keywords: [
                "focus", "bring to front", "bring forward", "activate window", "popup",
                "pop up", "attention", "dedicated device", "kiosk", "monitor", "incoming",
                "inbound", "channel window", "channel tab", "new message", "steal focus",
            ],
            disambiguation:
                "Channels-only: brings the channel conversation's chat tab and window forward when a message arrives. Toast notifications are under Settings → General → Notifications."
        ),
        .init(
            id: "agentChannels.discord",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Discord",
            keywords: ["discord bot token", "discord server ids", "discord channel allowlist"]
        ),
        .init(
            id: "agentChannels.slack",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Slack",
            keywords: [
                "slack bot token", "slack signing secret", "socket mode",
                "slack workspace ids", "slack channel allowlist",
            ]
        ),
        .init(
            id: "agentChannels.telegram",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Telegram",
            keywords: [
                "telegram bot token", "telegram chat ids", "sender allowlist",
                "telegram channel allowlist", "telegram long polling",
                "telegram getupdates", "store incoming messages",
            ]
        ),
        .init(
            id: "agentChannels.imessage",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "iMessage",
            keywords: [
                "imessage", "messages app", "imessage chats", "full disk access",
                "messages automation", "imsg helper", "sender allowlist",
                "tapback", "unsend", "sip", "library validation",
            ]
        ),
        .init(
            id: "agentChannels.whatsapp",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "WhatsApp",
            keywords: [
                "whatsapp", "whatsapp web", "whatsapp qr code", "qr code", "link device",
                "whatsmeow",
                "osaurus-wa helper", "sender allowlist", "whatsapp chats",
                "phone number", "group jid",
            ]
        ),
        .init(
            id: "agentChannels.n8n",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "n8n",
            keywords: [
                "n8n", "workflow automation", "webhook bridge", "channel secret",
                "hmac signature", "shared secret header", "poll url", "task poll",
                "host.docker.internal", "plaintext allowed", "secure channel required",
                "http request", "conversation_id", "topology", "docker desktop",
                "name it", "who answers", "pair", "prove it", "display name", "connection id",
                "who may speak", "connect n8n", "remote callers",
            ],
            disambiguation:
                "The n8n channel sheet (Settings → Channels → n8n): Name it → Where is your n8n? → Who answers? → Pair → Prove it. n8n calls Osaurus; the only n8n URL Osaurus stores is the optional Outbound Webhook URL under Who answers?."
        ),
        .init(
            id: "agentChannels.n8n.enabled",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "n8n channel on/off",
            keywords: [
                "enable n8n channel", "disable n8n channel", "channel enabled", "pause n8n",
                "connection_disabled", "turn off n8n", "turn on n8n",
            ],
            disambiguation:
                "The switch on the n8n card in Settings → Channels. Off answers every inbound, poll and ping with 403 connection_disabled. It is no longer inside the setup sheet."
        ),
        .init(
            id: "agentChannels.n8n.callerLocation",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Where is your n8n?",
            keywords: [
                "where is n8n", "n8n location", "caller location", "this mac", "docker desktop on this mac",
                "another machine on my network", "remote (hosted or another network)", "lan n8n", "remote n8n",
                "hosted n8n",
                "n8n cloud", "relay", "expose to network", "allow plaintext http",
                "plaintext from other machines", "remote callers", "426",
            ],
            disambiguation:
                "Step 2 of the n8n sheet. Picks which URL the pairing code carries (127.0.0.1, host.docker.internal, LAN address, or relay URL), whether Relay is required, and whether the plaintext toggle is shown (LAN only)."
        ),
        .init(
            id: "agentChannels.n8n.plaintextAllowed",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Allow plaintext HTTP from other machines",
            keywords: [
                "plaintext http", "remote callers", "plaintext allowed", "secure channel required",
                "426", "trusted lan", "lan plaintext", "n8n plaintext",
            ],
            disambiguation:
                "Shown only when Where is your n8n? is 'Another machine on my network'. Off: non-loopback callers must speak Secure Channel or get 426. Remote uses Secure Channel via Relay and never needs this."
        ),
        .init(
            id: "agentChannels.n8n.relay",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Relay for the bound agent",
            keywords: [
                "enable relay", "n8n relay", "relay connected", "public url", "agent.osaurus.ai",
                "hosted n8n relay", "expose agent to internet", "take over relay",
            ],
            disambiguation:
                "Under Who answers? in the n8n sheet, shown for Remote (required) and LAN (optional). Enables Relay on the agent picked as the default target; the pairing code is issued once the relay reports connected."
        ),
        .init(
            id: "agentChannels.n8n.outboundWebhookURL",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Outbound Webhook URL",
            keywords: [
                "n8n url", "n8n webhook url", "push replies to n8n", "osaurus trigger", "webhook trigger",
                "sign outbound bodies", "reply automatically", "where do i enter my n8n url",
            ],
            disambiguation:
                "Under Who answers? → Push replies to n8n (optional). The only place an n8n URL is entered; must be public https. Leave empty for poll-only replies."
        ),
        .init(
            id: "agentChannels.n8n.channelSecret",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Channel Secret",
            keywords: [
                "channel secret", "rotate secret", "generate secret", "n8n secret", "hmac key",
                "keychain secret", "webhook secret",
            ],
            disambiguation:
                "Under Pair → Advanced in the n8n sheet. Generated automatically for a new channel and carried inside the pairing code; rotating it invalidates every issued code."
        ),
        .init(
            id: "agentChannels.n8n.pairingCode",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Pair with n8n",
            keywords: [
                "pairing code", "pair n8n", "pair", "n8n node", "n8n credential", "osaurus channel credential",
                "n8n-nodes-osaurus", "@osaurus/n8n-nodes-osaurus", "remote n8n", "hosted n8n",
                "relay url", "secure channel", "channel secret", "rotate secret",
                "end-to-end encrypted", "osrs-n8n", "ping", "credential test", "no pairing code yet",
            ],
            disambiguation:
                "Inside the n8n channel sheet (Settings → Channels → n8n → Pair). One copyable string the Osaurus n8n community node decodes; it contains the channel secret and only the URL valid for Where is your n8n?. Withheld until it can work (e.g. Relay connected for Remote). Not the osk-v1 access key from Share Agent."
        ),
        .init(
            id: "agentChannels.n8n.pendingApprovals",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Who may speak",
            keywords: [
                "approve workflow", "allow workflow", "deny workflow", "pending approval", "first contact",
                "waiting for approval", "wants to use", "allowed conversations", "allowed senders",
                "allowlist", "edit allowlists by hand", "conversation_id", "sender.id", "accept bot senders",
                "prove it",
            ],
            disambiguation:
                "Step 5 (Prove it) of the n8n sheet. The first run of a workflow appears here as 'Workflow X (sender Y) wants to use <channel> — Allow / Deny'; Allow adds its ids to the allowlists. Manual allowlist editing is under Advanced in the same step."
        ),
        .init(
            id: "agentChannels.customJSON",
            tab: .agentChannels,
            section: "Custom JSON Connections",
            title: "Custom HTTP Connections",
            keywords: ["custom json channels", "webhook", "agent-channels.json", "secret references"]
        ),
        .init(
            id: "agentChannels.destinations",
            tab: .agentChannels,
            section: "Messages Agents Can Start",
            title: "Messages Agents Can Start",
            keywords: [
                "proactive", "publish", "destination", "binding", "outbound",
                "autonomous", "draft", "confirm", "agent destinations",
                "new messages", "agent posting", "post", "room", "auto-send",
            ]
        ),
        .init(
            id: "agentChannels.outbox",
            tab: .agentChannels,
            section: "Outbox",
            title: "Channel Outbox",
            keywords: [
                "outbox", "pending approval", "approve message", "queued messages",
                "outbound activity", "drafts",
            ]
        ),

        // MARK: Image Generation tab (subTab values are ImageGenerationTab raw values)
        .init(
            id: "imageGeneration.tab",
            tab: .imageGeneration,
            title: "Images",
            keywords: [
                "image", "image generation", "text to image", "ideogram",
                "diffusion", "mflux", "generate image", "edit image",
            ]
        ),
        .init(
            id: "imageGeneration.models",
            tab: .imageGeneration,
            section: "Settings",
            title: "Default Models",
            keywords: ["generation model", "edit model", "default image model"],
            subTab: "Settings"
        ),
        .init(
            id: "imageGeneration.permission",
            tab: .imageGeneration,
            section: "Settings",
            title: "Permission",
            keywords: ["image permission", "ask", "deny", "always allow"],
            subTab: "Settings"
        ),
        .init(
            id: "imageGeneration.loadPolicy",
            tab: .imageGeneration,
            section: "Settings",
            title: "Load Policy",
            keywords: ["load policy", "image jobs", "unload", "residency", "gpu"],
            subTab: "Settings"
        ),
        .init(
            id: "imageGeneration.download",
            tab: .imageGeneration,
            section: "Models",
            title: "Download image models",
            keywords: ["download", "image model", "ideogram", "mflux", "catalog", "import"],
            subTab: "Models"
        ),

        // MARK: Subagents (Orchestrator delegation policy + runtime knobs)
        // There is no global master switch and no dedicated Spawn tab anymore.
        // Settings → Orchestrator: Model readiness, Working Folder, Subagents
        // (Allowed subagents / Permission / Limits / Advanced), Delegations.
        // Custom-agent spawn policy remains in each agent's Subagents tab.
        .init(
            id: "settings.orchestrator.modelReadiness",
            tab: .orchestrator,
            section: "Model & Generation",
            title: "Model readiness",
            keywords: [
                "orchestrator model", "context window", "tools ok", "tools limited",
                "recommended model", "model too small", "readiness", "can the orchestrator use tools",
            ]
        ),
        .init(
            id: "settings.orchestrator.workingFolder",
            tab: .orchestrator,
            section: "Working Folder",
            title: "Working Folder",
            keywords: [
                "orchestrator folder", "folder access", "file access", "read files",
                "file_read", "file_search", "deliverables", "project folder",
                "subagent folder", "inherit folder", "choose folder",
            ],
            disambiguation: "The Orchestrator's folder. Custom agents set theirs in Agents → Abilities."
        ),
        .init(
            id: "settings.orchestrator.delegation",
            tab: .orchestrator,
            section: "Subagents",
            title: "Subagents",
            keywords: [
                "spawn", "delegate", "delegation", "subagent", "subagents",
                "helper jobs", "agent delegation", "allowed agents",
                "allowed subagents", "main chat", "orchestrator",
                "parallel subagents", "child budgets", "spawn_agent",
            ],
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.orchestrator.delegation.mainChat",
            tab: .orchestrator,
            section: "Subagents",
            title: "Allowed subagents",
            keywords: [
                "default agent", "built-in chat", "spawn pool", "main chat spawn",
                "allowed agents", "shared workspace agents", "workspace agents",
                "teammate agents", "auto-join", "remove agent",
            ],
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.orchestrator.delegation.starterAgents",
            tab: .orchestrator,
            section: "Subagents",
            title: "Create starter agents",
            keywords: [
                "starter agents", "coder", "researcher", "writer", "create agents",
                "no agents yet", "first agents", "quick start",
            ]
        ),
        .init(
            id: "settings.orchestrator.delegation.permission",
            tab: .orchestrator,
            section: "Subagents",
            title: "Permission",
            keywords: [
                "ask before delegating", "always allow", "approval card", "spawn permission",
                "local agents permission", "shared agents permission", "workspace permission",
                "permission for shared (workspace) agents", "deny delegation", "one approval per wave",
            ],
            disambiguation: "Whether to ask before subagents run. For every tool, see Chat → Auto-allow all tools.",
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.orchestrator.delegation.limits",
            tab: .orchestrator,
            section: "Subagents",
            title: "Limits",
            keywords: [
                "max output tokens per subagent", "max turns per subagent",
                "time limit per subagent (seconds)", "max local subagents at once",
                "max remote subagents at once", "max parallel", "parallel subagents",
                "remote parallel", "budgets", "subagent limits", "agents end too fast",
                "delegation limits", "max delegate tokens", "elapsed seconds",
            ],
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.orchestrator.delegation.advanced",
            tab: .orchestrator,
            section: "Subagents",
            title: "Advanced",
            keywords: [
                "agent-target model override", "model override", "subagent model",
                "run subagents on model", "override model", "advanced delegation",
            ],
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.orchestrator.delegation.handoff",
            tab: .orchestrator,
            section: "Subagents",
            title: "Local Models & Memory",
            keywords: [
                "handoff", "swap local models", "swap", "ram safety", "memory check",
                "residency", "unload", "preflight", "coexistence", "keep chat model loaded",
                "check memory before delegating",
            ]
        ),
        .init(
            id: "settings.orchestrator.delegation.swapModels",
            tab: .orchestrator,
            section: "Local Models & Memory",
            title: "Swap local models for subagents",
            keywords: [
                "handoff", "browser use", "computer use", "applescript", "batch", "unload", "restore", "keep loaded",
                "coexistence",
            ],
            disambiguation:
                "Shared by all agents for text, Browser Use, Computer Use, AppleScript, local image jobs and context compaction. Off retains the invoking model during the job, including under Server Strict; memory admission and image cleanup remain separate.",
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.orchestrator.delegation.ramSafety",
            tab: .orchestrator,
            section: "Local Models & Memory",
            title: "Check memory before delegating",
            keywords: [
                "ram safety", "memory pressure", "stable_memory_refusal", "preflight", "subagent",
                "disable memory check",
            ],
            disambiguation:
                "One shared delegation RAM check for the Orchestrator and all agents. Separate from Server → Memory Safety load budgets.",
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.orchestrator.delegations",
            tab: .orchestrator,
            section: "Delegations",
            title: "Delegations",
            keywords: [
                "delegation history", "sent", "received", "worker runs", "subagent runs",
                "open chat", "tok/s", "artifacts", "delegated tasks", "inbound runs",
                "shared agent runs",
            ]
        ),
        .init(
            id: "privacy.tab",
            tab: .privacy,
            title: "Privacy Filter",
            keywords: ["redaction", "filter", "scrub", "mask", "sensitive data", "custom rules", "pii"]
        ),

        // MARK: Identity / Storage / Themes / Memory
        .init(
            id: "identity.osaurusId",
            tab: .identity,
            title: "Osaurus ID",
            keywords: [
                "osaurus id", "handle", "username", "profile", "display name", "bio", "claim",
                "public name",
            ]
        ),
        .init(
            id: "identity.keys",
            tab: .identity,
            title: "Identity & Recovery",
            keywords: [
                "mnemonic", "seed phrase", "recovery phrase", "agent keys", "signing",
                "cryptographic identity", "keys",
            ]
        ),
        .init(
            id: "workspaces.overview",
            tab: .workspaces,
            title: "Workspaces",
            keywords: [
                "workspace", "workspaces", "new workspace", "create workspace", "team", "teams",
                "collaboration", "share agents",
            ]
        ),
        .init(
            id: "workspaces.invites",
            tab: .workspaces,
            section: "Members",
            title: "Invites & Members",
            keywords: [
                "invite", "invite link", "join", "join code", "member", "role", "admin",
                "owner", "viewer", "join workspace", "join team",
            ]
        ),
        .init(
            id: "workspaces.agents",
            tab: .workspaces,
            section: "Shared Agents",
            title: "Shared Agents",
            keywords: [
                "share agent", "shared agent", "relay", "presence", "workspace billing", "team billing",
            ]
        ),
        .init(
            id: "workspaces.agents.orchestratorAutoJoin",
            tab: .workspaces,
            section: "Shared Agents",
            title: "Let the Orchestrator delegate to shared agents",
            keywords: [
                "auto-join", "auto join", "workspace auto join", "orchestrator shared agents",
                "delegate to teammates", "shared agents pool", "stop joining", "workspace delegation",
            ],
            disambiguation: "Per-workspace switch. The pool itself is Settings → Orchestrator → Allowed subagents.",
            declarativeSection: "delegation"
        ),
        // The standalone Storage tab is gone: the models directory +
        // external sources live on the General tab, and the encryption
        // panel lives on the Privacy tab's Storage sub-tab.
        .init(
            id: "storage.location",
            tab: .settings,
            title: "Models Directory",
            keywords: ["disk", "data location", "models folder", "move models", "cleanup", "models size"]
        ),
        .init(
            id: "storage.externalModels",
            tab: .settings,
            title: "External Model Sources",
            keywords: ["hugging face", "hf cache", "lm studio", "external", "import models"]
        ),
        .init(
            id: "storage.encryption",
            tab: .privacy,
            title: "Encrypt Local Data at Rest",
            keywords: ["sqlcipher", "encryption", "filevault", "at rest", "storage key", "backup"]
        ),
        .init(
            id: "themes.appearance",
            tab: .themes,
            title: "Appearance & Themes",
            keywords: ["theme", "appearance", "dark mode", "color", "accent"]
        ),
        .init(
            id: "memory.settings",
            tab: .memory,
            title: "Memory",
            keywords: ["memories", "facts", "recall", "long term memory"],
            declarativeSection: "memory"
        ),
        .init(
            id: "memory.settings.enabled",
            tab: .memory,
            section: "Configuration",
            title: "Enable Memory",
            keywords: ["turn on memory", "disable memory", "memory switch"],
            subTab: "settings",
            declarativeSection: "memory"
        ),
        .init(
            id: "memory.settings.budget",
            tab: .memory,
            section: "Configuration",
            title: "Memory Budget",
            keywords: ["memory tokens", "injection", "memory budget"],
            subTab: "settings",
            disambiguation:
                "Tokens of long-term memory injected per turn — not the chat Context Window Cap.",
            declarativeSection: "memory"
        ),
        .init(
            id: "memory.settings.consolidation",
            tab: .memory,
            section: "Configuration",
            title: "Consolidation Interval",
            keywords: ["consolidation", "decay", "dedup", "eviction interval"],
            subTab: "settings"
        ),
        .init(
            id: "memory.settings.retention",
            tab: .memory,
            section: "Configuration",
            title: "Episode Retention",
            keywords: ["retention", "prune", "days", "history cleanup"],
            subTab: "settings"
        ),

        // MARK: Agents
        // Landing anchors live on the Agents screen (`AgentsView`): the header
        // glows for the overview entry; the agent grid glows for the database
        // entry, where each custom agent card exposes an Open Database
        // shortcut into that agent's Database workspace.
        .init(
            id: "agents.overview",
            tab: .agents,
            title: "Agents",
            keywords: [
                "agent", "assistant", "persona", "custom agent", "create agent",
                "system prompt", "agent settings",
            ],
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.configure",
            tab: .agents,
            title: "Configure Agent",
            keywords: [
                "per-agent", "capabilities", "max tokens", "temperature",
                "advanced", "agent model", "configure",
            ],
            disambiguation:
                "Per-agent Advanced generation and capability toggles. Orchestrator defaults live under Orchestrator → Generation.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.description",
            tab: .agents,
            title: "Agent description (required)",
            keywords: ["descriptions required", "agent description", "purpose", "routing", "legacy agent", "repair", "helper", "Suggest from system prompt", "suggest description", "core model description"],
            disambiguation: "Open an agent's Configure tab to supply its required routing description, or suggest one from its system prompt when the description is empty.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.database",
            tab: .agents,
            section: "Knowledge",
            title: "Agent Database",
            keywords: [
                "database", "tables", "rows", "saved views", "sql", "sqlite",
                "agent data", "structured data", "encrypted database", "db",
            ]
        ),
        // Agents → (custom agent) → Abilities → Tools. The built-in Apple
        // apps are groups in the tool picker (one per app, toggled per app);
        // the anchor sits on the picker. Also writable via
        // `capabilities.apple_apps`.
        .init(
            id: "agents.appleApps",
            tab: .agents,
            section: "Abilities → Tools",
            title: "Apple Apps",
            keywords: [
                "apple apps", "apple", "native apps", "mac apps", "built-in apps", "apple tools",
                "calendar", "reminders", "contacts", "notes", "mail", "messages", "imessage",
                "maps", "location", "music", "shortcuts", "apple_apps",
            ],
            subTab: "capabilities",
            disambiguation:
                "Per-custom-agent groups in Abilities → Tools for the built-in Apple app tools (off by default, toggled per app). The Orchestrator never uses them directly; it enables them on a custom agent via osaurus_config capabilities.apple_apps.",
            declarativeSection: "agents"
        ),

        // MARK: Search
        .init(
            id: "search.providers",
            tab: .search,
            title: "Search Providers",
            keywords: [
                "web search", "search engine", "tavily", "exa", "brave", "serper", "parallel",
                "google", "kagi", "duckduckgo", "bing", "api key", "internet",
            ]
        ),
        .init(
            id: "search.premium",
            tab: .search,
            title: "Premium Search",
            keywords: [
                "premium search", "hosted search", "osaurus search", "router search",
                "paid search", "web search credits",
            ]
        ),
        .init(
            id: "credits.webSearch",
            tab: .credits,
            section: "Web search",
            title: "Search Credits",
            keywords: [
                "web search", "premium search", "free searches", "search credits",
                "auto pay", "search billing", "page extract", "grant",
            ]
        ),
        .init(
            id: "search.tryIt",
            tab: .search,
            section: "Try it",
            title: "Test Search",
            keywords: ["test query", "search playground", "try search"]
        ),
        .init(
            id: "search.routing",
            tab: .search,
            section: "Advanced",
            title: "Per-category Provider Order",
            keywords: ["fallback", "ranking", "routing", "news", "images", "priority"]
        ),
        .init(
            id: "search.custom",
            tab: .search,
            section: "Advanced",
            title: "Custom Search Provider",
            keywords: ["custom api", "json definition", "searxng", "perplexity", "self-hosted"],
            declarativeSection: "search_providers"
        ),

        // MARK: Tab-level rows for Management areas that had zero search hits
        .init(
            id: "models.automaticUpdates",
            tab: .models,
            title: "Automatically Check Model Updates",
            keywords: ["background model updates", "huggingface", "model revision", "automatic checks", "offline"],
            disambiguation: "Checks installed OsaurusAI model metadata only. Does not update the Osaurus application or download model files."
        ),
        .init(
            id: "models.overview",
            tab: .models,
            title: "Local Models",
            keywords: ["install model", "download model", "mlx", "huggingface", "catalog"],
            declarativeSection: "models"
        ),
        .init(
            id: "providers.overview",
            tab: .providers,
            title: "Providers",
            keywords: ["cloud models", "provider", "api key", "openai", "anthropic", "openrouter", "xai"],
            declarativeSection: "providers"
        ),
        .init(
            id: "knowledge.overview",
            tab: .knowledge,
            title: "Knowledge",
            keywords: ["collections", "documents", "rag", "index files"],
            declarativeSection: "knowledge_collections"
        ),
        .init(
            id: "tools.overview",
            tab: .tools,
            title: "Tools",
            keywords: [
                "tool catalog", "enable tools", "ask deny", "auto ask deny",
                "mcp", "plugins", "tool policy",
            ],
            disambiguation:
                "Global tool enablement and Auto/Ask/Deny. Not macOS Permissions and not Chat folder-tool policies.",
            declarativeSection: "tools"
        ),
        .init(
            id: "skills.overview",
            tab: .skills,
            title: "Skills",
            keywords: ["skill packs", "install skill", "skill.md"]
        ),
        .init(
            id: "commands.overview",
            tab: .commands,
            title: "Commands",
            keywords: ["slash commands", "custom command", "prompt command"],
            declarativeSection: "commands"
        ),
        .init(
            id: "schedules.overview",
            tab: .schedules,
            title: "Schedules",
            keywords: ["cron", "interval", "timed job", "recurring"],
            declarativeSection: "schedules"
        ),
        .init(
            id: "watchers.overview",
            tab: .watchers,
            title: "Watchers",
            keywords: ["folder watcher", "file events", "watch folder"],
            declarativeSection: "watchers"
        ),
        .init(
            id: "sandbox.overview",
            tab: .sandbox,
            title: "Sandbox",
            keywords: ["container", "isolation", "sandbox resources"]
        ),
        .init(
            id: "insights.overview",
            tab: .insights,
            title: "Insights",
            keywords: ["analytics", "usage", "charts", "metrics"]
        ),
    ] + appleAppEntries

    /// One row per Apple app group in a custom agent's Abilities → Tools
    /// picker (`agents.appleApps.<app>`), with the exact group title and the
    /// tool verbs the model or a user might type. Generated from `AppleApp`
    /// so a new family cannot ship without a catalog row.
    static let appleAppEntries: [SettingsSearchEntry] = AppleApp.allCases.map { app in
        SettingsSearchEntry(
            id: "agents.appleApps.\(app.rawValue)",
            tab: .agents,
            section: "Abilities → Tools",
            title: app.displayName,
            keywords: appleAppKeywords(app),
            subTab: "capabilities",
            disambiguation:
                "Abilities → Tools group on a custom agent; the master checkbox (or any row switch) turns all \(app.displayName) tools on or off together (off by default). Not the \(app.displayName) plugin, which is built in now; not the macOS Permissions tab. Declarative: capabilities.apple_apps includes \"\(app.rawValue)\".",
            declarativeSection: "agents"
        )
    }

    private static func appleAppKeywords(_ app: AppleApp) -> [String] {
        var words = ["apple", "apple apps", "apple app", app.rawValue, "apple_apps"]
        words += app.toolNames.sorted()
        switch app {
        case .calendar: words += ["events", "schedule", "meeting", "ical", "eventkit", "agenda"]
        case .reminders: words += ["todo", "to-do", "task list", "due date", "reminder"]
        case .contacts: words += ["address book", "phone number", "email address", "people", "my card"]
        case .notes: words += ["apple notes", "note", "folders", "notebook"]
        case .mail: words += ["email", "inbox", "mailbox", "compose", "reply", "apple mail"]
        case .messages: words += ["imessage", "sms", "text message", "chat.db", "conversations"]
        case .maps: words += ["maps & location", "location", "directions", "geocode", "eta", "places", "nearby", "current location"]
        case .music: words += ["apple music", "now playing", "playlist", "play", "pause", "volume", "itunes"]
        case .shortcuts: words += ["shortcut", "run shortcut", "automation", "workflow"]
        }
        return words
    }
}
