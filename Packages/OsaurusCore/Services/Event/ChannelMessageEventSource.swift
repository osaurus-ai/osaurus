//
//  ChannelMessageEventSource.swift
//  osaurus
//
//  The channel-message source. A platform connection service authorizes a
//  message (allowlists, provider dedupe) and hands it here; the events it
//  selects decide what runs. Agent events run as a channel conversation
//  turn (`AgentChannelInboundRelay`); workflow events go through the
//  regular event queue and may reply with the workflow's output.
//

import Foundation
import os

/// One authorized inbound channel message, as a platform reports it.
struct ChannelInboundMessage: Sendable {
    var identity: ChannelIdentity
    var kind: AgentChannelKind
    var connectionId: String
    var providerEventId: String
    var providerRoute: AgentChannelProviderRoute
    /// The message text with bot mention tokens removed.
    var content: String
    var attachments: [AgentChannelStoredAttachment] = []
    var sourceLabel: String
    /// nil when the platform cannot tell (no bot identity, direct message).
    var mentionsBot: Bool?
    /// The bot already posted in this room/thread.
    var hasPriorOutbound: Bool = false
    /// Sends a reply into the conversation. Events decide whether to use it.
    var reply: AgentChannelInboundReplyHandler?
    var replyAttachment: AgentChannelInboundAttachmentReplyHandler?
    /// Keeps an unsent agent reply on this Mac for review when the event
    /// does not reply automatically (an email draft in Mail).
    var draftReply: AgentChannelInboundReplyHandler? = nil
    /// Platform-specific trigger values added to the run payload
    /// (`{{email.subject}}`).
    var extraPayload: [String: JSONValue] = [:]

    var conversationKey: String {
        [connectionId, providerRoute.conversationId, providerRoute.threadId ?? ""].joined(separator: "|")
    }
}

/// The channel-message adapter. Messages arrive pushed by the platform
/// services (`ingestChannelMessage`), so there is nothing to arm; the
/// adapter only answers Run Now.
@MainActor
final class ChannelMessageEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .channelMessage
    private unowned let manager: EventManager

    init(manager: EventManager) {
        self.manager = manager
    }

    func stop() {}
    func reconcile(_ events: [OsaurusEvent]) async {}

    func status(_ eventId: UUID) -> EventSourceStatus {
        manager.sourceStatus[eventId] ?? EventSourceStatus()
    }

    /// Runs the event on a sample message: `{ "text": … }` or a bare string.
    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        guard let source = event.source.channelMessage else {
            return EventFireResult(runId: UUID(), status: .suppressed, reason: "event_not_found")
        }
        let now = Date()
        let text = sample?.value(atPath: "text")?.stringValue ?? sample?.stringValue ?? ""
        let payload = EventPayload.message(
            event: event, firedAt: now, text: text, platform: source.kind, connectionId: source.connectionId,
            roomId: source.roomIds.first ?? "", threadId: nil, senderId: nil, senderName: nil, attachments: [])
        var prompt: String?
        if let action = event.action.agent {
            let instructions = EventTemplate.render(action.instructions, payload: payload)
            let wrapped = ChannelRemoteSafetyGate.wrapUntrustedContent(
                text, source: "Sample \(source.kind.displayName) message (Fire now)")
            prompt = instructions.isEmpty ? wrapped : instructions + "\n\n" + wrapped
        }
        return manager.submit(
            EventOccurrence(
                eventId: event.id, firedAt: now, payload: payload, trigger: .manual, agentPrompt: prompt,
                loadIntent: .interactive))
    }
}

