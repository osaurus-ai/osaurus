//
//  LiveChatSessionRegistry.swift
//  OsaurusCore
//
//  One live `ChatSession` instance per session id. Two surfaces hydrating
//  their own `ChatSession` from disk for the same conversation row race
//  each other's saves. This registry removes the race class instead of
//  hiding it: owners register their live instance, and any other surface
//  that wants the same conversation attaches to that exact object — every
//  publisher (`turns`, `isStreaming`, …) then drives all views at once.
//
//  `ChatWindowState.loadSession` resolves through here before falling back
//  to disk hydration.
//

import Foundation

@MainActor
public final class LiveChatSessionRegistry {
    public static let shared = LiveChatSessionRegistry()

    private struct WeakEntry {
        weak var session: ChatSession?
    }

    private var entries: [UUID: WeakEntry] = [:]

    private init() {}

    /// Register `session` as THE live instance for `id`, replacing any
    /// previous (or dead) entry. Owners call this when they create or rebind
    /// their session (the director on engagement attach and on
    /// "Clear chat"'s fresh-id rebind).
    func register(_ session: ChatSession, id: UUID) {
        compact()
        entries[id] = WeakEntry(session: session)
    }

    /// Drop the entry for `id` (owner tore the session down).
    func unregister(id: UUID) {
        entries.removeValue(forKey: id)
    }

    /// The single live instance for `id`, if any surface holds one.
    func liveSession(for id: UUID) -> ChatSession? {
        entries[id]?.session
    }

    /// The live instance for `id` only if one is already registered.
    /// Metadata sync paths (rename, archive, pin) use this so a sidebar
    /// edit updates an existing live copy.
    func registeredSession(for id: UUID) -> ChatSession? {
        entries[id]?.session
    }

    /// Whether `session` is a registered shared instance. Windows use this
    /// to decide teardown behavior: a shared session is co-owned by another
    /// surface, so leaving it must unlink — never `reset()`, `load(from:)`
    /// over, or `stop()` it.
    func isShared(_ session: ChatSession) -> Bool {
        guard let id = session.sessionId else { return false }
        return entries[id]?.session === session
    }

    /// Drop entries whose sessions have been deallocated.
    private func compact() {
        entries = entries.filter { $0.value.session != nil }
    }

    /// Test hook: clear all entries.
    func _resetForTesting() {
        entries.removeAll()
    }
}
