//
//  ChatConfiguration.swift
//  osaurus
//
//  Defines user-facing chat settings such as the global hotkey and system prompt.
//

import Carbon.HIToolbox
import Foundation

public struct Hotkey: Codable, Equatable, Sendable {
    /// Carbon virtual key code (e.g., kVK_ANSI_Semicolon)
    public let keyCode: UInt32
    /// Carbon-style modifier mask (cmdKey, optionKey, controlKey, shiftKey)
    public let carbonModifiers: UInt32
    /// Human-readable shortcut string (e.g., "⌘;")
    public let displayString: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, displayString: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayString = displayString
    }
}

public struct ChatConfiguration: Codable, Equatable, Sendable {
    /// Default name baked into `ChatConfiguration.default.coreModelName`
    /// and used by the legacy-install backfill in
    /// `AppConfiguration.backfillFoundationCoreModelIfMissing`.
    /// Both call sites must reference this constant so they can
    /// never drift apart and re-trigger the 2026-04 schema-migration
    /// outage.
    public static let defaultCoreModelName = "foundation"

    /// Optional global hotkey to toggle chat overlay; nil disables the hotkey
    public var hotkey: Hotkey?
    /// Global system prompt prepended to every chat session (optional)
    public var systemPrompt: String
    /// Optional per-chat override for temperature (nil uses app default)
    public var temperature: Float?
    /// Optional per-chat override for maximum response tokens (nil uses app default)
    public var maxTokens: Int?
    /// Optional default context length for models with unknown limits (e.g. remote)
    public var contextLength: Int?
    /// Optional per-chat override for top_p sampling (nil uses server default)
    public var topPOverride: Float?
    /// Optional per-chat limit on consecutive tool attempts (nil uses default)
    public var maxToolAttempts: Int?
    /// Default model for new chat sessions (nil uses first available)
    public var defaultModel: String?

    // MARK: - Core Model Settings
    /// Provider for the shared core model. Empty / nil means a
    /// local model (Apple Foundation, MLX) — only set this when
    /// the user has selected a remote model like
    /// `"anthropic/claude-haiku-4-5"`.
    public var coreModelProvider: String?
    /// Name of the shared core model. Defaults to `"foundation"`
    /// (Apple's on-device Language Model on macOS 26+) so that
    /// memory consolidation and the transcription cleanup path all work
    /// out of the box without the user needing to configure an API key.
    public var coreModelName: String?

    /// Full model identifier for routing, or nil when no core model is configured.
    public var coreModelIdentifier: String? {
        guard let name = coreModelName, !name.isEmpty else { return nil }
        if let provider = coreModelProvider, !provider.isEmpty {
            return "\(provider)/\(name)"
        }
        return name
    }

    // MARK: - Context Compaction Model Settings
    /// Provider for the context-compaction model (same split/join contract
    /// as `coreModelProvider`). Nil for local/Foundation models.
    public var compactionModelProvider: String?
    /// Name of the model that runs LLM context compaction (conversation
    /// summarization when a chat outgrows the context window). Unlike the
    /// core model there is deliberately NO chat-model fallback: when unset,
    /// the first compaction run asks the user to pick a model.
    public var compactionModelName: String?

    /// Full compaction-model identifier for routing, or nil when unset.
    public var compactionModelIdentifier: String? {
        guard let name = compactionModelName, !name.isEmpty else { return nil }
        if let provider = compactionModelProvider, !provider.isEmpty {
            return "\(provider)/\(name)"
        }
        return name
    }

    // MARK: - Tool Settings
    /// When true, no tools are passed to the model. The raw message is sent
    /// directly, keeping the prompt stable across turns for maximum KV-cache reuse. Recommended
    /// when osaurus is acting as a plain LLM backend for an external agent.
    public var disableTools: Bool

    // MARK: - Clipboard Settings
    /// When true, Osaurus will monitor the clipboard for new text content to offer as context.
    public var enableClipboardMonitoring: Bool

    // MARK: - Model Warm-Up
    /// When true, local chat sessions proactively load the selected model and
    /// prefill the static prompt prefix (system + tools + history) before the
    /// user sends, so the first response pays less time-to-first-token cost.
    public var warmModelsOnLoad: Bool

