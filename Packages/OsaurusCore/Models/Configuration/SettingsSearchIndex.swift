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

    public init(
        id: String,
        tab: ManagementTab,
        section: String = "",
        title: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.tab = tab
        self.section = section
        self.title = title
        self.keywords = keywords
    }

    /// Breadcrumb shown in results, e.g. ["Voice", "Speech to Text", "Transcription Model"].
    public var breadcrumb: [String] {
        section.isEmpty ? [tab.label, title] : [tab.label, section, title]
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
        return ranked
            .enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { $0.element.entry }
    }

    /// Every searchable setting, grouped by tab in declaration order.
    public static let entries: [SettingsSearchEntry] = [
        // MARK: Settings (General)
        .init(
            id: "settings.general.hotkey", tab: .settings, section: "General",
            title: "Global Hotkey", keywords: ["shortcut", "keybinding", "hotkey"]
        ),
        .init(
            id: "settings.general.login", tab: .settings, section: "General",
            title: "Start at Login", keywords: ["launch", "startup", "autostart"]
        ),
        .init(
            id: "settings.general.updates", tab: .settings, section: "General",
            title: "Beta Updates", keywords: ["beta", "prerelease", "updates", "channel"]
        ),
        .init(
            id: "settings.general.coreModel", tab: .settings, section: "General",
            title: "Core Model", keywords: ["default model", "core model"]
        ),
        .init(
            id: "settings.general.cli", tab: .settings, section: "General",
            title: "Command Line Tool", keywords: ["cli", "terminal", "symlink", "install"]
        ),
        .init(
            id: "settings.general.reset", tab: .settings, section: "General",
            title: "Factory Reset", keywords: ["reset", "wipe", "erase", "maintenance"]
        ),

        // MARK: Settings (Chat)
        .init(
            id: "settings.chat.systemPrompt", tab: .settings, section: "Chat",
            title: "System Prompt", keywords: ["persona", "instructions", "system prompt"]
        ),
        .init(
            id: "settings.chat.temperature", tab: .settings, section: "Chat",
            title: "Temperature", keywords: ["randomness", "creativity", "sampling"]
        ),
        .init(
            id: "settings.chat.maxTokens", tab: .settings, section: "Chat",
            title: "Max Tokens", keywords: ["response length", "output tokens"]
        ),
        .init(
            id: "settings.chat.contextLength", tab: .settings, section: "Chat",
            title: "Context Length", keywords: ["context window", "context"]
        ),
        .init(
            id: "settings.chat.topP", tab: .settings, section: "Chat",
            title: "Top P", keywords: ["nucleus sampling", "top-p"]
        ),
        .init(
            id: "settings.chat.toolAttempts", tab: .settings, section: "Chat",
            title: "Max Tool Attempts", keywords: ["tool calls", "agent loop", "attempts"]
        ),

        // MARK: Settings (Privacy / Notifications / Legal)
        .init(
            id: "settings.privacy.usage", tab: .settings, section: "Privacy",
            title: "Share Anonymous Usage Data", keywords: ["telemetry", "analytics", "tracking"]
        ),
        .init(
            id: "settings.privacy.crash", tab: .settings, section: "Privacy",
            title: "Send Crash Reports", keywords: ["crash", "diagnostics", "freeze"]
        ),
        .init(
            id: "settings.notifications.toasts", tab: .settings, section: "Notifications",
            title: "Toast Notifications", keywords: ["toast", "position", "timeout", "alerts"]
        ),
        .init(
            id: "settings.toolPermissions", tab: .settings, section: "Tool Permissions",
            title: "Folder Tool Permissions",
            keywords: ["permissions", "shell", "git", "write files", "edit files"]
        ),
        .init(
            id: "settings.legal", tab: .settings, section: "Legal",
            title: "Terms & Privacy Policy", keywords: ["terms", "privacy policy", "legal", "about"]
        ),

        // MARK: Voice
        .init(
            id: "voice.stt.model", tab: .voice, section: "Speech to Text",
            title: "Transcription Model",
            keywords: ["transcription", "parakeet", "whisper", "speech recognition", "dictation"]
        ),
        .init(
            id: "voice.stt.hotkey", tab: .voice, section: "Speech to Text",
            title: "Dictation Hotkey", keywords: ["push to talk", "voice hotkey", "shortcut"]
        ),
        .init(
            id: "voice.stt.vad", tab: .voice, section: "Speech to Text",
            title: "Voice Activity Detection",
            keywords: ["vad", "silence", "auto stop", "endpointing"]
        ),
        .init(
            id: "voice.tts.voice", tab: .voice, section: "Text to Speech",
            title: "Spoken Voice", keywords: ["tts", "read aloud", "speech synthesis", "voice"]
        ),
        .init(
            id: "voice.models", tab: .voice, section: "Models",
            title: "Voice Models", keywords: ["download model", "speech model", "parakeet"]
        ),

        // MARK: Server
        .init(
            id: "server.connection", tab: .server, section: "Connection",
            title: "Port & Network", keywords: ["port", "expose", "network", "host", "bind"]
        ),
        .init(
            id: "server.cors", tab: .server, section: "Connection",
            title: "Allowed Origins (CORS)", keywords: ["cors", "origins", "cross origin"]
        ),
        .init(
            id: "server.auth", tab: .server, section: "Authentication",
            title: "API Authentication", keywords: ["api key", "auth", "token", "bearer"]
        ),
        .init(
            id: "server.generation", tab: .server, section: "Generation Defaults",
            title: "Generation Defaults", keywords: ["top p", "temperature", "sampling", "defaults"]
        ),
        .init(
            id: "server.residency", tab: .server, section: "Model Residency",
            title: "Model Residency", keywords: ["eviction", "idle", "keep model loaded", "unload"]
        ),
        .init(
            id: "server.concurrency", tab: .server, section: "Concurrency",
            title: "Concurrency", keywords: ["parallel", "batch", "requests", "threads"]
        ),
        .init(
            id: "server.proxy", tab: .server, section: "Network",
            title: "Global Proxy", keywords: ["proxy", "http proxy", "socks"]
        ),

        // MARK: Permissions / Computer Use / Privacy tabs
        .init(
            id: "permissions.tools", tab: .permissions,
            title: "Tool Permissions",
            keywords: ["allow", "ask", "deny", "shell", "files", "git", "auto approve"]
        ),
        .init(
            id: "computerUse.enable", tab: .computerUse,
            title: "Computer Use",
            keywords: ["screen control", "cursor", "automation", "accessibility", "per-app"]
        ),
        .init(
            id: "privacy.tab", tab: .privacy,
            title: "Privacy Controls",
            keywords: ["telemetry", "analytics", "crash reports", "data", "tracking"]
        ),

        // MARK: Identity / Storage / Themes / Memory
        .init(
            id: "identity.mnemonic", tab: .identity,
            title: "Master Recovery Phrase",
            keywords: ["mnemonic", "seed phrase", "recovery", "keys", "identity"]
        ),
        .init(
            id: "identity.agentKeys", tab: .identity,
            title: "Agent Keys", keywords: ["agent key", "signing", "cryptographic identity"]
        ),
        .init(
            id: "storage.location", tab: .storage,
            title: "Storage & Cleanup",
            keywords: ["disk", "cache", "data location", "cleanup", "models size"]
        ),
        .init(
            id: "themes.appearance", tab: .themes,
            title: "Appearance & Themes",
            keywords: ["theme", "appearance", "dark mode", "color", "accent"]
        ),
        .init(
            id: "memory.settings", tab: .memory,
            title: "Memory",
            keywords: ["memories", "facts", "recall", "long term memory"]
        ),
    ]
}
