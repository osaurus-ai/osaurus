//
//  AppleURLOpener.swift
//  osaurus
//
//  Non-blocking URL opener for the `*_open_*` Apple-app tools.
//
//  `NSWorkspace.shared.open(_:)` is synchronous: it waits on a LaunchServices
//  mach reply until the target app (Calendar, Contacts, Maps, Reminders) has
//  been launched/activated. Calling it on the main actor froze the UI for
//  seconds on a cold launch (Sentry APPLE-MACOS-36N). This helper uses the
//  completion-handler variant instead, so no thread blocks while the system
//  launches the app.
//

import AppKit
import Foundation

enum AppleURLOpener {
    /// Test seam: replace to stub URL opening without launching apps.
    nonisolated(unsafe) static var handler: @Sendable (URL) async -> Bool = defaultOpen

    /// Open `url` in its default handler app. Returns `false` if the system
    /// reports an error. Never blocks the calling (or main) thread.
    static func open(_ url: URL) async -> Bool {
        await handler(url)
    }

    @Sendable
    static func defaultOpen(_ url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}
