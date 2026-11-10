//
//  EventInspection.swift
//  osaurus
//
//  Read-only projections of events and their run ledger for
//  `osaurus_inspect` (scope `automations`; the pre-rename `events` and the
//  legacy `schedules` / `watchers` scopes still answer, the last two
//  narrowed to schedule and folder automations).
//

import Foundation

@MainActor
enum EventInspection {
    /// Inspect scopes that list events, and the source kind each narrows to.
    static let scopeSourceKinds: [String: EventSourceKind?] = [
        "automations": nil,
        "events": nil,
        "schedules": .schedule,
        "watchers": .folder,
    ]

    static func statusSummary(_ events: [OsaurusEvent] = EventManager.shared.events) -> [String: Any] {
        var bySource: [String: Int] = [:]
        for event in events { bySource[event.sourceKind.rawValue, default: 0] += 1 }
        let failing = events.filter { $0.lastStatus == .failed }.map(\.name)
        return [
            "total": events.count,
            "enabled": events.filter(\.isEnabled).count,
            "by_source": bySource,
            "last_run_failed": failing,
        ]
    }

    /// Rows for a list scope. `filter`: enabled | disabled | failed | a
    /// source kind (`schedule`, `folder`, `webhook`, `channel_message`) |
    /// an action kind (`agent`, `workflow`).
    static func list(scope: String, filter: String?) -> [[String: Any]] {
        var events = EventManager.shared.events
        if let kind = scopeSourceKinds[scope] ?? nil {
            events = events.filter { $0.sourceKind == kind }
        }
        switch filter?.lowercased() {
        case "enabled": events = events.filter(\.isEnabled)
        case "disabled": events = events.filter { !$0.isEnabled }
        case "failed": events = events.filter { $0.lastStatus == .failed }
        case .some(let raw):
            if let kind = EventSourceKind(rawValue: raw) {
                events = events.filter { $0.sourceKind == kind }
            } else if let action = EventActionKind(rawValue: raw) {
                events = events.filter { $0.action.kind == action }
            }
        case .none:
            break
        }
        return events.map(listItem)
    }

    static func listItem(_ event: OsaurusEvent) -> [String: Any] {
        var item: [String: Any] = [
            "id": event.id.uuidString,
            "name": event.name,
            "enabled": event.isEnabled,
            "source": event.sourceKind.rawValue,
            "source_summary": event.sourceSummary,
            "action": event.action.kind.rawValue,
            "runs": actionLabel(event),
        ]
        if let status = event.lastStatus { item["last_status"] = status.rawValue }
        if let last = event.lastRunAt { item["last_run_at"] = EventPayload.iso8601(last) }
        if let next = event.nextFireDate() { item["next_fire_at"] = EventPayload.iso8601(next) }
        if let problem = targetProblem(event) { item["problem"] = problem.reason }
        return item
    }

    static func find(_ idOrName: String, scope: String) -> OsaurusEvent? {
        let uuid = UUID(uuidString: idOrName)
        let kind = scopeSourceKinds[scope] ?? nil
        return EventManager.shared.events.first { event in
            (kind == nil || event.sourceKind == kind)
                && (event.id == uuid || event.name.caseInsensitiveCompare(idOrName) == .orderedSame)
        }
    }

    static func detail(_ event: OsaurusEvent, runs: [EventRun]) -> [String: Any] {
        var detail = listItem(event)
        switch event.source {
        case .schedule(let s):
            detail["frequency"] = s.frequency.displayDescription
            detail["missed_fire_policy"] = event.delivery.missedFirePolicy.rawValue
        case .folder(let f):
            detail["path"] = f.path ?? ""
            detail["recursive"] = f.recursive
            detail["responsiveness"] = f.responsiveness.rawValue
        case .webhook(let w):
            // The token is a credential; only say whether verification is on.
            detail["verification"] = w.verification.rawValue
            detail["provider"] = w.provider.rawValue
            detail["max_body_bytes"] = w.maxBodyBytes
            detail["rate_limit_per_minute"] = w.rateLimitPerMinute
        case .rss(let r):
            detail["url"] = r.url
            detail["poll_interval_seconds"] = r.pollIntervalSeconds
            detail["catch_up"] = r.catchUp.rawValue
            detail["max_items_per_tick"] = r.maxItemsPerTick
        case .sse(let s):
            detail["url"] = s.url
            // Header values can carry credentials; only their names are shown.
            detail["header_names"] = s.headers.keys.sorted()
            detail["event_names"] = s.eventNames
            if let timeout = s.heartbeatTimeoutSeconds { detail["heartbeat_timeout_seconds"] = timeout }
        case .runFailed(let f):
            detail["workflows"] = f.workflowIDs.map {
                InstalledWorkflowStore.shared.workflow(id: $0)?.name ?? $0.uuidString
            }
            detail["include_automation_runs"] = f.includeAutomationRuns
        case .app(let a):
            detail["reasons"] = a.reasons.map(\.rawValue)
        case .email(let e):
            detail["mailboxes"] = e.effectiveMailboxes
            detail["unread_only"] = e.unreadOnly
            detail["include_body"] = e.includeBody
            detail["poll_interval_seconds"] = e.pollIntervalSeconds
            detail["catch_up"] = e.catchUp.rawValue
        case .channelMessage(let m):
            detail["platform"] = m.kind.rawValue
            detail["connection_id"] = m.connectionId
            detail["rooms"] = m.roomIds
            detail["aliases"] = m.aliases
            detail["require_mention"] = m.requireMention
        }
        switch event.action {
        case .agent(let a):
            detail["instructions"] = a.instructions
            detail["fresh_session_per_fire"] = a.freshSessionPerFire
        case .workflow(let w):
            detail["workflow_id"] = w.workflowID.uuidString
            detail["input_mapping"] = w.inputMapping
            if let agentId = w.runAsAgentId { detail["run_as_agent_id"] = agentId.uuidString }
        case .prompt(let p):
            detail["instructions"] = p.instructions
            detail["model"] = p.model ?? PromptRunWorker.resolvedModel(p) ?? NSNull()
        }
        detail["delivery"] = [
            "mode": event.delivery.mode.rawValue,
            "max_concurrent": event.delivery.maxConcurrent,
            "max_queued": event.delivery.maxQueued,
            "dedupe": event.delivery.dedupe.mode.rawValue,
            "dedupe_window_seconds": Int(event.delivery.dedupeWindowSeconds),
        ]
        if let connectionId = event.source.connectionId { detail["source_connection_id"] = connectionId }
        let status = EventManager.shared.status(of: event.id)
        if !status.isEmpty { detail["source_status"] = status.inspection }
        detail["reply"] = [
            "auto_reply": event.reply.autoReply,
            "workflow_output": event.reply.replyWithWorkflowOutput,
        ]
        detail["running"] = EventManager.shared.isRunning(event.id)
        detail["queued"] = EventManager.shared.queuedCount(event.id)
        detail["recent_runs"] = runs.map(runItem)
        return detail
    }

