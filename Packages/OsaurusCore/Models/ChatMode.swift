//
//  ChatMode.swift
//  osaurus
//
//  Defines the operating mode for the chat interface.
//

import Foundation

/// Operating mode for the chat window
public enum ChatMode: String, Codable, Sendable {
    /// Standard chat mode - conversational interaction
    case chat
    /// Agent mode - task execution with issue tracking
    case agent

    public var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .agent: return "Agent"
        }
    }

    public var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .agent: return "bolt.circle"
        }
    }
}
