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
    /// Provider for the shared core model (e.g. "anthropic")
    public var coreModelProvider: String?
    /// Name of the shared core model (e.g. "claude-haiku-4-5")
    public var coreModelName: String?

    /// Full model identifier for routing, or nil when no core model is configured.
    public var coreModelIdentifier: String? {
        guard let name = coreModelName, !name.isEmpty else { return nil }
        if let provider = coreModelProvider, !provider.isEmpty {
            return "\(provider)/\(name)"
        }
        return name
    }

    // MARK: - Work Generation Settings
    /// Work-specific temperature override (nil uses default 0.3)
    public var workTemperature: Float?
    /// Work-specific max tokens override (nil uses default 4096)
    public var workMaxTokens: Int?
    /// Work-specific top_p override (nil uses server default)
    public var workTopPOverride: Float?
    /// Work-specific max reasoning loop iterations (nil uses default 50)
    public var workMaxIterations: Int?
    /// Global sandbox execution config used by the built-in Default agent.
    public var defaultAutonomousExec: AutonomousExecConfig?

    // MARK: - Preflight Search Settings
    /// Controls how aggressively pre-flight capability search loads context (nil defaults to .balanced)
    public var preflightSearchMode: PreflightSearchMode?

    // MARK: - Tool Settings
    /// When true, no tools or preflight context are passed to the model. The raw message is sent
    /// directly, keeping the prompt stable across turns for maximum KV-cache reuse. Recommended
    /// when osaurus is acting as a plain LLM backend for an external agent (e.g. Claude via API).
    public var disableTools: Bool

    // MARK: - Clipboard Settings
    /// When true, Osaurus will monitor the clipboard for new text content to offer as context.
    public var enableClipboardMonitoring: Bool

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
        workTemperature: Float? = nil,
        workMaxTokens: Int? = nil,
        workTopPOverride: Float? = nil,
        workMaxIterations: Int? = nil,
        defaultAutonomousExec: AutonomousExecConfig? = nil,
        preflightSearchMode: PreflightSearchMode? = nil,
        disableTools: Bool = false,
        enableClipboardMonitoring: Bool = true
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
        self.workTemperature = workTemperature
        self.workMaxTokens = workMaxTokens
        self.workTopPOverride = workTopPOverride
        self.workMaxIterations = workMaxIterations
        self.defaultAutonomousExec = defaultAutonomousExec
        self.preflightSearchMode = preflightSearchMode
        self.disableTools = disableTools
        self.enableClipboardMonitoring = enableClipboardMonitoring
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
        workTemperature = try container.decodeIfPresent(Float.self, forKey: .workTemperature)
        workMaxTokens = try container.decodeIfPresent(Int.self, forKey: .workMaxTokens)
        workTopPOverride = try container.decodeIfPresent(Float.self, forKey: .workTopPOverride)
        workMaxIterations = try container.decodeIfPresent(Int.self, forKey: .workMaxIterations)
        defaultAutonomousExec = try container.decodeIfPresent(
            AutonomousExecConfig.self,
            forKey: .defaultAutonomousExec
        )
        preflightSearchMode = try container.decodeIfPresent(
            PreflightSearchMode.self,
            forKey: .preflightSearchMode
        )
        disableTools = try container.decodeIfPresent(Bool.self, forKey: .disableTools) ?? false
        enableClipboardMonitoring = try container.decodeIfPresent(Bool.self, forKey: .enableClipboardMonitoring) ?? true
    }

    public static var `default`: ChatConfiguration {
        let key: UInt32 = UInt32(kVK_ANSI_Semicolon)
        let mods: UInt32 = UInt32(cmdKey)
        let display = "⌘;"
        return ChatConfiguration(
            hotkey: Hotkey(keyCode: key, carbonModifiers: mods, displayString: display),
            systemPrompt: "",
            temperature: nil,
            maxTokens: 16384,
            contextLength: 128000,
            topPOverride: nil,
            maxToolAttempts: 15,
            coreModelProvider: nil,
            coreModelName: nil,
            workTemperature: 0.3,
            workMaxTokens: 4096,
            workTopPOverride: nil,
            workMaxIterations: 50,
            defaultAutonomousExec: nil,
            preflightSearchMode: .balanced,
            enableClipboardMonitoring: true
        )
    }
}