extension EventManager {
    /// Runs every event the message selects. The result describes the first
    /// agent turn when that is all that ran, else the events that fired.
    func ingestChannelMessage(
        _ message: ChannelInboundMessage,
        relay: AgentChannelInboundRelay = .shared,
        safetyGate: ChannelRemoteSafetyGate = .shared,
        auditStore: AgentChannelMessageStore = .shared
    ) async -> AgentChannelInboundRelaySubmission {
        await awaitLoaded()
        guard !message.providerEventId.isEmpty, !message.providerRoute.conversationId.isEmpty else {
            return .suppressed("invalid_dispatch_payload")
        }
        // The sender answering a workflow's question in this conversation
        // continues that run instead of starting another.
        let dialogRelay = ChannelDialogRelay.shared
        let facts = EventMatcher.ChannelFacts(
            kind: message.kind,
            connectionId: message.connectionId,
            roomId: message.providerRoute.conversationId,
            content: message.content,
            mentionsBot: message.mentionsBot,
            hasPriorOutbound: message.hasPriorOutbound
        )
        if dialogRelay.awaitsAnswer(from: message), answerPassesMentionGate(message, facts: facts, relay: dialogRelay) {
            let safety = await safetyGate.authorize(
                ChannelRemoteSafetyRequest(
                    identity: message.identity, action: .receive, content: message.content,
                    taskId: message.providerEventId))
            guard safety.allowed else { return .suppressed(safety.reason.rawValue) }
            if let answered = await dialogRelay.consume(message) {
                let record = Self.dialogAnswerAuditRecord(message, submission: answered)
                Self.ioQueue.async {
                    guard (try? auditStore.recordAuditEvent(record)) != nil else { return }
                    NotificationCenter.default.post(name: .agentChannelUnreachedMessageRecorded, object: nil)
                }
                return answered
            }
        }
        let matches = EventMatcher.rankChannelEvents(events, facts: facts)
        guard !matches.isEmpty else {
            let reason = Self.noMatchReason(events, facts: facts)
            let record = Self.unclaimedAuditRecord(message, reason: reason)
            Self.ioQueue.async { _ = try? auditStore.recordAuditEvent(record) }
            return .suppressed(reason)
        }

        var outcomes: [(event: OsaurusEvent, rule: String, submission: AgentChannelInboundRelaySubmission)] = []
        for match in matches {
            let submission: AgentChannelInboundRelaySubmission
            switch match.event.action {
            case .agent(let action):
                submission = await runChannelAgentTurn(match, action: action, message: message, relay: relay)
            case .workflow:
                submission = await fireChannelWorkflow(match, message: message, safetyGate: safetyGate)
            case .prompt:
                submission = .suppressed("channel_rule_needs_agent_or_workflow")
            }
            outcomes.append((match.event, match.rule, submission))
        }

        let fired = outcomes.filter { if case .suppressed = $0.submission { false } else { true } }
        if !fired.isEmpty {
            let agentId: UUID? = {
                if case .dispatched(let target, _) = fired[0].submission { return target.localId }
                return nil
            }()
            AttentionProducers.raiseInboundChannelMessage(message, agentId: agentId)
        }
        if fired.count == 1, case .dispatched = fired[0].submission { return fired[0].submission }
        if !fired.isEmpty {
            return .fired(eventNames: fired.map(\.event.name), rule: fired[0].rule)
        }
        if case .suppressed(let reason) = outcomes.last?.submission { return .suppressed(reason) }
        return .suppressed("no_event_matched")
    }

    /// An answer in a group follows the asking event's mention rule, so a
    /// message not meant for the bot is not taken as one.
    func answerPassesMentionGate(
        _ message: ChannelInboundMessage, facts: EventMatcher.ChannelFacts, relay: ChannelDialogRelay
    ) -> Bool {
        guard let eventID = relay.askingEventID(for: message),
            let source = event(for: eventID)?.source.channelMessage
        else { return true }
        return EventMatcher.passesMentionGate(source, facts: facts)
    }

    /// The agent the message's first matching agent event runs.
    func channelAgentTarget(for facts: EventMatcher.ChannelFacts) -> AgentDispatchTarget? {
        EventMatcher.rankChannelEvents(events, facts: facts).lazy.compactMap { $0.event.action.agent?.target }.first
    }

