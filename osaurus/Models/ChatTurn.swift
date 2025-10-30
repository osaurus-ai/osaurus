//
//  ChatTurn.swift
//  osaurus
//
//  Reference-type chat turn for efficient UI updates
//

import Combine
import Foundation

final class ChatTurn: ObservableObject, Identifiable {
  let id = UUID()
  let role: MessageRole
  @Published var content: String

  init(role: MessageRole, content: String) {
    self.role = role
    self.content = content
  }
}
