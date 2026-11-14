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
//  - `AttentionCenter`'s pending blocking items mark their session waiting:
//    an owner approval on a hosted run, a tool approval in its own panel, a
//    workflow form. Waiting outranks working, since the run can't go on
//    without an answer.
//

import Combine
import Foundation

@MainActor
final class SessionActivityMonitor: ObservableObject {
    static let shared = SessionActivityMonitor(attention: .shared)

    enum Status: Equatable {
        /// A run is executing (streaming, warming up, or queued for a slot).
        case working
        /// The run is paused on a user response (clarify / secret prompt,
        /// an approval, a workflow form).
        case waitingForInput
    }

    /// Merged activity per persisted session id. Absent key means idle.
    @Published private(set) var statuses: [UUID: Status] = [:]

    /// Status reported by the live `ChatSession` driving each session id.
    private var sessionReported: [UUID: Status] = [:]
    /// Session ids of registry tasks still queued for an execution slot.
    private var queuedSessionIds: Set<UUID> = []
    /// Session ids with a pending blocking attention item.
    private var attentionWaitingIds: Set<UUID> = []
    private var attentionCancellable: AnyCancellable?

    /// Tests pass no center and drive `reportAttention` directly.
    init(attention: AttentionCenter? = nil) {
        attentionCancellable = attention?.$pending.sink { [weak self] pending in
            MainActor.assumeIsolated {
                self?.reportAttention(waitingSessionIds: Self.waitingSessionIds(in: pending))
            }
        }
    }

    func status(for sessionId: UUID) -> Status? {
        statuses[sessionId]
    }

    /// Called by `ChatSession` whenever its own activity changes, and by
    /// `InboundSharedRunBridge` for the read-only transcript of a run hosted
    /// for a remote caller (that session never streams itself).
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

    /// Replaces the set of sessions with a pending blocking attention item.
    func reportAttention(waitingSessionIds: Set<UUID>) {
        guard waitingSessionIds != attentionWaitingIds else { return }
        let changed = waitingSessionIds.symmetricDifference(attentionWaitingIds)
        attentionWaitingIds = waitingSessionIds
        for id in changed { rebuild(id) }
    }

    /// One status for several sessions (an agent's row): waiting on the
    /// owner outranks working, so a row never hides a question behind a
    /// spinner.
    nonisolated static func rollUp(_ statuses: some Sequence<Status>) -> Status? {
        var rolled: Status?
        for status in statuses {
            if status == .waitingForInput { return .waitingForInput }
            rolled = status
        }
        return rolled
    }

    static func waitingSessionIds(in pending: [AttentionItem]) -> Set<UUID> {
        Set(pending.lazy.filter { $0.kind.isBlocking }.compactMap(\.sessionId))
    }

    private func rebuild(_ sessionId: UUID) {
        let merged: Status? =
            attentionWaitingIds.contains(sessionId)
            ? .waitingForInput
            : sessionReported[sessionId] ?? (queuedSessionIds.contains(sessionId) ? .working : nil)
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