    /// Why a message selected no event, for the channel activity row.
    nonisolated static func noMatchReason(_ events: [OsaurusEvent], facts: EventMatcher.ChannelFacts) -> String {
        let connectionId = AgentChannelConnection.normalizedId(facts.connectionId)
        let forConnection = events.filter {
            guard $0.isEnabled, let source = $0.source.channelMessage else { return false }
            return source.kind == facts.kind && AgentChannelConnection.normalizedId(source.connectionId) == connectionId
        }
        guard !forConnection.isEmpty else { return "no_event_configured" }
        let room = facts.roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        let forRoom = forConnection.filter {
            let rooms = $0.source.channelMessage?.roomIds ?? []
            return rooms.isEmpty || rooms.contains(room)
        }
        guard !forRoom.isEmpty else { return "no_event_for_room" }
        if forRoom.allSatisfy({ !EventMatcher.passesMentionGate($0.source.channelMessage!, facts: facts) }) {
            return "mention_required"
        }
        return "no_event_matched"
    }

    /// The audit row for a message no automation claimed, so Automations
    /// History can show it next to the runs.
    nonisolated static func unclaimedAuditRecord(
        _ message: ChannelInboundMessage, reason: String, at: Date = Date()
    ) -> AgentChannelAuditRecord {
        AgentChannelAuditRecord(
            connectionId: message.connectionId,
            roomId: message.providerRoute.conversationId,
            providerEventId: message.providerEventId,
            direction: .inbound,
            action: AutomationHistoryFeed.unclaimedAction,
            status: .denied,
            reason: reason,
            messageInserted: true,
            redactedSummary: AgentChannelAuditRedactor.redactedPreview(message.content),
            createdAt: at
        )
    }

    /// Audit action for a message taken as the answer to a workflow's
    /// question; `reason` carries the relay's rule (`dialog_answer`, …).
    nonisolated static let dialogAnswerAction = "workflow_dialog_answer"

    nonisolated static func dialogAnswerAuditRecord(
        _ message: ChannelInboundMessage, submission: AgentChannelInboundRelaySubmission, at: Date = Date()
    ) -> AgentChannelAuditRecord {
        var reason = "dialog_answer"
        if case .fired(_, let rule) = submission { reason = rule }
        return AgentChannelAuditRecord(
            connectionId: message.connectionId,
            roomId: message.providerRoute.conversationId,
            providerEventId: message.providerEventId,
            direction: .inbound,
            action: dialogAnswerAction,
            status: .accepted,
            reason: reason,
            messageInserted: true,
            redactedSummary: AgentChannelAuditRedactor.redactedPreview(message.content),
            createdAt: at
        )
    }

    /// The conversation a workflow run started by `message` may address.
    nonisolated static func replyTarget(for message: ChannelInboundMessage) -> WorkflowChannelReplyTarget {
        WorkflowChannelReplyTarget(
            connectionId: message.connectionId,
            kind: message.kind,
            conversationId: message.providerRoute.conversationId,
            threadId: message.providerRoute.threadId,
            replyAddress: message.providerRoute.replyAddress,
            senderId: message.identity.sender.senderId,
            senderName: message.identity.sender.displayName,
            displayName: message.providerRoute.displayName
        )
    }

    private func channelPayload(_ event: OsaurusEvent, content: String, message: ChannelInboundMessage, at: Date)
        -> JSONValue
    {
        EventPayload.message(
            event: event,
            firedAt: at,
            text: content,
            platform: message.kind,
            connectionId: message.connectionId,
            roomId: message.providerRoute.conversationId,
            threadId: message.providerRoute.threadId,
            senderId: message.identity.sender.senderId,
            senderName: message.identity.sender.displayName,
            attachments: message.attachments.map { $0.filename ?? $0.providerId },
            extra: message.extraPayload
        )
    }

    private func channelOccurrence(
        _ event: OsaurusEvent, payload: JSONValue, message: ChannelInboundMessage, at: Date, rule: String,
        replySink: ChannelReplySink? = nil, replyTarget: WorkflowChannelReplyTarget? = nil
    ) -> EventOccurrence {
        EventOccurrence(
            eventId: event.id,
            firedAt: at,
            payload: payload,
            dedupeKey: message.providerEventId,
            conversationKey: message.conversationKey,
            isExternal: true,
            replySink: replySink,
            channelReplyTarget: replyTarget,
            summary: [
                "rule": rule,
                "connection_id": message.connectionId,
                "room_id": message.providerRoute.conversationId,
                "content_bytes": String(message.content.utf8.count),
                "attachments": String(message.attachments.count),
            ]
        )
    }

