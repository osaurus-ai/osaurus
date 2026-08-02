//
//  SessionActivityMonitor.swift
//  osaurus
//
//  Observable "session id → live activity" map for the History sidebar.
//
//  Live run state is otherwise keyed by objects, not persisted session ids:
//  windowed runs live on per-window `ChatSession` instances and detached runs
//  in `BackgroundTaskManager.backgroundTasks`. This monitor aggregates both
//  into a single published dictionary the sidebar can observe to show an
//  animated "working" ring, a "needs your input" state, float active rows to
//  the top, and offer a per-row Stop.
//
//  Updates are push-based:
//  - Every `ChatSession` reports its own status (streaming / pre-send
//    handshake → working; mounted clarify/secret prompt card → waiting).
//    This covers windowed AND detached runs, since a background task retains
//    the same `ChatSession` object.
//  - `BackgroundTaskState` additionally reports `.queued` registry tasks,
//    whose session isn't streaming yet and therefore reports nothing itself.
//

import Foundation

@MainActor
final class SessionActivityMonitor: ObservableObject {
    static let shared = SessionActivityMonitor()

    enum Status: Equatable {
        /// A run is executing (streaming, warming up, or queued for a slot).
        case working
        /// The run is paused on a user response (clarify / secret prompt).
        case waitingForInput
    }

    /// Merged activity per persisted session id. Absent key means idle.
    @Published private(set) var statuses: [UUID: Status] = [:]

    /// Status reported by the live `ChatSession` driving each session id.
    private var sessionReported: [UUID: Status] = [:]
    /// Session ids of registry tasks still queued for an execution slot.
    private var queuedSessionIds: Set<UUID> = []

    init() {}

    func status(for sessionId: UUID) -> Status? {
        statuses[sessionId]
    }

    /// Called by `ChatSession` whenever its own activity changes.
    /// `nil` clears the session's contribution (run finished / stopped).
    func reportSession(_ sessionId: UUID, status: Status?) {
        if sessionReported[sessionId] == status { return }
        if let status {
            sessionReported[sessionId] = status
        } else {
            sessionReported.removeValue(forKey: sessionId)
        }
        rebuild(sessionId)
    }

    /// Called by `BackgroundTaskState` on status transitions so queued
    /// dispatches surface as working before their stream starts.
    func reportQueued(_ sessionId: UUID, isQueued: Bool) {
        let changed = isQueued
            ? queuedSessionIds.insert(sessionId).inserted
            : queuedSessionIds.remove(sessionId) != nil
        guard changed else { return }
        rebuild(sessionId)
    }

    private func rebuild(_ sessionId: UUID) {
        let merged: Status? =
            sessionReported[sessionId]
            ?? (queuedSessionIds.contains(sessionId) ? .working : nil)
        guard statuses[sessionId] != merged else { return }
        if let merged {
            statuses[sessionId] = merged
        } else {
            statuses.removeValue(forKey: sessionId)
        }
    }

    /// Stop the run driving `sessionId`, wherever it lives. Detached
    /// registry tasks go through `cancelTask` so the task row is marked
    /// cancelled (which also stops the session); windowed runs call the
    /// session's own `stop()`.
    func stop(sessionId: UUID) {
        if let task = BackgroundTaskManager.shared.liveTask(forSessionId: sessionId) {
            BackgroundTaskManager.shared.cancelTask(task.id)
            return
        }
        ChatWindowManager.shared.session(forSessionId: sessionId)?.stop()
    }
}

// MARK: - Sidebar Ordering

/// Pure ordering helper for the sidebar list: active sessions first, then
/// pinned, then the rest, preserving the incoming (recency-descending) order
/// within each tier. Extracted from the view for unit testing.
enum SessionActivityOrdering {
    static func ordered(
        _ list: [ChatSessionData],
        activeIds: Set<UUID>
    ) -> [ChatSessionData] {
        guard !activeIds.isEmpty || list.contains(where: { $0.pinned }) else { return list }
        var active: [ChatSessionData] = []
        var pinned: [ChatSessionData] = []
        var rest: [ChatSessionData] = []
        for session in list {
            if activeIds.contains(session.id) {
                active.append(session)
            } else if session.pinned {
                pinned.append(session)
            } else {
                rest.append(session)
            }
        }
        return active + pinned + rest
    }
}