    // MARK: - Auto-Generated Chat Titles
    /// When true, the first completed exchange of a new chat triggers a
    /// background Core Model call that replaces the first-message preview
    /// title with a short generated summary (see `ChatTitleService`).
    /// Ships default-off while the feature bakes across releases; flip the
    /// default here once it has proven regression-free.
    public var autoGenerateChatTitles: Bool

    public init(
        hotkey: Hotkey?,
        systemPrompt: String,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        contextLength: Int? = nil,
        topPOverride: Float? = nil,
        maxToolAttempts: Int? = nil,
        defaultModel: String? = nil,
        coreModelProvider: String? = nil,
        coreModelName: String? = nil,
        compactionModelProvider: String? = nil,
        compactionModelName: String? = nil,
        disableTools: Bool = false,
        enableClipboardMonitoring: Bool = true,
        warmModelsOnLoad: Bool = true,
        autoGenerateChatTitles: Bool = false
    ) {
        self.hotkey = hotkey
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextLength = contextLength
        self.topPOverride = topPOverride
        self.maxToolAttempts = maxToolAttempts
        self.defaultModel = defaultModel
        self.coreModelProvider = coreModelProvider
        self.coreModelName = coreModelName
        self.compactionModelProvider = compactionModelProvider
        self.compactionModelName = compactionModelName
        self.disableTools = disableTools
        self.enableClipboardMonitoring = enableClipboardMonitoring
        self.warmModelsOnLoad = warmModelsOnLoad
        self.autoGenerateChatTitles = autoGenerateChatTitles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        temperature = try container.decodeIfPresent(Float.self, forKey: .temperature)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        topPOverride = try container.decodeIfPresent(Float.self, forKey: .topPOverride)
        maxToolAttempts = try container.decodeIfPresent(Int.self, forKey: .maxToolAttempts)
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        coreModelProvider = try container.decodeIfPresent(String.self, forKey: .coreModelProvider)
        coreModelName = try container.decodeIfPresent(String.self, forKey: .coreModelName)
        compactionModelProvider = try container.decodeIfPresent(
            String.self, forKey: .compactionModelProvider)
        compactionModelName = try container.decodeIfPresent(
            String.self, forKey: .compactionModelName)
        disableTools = try container.decodeIfPresent(Bool.self, forKey: .disableTools) ?? false
        enableClipboardMonitoring = try container.decodeIfPresent(Bool.self, forKey: .enableClipboardMonitoring) ?? true
        warmModelsOnLoad = try container.decodeIfPresent(Bool.self, forKey: .warmModelsOnLoad) ?? true
        autoGenerateChatTitles =
            try container.decodeIfPresent(Bool.self, forKey: .autoGenerateChatTitles) ?? false
    }

    public static var `default`: ChatConfiguration {
        let key: UInt32 = UInt32(kVK_ANSI_Semicolon)
        let mods: UInt32 = UInt32(cmdKey)
        let display = "⌘;"
        return ChatConfiguration(
            hotkey: Hotkey(keyCode: key, carbonModifiers: mods, displayString: display),
            systemPrompt: "",
            temperature: nil,
            maxTokens: nil,
            contextLength: 128000,
            topPOverride: nil,
            maxToolAttempts: 30,
            // Out-of-box core model: Apple Foundation when this Mac can
            // actually run it (macOS 26+ with Apple Intelligence). On
            // older systems / Intel, leave the core model unset and let
            // `CoreModelService` fall back to the active chat model —
            // shipping `"foundation"` here was the root cause of
            // GitHub issue #823. The literal name is centralised in
            // `defaultCoreModelName` so the legacy-install backfill in
            // `AppConfiguration` picks exactly the same value.
            coreModelProvider: nil,
            coreModelName: defaultCoreModelNameIfAvailable,
            enableClipboardMonitoring: true,
            warmModelsOnLoad: true,
            autoGenerateChatTitles: false
        )
    }

    /// `defaultCoreModelName` gated by runtime Foundation availability.
    /// Returns `nil` on any Mac where `FoundationModelService` can't
    /// actually serve the model, keeping the data layer honest so the
    /// chat-model fallback (and the AppConfiguration cleanup migration)
    /// don't have to chase the silent-invalid-default state.
    public static var defaultCoreModelNameIfAvailable: String? {
        FoundationModelService.isDefaultModelAvailable() ? defaultCoreModelName : nil
    }
}
