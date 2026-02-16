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
    /// Work mode - task execution with issue tracking
    case work = "agent"

    public var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .work: return "Work"
        }
    }

    public var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .work: return "bolt.circle"
        }
    }
}
