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

    // MARK: - Tool Settings
    /// When true, no tools are passed to the model. The raw message is sent
    /// directly, keeping the prompt stable across turns for maximum KV-cache reuse. Recommended
    /// when osaurus is acting as a plain LLM backend for an external agent.
    public var disableTools: Bool

    // MARK: - Clipboard Settings
    /// When true, Osaurus will monitor the clipboard for new text content to offer as context.
    public var enableClipboardMonitoring: Bool

    // MARK: - Generative Greetings
    /// Free-text "voice" instruction that shapes the AI-generated empty-state
    /// greetings and quick actions. Empty string means "use the built-in
    /// playful default" baked into `GenerativeGreetingService`. This is the
    /// global default voice; the on/off decision is per-agent
    /// (`AgentSettings.generativeGreetingsEnabled`). Per-agent
    /// `AgentSettings.greetingPersona` overrides this when non-empty.
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
        disableTools: Bool = false,
        enableClipboardMonitoring: Bool = true,
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
        self.disableTools = disableTools
        self.enableClipboardMonitoring = enableClipboardMonitoring
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
        disableTools = try container.decodeIfPresent(Bool.self, forKey: .disableTools) ?? false
        enableClipboardMonitoring = try container.decodeIfPresent(Bool.self, forKey: .enableClipboardMonitoring) ?? true
        // The on/off for AI greetings is now per-agent
        // (`AgentSettings.generativeGreetingsEnabled`). Any legacy
        // `generativeGreetingsEnabled` boolean persisted here is ignored
        // by the auto-synthesized decoder and dropped on the next save.
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
            // Empty persona = "use built-in playful default". This is the
            // global default voice; the on/off is per-agent. Users opt
            // into a custom voice from Settings → Chat (or a per-agent
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
