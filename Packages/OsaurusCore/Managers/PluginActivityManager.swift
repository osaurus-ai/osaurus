//
//  PluginActivityManager.swift
//  osaurus
//
//  Tracks in-flight inline plugin inference (`complete`, `complete_stream`,
//  `embed`) so the notch UI can surface a "plugin working" indicator even
//  when no background task / chat session has been registered for the call.
//
//  Dispatched tasks (`host->dispatch`) live in `BackgroundTaskManager`. This
//  manager covers the inline / streaming paths that previously had no UI
//  feedback at all.
//

import Combine
import Foundation

public struct PluginActivityRecord: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case complete
        case completeStream
        case embed
    }

    public let id: UUID
    public let pluginId: String
    public let pluginDisplayName: String
    public let kind: Kind
    public let startedAt: Date
    public var lastChunkAt: Date?
}

@MainActor
public final class PluginActivityManager: ObservableObject {
    public static let shared = PluginActivityManager()

    /// Currently in-flight inline plugin calls, keyed by activity id.
    @Published public private(set) var active: [UUID: PluginActivityRecord] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Mark a new inline plugin call as started. Caller supplies the
    /// activity id so the corresponding `end` can be issued from a `defer`
    /// without awaiting the begin's return value.
    public func begin(
        id: UUID,
        pluginId: String,
        pluginDisplayName: String,
        kind: PluginActivityRecord.Kind
    ) {
        active[id] = PluginActivityRecord(
            id: id,
            pluginId: pluginId,
            pluginDisplayName: pluginDisplayName,
            kind: kind,
            startedAt: Date(),
            lastChunkAt: nil
        )
    }

    /// Stamp a chunk timestamp for streaming activities so the UI can
    /// distinguish "still flowing" from "stalled".
    public func observeChunk(_ id: UUID) {
        guard var record = active[id] else { return }
        record.lastChunkAt = Date()
        active[id] = record
    }

    /// Remove a finished activity. Safe to call multiple times.
    public func end(_ id: UUID) {
        active.removeValue(forKey: id)
    }

    // MARK: - Convenience

    /// True when at least one inline plugin call is in flight.
    public var hasActive: Bool { !active.isEmpty }

    /// Most-recently-started activity (for the compact notch indicator).
    public var topActivity: PluginActivityRecord? {
        active.values.sorted { $0.startedAt > $1.startedAt }.first
    }
}
