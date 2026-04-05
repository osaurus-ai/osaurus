//
//  UIWorkarounds.swift
//  osaurus
//
//  Centralized workarounds for SwiftUI bugs and platform-specific UI quirks.
//

import Foundation

extension Task where Success == Never, Failure == Never {
    /// A timing workaround for a SwiftUI bug where presenting a new window, sheet, or file picker
    /// while a popover is still animating its dismissal causes the presentation to be ignored or the app to freeze.
    ///
    /// - Note: 100ms is generally enough to outlast the standard macOS popover dismiss animation.
    /// If this becomes flaky on newer OS versions, consider increasing the delay or finding a non-timing-based workaround.
    @MainActor
    static func sleepForPopoverDismiss() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}
