//
//  SelfScheduleAutomations.swift
//  osaurus
//
//  An agent's self-scheduled wake-up (`schedule_next_run`) is a one-shot
//  schedule automation the agent owns: one per agent, tagged in
//  `parameters`, fired by `ScheduleEventSource` like any other schedule and
//  run as a task on the agent's queue. Re-scheduling re-arms it; a fired or
//  cancelled wake leaves it disabled so its run history stays attached.
//  See docs/TASK_QUEUE.md, "Self-scheduling".
//

import Foundation

@MainActor
enum SelfScheduleAutomations {
    /// `parameters` keys on the owned automation.
    nonisolated static let ownerKey = "selfScheduleOwner"
    nonisolated static let contextViewsKey = "selfScheduleContextViews"
    nonisolated static let priorityKey = "selfSchedulePriority"
    nonisolated static let scheduledByKey = "selfScheduleScheduledBy"
    nonisolated static let scheduledAtWallKey = "selfScheduleScheduledAtWall"
    nonisolated static let onMissKey = "selfScheduleOnMiss"

    /// Two wakes of one agent this close together are one wake.
    static let coalesceWindow: TimeInterval = 5
    /// A wake missed by less than this still runs, whatever its on-miss.
    static let missGrace: TimeInterval = 5 * 60

    // MARK: - Lookup

    nonisolated static func ownerAgentId(of event: OsaurusEvent) -> UUID? {
        event.parameters[ownerKey].flatMap(UUID.init(uuidString:))
    }

    nonisolated static func isAgentOwned(_ event: OsaurusEvent) -> Bool {
        ownerAgentId(of: event) != nil
    }

    static func automation(for agentId: UUID, manager: EventManager = .shared) -> OsaurusEvent? {
        manager.events.first { ownerAgentId(of: $0) == agentId }
    }

    /// The agent's pending wake: its automation is armed and the slot has
    /// not been consumed.
    static func entry(for agentId: UUID, manager: EventManager = .shared) -> NextRunEntry? {
        automation(for: agentId, manager: manager).flatMap(entry(from:))
    }

    nonisolated static func entry(from event: OsaurusEvent) -> NextRunEntry? {
        guard let agentId = ownerAgentId(of: event), event.isEnabled, event.lastFiredAt == nil,
            case .once(let date)? = event.source.schedule?.frequency
        else { return nil }
        return slotEntry(event, agentId: agentId, scheduledAt: date)
    }

    nonisolated private static func slotEntry(_ event: OsaurusEvent, agentId: UUID, scheduledAt: Date) -> NextRunEntry {
        let views =
            event.parameters[contextViewsKey]
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return NextRunEntry(
            agentId: agentId,
            scheduledAt: scheduledAt,
            instructions: event.action.agent?.instructions ?? "",
            contextViews: views,
            priority: event.parameters[priorityKey].flatMap(NextRunPriority.init(rawValue:)) ?? .normal,
            onMiss: event.parameters[onMissKey].flatMap(NextRunOnMiss.init(rawValue:)) ?? .skip,
            scheduledBy: event.parameters[scheduledByKey].flatMap(NextRunScheduledBy.init(rawValue:)) ?? .system,
            scheduledAtWall: event.parameters[scheduledAtWallKey].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                ?? event.updatedAt
        )
    }

    // MARK: - Writes

    /// Creates or re-arms the agent's wake. Last write wins.
    @discardableResult
    static func schedule(_ entry: NextRunEntry, manager: EventManager = .shared) -> NextRunEntry {
        var parameters: [String: String] = [
            ownerKey: entry.agentId.uuidString,
            priorityKey: entry.priority.rawValue,
            scheduledByKey: entry.scheduledBy.rawValue,
            scheduledAtWallKey: String(entry.scheduledAtWall.timeIntervalSince1970),
            onMissKey: entry.onMiss.rawValue,
        ]
        if !entry.contextViews.isEmpty, let data = try? JSONEncoder().encode(entry.contextViews) {
            parameters[contextViewsKey] = String(data: data, encoding: .utf8)
        }
        let source = EventSource.schedule(ScheduleSourceConfig(frequency: .once(date: entry.scheduledAt)))
        let action = EventAction.agent(
            AgentEventAction(target: .local(entry.agentId), instructions: entry.instructions, freshSessionPerFire: true))
        if var existing = automation(for: entry.agentId, manager: manager) {
            existing.source = source
            existing.action = action
            existing.parameters = parameters
            existing.delivery = delivery(for: entry, queueId: existing.delivery.queueId)
            existing.isEnabled = true
            existing.lastFiredAt = nil
            existing.lastRunAt = nil
            manager.update(existing)
        } else {
            manager.create(
                OsaurusEvent(
                    name: L("Agent-scheduled wake-up"),
                    source: source,
                    action: action,
                    delivery: delivery(for: entry, queueId: nil),
                    parameters: parameters))
        }
        return entry
    }