    static func runItem(_ run: EventRun) -> [String: Any] {
        var item: [String: Any] = [
            "run_id": run.id.uuidString,
            "status": run.status.rawValue,
            "fired_at": EventPayload.iso8601(run.firedAt),
        ]
        if let reason = run.reason { item["reason"] = reason }
        if let error = run.error { item["error"] = error }
        if let session = run.sessionId { item["session_id"] = session.uuidString }
        if let workflowRun = run.workflowRunId { item["workflow_run_id"] = workflowRun.uuidString }
        if let seconds = run.durationSeconds { item["duration_seconds"] = (seconds * 10).rounded() / 10 }
        return item
    }

    static func actionLabel(_ event: OsaurusEvent) -> String {
        switch event.action {
        case .agent(let a):
            return targetName(a.target)
        case .workflow(let w):
            return InstalledWorkflowStore.shared.workflow(id: w.workflowID)?.name ?? L("Missing workflow")
        case .prompt(let p):
            return p.model ?? L("Default model")
        }
    }

    /// What each run produces, for the list's When → Do → Result line.
    static func resultLabel(_ event: OsaurusEvent) -> String {
        switch event.action {
        case .agent(let a):
            if event.sourceKind == .channelMessage {
                return event.reply.autoReply ? L("Replies in the conversation") : L("Reply waits for approval")
            }
            return a.freshSessionPerFire ? L("New chat each run") : L("Continues one chat")
        case .workflow(let w):
            let bound = w.inputMapping.values.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            switch bound {
            case 0: return L("Workflow run")
            case 1: return L("Workflow run, 1 input")
            default: return L("Workflow run, \(bound) inputs")
            }
        case .prompt:
            return L("One answer, no tools")
        }
    }

    static func targetName(_ target: AgentDispatchTarget?) -> String {
        switch target {
        case .none: return L("No agent selected")
        case .local(let id): return AgentManager.shared.agent(for: id)?.name ?? L("Missing agent")
        case .workspace(let ref): return AgentTargetResolver.displayName(for: ref)
        }
    }

    /// Something the automation points at that no longer exists, or nil.
    /// Native platforms are configured rather than deleted, so only n8n and
    /// Custom HTTP connections are checked.
    static func targetProblem(_ event: OsaurusEvent, lookup: EventTargetLookup = .live) -> EventTargetProblem? {
        if case .channelMessage(let config) = event.source, config.kind == .n8n || config.kind == .customHTTP,
            !lookup.connectionExists(config.connectionId)
        {
            return .channelDeleted
        }
        if let connectionId = event.source.connectionId, !lookup.sourceConnectionExists(connectionId) {
            return .connectionDeleted
        }
        switch event.action {
        case .agent(let action):
            if case .local(let id) = action.target, !lookup.agentExists(id) { return .agentDeleted }
        case .workflow(let action):
            if !lookup.workflowExists(action.workflowID) { return .workflowDeleted }
        case .prompt:
            break
        }
        return nil
    }
}

enum EventTargetProblem: String, Sendable {
    case agentDeleted = "agent_deleted"
    case workflowDeleted = "workflow_deleted"
    case channelDeleted = "channel_deleted"
    case connectionDeleted = "connection_deleted"

    var reason: String { rawValue }

    var message: String {
        switch self {
        case .agentDeleted: L("The agent this automation runs was deleted. Pick another agent.")
        case .workflowDeleted: L("The workflow this automation runs was removed. Pick another workflow.")
        case .channelDeleted: L("The channel this automation listens to was removed. Pick another channel.")
        case .connectionDeleted: L("The account this automation reads from was removed. Pick another account.")
        }
    }
}

/// Existence checks behind `EventInspection.targetProblem`; injectable so
/// pipeline tests can use placeholder agents.
@MainActor
struct EventTargetLookup {
    var agentExists: @MainActor (UUID) -> Bool = { AgentManager.shared.agent(for: $0) != nil }
    var workflowExists: @MainActor (UUID) -> Bool = { InstalledWorkflowStore.shared.workflow(id: $0) != nil }
    var connectionExists: @MainActor (String) -> Bool = {
        AgentChannelConnectionManager.shared.connection(id: $0) != nil
    }
    var sourceConnectionExists: @MainActor (String) -> Bool = {
        SourceConnectionStore.shared.connection(id: $0) != nil
    }

    static let live = EventTargetLookup()
}
