//
//  PluginOnceLogger.swift
//  osaurus
//
//  Thread-safe "log this warning once per (plugin, key) per process" helper.
//  Used by the host API and BackgroundTaskManager to surface ABI-level
//  patterns that work but indicate a likely plugin bug — e.g. NULL chunk
//  callbacks, invalid task UUIDs, no-op interrupt messages, racy host
//  context resolution. Logging once per occurrence keeps the signal
//  visible without flooding the unified log on every call.
//

import Foundation

enum PluginOnceLogger {

    private static let lock = NSLock()
    private nonisolated(unsafe) static var seen: Set<String> = []

    /// Emits `message` (formatted with `arguments`) via `NSLog` exactly
    /// once per `key` per process. Subsequent calls with the same key are
    /// silently suppressed.
    ///
    /// Compose `key` as a stable string that uniquely identifies the
    /// occurrence you want to deduplicate, e.g.
    /// `"<pluginId>|complete_stream|null_chunk"`.
    static func warnOnce(key: String, _ message: String, _ arguments: CVarArg...) {
        let shouldLog: Bool = lock.withLock {
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        guard shouldLog else { return }
        withVaList(arguments) { NSLogv(message, $0) }
    }
}