    private func runChannelAgentTurn(
        _ match: EventMatcher.ChannelMatch,
        action: AgentEventAction,
        message: ChannelInboundMessage,
        relay: AgentChannelInboundRelay
    ) async -> AgentChannelInboundRelaySubmission {
        let event = match.event
        let now = Date()
        let payload = channelPayload(event, content: match.content, message: message, at: now)
        let occurrence = channelOccurrence(event, payload: payload, message: message, at: now, rule: match.rule)
        var run = EventRun(
            eventId: event.id,
            eventName: event.name,
            sourceKind: .channelMessage,
            actionKind: .agent,
            firedAt: now,
            dedupeKey: occurrence.dedupeKey,
            conversationKey: occurrence.conversationKey,
            summary: occurrence.summary
        )
        if let rejection = admissionRejection(event: event, occurrence: occurrence) {
            run.status = rejection.status
            run.reason = rejection.reason
            settleNew(run)
            return .suppressed(rejection.reason)
        }
        guard let target = action.target else {
            run.status = .suppressed
            run.reason = "agent_not_selected"
            settleNew(run)
            return .suppressed("agent_not_selected")
        }
        rememberDedupe(event: event, occurrence: occurrence, runId: run.id)
        run.status = .running
        run.startedAt = now
        write(run)
        adjustRunningCount(event.id, by: 1)
        updateState(event.id) { $0.lastFiredAt = now }

        let runId = run.id
        let eventId = event.id
        let request = AgentChannelInboundRelayRequest(
            identity: message.identity,
            connectionId: message.connectionId,
            providerEventId: message.providerEventId,
            providerRoute: message.providerRoute,
            content: match.content,
            attachments: message.attachments,
            target: target,
            rule: match.rule,
            instructions: EventTemplate.render(action.instructions, payload: payload),
            autoReplyEnabled: event.reply.autoReply,
            maxQueued: event.delivery.maxQueued,
            steerRunningTurn: event.delivery.steerRunningTurn,
            folderPath: action.folderPath,
            folderBookmark: action.folderBookmark,
            sourceLabel: message.sourceLabel,
            reply: message.reply,
            replyAttachment: message.replyAttachment,
            draftReply: message.draftReply,
            onOutcome: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .started(let sessionId):
                    guard var live = self.liveRun(runId) else { return }
                    live.sessionId = sessionId
                    self.write(live)
                case .finished(let status, let sessionId, let error, let reason):
                    guard var live = self.liveRun(runId) else { return }
                    live.sessionId = sessionId ?? live.sessionId
                    live.error = error
                    self.write(live)
                    self.adjustRunningCount(eventId, by: -1)
                    self.settle(runId, status: status == .awaitingUser ? .succeeded : status, reason: reason)
                }
            }
        )
        let submission = await relay.submit(request)
        if case .suppressed(let reason) = submission, liveRun(runId) != nil {
            adjustRunningCount(eventId, by: -1)
            settle(runId, status: .suppressed, reason: reason)
        }
        return submission
    }

    private func fireChannelWorkflow(
        _ match: EventMatcher.ChannelMatch,
        message: ChannelInboundMessage,
        safetyGate: ChannelRemoteSafetyGate
    ) async -> AgentChannelInboundRelaySubmission {
        let event = match.event
        let now = Date()
        let payload = channelPayload(event, content: match.content, message: message, at: now)
        // Rate limits and content screening apply to workflow fires too;
        // `.receive` reserves no agent task slot.
        let safety = await safetyGate.authorize(
            ChannelRemoteSafetyRequest(
                identity: message.identity,
                action: .receive,
                content: match.content,
                taskId: message.providerEventId
            )
        )
        // The sink is built whenever the platform can reply: `reply` steps
        // and relayed dialogs use it mid-run. Whether the final output is
        // posted on its own is the rule's `replyWithWorkflowOutput`.
        let sink: ChannelReplySink? = message.reply.map {
            ChannelReplySink(
                connectionId: message.connectionId, providerRoute: message.providerRoute, reply: $0,
                replyAttachment: message.replyAttachment)
        }
        let occurrence = channelOccurrence(
            event, payload: payload, message: message, at: now, rule: match.rule, replySink: sink,
            replyTarget: Self.replyTarget(for: message))
        guard safety.allowed else {
            settleNew(
                EventRun(
                    eventId: event.id, eventName: event.name, sourceKind: .channelMessage, actionKind: .workflow,
                    firedAt: now, status: .suppressed, reason: safety.reason.rawValue,
                    dedupeKey: occurrence.dedupeKey, conversationKey: occurrence.conversationKey,
                    summary: occurrence.summary))
            return .suppressed(safety.reason.rawValue)
        }
        let result = submit(occurrence)
        return result.accepted
            ? .fired(eventNames: [event.name], rule: match.rule)
            : .suppressed(result.reason ?? result.status.rawValue)
    }
}

