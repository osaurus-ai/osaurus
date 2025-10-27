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

  public init(hotkey: Hotkey?, systemPrompt: String) {
    self.hotkey = hotkey
    self.systemPrompt = systemPrompt
  }

  public static var `default`: ChatConfiguration {
    // Default hotkey: Command + Semicolon
    let key: UInt32 = UInt32(kVK_ANSI_Semicolon)
    let mods: UInt32 = UInt32(cmdKey)
    let display = "⌘;"
    return ChatConfiguration(
      hotkey: Hotkey(keyCode: key, carbonModifiers: mods, displayString: display),
      systemPrompt: ""
    )
  }
}