    /// Disarms the agent's wake. Returns whether one was pending. A run
    /// already in flight is not stopped.
    @discardableResult
    static func cancel(agentId: UUID, manager: EventManager = .shared) -> Bool {
        guard var existing = automation(for: agentId, manager: manager) else { return false }
        let pending = entry(from: existing) != nil
        guard existing.isEnabled else { return pending }
        existing.isEnabled = false
        manager.update(existing)
        return pending
    }

    /// The agent was deleted: its wake and history go with it.
    static func removeAll(agentId: UUID, manager: EventManager = .shared) {
        for event in manager.events where ownerAgentId(of: event) == agentId {
            manager.delete(id: event.id)
        }
    }

    /// One wake at a time per agent; a wake that comes due while the last
    /// one is still running waits behind it. The wake's own on-miss maps
    /// onto the schedule's missed-fire policy.
    private static func delivery(for entry: NextRunEntry, queueId: UUID?) -> EventDeliveryPolicy {
        let missed: EventMissedFirePolicy
        switch entry.onMiss {
        case .skip: missed = .skip
        case .runOnce: missed = .runOnce
        case .runCatchup: missed = .runCatchup
        }
        return EventDeliveryPolicy(
            mode: .serial, maxQueued: 1, dedupe: .window(coalesceWindow), missedFirePolicy: missed,
            queueId: queueId)
    }

    // MARK: - Firing

    /// When the owning agent is paused, the end of the pause.
    static func pausedUntil(_ event: OsaurusEvent, now: Date = Date()) -> Date? {
        guard let agentId = ownerAgentId(of: event),
            let pause = try? LocalAgentBridge.shared.pauseInfo(agentId: agentId),
            pause.pausedUntil > now
        else { return nil }
        return pause.pausedUntil
    }

    /// Moves a paused agent's wake to the end of the pause.
    static func deferSlot(_ event: OsaurusEvent, to date: Date, manager: EventManager) {
        manager.updateState(event.id) { updated in
            updated.source = .schedule(ScheduleSourceConfig(frequency: .once(date: date)))
            updated.lastFiredAt = nil
        }
    }

    /// A wake missed by only a few minutes (a relaunch) still runs.
    static func isWithinMissGrace(_ event: OsaurusEvent, slot: Date, now: Date) -> Bool {
        isAgentOwned(event) && now.timeIntervalSince(slot) <= missGrace
    }

    /// The run a wake starts: a fresh chat whose prompt explains why it
    /// exists, titled with the wake time.
    static func dispatchRequest(
        event: OsaurusEvent,
        occurrence: EventOccurrence,
        taskId: UUID,
        store: TaskStore = .shared
    ) -> DispatchRequest? {
        guard let agentId = ownerAgentId(of: event),
            case .once(let date)? = event.source.schedule?.frequency
        else { return nil }
        let entry = slotEntry(event, agentId: agentId, scheduledAt: date)
        return makeDispatchRequest(
            for: entry, previousRun: previousRun(for: agentId, excluding: taskId, store: store), taskId: taskId,
            loadIntent: occurrence.loadIntent, queueId: event.delivery.queueId, subscriptionId: event.id)
    }

    static func makeDispatchRequest(
        for entry: NextRunEntry,
        previousRun: PreviousRun?,
        taskId: UUID = UUID(),
        loadIntent: ModelLoadIntent = .interactive,
        queueId: UUID? = nil,
        subscriptionId: UUID? = nil
    ) -> DispatchRequest {
        DispatchRequest(
            id: taskId,
            prompt: composeDispatchPrompt(entry: entry, previousRun: previousRun),
            agentId: entry.agentId,
            title: sessionTitle(for: entry),
            source: .selfSchedule,
            externalSessionKey: nil,
            loadIntent: loadIntent,
            unattended: true,
            queueId: queueId,
            taskOrigin: .selfSchedule,
            subscriptionId: subscriptionId
        )
    }

    /// The agent's last finished wake, for the fresh-chat preamble.
    struct PreviousRun: Equatable, Sendable {
        var state: TaskState
        var finishedAt: Date
    }

