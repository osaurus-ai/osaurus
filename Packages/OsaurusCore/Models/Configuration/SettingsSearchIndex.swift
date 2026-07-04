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

    public init(
        id: String,
        tab: ManagementTab,
        section: String = "",
        title: String,
        keywords: [String] = [],
        subTab: String? = nil
    ) {
        self.id = id
        self.tab = tab
        self.section = section
        self.title = title
        self.keywords = keywords
        self.subTab = subTab
    }

    /// Breadcrumb shown in results, e.g. ["Voice", "Speech to Text", "Transcription Model"].
    /// A section that just repeats the tab label (e.g. the "General" card inside
    /// the General tab) is collapsed so results don't read "General › General".
    public var breadcrumb: [String] {
        section.isEmpty || section == tab.label
            ? [tab.label, title]
            : [tab.label, section, title]
    }
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

        // MARK: Chat (generation knobs now live in the dedicated Chat tab)
        .init(
            id: "settings.chat.systemPrompt",
            tab: .chat,
            section: "Chat",
            title: "System Prompt",
            keywords: ["persona", "instructions", "system prompt"]
        ),
        .init(
            id: "settings.chat.temperature",
            tab: .chat,
            section: "Generation",
            title: "Temperature",
            keywords: ["randomness", "creativity", "sampling"]
        ),
        .init(
            id: "settings.chat.maxTokens",
            tab: .chat,
            section: "Generation",
            title: "Max Tokens",
            keywords: ["response length", "output tokens"]
        ),
        .init(
            id: "settings.chat.contextLength",
            tab: .chat,
            section: "Generation",
            title: "Context Length",
            keywords: ["context window", "context"]
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
            id: "settings.toolPermissions",
            tab: .chat,
            section: "Tool Permissions",
            title: "Folder Tool Permissions",
            keywords: ["permissions", "shell", "git", "write files", "edit files"]
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
            title: "Dictation Hotkey",
            keywords: ["push to talk", "voice hotkey", "shortcut"],
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
            keywords: ["top p", "temperature", "sampling", "defaults"],
            subTab: "sampling"
        ),
        .init(
            id: "server.residency",
            tab: .server,
            section: "Model Memory",
            title: "Model Residency",
            keywords: ["eviction", "idle", "keep model loaded", "unload"],
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
            keywords: ["cache", "kv cache", "prefix"],
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
            keywords: ["decode", "throughput", "speed", "tokens per second"],
            subTab: "decodePerformance"
        ),
        .init(
            id: "server.speculative",
            tab: .server,
            section: "Speculative Decoding",
            title: "Speculative Decoding",
            keywords: ["speculative", "mtp", "draft model"],
            subTab: "speculative"
        ),
        .init(
            id: "server.liveActivity",
            tab: .server,
            section: "Live Activity",
            title: "Live Activity",
            keywords: ["live activity", "dynamic island", "status"],
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
            keywords: ["tool calling", "templates", "chat template"],
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
            title: "Tool Permissions",
            keywords: ["allow", "ask", "deny", "shell", "files", "git", "auto approve"]
        ),
        .init(
            id: "computerUse.enable",
            tab: .computerUse,
            title: "Computer Use",
            keywords: ["screen control", "cursor", "automation", "accessibility", "per-app"]
        ),

        // MARK: Channels / Integrations
        .init(
            id: "agentChannels.overview",
            tab: .agentChannels,
            title: "Channels",
            keywords: [
                "agent channels", "integrations", "channels", "discord", "slack", "telegram",
                "custom json", "custom http", "remote channel",
            ]
        ),
        .init(
            id: "agentChannels.globalWrites",
            tab: .agentChannels,
            section: "Global Channel Safety",
            title: "Global Channel Writes",
            keywords: ["kill switch", "disable writes", "remote writes", "channel writes"]
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
            id: "agentChannels.customJSON",
            tab: .agentChannels,
            section: "Custom JSON Connections",
            title: "Custom HTTP Connections",
            keywords: ["custom json channels", "webhook", "agent-channels.json", "secret references"]
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

        // MARK: Subagents (runtime knobs in the Settings tab)
        // There is no global master switch and no dedicated Spawn tab anymore.
        // What remains are the shared runtime knobs (local handoff, RAM-safety),
        // folded into the Settings tab as a "Subagents" card. Per-agent
        // spawn/image config (targets, models, permissions, budgets) — including
        // the built-in main chat — is configured in each agent's Subagents tab
        // (not indexed here). Global image-generation settings live in the
        // Image Generation tab (indexed above).
        .init(
            id: "settings.subagents",
            tab: .settings,
            section: "Subagents",
            title: "Subagents",
            keywords: [
                "spawn", "delegate", "delegation", "subagent",
                "helper jobs", "agent delegation",
            ]
        ),
        .init(
            id: "settings.subagents.handoff",
            tab: .settings,
            section: "Subagents",
            title: "Local Handoff & RAM Safety",
            keywords: ["handoff", "ram safety", "residency", "unload", "preflight"]
        ),
        .init(
            id: "privacy.tab",
            tab: .privacy,
            title: "Privacy Filter",
            keywords: ["redaction", "filter", "scrub", "mask", "sensitive data", "custom rules", "pii"]
        ),

        // MARK: Identity / Storage / Themes / Memory
        .init(
            id: "identity.keys",
            tab: .identity,
            title: "Identity & Recovery",
            keywords: [
                "mnemonic", "seed phrase", "recovery phrase", "agent keys", "signing",
                "cryptographic identity", "keys",
            ]
        ),
        // The Storage tab is the single home for disk concerns: the models
        // directory + external sources moved here from the General tab.
        .init(
            id: "storage.location",
            tab: .storage,
            title: "Models Directory",
            keywords: ["disk", "data location", "models folder", "move models", "cleanup", "models size"]
        ),
        .init(
            id: "storage.externalModels",
            tab: .storage,
            title: "External Model Sources",
            keywords: ["hugging face", "hf cache", "lm studio", "external", "import models"]
        ),
        .init(
            id: "storage.encryption",
            tab: .storage,
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
            keywords: ["memories", "facts", "recall", "long term memory"]
        ),
        .init(
            id: "memory.settings.budget",
            tab: .memory,
            section: "Configuration",
            title: "Memory Budget",
            keywords: ["memory tokens", "context budget", "injection"],
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
    ]
}
