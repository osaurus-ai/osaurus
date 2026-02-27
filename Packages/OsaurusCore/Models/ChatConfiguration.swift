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
    /// Load capabilities in two phases (catalog, then select_capabilities) to reduce token usage
    public var phasedContextLoading: Bool

    // MARK: - Work Generation Settings
    /// Work-specific temperature override (nil uses default 0.3)
    public var workTemperature: Float?
    /// Work-specific max tokens override (nil uses default 4096)
    public var workMaxTokens: Int?
    /// Work-specific top_p override (nil uses server default)
    public var workTopPOverride: Float?
    /// Work-specific max reasoning loop iterations (nil uses default 30)
    public var workMaxIterations: Int?

    public init(
        hotkey: Hotkey?,
        systemPrompt: String,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        contextLength: Int? = nil,
        topPOverride: Float? = nil,
        maxToolAttempts: Int? = nil,
        defaultModel: String? = nil,
        phasedContextLoading: Bool = true,
        workTemperature: Float? = nil,
        workMaxTokens: Int? = nil,
        workTopPOverride: Float? = nil,
        workMaxIterations: Int? = nil
    ) {
        self.hotkey = hotkey
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextLength = contextLength
        self.topPOverride = topPOverride
        self.maxToolAttempts = maxToolAttempts
        self.defaultModel = defaultModel
        self.phasedContextLoading = phasedContextLoading
        self.workTemperature = workTemperature
        self.workMaxTokens = workMaxTokens
        self.workTopPOverride = workTopPOverride
        self.workMaxIterations = workMaxIterations
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
        phasedContextLoading = try container.decodeIfPresent(Bool.self, forKey: .phasedContextLoading) ?? true
        workTemperature = try container.decodeIfPresent(Float.self, forKey: .workTemperature)
        workMaxTokens = try container.decodeIfPresent(Int.self, forKey: .workMaxTokens)
        workTopPOverride = try container.decodeIfPresent(Float.self, forKey: .workTopPOverride)
        workMaxIterations = try container.decodeIfPresent(Int.self, forKey: .workMaxIterations)
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
            workTemperature: 0.3,  // Low temperature for reliable tool-calling
            workMaxTokens: 4096,  // Conservative per-iteration limit for work steps
            workTopPOverride: nil,
            workMaxIterations: 30  // Default reasoning loop iterations
        )
    }
}
