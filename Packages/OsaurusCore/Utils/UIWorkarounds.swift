//
//  UIWorkarounds.swift
//  osaurus
//
//  Centralized workarounds for SwiftUI bugs and platform-specific UI quirks.
//

import AppKit
import Foundation

extension Task where Success == Never, Failure == Never {
    /// A timing workaround for a SwiftUI bug where presenting a new window, sheet, or file picker
    /// while a popover is still animating its dismissal causes the presentation to be ignored or the app to freeze.
    ///
    /// - Note: 100ms is generally enough to outlast the standard macOS popover dismiss animation.
    /// If this becomes flaky on newer OS versions, consider increasing the delay or finding a non-timing-based workaround.
    @MainActor
    static func sleepForPopoverDismiss() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}

extension NSSavePanel {
    /// Presents the panel without spinning a nested modal run loop on the
    /// main thread. `runModal()` blocks the run loop for as long as the user
    /// browses, which Sentry's app-hang watchdog reports as a false 2000ms+
    /// "App Hang". `begin` is non-blocking and resumes on the main thread once
    /// the user dismisses the panel.
    ///
    /// Covers `NSOpenPanel` too, since it subclasses `NSSavePanel`.
    @MainActor
    func beginModal() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin { continuation.resume(returning: $0) }
        }
    }

    /// Sheet variant of `beginModal()`: attaches the panel to `window`
    /// instead of opening a detached panel window. A detached panel has to
    /// steal key status from (and reorder around) the presenting window —
    /// visibly flickery when the chat window is a floating `NSPanel` — while
    /// a sheet never competes for key status or window level. Equally
    /// non-blocking (no nested modal run loop, no watchdog false hangs).
    @MainActor
    func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
