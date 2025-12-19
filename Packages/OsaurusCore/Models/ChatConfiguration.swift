//
//  ChatConfiguration.swift
//  osaurus
//
//  Defines user-facing chat settings such as the global hotkey and system prompt.
//

import Carbon.HIToolbox
import Foundation

/// How tool calls are displayed in the chat UI
public enum ToolCallDisplayStyle: String, Codable, CaseIterable, Sendable {
    /// Each tool call appears as a separate compact row (default)
    case inline = "inline"
    /// All tool calls are grouped in a collapsible container
    case grouped = "grouped"

    public var displayName: String {
        switch self {
        case .inline: return "Inline"
        case .grouped: return "Grouped"
        }
    }
}

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
    /// Optional per-chat override for top_p sampling (nil uses server default)
    public var topPOverride: Float?
    /// Optional per-chat limit on consecutive tool attempts (nil uses default)
    public var maxToolAttempts: Int?
    /// Whether the chat window should float above other windows
    public var alwaysOnTop: Bool
    /// Default model for new chat sessions (nil uses first available)
    public var defaultModel: String?
    /// How tool calls are displayed in the chat UI
    public var toolCallDisplayStyle: ToolCallDisplayStyle

    public init(
        hotkey: Hotkey?,
        systemPrompt: String,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        topPOverride: Float? = nil,
        maxToolAttempts: Int? = nil,
        alwaysOnTop: Bool = false,
        defaultModel: String? = nil,
        toolCallDisplayStyle: ToolCallDisplayStyle = .inline
    ) {
        self.hotkey = hotkey
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topPOverride = topPOverride
        self.maxToolAttempts = maxToolAttempts
        self.alwaysOnTop = alwaysOnTop
        self.defaultModel = defaultModel
        self.toolCallDisplayStyle = toolCallDisplayStyle
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
            topPOverride: nil,
            maxToolAttempts: 15,  // Increased from 3 to support longer agentic workflows
            alwaysOnTop: false,
            toolCallDisplayStyle: .inline
        )
    }
}
