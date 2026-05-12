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
//  As of v1 of plugin authoring: the formatted message is also retained
//  in-memory (keyed by plugin id, derived from the dedup key's first
//  `|`-separated component) so the plugin detail UI can show authors a
//  "Diagnostics" section without making them grep `Console.app`.
//

import Foundation

public enum PluginOnceLogger {

    /// One captured warning, surfaced to plugin authors in the
    /// Diagnostics UI. `key` is the dedup key (`"<pluginId>|...|..."`)
    /// so duplicate suppression and UI rendering use the same identity.
    public struct Entry: Identifiable, Sendable, Hashable {
        public let id: String  // == key (unique per process)
        public let key: String
        public let pluginId: String
        public let message: String
        public let date: Date
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var seen: Set<String> = []
    /// Formatted entries in insertion order, capped at `maxRetained`.
    /// Capped because every plugin warning sits here for the lifetime
    /// of the process; an unbounded list would be a small but real
    /// memory leak under hostile inputs.
    private nonisolated(unsafe) static var entries: [Entry] = []
    private static let maxRetained = 256

    /// Emits `message` (formatted with `arguments`) via `NSLog` exactly
    /// once per `key` per process. Subsequent calls with the same key are
    /// silently suppressed.
    ///
    /// Compose `key` as a stable string that uniquely identifies the
    /// occurrence you want to deduplicate, e.g.
    /// `"<pluginId>|complete_stream|null_chunk"`. The first
    /// `|`-separated segment is treated as the plugin id for UI
    /// filtering; warnings without a `|` are filed under
    /// `"<unknown>"`.
    public static func warnOnce(key: String, _ message: String, _ arguments: CVarArg...) {
        // Format once outside the lock so we can both NSLog and retain
        // the same string. `withVaList` requires the arguments live
        // for the call's duration.
        let formatted = withVaList(arguments) { ptr in
            NSString(format: message, arguments: ptr) as String
        }

        let shouldLog: Bool = lock.withLock {
            if seen.contains(key) { return false }
            seen.insert(key)
            // Only treat the prefix as a plugin id when the convention
            // (`<pluginId>|<op>|<reason>`) is actually used. A
            // separator-less key would otherwise file the entire
            // string as the pluginId, which the UI can't filter
            // sensibly.
            let pluginId: String
            if let pipeIdx = key.firstIndex(of: "|") {
                pluginId = String(key[key.startIndex ..< pipeIdx])
            } else {
                pluginId = "<unknown>"
            }
            entries.append(
                Entry(id: key, key: key, pluginId: pluginId, message: formatted, date: Date())
            )
            if entries.count > maxRetained {
                entries.removeFirst(entries.count - maxRetained)
            }
            return true
        }
        guard shouldLog else { return }
        NSLog("%@", formatted)
    }

    // MARK: - UI accessors

    /// All retained entries (most recent last). Caller-owned snapshot
    /// — the underlying array is mutated under the lock.
    public static func allEntries() -> [Entry] {
        lock.withLock { entries }
    }

    /// Entries for a specific plugin, most recent last.
    public static func entries(forPlugin pluginId: String) -> [Entry] {
        lock.withLock { entries.filter { $0.pluginId == pluginId } }
    }

    /// Number of warnings retained for a given plugin id. Cheap O(N)
    /// over the capped buffer; lets badge counts in the UI avoid a
    /// full snapshot when N is large.
    public static func count(forPlugin pluginId: String) -> Int {
        lock.withLock { entries.reduce(0) { $0 + ($1.pluginId == pluginId ? 1 : 0) } }
    }

    /// Test-only: clear retained state matching `keyPrefix`. Scoped because
    /// `seen` + `entries` are process-global — a blanket reset races
    /// across parallel `@Suite(.serialized)` blocks that share this state
    /// (`.serialized` only orders tests within a single suite). Each test
    /// passes its own pluginId-prefixed key so it can only ever clear
    /// state it owns.
    static func _resetForTesting(forKeyPrefix keyPrefix: String) {
        lock.withLock {
            seen = seen.filter { !$0.hasPrefix(keyPrefix) }
            entries.removeAll { $0.key.hasPrefix(keyPrefix) }
        }
    }
}
