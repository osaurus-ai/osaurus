//
//  LoginItemService.swift
//  osaurus
//
//  Created by Terence on 8/31/25.
//

import Foundation
import ServiceManagement

/// Manages "Start at Login" registration for the main app
final class LoginItemService {
  static let shared = LoginItemService()
  private init() {}

  /// Returns whether the app is currently registered to start at login
  var isEnabled: Bool {
    if #available(macOS 13.0, *) {
      return SMAppService.mainApp.status == .enabled
    } else {
      return false
    }
  }

  /// Apply desired start-at-login state
  func applyStartAtLogin(_ enabled: Bool) {
    if #available(macOS 13.0, *) {
      let service = SMAppService.mainApp
      do {
        if enabled {
          if service.status != .enabled {
            try service.register()
          }
        } else {
          if service.status != .notRegistered {
            try service.unregister()
          }
        }
      } catch {
        print("[Osaurus] Failed to update Start at Login state: \(error)")
      }
    } else {
      print("[Osaurus] Start at Login requires macOS 13.0 or later")
    }
  }
}
