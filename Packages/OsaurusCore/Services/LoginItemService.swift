//
//  LoginItemService.swift
//  osaurus
//
//  Created by Terence on 8/31/25.
//

import Foundation
import ServiceManagement

/// Manages "Start at Login" registration for the main app
@MainActor
final class LoginItemService {
    static let shared = LoginItemService()
    private init() {}

    /// Returns whether the app is currently registered to start at login
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Apply desired start-at-login state.
    ///
    /// `SMAppService.status`/`register`/`unregister` each make a synchronous XPC
    /// round trip to the service-management daemon, which can block for seconds
    /// (it's invoked from launch and reported as an app hang). Both call sites
    /// are fire-and-forget, so the work runs off the main thread.
    func applyStartAtLogin(_ enabled: Bool) {
        Task.detached(priority: .utility) {
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
        }
    }
}