    static func previousRun(for agentId: UUID, excluding taskId: UUID? = nil, store: TaskStore = .shared)
        -> PreviousRun?
    {
        store.tasksSnapshot(
            TaskQuery(
                states: [.succeeded, .failed, .cancelled, .interrupted], origin: .selfSchedule, agentId: agentId,
                limit: 8)
        )
        .first { $0.id != taskId && $0.finishedAt != nil }
        .map { PreviousRun(state: $0.state, finishedAt: $0.finishedAt!) }
    }

    /// Successful or failed wakes in the last 24 hours, charged against the
    /// agent's daily run cap. Readable off the main actor.
    nonisolated static func runsToday(agentId: UUID, now: Date = Date()) -> Int {
        let query = TaskQuery(
            states: [.succeeded, .failed], origin: .selfSchedule, agentId: agentId,
            since: now.addingTimeInterval(-24 * 3600))
        return (try? TaskDatabase.shared.count(query)) ?? 0
    }

    // MARK: - Prompt

    /// Fixed fragments of the self-scheduled dispatch prompt. Shared with
    /// `DispatchEnvelope`, which strips them for display, so the producer and
    /// the parser can never drift apart. Byte-for-byte the historical text.
    nonisolated static let selfScheduledRunPrefix = "[Self-scheduled run] "
    nonisolated static let selfScheduledRunIntro =
        selfScheduledRunPrefix
        + "This chat was started automatically for a "
        + "scheduled wake. It is a fresh session with no prior "
        + "conversation context."
    nonisolated static let scheduledByLinePrefix = "Scheduled by: "
    nonisolated static let previousRunLinePrefix = "Your previous run "
    nonisolated static let instructionsHeader = "Instructions for this run:"

    /// Prompt preamble + verbatim instructions for a self-scheduled wake.
    nonisolated static func composeDispatchPrompt(entry: NextRunEntry, previousRun: PreviousRun?) -> String {
        var lines: [String] = [
            selfScheduledRunIntro,
            scheduledByLinePrefix + "\(entry.scheduledBy.rawValue), "
                + "for \(promptTimestamp(entry.scheduledAt)).",
        ]
        if let previousRun {
            lines.append(
                previousRunLinePrefix + "\(statusPhrase(previousRun.state)) at "
                    + "\(promptTimestamp(previousRun.finishedAt)). Consult your agent database "
                    + "or notes for any state you saved."
            )
        }
        lines.append("")
        lines.append(instructionsHeader)
        lines.append(entry.instructions)
        return lines.joined(separator: "\n")
    }

    /// Session title for a self-scheduled wake, e.g.
    /// "Self-scheduled run — Jul 4, 2:42 PM".
    nonisolated static func sessionTitle(for entry: NextRunEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Self-scheduled run — \(formatter.string(from: entry.scheduledAt))"
    }

    nonisolated private static func promptTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    nonisolated private static func statusPhrase(_ state: TaskState) -> String {
        switch state {
        case .succeeded: return "completed"
        case .failed: return "failed"
        case .cancelled, .interrupted: return "was cancelled"
        default: return "was still running"
        }
    }

    // MARK: - Migration

    /// Moves the legacy `agent_next_run` slots onto owned automations. The
    /// encrypted scheduler store is opened off the main thread, and not at
    /// all on installs that never created it or already moved everything.
    static func migrateLegacyNextRuns(manager: EventManager) async {
        guard manager.persistsToDisk, !UserDefaults.standard.bool(forKey: legacyNextRunsDoneKey) else { return }
        let legacy = await Task.detached(priority: .utility) { () -> [NextRunEntry]? in
            guard FileManager.default.fileExists(atPath: OsaurusPaths.schedulerDatabaseFile().path),
                (try? SchedulerDatabase.shared.open()) != nil
            else { return [] }
            return try? SchedulerDatabase.shared.legacyNextRuns()
        }.value
        guard let legacy else { return }
        guard !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: legacyNextRunsDoneKey)
            return
        }
        let movable = legacy.filter { AgentManager.shared.agent(for: $0.agentId) != nil }
        for entry in movable { schedule(entry, manager: manager) }
        // Retired only once every wake is on disk; otherwise the next
        // launch moves them again (scheduling is idempotent per agent).
        let saved = Set(manager.persistedEventsNow().compactMap(ownerAgentId(of:)))
        guard movable.allSatisfy({ saved.contains($0.agentId) }) else { return }
        if (try? SchedulerDatabase.shared.retireLegacyTable("agent_next_run")) != nil {
            UserDefaults.standard.set(true, forKey: legacyNextRunsDoneKey)
        }
    }

    private static let legacyNextRunsDoneKey = "SelfScheduleAutomations.legacyNextRunsMigrated.v1"
}
