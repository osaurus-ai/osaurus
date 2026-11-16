//
//  AttentionActivityLogger.swift
//  osaurus
//
//  Records every settled attention item: one Insights row, plus the
//  workspace audit trail for shared-agent approvals, the task journal for
//  items on a task, and a closed-token telemetry counter.
//

import Foundation

@MainActor
final class AttentionActivityLogger {
    static let shared = AttentionActivityLogger()

    private var token: UUID?
    private weak var center: AttentionCenter?

    func start(center: AttentionCenter) {
        guard token == nil else { return }
        self.center = center
        token = center.observe { [weak self] event in self?.handle(event) }
    }

    func stop() {
        if let token { center?.removeObserver(token) }
        token = nil
    }

    private func handle(_ event: AttentionEvent) {
        switch event {
        case .raised(let item):
            Self.recordRaised(item)
            Self.journal(item)
            Self.transcriptEvent(item)
            Self.trackDelivery(item)
        case .resolved(let item):
            Self.record(item)
            Self.journal(item)
            Self.transcriptEvent(item)
            Self.trackSettled(item)
        case .retracted(let item):
            // A non-blocking item withdrawn because the owner opened the
            // conversation is not an interaction; a blocking one withdrawn
            // by its producer is.
            guard item.kind.isBlocking else { return }
            Self.record(item)
            Self.journal(item)
            Self.transcriptEvent(item)
            Self.trackSettled(item)
        case .updated:
            break
        }
    }

    // MARK: - Task journal

    /// Blocking items on a task, journaled when raised and when settled under
    /// the item's kind ("Tool approval: web_fetch — Approved · @bob").
    static func journal(_ item: AttentionItem, store: TaskStore = .shared) {
        guard item.kind.isBlocking, let taskId = item.taskId, store.task(id: taskId) != nil else { return }
        var data: [String: String] = ["attention_id": item.id.uuidString, "attention_kind": item.kind.rawValue]
        if let tool = item.toolName { data["tool"] = tool }
        if item.isPending {
            if let requester = item.requester { data["who"] = ParticipantFormatter.short(requester) }
            store.journal(
                taskId, .approvalRequested,
                actor: item.requester.map(TaskActor.participant),
                data: data
            )
            return
        }
        let resolution = item.resolution
        if let decider = resolution?.decidedBy { data["who"] = ParticipantFormatter.short(decider) }
        data["decision"] = resolution?.outcome.rawValue ?? "retracted"
        if let surface = resolution?.surface { data["surface"] = surface.rawValue }
        store.journal(
            taskId, .approvalResolved,
            actor: resolution?.decidedBy.map(TaskActor.participant) ?? .system("attention"),
            reason: RequestLog.interactionOutcomeLabel(method(for: item)),
            data: data
        )
    }

    // MARK: - Transcript

    /// Event rows in the hosted conversation: who joined, and how the owner
    /// answered someone else's request. The owner's own approvals in their
    /// own chats already show on the tool card.
    static func transcriptEvent(_ item: AttentionItem, log: ConversationEventLog = .shared) {
        guard let sessionId = item.sessionId, let requester = item.requester, !requester.kind.isTrusted else { return }
        let who = ParticipantFormatter.short(requester)
        if item.isPending {
            guard item.kind == .inboundSharedRun else { return }
            let agent = item.agent.map { ParticipantFormatter.short($0) } ?? L("your agent")
            log.record(
                sessionId: sessionId,
                text: L("\(who) started a conversation with \(agent)"),
                icon: "person.badge.plus",
                key: "joined:\(requester.key)",
                at: item.createdAt
            )
            return
        }
        guard item.kind.isBlocking, let text = transcriptText(item, requester: who) else { return }
        log.record(
            sessionId: sessionId,
            text: text,
            icon: transcriptIcon(item),
            attentionId: item.id,
            at: item.settledAt ?? Date()
        )
    }

    static func transcriptText(_ item: AttentionItem, requester who: String) -> String? {
        let subject = item.toolName ?? item.kind.displayName
        guard let resolution = item.resolution else {
            return L("The request to use \(subject) for \(who) was withdrawn")
        }
        let decider: String = {
            guard let p = resolution.decidedBy else { return L("You") }
            return p.kind == .owner || p.kind == .ownerDevice ? L("You") : ParticipantFormatter.short(p)
        }()
        var text: String
        switch resolution.outcome {
        case .approved: text = L("\(decider) allowed \(subject) for \(who)")
        case .allowedForConversation:
            text = L("\(decider) allowed \(subject) for \(who) for the rest of the conversation")
        case .denied, .dismissed: text = L("\(decider) denied \(subject) for \(who)")
        case .replied: text = L("\(decider) answered \(who)")
        case .timedOut: return L("\(subject) for \(who) timed out, so it was declined")
        case .abandoned: return L("The run ended before anyone answered \(subject) for \(who)")
        }
        if resolution.surface != .inline, resolution.surface != .system {
            text += " · " + resolution.surface.displayName
        }
        return text
    }

    private static func transcriptIcon(_ item: AttentionItem) -> String {
        switch item.resolution?.outcome {
        case .approved?, .allowedForConversation?: return "checkmark.shield"
        case .denied?, .dismissed?: return "xmark.shield"
        case .timedOut?: return "clock.badge.xmark"
        default: return "hand.raised"
        }
    }

    // MARK: - Telemetry

    private static func trackDelivery(_ item: AttentionItem) {
        for raw in item.deliveredTo {
            guard let channel = NotificationChannelID(rawValue: raw) else { continue }
            FeatureTelemetry.notificationDelivered(kind: item.kind, channel: channel)
        }
    }

