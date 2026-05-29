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
    /// memory consolidation, preflight tool selection, and the
    /// transcription cleanup path all work out of the box without
    /// the user needing to configure an API key.
    public var coreModelName: String?

    /// Full model identifier for routing, or nil when no core model is configured.
    public var coreModelIdentifier: String? {
        guard let name = coreModelName, !name.isEmpty else { return nil }
        if let provider = coreModelProvider, !provider.isEmpty {
            return "\(provider)/\(name)"
        }
        return name
    }

    /// Global sandbox execution config used by the built-in Default agent.
    public var defaultAutonomousExec: AutonomousExecConfig?

    // MARK: - Preflight Search Settings
    /// Controls how aggressively pre-flight capability search loads context (nil defaults to .balanced)
    public var preflightSearchMode: PreflightSearchMode?

    // MARK: - Tool Settings
    /// When true, no tools or preflight context are passed to the model. The raw message is sent
    /// directly, keeping the prompt stable across turns for maximum KV-cache reuse. Recommended
    /// when osaurus is acting as a plain LLM backend for an external agent.
    public var disableTools: Bool

    /// Default tool selection mode for the built-in Default agent (nil => .auto).
    public var defaultToolSelectionMode: ToolSelectionMode?
    /// Manually selected tool names for the built-in Default agent (used when mode is .manual).
    public var defaultManualToolNames: [String]?
    /// Manually selected skill names for the built-in Default agent (used when mode is .manual).
    public var defaultManualSkillNames: [String]?

    // MARK: - Clipboard Settings
    /// When true, Osaurus will monitor the clipboard for new text content to offer as context.
    public var enableClipboardMonitoring: Bool

    // MARK: - Generative Greetings
    /// Global master switch for the AI-generated empty-state greetings.
    /// Defaults to `false` because the first generation against a small
    /// Core Model (Foundation in particular) blocks for several seconds
    /// and the output quality varies — opt-in keeps the chat empty state
    /// snappy out of the box. Per-agent `AgentSettings.generativeGreetingsEnabled`
    /// still wins when explicitly set; `nil` (the per-agent default)
    /// inherits this global flag.
    public var generativeGreetingsEnabled: Bool
    /// Free-text "voice" instruction that shapes the AI-generated empty-state
    /// greetings and quick actions. Empty string means "use the built-in
    /// playful default" baked into `GenerativeGreetingService`. Per-agent
    /// overrides live on `AgentSettings.greetingPersona` and take precedence
    /// when non-empty.
    public var greetingPersona: String

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
        defaultAutonomousExec: AutonomousExecConfig? = nil,
        preflightSearchMode: PreflightSearchMode? = nil,
        disableTools: Bool = false,
        defaultToolSelectionMode: ToolSelectionMode? = nil,
        defaultManualToolNames: [String]? = nil,
        defaultManualSkillNames: [String]? = nil,
        enableClipboardMonitoring: Bool = true,
        generativeGreetingsEnabled: Bool = false,
        greetingPersona: String = ""
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
        self.defaultAutonomousExec = defaultAutonomousExec
        self.preflightSearchMode = preflightSearchMode
        self.disableTools = disableTools
        self.defaultToolSelectionMode = defaultToolSelectionMode
        self.defaultManualToolNames = defaultManualToolNames
        self.defaultManualSkillNames = defaultManualSkillNames
        self.enableClipboardMonitoring = enableClipboardMonitoring
        self.generativeGreetingsEnabled = generativeGreetingsEnabled
        self.greetingPersona = greetingPersona
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
        defaultAutonomousExec = try container.decodeIfPresent(
            AutonomousExecConfig.self,
            forKey: .defaultAutonomousExec
        )
        preflightSearchMode = try container.decodeIfPresent(
            PreflightSearchMode.self,
            forKey: .preflightSearchMode
        )
        disableTools = try container.decodeIfPresent(Bool.self, forKey: .disableTools) ?? false
        defaultToolSelectionMode = try container.decodeIfPresent(
            ToolSelectionMode.self,
            forKey: .defaultToolSelectionMode
        )
        defaultManualToolNames = try container.decodeIfPresent(
            [String].self,
            forKey: .defaultManualToolNames
        )
        defaultManualSkillNames = try container.decodeIfPresent(
            [String].self,
            forKey: .defaultManualSkillNames
        )
        enableClipboardMonitoring = try container.decodeIfPresent(Bool.self, forKey: .enableClipboardMonitoring) ?? true
        // Master switch for AI-generated greetings. Older persisted JSON
        // may carry an `enableGenerativeGreetings` boolean from a prior
        // shape of this toggle — auto-synthesized `Codable` ignores
        // unknown keys, so legacy values are simply dropped on the next
        // save. Default `false` matches the new opt-in behavior.
        generativeGreetingsEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .generativeGreetingsEnabled) ?? false
        greetingPersona = try container.decodeIfPresent(String.self, forKey: .greetingPersona) ?? ""
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
            maxToolAttempts: 15,
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
            defaultAutonomousExec: nil,
            preflightSearchMode: .balanced,
            enableClipboardMonitoring: true,
            // Master AI-greetings switch defaults to OFF: cold-start cost
            // and small-model output quality made it a poor default. Users
            // opt in from Settings → Chat or per-agent in the Customization
            // tab.
            generativeGreetingsEnabled: false,
            // Empty persona = "use built-in playful default". Users opt
            // into a custom voice from Settings → Chat (or per-agent
            // override in the Customization tab).
            greetingPersona: ""
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
