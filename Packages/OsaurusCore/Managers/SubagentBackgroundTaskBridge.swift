//
//  SubagentBackgroundTaskBridge.swift
//  osaurus
//
//  Mirrors live spawned-helper runs (spawn_agent / spawn_model /
//  spawn_batch) into `BackgroundTaskManager` so they surface in the
//  notch's background tasks alongside dispatched chats. Helper runs
//  launched from any chat whose window is closed
//  were previously invisible outside the launching transcript.
//
//  The bridge is read-mostly: it observes `SubagentFeedRegistry`,
//  registers a visibility-only mirror per spawn feed, forwards phase /
//  error events into the mirror's activity feed, and closes the row when
//  the feed finishes. Cancellation flows the other way through
//  `BackgroundTaskManager.cancelTask`, which trips the spawn's
//  `SubagentInterruptCenter` token.
//

import Combine
import Foundation

@MainActor
public final class SubagentBackgroundTaskBridge {
    public static let shared = SubagentBackgroundTaskBridge()

    private let manager: BackgroundTaskManager
    private let registry: SubagentFeedRegistry

    private var registryCancellable: AnyCancellable?
    /// Per-feed status/event subscriptions, keyed by spawn tool-call id.
    private var feedObservers: [String: Set<AnyCancellable>] = [:]
    /// Mirror task id per spawn tool-call id.
    private var taskIdsByToolCallId: [String: UUID] = [:]
    /// How many feed events have already been forwarded per feed, so each
    /// published snapshot only appends the new tail. Coalescing updates
    /// (streamed text, progress ticks) mutate the last event in place
    /// without growing the array and are intentionally not re-forwarded.
    private var forwardedEventCounts: [String: Int] = [:]

    init(
        manager: BackgroundTaskManager = .shared,
        registry: SubagentFeedRegistry = .shared
    ) {
        self.manager = manager
        self.registry = registry
    }

    /// Begin observing the feed registry. Idempotent; called once at launch.
    public func start() {
        guard registryCancellable == nil else { return }
        registryCancellable = registry.feedsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] feeds in
                self?.reconcile(feeds)
            }
    }

    private func reconcile(_ feeds: [String: SubagentFeed]) {
        for (toolCallId, feed) in feeds where taskIdsByToolCallId[toolCallId] == nil {
            // Only helper-agent runs. Other subagent kinds (image,
            // computer_use, applescript) keep their existing in-chat-only
            // presentation.
            guard feed.kindId == SubagentCapabilityRegistry.spawn.id else { continue }
            // True agent delegations already register a REAL background
            // task via `dispatchChat` (with a working "Open Chat");
            // mirroring the feed too would show two notch rows per run.
            guard !feed.suppressNotchMirror else { continue }
            adopt(feed)
        }
        // A feed leaving the registry means its run is over (`unregister`
        // always follows `finish`). Drop our subscriptions; the safety
        // finish below only fires if a terminal status never reached us.
        for (toolCallId, taskId) in taskIdsByToolCallId where feeds[toolCallId] == nil {
            release(toolCallId: toolCallId, taskId: taskId)
        }
    }

    private func adopt(_ feed: SubagentFeed) {
        let taskId = UUID()
        let toolCallId = feed.toolCallId
        let state = BackgroundTaskState(
            subagentMirrorId: taskId,
            toolCallId: toolCallId,
            parentSessionId: feed.parentSessionId,
            taskTitle: feed.title,
            agentId: feed.agentId ?? Agent.defaultId
        )
        taskIdsByToolCallId[toolCallId] = taskId
        forwardedEventCounts[toolCallId] = 0
        manager.registerSubagentMirror(state)

        var observers = Set<AnyCancellable>()
        feed.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard case .finished(let success, let summary) = status else { return }
                self?.manager.finishSubagentMirror(taskId, success: success, summary: summary)
            }
            .store(in: &observers)
        feed.eventsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in
                self?.forward(events, toolCallId: toolCallId, taskId: taskId)
            }
            .store(in: &observers)
        feedObservers[toolCallId] = observers
    }

    /// Forward the new tail of a feed snapshot into the mirror. Phases and
    /// errors become activity rows; streamed reasoning/response text stays
    /// in the in-chat card. The latest phase/progress title doubles as the
    /// mirror's one-line current step.
    private func forward(_ events: [SubagentActivityEvent], toolCallId: String, taskId: UUID) {
        let alreadyForwarded = forwardedEventCounts[toolCallId] ?? 0
        if events.count > alreadyForwarded {
            for event in events[alreadyForwarded...] {
                switch event.kind {
                case .phase:
                    manager.appendSubagentMirrorActivity(
                        taskId, kind: .progress, title: event.title, detail: event.detail
                    )
                case .error:
                    manager.appendSubagentMirrorActivity(
                        taskId, kind: .error, title: event.title, detail: event.detail
                    )
                default:
                    break
                }
            }
            forwardedEventCounts[toolCallId] = events.count
        }
        if let last = events.last, last.kind == .phase || last.kind == .progress {
            manager.updateSubagentMirrorStep(taskId, step: last.title)
        }
    }

    private func release(toolCallId: String, taskId: UUID) {
        feedObservers.removeValue(forKey: toolCallId)?.forEach { $0.cancel() }
        forwardedEventCounts.removeValue(forKey: toolCallId)
        taskIdsByToolCallId.removeValue(forKey: toolCallId)
        // Every run path finishes its feed before unregistering; this only
        // fires if that contract is ever broken, so the row can't spin
        // forever with no live run behind it.
        manager.finishSubagentMirror(taskId, success: false, summary: "Helper run ended")
    }
}