    private static func trackSettled(_ item: AttentionItem) {
        FeatureTelemetry.attentionResolved(
            kind: item.kind,
            outcome: item.resolution?.outcome.rawValue ?? "retracted",
            surface: item.resolution?.surface ?? .system,
            wait: item.waitDuration
        )
    }

    // MARK: - Insights

    /// Non-blocking items (an inbound message, a conversation starting, an
    /// agent's notice) are logged when delivered; nothing waits on them.
    /// Blocking items are logged once, when settled.
    static func recordRaised(_ item: AttentionItem) {
        if item.kind.isBlocking {
            AttentionLog.info("waiting id=\(item.id) kind=\(item.kind.rawValue)")
            return
        }
        InsightsService.logEgress(
            category: .interaction,
            source: source(for: item),
            method: "DELIVER",
            path: path(for: item),
            statusCode: 200,
            durationMs: 0,
            egress: EgressInfo(details: details(for: item)),
            locality: .local,
            attribution: attribution(for: item)
        )
    }

    static func record(_ item: AttentionItem) {
        InsightsService.logEgress(
            category: .interaction,
            source: source(for: item),
            method: method(for: item),
            path: path(for: item),
            statusCode: statusCode(for: item),
            durationMs: (item.waitDuration ?? 0) * 1000,
            egress: EgressInfo(details: details(for: item)),
            locality: .local,
            errorMessage: nil,
            attribution: attribution(for: item)
        )
    }

    static func path(for item: AttentionItem) -> String {
        "/attention/\(item.kind.rawValue)"
    }

    /// `APPROVE`, `DENY`, `ALLOW_CONVERSATION`, `REPLY`, `DISMISS`,
    /// `TIMEOUT`, `ABANDON`; `RETRACT` for a blocking item its producer
    /// withdrew.
    static func method(for item: AttentionItem) -> String {
        guard let resolution = item.resolution else { return item.isPending ? "WAIT" : "RETRACT" }
        switch resolution.outcome {
        case .approved: return "APPROVE"
        case .denied: return "DENY"
        case .allowedForConversation: return "ALLOW_CONVERSATION"
        case .replied: return "REPLY"
        case .dismissed: return "DISMISS"
        case .timedOut: return "TIMEOUT"
        case .abandoned: return "ABANDON"
        }
    }

    /// 200 granted or answered, 403 denied, 408 timed out, 499 abandoned
    /// or withdrawn.
    static func statusCode(for item: AttentionItem) -> Int {
        guard let resolution = item.resolution else { return item.isPending ? 202 : 499 }
        switch resolution.outcome {
        case .approved, .allowedForConversation, .replied, .dismissed: return 200
        case .denied: return 403
        case .timedOut: return 408
        case .abandoned: return 499
        }
    }

    /// The requester is the row's participant: who the interaction was for.
    /// Who answered goes in `decided_by`.
    static func attribution(for item: AttentionItem) -> InsightsService.ActivityAttribution {
        InsightsService.ActivityAttribution(
            agentId: item.agentId,
            agentName: item.agent?.agentName,
            sessionId: item.sessionId,
            taskId: item.taskId,
            participant: item.requester
        )
    }

    /// Where the request came from: a channel, another Osaurus (a teammate,
    /// an invite-link peer or their agent), or this Mac and its owner's own
    /// devices. Never "HTTP API": a person isn't an API client.
    static func source(for item: AttentionItem) -> RequestSource {
        switch item.requester?.kind {
        case .channelSender: return .channel
        case .teammate, .invitePeer, .remoteAgent, .agentOwner: return .p2p
        case .owner, .ownerDevice, .agent, nil: return .chatUI
        }
    }

    /// Metadata only. Reply text rides under `message`, a content key that
    /// is withheld when Store Prompts and Responses is off. Secret-request
    /// replies never carry text.
    static func details(for item: AttentionItem) -> [String: String] {
        var details: [String: String] = [
            "attention_id": item.id.uuidString,
            "kind": item.kind.rawValue,
            // Titles can carry an agent's own words (a notice, a workflow
            // form name), so they are content.
            "attention_title": item.title,
        ]
        if let tool = item.toolName { details["tool"] = tool }
        if item.kind == .ownerApproval { details["approval_id"] = item.id.uuidString }
        if !item.deliveredTo.isEmpty { details["delivered_to"] = item.deliveredTo.joined(separator: ",") }
        if let requester = item.requester {
            details["requester"] = ParticipantFormatter.short(requester)
            details["requester_kind"] = requester.kind.rawValue
            details["requester_key"] = requester.key
        }
        if let agent = item.agent {
            details["agent"] = ParticipantFormatter.short(agent)
            if let address = agent.agentAddress { details["agent_address"] = address }
        }
        if let resolution = item.resolution {
            details["decision"] = resolution.outcome.rawValue
            details["surface"] = resolution.surface.rawValue
            if let decider = resolution.decidedBy {
                details["decided_by"] = ParticipantFormatter.short(decider)
                details["decided_by_kind"] = decider.kind.rawValue
            }
            if resolution.outcome == .allowedForConversation { details["scope"] = "conversation" }
            if let reply = resolution.replyText, !reply.isEmpty, item.kind != .secretRequest {
                details["message"] = String(reply.prefix(AttentionLimits.insightsMessageCharacters))
            }
        } else if !item.isPending {
            details["decision"] = "retracted"
        }
        if let wait = item.waitDuration { details["wait_ms"] = String(Int(max(0, wait) * 1000)) }
        details["raised_at_ms"] = Self.milliseconds(item.createdAt)
        if let deliveredAt = item.deliveredAt { details["delivered_at_ms"] = Self.milliseconds(deliveredAt) }
        if let settledAt = item.settledAt { details["settled_at_ms"] = Self.milliseconds(settledAt) }
        return details
    }

    private static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
}
