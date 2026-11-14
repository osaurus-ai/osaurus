//
//  ToolCanonicalPayloadCache.swift
//  osaurus
//
//  Memoizes `Tool.canonicalHashPayload()` so the chat preview's main-actor
//  prefix hashing does not re-serialize every tool schema on each
//  prompt-shape signal (APPLE-MACOS-1QA).
//

import Foundation

/// Process-wide memo of `Tool.canonicalHashPayload()`.
///
/// The key is the full `Tool` value (type, name, description, the entire
/// `parameters` schema tree and `strict`), never just the tool name, so any
/// schema edit misses and recomputes. Stored bytes are exactly what the
/// uncached `computeCanonicalHashPayload()` produced, so prefix-cache and
/// static-prefix hash identity is unchanged.
///
/// Bounded: cleared wholesale once it reaches `maxEntries`, which only costs a
/// recompute on the next lookup.
final class ToolCanonicalPayloadCache: @unchecked Sendable {
    static let shared = ToolCanonicalPayloadCache()
    static let maxEntries = 1024

    private let lock = NSLock()
    private var entries: [Tool: Data] = [:]

    func payload(for tool: Tool) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return entries[tool]
    }

    func store(_ data: Data, for tool: Tool) {
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= Self.maxEntries {
            entries.removeAll(keepingCapacity: true)
        }
        entries[tool] = data
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
