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

    // MARK: - Agent Generation Settings
    /// Agent-specific temperature override (nil uses default 0.3)
    public var agentTemperature: Float?
    /// Agent-specific max tokens override (nil uses default 4096)
    public var agentMaxTokens: Int?
    /// Agent-specific top_p override (nil uses server default)
    public var agentTopPOverride: Float?
    /// Agent-specific max reasoning loop iterations (nil uses default 30)
    public var agentMaxIterations: Int?

    public init(
        hotkey: Hotkey?,
        systemPrompt: String,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        contextLength: Int? = nil,
        topPOverride: Float? = nil,
        maxToolAttempts: Int? = nil,
        defaultModel: String? = nil,
        agentTemperature: Float? = nil,
        agentMaxTokens: Int? = nil,
        agentTopPOverride: Float? = nil,
        agentMaxIterations: Int? = nil
    ) {
        self.hotkey = hotkey
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextLength = contextLength
        self.topPOverride = topPOverride
        self.maxToolAttempts = maxToolAttempts
        self.defaultModel = defaultModel
        self.agentTemperature = agentTemperature
        self.agentMaxTokens = agentMaxTokens
        self.agentTopPOverride = agentTopPOverride
        self.agentMaxIterations = agentMaxIterations
    }

    public static var `default`: ChatConfiguration {
        // Default hotkey: Command + Semicolon
        let key: UInt32 = UInt32(kVK_ANSI_Semicolon)
        let mods: UInt32 = UInt32(cmdKey)
        let display = "⌘;"
        return ChatConfiguration(
            hotkey: Hotkey(keyCode: key, carbonModifiers: mods, displayString: display),
            systemPrompt: "",
            temperature: nil,
            maxTokens: 16384,  // High default to support long generations (essays, code, etc.)
            contextLength: 128000,  // Default to 128k for modern remote models
            topPOverride: nil,
            maxToolAttempts: 15,  // Max consecutive tool calls per chat turn
            agentTemperature: 0.3,  // Low temperature for reliable tool-calling
            agentMaxTokens: 4096,  // Conservative per-iteration limit for agent steps
            agentTopPOverride: nil,
            agentMaxIterations: 30  // Default reasoning loop iterations
        )
    }
}
