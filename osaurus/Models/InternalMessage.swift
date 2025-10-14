//
//  InternalMessage.swift
//  osaurus
//
//  Extracted from MLXService for reuse across services.
//

import Foundation

/// Message role for chat interactions
enum MessageRole: String, Codable {
  case system
  case user
  case assistant
}

/// Chat message structure
struct Message: Codable {
  let role: MessageRole
  let content: String

  init(role: MessageRole, content: String) {
    self.role = role
    self.content = content
  }
}
