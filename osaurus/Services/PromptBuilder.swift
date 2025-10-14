//
//  PromptBuilder.swift
//  osaurus
//
//  Created by Terence on 10/14/25.
//

import Foundation

struct PromptBuilder {
  static func buildPrompt(from messages: [Message]) -> String {
    var parts: [String] = []
    parts.reserveCapacity(max(4, messages.count * 2))
    for m in messages {
      switch m.role {
      case .system:
        parts.append("System:")
        parts.append(m.content)
      case .user:
        parts.append("User:")
        parts.append(m.content)
      case .assistant:
        parts.append("Assistant:")
        parts.append(m.content)
      }
    }
    parts.append("Assistant:")
    return parts.joined(separator: "\n")
  }
}