// MARK: - Listener snapshot

/// What the enabled channel events on one connection add up to, for status
/// rows, the per-agent Replies summary and automatic destinations. Readable
/// from any thread; `EventManager.shared` republishes it on every change.
struct ChannelEventListeners: Sendable, Equatable {
    struct Listener: Sendable, Equatable {
        var eventId: UUID
        var eventName: String
        /// nil for a workflow event.
        var target: AgentDispatchTarget?
        /// Set for a workflow event.
        var workflowId: UUID? = nil
        /// Empty = every room.
        var roomIds: [String]
        var repliesAutomatically: Bool
    }

    var listeners: [Listener] = []

    var isEmpty: Bool { listeners.isEmpty }
    var repliesAutomatically: Bool { listeners.contains(where: \.repliesAutomatically) }

    var referencedTargets: [AgentDispatchTarget] {
        var seen = Set<AgentDispatchTarget>()
        return listeners.compactMap(\.target).filter { seen.insert($0).inserted }
    }

    var referencedAgentIds: [UUID] { referencedTargets.compactMap(\.localId) }

    /// Local agents an event runs for messages in `roomId`.
    func agentIds(answering roomId: String) -> [UUID] {
        var seen = Set<UUID>()
        return listeners.compactMap { listener in
            guard listener.roomIds.isEmpty || listener.roomIds.contains(roomId),
                let id = listener.target?.localId, seen.insert(id).inserted
            else { return nil }
            return id
        }
    }

    func listeners(forAgent agentId: UUID) -> [Listener] {
        listeners.filter { $0.target?.localId == agentId }
    }

    static func build(_ events: [OsaurusEvent]) -> [String: ChannelEventListeners] {
        var out: [String: ChannelEventListeners] = [:]
        for event in events where event.isEnabled {
            guard let source = event.source.channelMessage else { continue }
            out[key(source.kind, source.connectionId), default: ChannelEventListeners()].listeners.append(
                Listener(
                    eventId: event.id,
                    eventName: event.name,
                    target: event.action.agent?.target,
                    workflowId: event.action.workflow?.workflowID,
                    roomIds: source.roomIds,
                    repliesAutomatically: event.reply.replies(for: event.action.kind)
                ))
        }
        return out
    }

    static func key(_ kind: AgentChannelKind, _ connectionId: String) -> String {
        kind.rawValue + "|" + AgentChannelConnection.normalizedId(connectionId)
    }
}

extension EventManager {
    nonisolated static let channelListenerSnapshot = OSAllocatedUnfairLock<[String: ChannelEventListeners]>(
        initialState: [:])

    /// The enabled channel events listening on a connection.
    nonisolated static func channelListeners(kind: AgentChannelKind, connectionId: String) -> ChannelEventListeners {
        channelListenerSnapshot.withLock { $0[ChannelEventListeners.key(kind, connectionId)] } ?? ChannelEventListeners()
    }

    func publishChannelListeners() {
        let built = ChannelEventListeners.build(events)
        Self.channelListenerSnapshot.withLock { $0 = built }
    }
}
