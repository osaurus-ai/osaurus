//
//  NSWorkspaceAsyncOpen.swift
//  osaurus
//
//  Non-blocking URL opening for async flows.
//

import AppKit

extension NSWorkspace {
    /// Open a URL without blocking the calling thread. The synchronous
    /// `open(_:)` round-trips to LaunchServices over blocking XPC, which can
    /// stall the main thread for seconds when LaunchServices is busy, so
    /// async flows use this completion-handler variant bridged to async.
    public func openAsync(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}
