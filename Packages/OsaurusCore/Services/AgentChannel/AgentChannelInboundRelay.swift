//
//  AgentChannelInboundRelay.swift
//  osaurus
//
//  Runs the agent turn for a channel-message event: conversation steering,
//  queueing behind a running turn, quick reattach and reply delivery.
//  Which agent answers is decided upstream, by the event that matched
//  (`EventManager.ingestChannelMessage`).
//

import Foundation

typealias AgentChannelInboundReplyHandler = @Sendable (String) async throws -> Void

/// How a channel agent turn went, reported back to the event ledger.
enum AgentChannelTurnOutcome: Sendable, Equatable {
    case started(sessionId: UUID)
    case finished(status: EventRunStatus, sessionId: UUID?, error: String?, reason: String?)
}

typealias AgentChannelTurnOutcomeHandler = @MainActor @Sendable (AgentChannelTurnOutcome) -> Void

/// Delivers one agent-produced file (a shared artifact staged on the host) back
/// to the channel as a native attachment. `path` is a trusted host path inside
/// `~/.osaurus/artifacts/`; providers stage it into their own fenced media root
/// before sending so the regular outbound gates still apply.
typealias AgentChannelInboundAttachmentReplyHandler =
    @Sendable (_ path: String, _ caption: String?) async throws -> Void

struct AgentChannelInboundRelayRequest: Sendable {
    var identity: ChannelIdentity
    var connectionId: String
    var providerEventId: String
    var providerRoute: AgentChannelProviderRoute
    var content: String
    var attachments: [AgentChannelStoredAttachment]
    /// The agent the matched event runs.
    var target: AgentDispatchTarget
    /// The event selection rule ("alias:<alias>", "room:<roomId>", "default").
    var rule: String
    /// The event's rendered instructions, put ahead of the message.
    var instructions: String
    var autoReplyEnabled: Bool
    /// Messages held behind a running turn for this conversation; past this
    /// they are skipped. From the event's Queueing step.
    var maxQueued: Int
    /// Whether a message may join a still-running turn instead of waiting.
    var steerRunningTurn: Bool
    var folderPath: String?
    var folderBookmark: Data?
    var sourceLabel: String
    var reply: AgentChannelInboundReplyHandler?
    var replyAttachment: AgentChannelInboundAttachmentReplyHandler?
    /// Keeps an unsent reply for review on this Mac (an email draft) when
    /// auto-reply is off. Nothing leaves the Mac.
    var draftReply: AgentChannelInboundReplyHandler?
    var onOutcome: AgentChannelTurnOutcomeHandler?

    init(
        identity: ChannelIdentity,
        connectionId: String,
        providerEventId: String,
        providerRoute: AgentChannelProviderRoute,
        content: String,
        attachments: [AgentChannelStoredAttachment] = [],
        target: AgentDispatchTarget,
        rule: String = "default",
        instructions: String = "",
        autoReplyEnabled: Bool = true,
        maxQueued: Int = AgentChannelInboundRelay.maxQueuedMessagesPerConversation,
        steerRunningTurn: Bool = true,
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        sourceLabel: String,
        reply: AgentChannelInboundReplyHandler? = nil,
        replyAttachment: AgentChannelInboundAttachmentReplyHandler? = nil,
        draftReply: AgentChannelInboundReplyHandler? = nil,
        onOutcome: AgentChannelTurnOutcomeHandler? = nil
    ) {
        self.identity = identity
        self.connectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerEventId = providerEventId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerRoute = providerRoute
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.attachments = attachments
        self.target = target
        self.rule = rule
        self.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        self.autoReplyEnabled = autoReplyEnabled
        self.maxQueued = max(0, maxQueued)
        self.steerRunningTurn = steerRunningTurn
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.sourceLabel = sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reply = reply
        self.replyAttachment = replyAttachment
        self.draftReply = draftReply
        self.onOutcome = onOutcome
    }
}

enum AgentChannelInboundRelaySubmission: Equatable, Sendable {
    /// The message was handed to `target`; `rule` is the matched event's
    /// selection rule ("alias:<alias>", "room:<roomId>", or "default").
    case dispatched(target: AgentDispatchTarget, rule: String)
    /// The message fired events that are not one agent turn (a workflow,
    /// or several events at once).
    case fired(eventNames: [String], rule: String)
    case suppressed(String)

    /// Convenience for the (many) local-only call sites and tests.
    static func dispatched(agentId: UUID, rule: String) -> AgentChannelInboundRelaySubmission {
        .dispatched(target: .local(agentId), rule: rule)
    }

    var dispatchAttempted: Int {
        if case .suppressed = self { return 0 }
        return 1
    }

    var dispatchSuppressed: Int {
        if case .suppressed = self { return 1 }
        return 0
    }
}

@MainActor
final class AgentChannelInboundRelay {
    static let shared = AgentChannelInboundRelay()
    private static let maxReplyWait: TimeInterval = 900

    private let substrate: AgentChannelAsyncSubstrate
    private let safetyGate: ChannelRemoteSafetyGate
    private let auditLog: AgentChannelAuditLog
    private let taskManager: BackgroundTaskManager
    private let activityCenter: AgentChannelInboundActivityCenter
    private let focusPreference: AgentChannelInboundFocusPreference
    private let writeGate: ChannelWriteKillSwitch
    private let revealTask: @MainActor (UUID) -> Void
    /// A message that arrived while its conversation already had a turn in
    /// flight, held until that turn ends.
    private struct QueuedMessage {
        let request: AgentChannelInboundRelayRequest
        let content: String
        let rule: String
    }

    /// Conversations with a turn in flight, mapped to the messages that
    /// arrived meanwhile. The queue is drained as one follow-up turn when
    /// the current turn ends, so no accepted message is dropped (#2987).
    private var activePartitions: [String: [QueuedMessage]] = [:]

    /// Ceiling on messages held behind one running turn, so a flood can't
    /// grow the follow-up prompt without bound.
    nonisolated static let maxQueuedMessagesPerConversation = 20

    /// A message for a busy conversation joins the running turn only when
    /// the event allows it and nothing is already queued ahead of it.
    nonisolated static func shouldTrySteer(queued: Int, request: AgentChannelInboundRelayRequest) -> Bool {
        request.steerRunningTurn && queued == 0
    }

    /// Why a message for a busy conversation can't wait in line, or nil
    /// when it can.
    nonisolated static func queueRejection(queued: Int, request: AgentChannelInboundRelayRequest) -> String? {
        if request.maxQueued == 0 { return "conversation_busy" }
        return queued < request.maxQueued ? nil : "conversation_queue_full"
    }

    init(
        substrate: AgentChannelAsyncSubstrate = .shared,
        safetyGate: ChannelRemoteSafetyGate = .shared,
        auditLog: AgentChannelAuditLog = .shared,
        taskManager: BackgroundTaskManager = .shared,
        activityCenter: AgentChannelInboundActivityCenter = .shared,
        focusPreference: AgentChannelInboundFocusPreference = .shared,
        writeGate: ChannelWriteKillSwitch = .shared,
        revealTask: @escaping @MainActor (UUID) -> Void = { ChatWindowManager.shared.revealTask($0) }
    ) {
        self.substrate = substrate
        self.safetyGate = safetyGate
        self.auditLog = auditLog
        self.taskManager = taskManager
        self.activityCenter = activityCenter
        self.focusPreference = focusPreference
        self.writeGate = writeGate
        self.revealTask = revealTask
    }

    /// Settings → Channels → Incoming → Focus Chat on Incoming Messages: when
    /// enabled, every inbound message brings its conversation forward (focus
    /// the tab, order the chat window front, open one if none is up). Off by
    /// default; a monitoring/dedicated machine turns it on to see each
    /// channel activation as it happens.
    func revealConversationIfPreferred(taskId: UUID) {
        guard focusPreference.isEnabled else { return }
        revealTask(taskId)
    }

    /// Starts, steers or queues the turn. A `.suppressed` result is final;
    /// otherwise `request.onOutcome` reports how the turn ends.
    func submit(_ request: AgentChannelInboundRelayRequest) async -> AgentChannelInboundRelaySubmission {
        let target = request.target
        let rule = request.rule
        // A local target must name a real custom agent; a workspace target
        // must still be a shared agent in one of our rosters (the owner may
        // have unshared it or we may have left the workspace). Liveness is
        // NOT checked here — `BackgroundTaskManager.dispatchChat` runs the
        // relay probe and the failure text flows back as the reply.
        switch target {
        case .local(let id):
            guard let agent = AgentManager.shared.agent(for: id), !agent.isBuiltIn else {
                return .suppressed("inbound_agent_unavailable")
            }
        case .workspace(let ref):
            let roster = WorkspaceRosterStore.shared
            guard roster.agent(forAddress: ref.agentAddress, workspaceId: ref.workspaceId) != nil,
                !roster.isHostedHere(address: ref.agentAddress)
            else {
                return .suppressed("inbound_workspace_agent_unavailable")
            }
        }
        let agentId = target.localId
        let content = request.content
        guard (!content.isEmpty || !request.attachments.isEmpty),
              !request.connectionId.isEmpty,
              !request.providerEventId.isEmpty,
              !request.providerRoute.conversationId.isEmpty
        else {
            return .suppressed("invalid_dispatch_payload")
        }

        let partition = substrate.makeSessionPartition(
            target: target,
            connectionId: request.connectionId,
            providerRoute: request.providerRoute
        )
        let key = partition.externalSessionKey
        if var queue = activePartitions[key] {
            // Steer a live turn when nothing is queued ahead of this message
            // (#2988). A queue already in line keeps arrival order.
            if Self.shouldTrySteer(queued: queue.count, request: request),
                let steered = await steerRunningTurn(
                    request,
                    content: content,
                    target: target,
                    rule: rule,
                    partition: partition
                )
            {
                return steered
            }
            // The steer check awaited: if the turn ended meanwhile, nothing
            // would ever drain a queue, so start this message's own turn.
            guard let current = activePartitions[key] else {
                activePartitions[key] = []
                return await start(
                    request,
                    content: content,
                    target: target,
                    rule: rule,
                    partition: partition
                )
            }
            queue = current
            if let rejection = Self.queueRejection(queued: queue.count, request: request) {
                NSLog(
                    "[AgentChannelInboundRelay] Dropped message %@, %d already waiting behind the running turn",
                    request.providerEventId,
                    queue.count
                )
                return .suppressed(rejection)
            }
            queue.append(QueuedMessage(request: request, content: content, rule: rule))
            activePartitions[key] = queue
            NSLog(
                "[AgentChannelInboundRelay] Queued message %@ behind the running turn (%d waiting)",
                request.providerEventId,
                queue.count
            )
            await auditLog.record(
                AgentChannelAuditEvent(
                    kind: .dispatchStarted,
                    status: .awaitingAgent,
                    connectionId: request.connectionId,
                    agentId: agentId,
                    sessionId: partition.sessionId,
                    auditKey: request.providerEventId,
                    metadata: [
                        "conversation_hash": partition.conversationHash,
                        "external_session_key": key,
                        "dispatch_rule": rule,
                        "queued": "true",
                    ]
                )
            )
            return .dispatched(target: target, rule: rule)
        }
        activePartitions[key] = []
        return await start(
            request,
            content: content,
            target: target,
            rule: rule,
            partition: partition
        )
    }

    /// Authorizes and launches one turn for a conversation already marked
    /// active. Every exit path ends in `finishTurn`, which drains the queue.
    private func start(
        _ request: AgentChannelInboundRelayRequest,
        content: String,
        target: AgentDispatchTarget,
        rule: String,
        partition: AgentChannelSessionPartition,
        notifyOnDenial: Bool = false
    ) async -> AgentChannelInboundRelaySubmission {
        let agentId = target.localId
        let safety = await safetyGate.authorize(
            ChannelRemoteSafetyRequest(
                identity: request.identity,
                action: .dispatch,
                content: content,
                taskId: request.providerEventId
            )
        )
        guard safety.allowed else {
            await auditLog.record(
                AgentChannelAuditEvent(
                    kind: .taskFailed,
                    status: .rejected,
                    connectionId: request.connectionId,
                    agentId: agentId,
                    auditKey: request.providerEventId,
                    failure: AgentChannelFailure(
                        code: safety.reason == .rateLimited ? .rateLimited : .dispatchUnavailable,
                        message: safety.message,
                        retryable: safety.reason == .rateLimited
                    ),
                    metadata: ["reason": safety.reason.rawValue]
                )
            )
            request.onOutcome?(
                .finished(status: .suppressed, sessionId: nil, error: nil, reason: safety.reason.rawValue))
            // A queued batch has no caller left to report the denial, so
            // tell the sender instead of dropping their messages silently.
            if notifyOnDenial {
                await sendDenialNotice(request, agentId: agentId, partition: partition, safety: safety)
            }
            await finishTurn(target: target, partition: partition)
            return .suppressed(safety.reason.rawValue)
        }

        let wrapped = ChannelRemoteSafetyGate.wrapUntrustedContent(
            content + Self.attachmentContext(request.attachments),
            source: request.sourceLabel,
            assessment: safety.contentAssessment
        )
        let prompt = request.instructions.isEmpty ? wrapped : request.instructions + "\n\n" + wrapped
        var startedMetadata = [
            "conversation_hash": partition.conversationHash,
            "external_session_key": partition.externalSessionKey,
            "dispatch_rule": rule,
        ]
        if let ref = target.workspaceRef { startedMetadata["workspace_agent"] = ref.key }
        await auditLog.record(
            AgentChannelAuditEvent(
                kind: .dispatchStarted,
                status: .dispatched,
                connectionId: request.connectionId,
                agentId: agentId,
                sessionId: partition.sessionId,
                auditKey: request.providerEventId,
                metadata: startedMetadata
            )
        )

        Task { @MainActor [weak self] in
            await self?.run(
                request,
                target: target,
                partition: partition,
                prompt: prompt
            )
            // Free the remote task slot before the queue drains, or the next
            // batch's authorize can still see this turn and be denied (#3184).
            await self?.safetyGate.finishRemoteTask(
                identity: request.identity,
                taskId: request.providerEventId
            )
            await self?.finishTurn(target: target, partition: partition)
        }
        return .dispatched(target: target, rule: rule)
    }

    /// Ends the conversation's current turn. Messages that queued up behind
    /// it start the next turn, otherwise the conversation goes idle.
    private func finishTurn(target: AgentDispatchTarget, partition: AgentChannelSessionPartition) async {
        let key = partition.externalSessionKey
        guard let queued = activePartitions[key], let first = queued.first else {
            activePartitions.removeValue(forKey: key)
            return
        }
        // Batch only one sender's consecutive messages, so the safety gate
        // and the reply attribution see the person who actually wrote them.
        let batch = Array(queued.prefix { $0.request.identity == first.request.identity })
        activePartitions[key] = Array(queued.dropFirst(batch.count))
        let merged = Self.mergedRequest(batch.map(\.request), contents: batch.map(\.content))
        _ = await start(
            merged.request,
            content: merged.content,
            target: target,
            rule: batch.last?.rule ?? first.rule,
            partition: partition,
            notifyOnDenial: true
        )
    }

    /// Replies to a sender whose queued messages the safety gate refused.
    private func sendDenialNotice(
        _ request: AgentChannelInboundRelayRequest,
        agentId: UUID?,
        partition: AgentChannelSessionPartition,
        safety: ChannelRemoteSafetyDecision
    ) async {
        guard request.autoReplyEnabled, writeGate.snapshot().writeEnabled, let responder = request.reply else {
            return
        }
        let notice = Self.denialNotice(retryAfterSeconds: safety.retryAfterSeconds)
        let activity = Self.replyActivity(for: request, agentId: agentId, sessionId: partition.sessionId)
        do {
            try await responder(notice)
            activity.finish(
                contentLength: notice.utf8.count, outcome: "refusal_sent", error: nil,
                extraDetails: ["reason": safety.reason.rawValue])
        } catch {
            activity.finish(
                contentLength: notice.utf8.count, outcome: "failed",
                error: error.localizedDescription, extraDetails: ["reason": safety.reason.rawValue])
        }
    }

    nonisolated static func denialNotice(retryAfterSeconds: TimeInterval?) -> String {
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            let seconds = Int(retryAfterSeconds.rounded(.up))
            return "Couldn't start your last message. Please send it again in \(seconds) seconds."
        }
        return "Couldn't start your last message. Please send it again."
    }

    /// Folds queued messages into one request, in arrival order. The last
    /// message's event id keys the reply, and its reply handlers answer.
    nonisolated static func mergedRequest(
        _ requests: [AgentChannelInboundRelayRequest],
        contents: [String]
    ) -> (request: AgentChannelInboundRelayRequest, content: String) {
        var request = requests[requests.count - 1]
        let content = contents.filter { !$0.isEmpty }.joined(separator: "\n\n")
        request.content = content
        request.attachments = requests.flatMap(\.attachments)
        let handlers: [AgentChannelTurnOutcomeHandler] = requests.compactMap(\.onOutcome)
        if handlers.isEmpty {
            request.onOutcome = nil
        } else {
            request.onOutcome = { @MainActor @Sendable (outcome: AgentChannelTurnOutcome) in
                for handler in handlers { handler(outcome) }
            }
        }
        return (request, content)
    }

    /// A message for a conversation whose turn is still streaming joins that
    /// turn at its next iteration boundary instead of waiting for a new one,
    /// so the agent keeps its in-flight work and answers everything together
    /// (#2988). `run` sends anything that missed the last boundary as the
    /// follow-up turn. Returns nil when the turn can't take a steer (not
    /// streaming yet, attachments, workspace run), so the caller queues it.
    private func steerRunningTurn(
        _ request: AgentChannelInboundRelayRequest,
        content: String,
        target: AgentDispatchTarget,
        rule: String,
        partition: AgentChannelSessionPartition
    ) async -> AgentChannelInboundRelaySubmission? {
        guard request.attachments.isEmpty,
            let runningId = taskManager.runningTaskId(
                source: .channel,
                externalSessionKey: partition.externalSessionKey,
                target: target
            )
        else {
            return nil
        }
        // Rate limits and content assessment still apply. `.receive` does not
        // reserve a remote task slot: the steer rides the running task's.
        let safety = await safetyGate.authorize(
            ChannelRemoteSafetyRequest(
                identity: request.identity,
                action: .receive,
                content: content,
                taskId: request.providerEventId
            )
        )
        guard safety.allowed else {
            await auditLog.record(
                AgentChannelAuditEvent(
                    kind: .taskFailed,
                    status: .rejected,
                    connectionId: request.connectionId,
                    agentId: target.localId,
                    auditKey: request.providerEventId,
                    failure: AgentChannelFailure(
                        code: safety.reason == .rateLimited ? .rateLimited : .dispatchUnavailable,
                        message: safety.message,
                        retryable: safety.reason == .rateLimited
                    ),
                    metadata: ["reason": safety.reason.rawValue]
                )
            )
            return .suppressed(safety.reason.rawValue)
        }
        let prompt = ChannelRemoteSafetyGate.wrapUntrustedContent(
            content,
            source: request.sourceLabel,
            assessment: safety.contentAssessment
        )
        guard taskManager.steerTask(runningId, text: prompt) else {
            return nil
        }
        NSLog("[AgentChannelInboundRelay] Steered message %@ into the running turn", request.providerEventId)
        request.onOutcome?(.finished(status: .succeeded, sessionId: runningId, error: nil, reason: "steered"))
        await auditLog.record(
            AgentChannelAuditEvent(
                kind: .dispatchStarted,
                status: .dispatched,
                connectionId: request.connectionId,
                agentId: target.localId,
                sessionId: runningId,
                auditKey: request.providerEventId,
                metadata: [
                    "conversation_hash": partition.conversationHash,
                    "external_session_key": partition.externalSessionKey,
                    "dispatch_rule": rule,
                    "steered": "true",
                ]
            )
        )
        return .dispatched(target: target, rule: rule)
    }

    private func run(
        _ request: AgentChannelInboundRelayRequest,
        target: AgentDispatchTarget,
        partition: AgentChannelSessionPartition,
        prompt: String
    ) async {
        let agentId = target.localId

        // Artifacts created before this run belong to earlier turns of a
        // reused channel session and must not be re-sent with this reply.
        let runStartedAt = Date()

        let taskId: UUID
        if let replyableId = taskManager.replyableTaskId(
            source: .channel,
            externalSessionKey: partition.externalSessionKey,
            target: target
        ), taskManager.submitQuickReply(replyableId, text: prompt, author: Self.author(of: request)) {
            taskId = replyableId
            try? await Task.sleep(for: .milliseconds(100))
        } else {
            let dispatch = DispatchRequest(
                id: partition.sessionId,
                prompt: prompt,
                target: target,
                title: request.providerRoute.displayName ?? "Channel conversation",
                folderPath: request.folderPath,
                folderBookmark: request.folderBookmark,
                // Channel turns surface in the Activity section like any other background
                // work so the user can watch (and cancel) remote-triggered runs.
                showToast: true,
                source: .channel,
                externalSessionKey: partition.externalSessionKey,
                // Plugin tools are deferred behind `capabilities_load`, and a
                // channel dispatch starts each message with an empty
                // loaded-tools set. Pre-load the agent's granted plugin tools
                // so calendar/mail/etc. work without the model having to
                // discover and load them itself every turn (#2443).
                // A workspace agent's tools are the host's business; nothing
                // to pre-load on this side.
                requestedToolNames: agentId.map { id in
                    Self.preloadedPluginToolNames(
                        registered: ToolRegistry.shared.registeredPluginToolNames,
                        granted: AgentManager.shared.effectiveEnabledToolNames(for: id)
                    )
                } ?? [],
                externalSurface: true,
                loadIntent: .background,
                author: Self.author(of: request)
            )
            guard let handle = await taskManager.dispatchChat(dispatch) else {
                // A refused workspace run carries the real reason (host
                // offline, unshared, key lapsed); surface it as the reply so
                // the sender learns why nothing answered.
                let refusal = target.workspaceRef.flatMap {
                    taskManager.consumeWorkspaceDispatchRefusal(for: $0)
                }
                let message = refusal ?? "The selected agent could not accept this channel message."
                request.onOutcome?(
                    .finished(status: .failed, sessionId: nil, error: message, reason: "dispatch_unavailable"))
                await recordFailure(
                    request,
                    agentId: agentId,
                    sessionId: partition.sessionId,
                    code: .dispatchUnavailable,
                    message: message
                )
                if let refusal, request.autoReplyEnabled, writeGate.snapshot().writeEnabled,
                    let responder = request.reply
                {
                    let activity = Self.replyActivity(for: request, agentId: agentId, sessionId: partition.sessionId)
                    do {
                        try await responder(refusal)
                        activity.finish(
                            contentLength: refusal.utf8.count, outcome: "refusal_sent", error: nil,
                            extraDetails: ["reason": "dispatch_unavailable"])
                    } catch {
                        activity.finish(
                            contentLength: refusal.utf8.count, outcome: "failed",
                            error: error.localizedDescription, extraDetails: ["reason": "dispatch_unavailable"])
                    }
                }
                return
            }
            taskId = handle.id
        }

        revealConversationIfPreferred(taskId: taskId)
        request.onOutcome?(.started(sessionId: taskId))

        var turnStartedAt = runStartedAt
        var outcome = AgentChannelTurnOutcome.finished(status: .succeeded, sessionId: taskId, error: nil, reason: nil)
        defer { request.onOutcome?(outcome) }
        while true {
            outcome = await deliverReply(request, taskId: taskId, agentId: agentId, runStartedAt: turnStartedAt)
            // Steered messages that arrived after the last iteration boundary
            // have not been answered yet: they become the follow-up turn.
            let leftover = taskManager.takeRemoteSteers(taskId)
            guard !leftover.isEmpty else { break }
            turnStartedAt = Date()
            guard taskManager.submitQuickReply(taskId, text: leftover.joined(separator: "\n\n")) else {
                await recordFailure(
                    request,
                    agentId: agentId,
                    sessionId: taskId,
                    code: .dispatchUnavailable,
                    message: "\(leftover.count) message(s) arrived while the agent was working but the turn ended before they could be answered."
                )
                outcome = .finished(
                    status: .failed, sessionId: taskId,
                    error: "\(leftover.count) message(s) arrived too late to be answered.", reason: "steer_missed")
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Waits for the turn, sends its reply, and says how the turn ended.
    private func deliverReply(
        _ request: AgentChannelInboundRelayRequest,
        taskId: UUID,
        agentId: UUID?,
        runStartedAt: Date
    ) async -> AgentChannelTurnOutcome {
        let terminal = await waitForReply(taskId: taskId, runStartedAt: runStartedAt)
        switch terminal {
        case .reply(let text, let awaitingClarification, let artifacts):
            let answered = AgentChannelTurnOutcome.finished(
                status: awaitingClarification ? .awaitingUser : .succeeded, sessionId: taskId, error: nil,
                reason: nil)
            guard request.autoReplyEnabled, let responder = request.reply else {
                var metadata = ["auto_reply": "disabled"]
                if let draft = request.draftReply {
                    let sanitized = ChannelRemoteSafetyGate.sanitizeResult(ChannelRemoteResultPayload(text: text))
                    do {
                        try await draft(sanitized.text)
                        metadata["draft"] = "saved"
                    } catch {
                        metadata["draft"] = "failed"
                        metadata["draft_error"] = error.localizedDescription
                    }
                }
                await auditLog.record(
                    AgentChannelAuditEvent(
                        kind: .taskCompleted,
                        status: awaitingClarification ? .awaitingClarification : .completed,
                        connectionId: request.connectionId,
                        agentId: agentId,
                        sessionId: taskId,
                        auditKey: request.providerEventId,
                        metadata: metadata
                    )
                )
                await activityCenter.record(
                    connectionId: request.connectionId,
                    providerEventId: request.providerEventId,
                    stage: .agentReplied,
                    reason: Self.autoReplyDisabledReason
                )
                return .finished(
                    status: awaitingClarification ? .awaitingUser : .succeeded,
                    sessionId: taskId, error: nil, reason: Self.autoReplyDisabledReason)
            }
            let sanitized = ChannelRemoteSafetyGate.sanitizeResult(
                ChannelRemoteResultPayload(text: text)
            )
            guard writeGate.snapshot().writeEnabled else {
                Self.replyActivity(for: request, agentId: agentId, sessionId: taskId).finish(
                    contentLength: sanitized.text.utf8.count, outcome: "blocked", error: nil,
                    extraDetails: ["reason": Self.globalWritesDisabledReason])
                await auditLog.record(
                    AgentChannelAuditEvent(
                        kind: .taskCompleted,
                        status: awaitingClarification ? .awaitingClarification : .completed,
                        connectionId: request.connectionId,
                        agentId: agentId,
                        sessionId: taskId,
                        auditKey: request.providerEventId,
                        metadata: ["auto_reply": "blocked", "reason": Self.globalWritesDisabledReason]
                    )
                )
                await activityCenter.record(
                    connectionId: request.connectionId,
                    providerEventId: request.providerEventId,
                    stage: .agentReplied,
                    reason: Self.globalWritesDisabledReason
                )
                return .finished(
                    status: awaitingClarification ? .awaitingUser : .succeeded,
                    sessionId: taskId, error: nil, reason: Self.globalWritesDisabledReason)
            }
            // Activity log: the reply is about to leave this Mac for the
            // provider. Captured before the send so attribution reads the
            // caller's task-locals; written once the attempt settles.
            let replyActivity = Self.replyActivity(for: request, agentId: agentId, sessionId: taskId)
            do {
                try await responder(sanitized.text)
                var metadata = [
                    "redacted": sanitized.redacted ? "true" : "false",
                    "truncated": sanitized.truncated ? "true" : "false",
                ]
                if let attachmentResponder = request.replyAttachment, !artifacts.isEmpty {
                    var sent = 0
                    var failed = 0
                    for artifact in artifacts.prefix(Self.maxReplyArtifacts) {
                        do {
                            try await attachmentResponder(artifact.hostPath, artifact.description)
                            sent += 1
                        } catch {
                            failed += 1
                            NSLog(
                                "[AgentChannelInboundRelay] Artifact reply '%@' failed: %@",
                                artifact.filename,
                                error.localizedDescription
                            )
                        }
                    }
                    if sent > 0 { metadata["artifacts_sent"] = "\(sent)" }
                    if failed > 0 { metadata["artifacts_failed"] = "\(failed)" }
                }
                replyActivity.finish(
                    contentLength: sanitized.text.utf8.count,
                    outcome: awaitingClarification ? "replied_awaiting_clarification" : "replied",
                    error: nil,
                    extraDetails: metadata
                )
                await auditLog.record(
                    AgentChannelAuditEvent(
                        kind: .replySent,
                        status: awaitingClarification ? .awaitingClarification : .replied,
                        connectionId: request.connectionId,
                        agentId: agentId,
                        sessionId: taskId,
                        auditKey: request.providerEventId,
                        metadata: metadata
                    )
                )
                await activityCenter.record(
                    connectionId: request.connectionId,
                    providerEventId: request.providerEventId,
                    stage: .replySent
                )
                return answered
            } catch {
                replyActivity.finish(
                    contentLength: sanitized.text.utf8.count,
                    outcome: "failed",
                    error: error.localizedDescription,
                    extraDetails: [:]
                )
                await recordFailure(
                    request,
                    agentId: agentId,
                    sessionId: taskId,
                    code: .providerUnavailable,
                    message: error.localizedDescription
                )
                return .finished(
                    status: .failed, sessionId: taskId, error: error.localizedDescription, reason: "reply_failed")
            }
        case .failed(let message):
            await recordFailure(
                request,
                agentId: agentId,
                sessionId: taskId,
                code: .internalFailure,
                message: message
            )
            return .finished(status: .failed, sessionId: taskId, error: message, reason: nil)
        }
    }

    /// The channel sender who wrote the message, so two people in one thread
    /// read as two authors in the transcript.
    nonisolated static func author(of request: AgentChannelInboundRelayRequest) -> ParticipantRef {
        Participant.channelSender(kind: request.identity.kind, sender: request.identity.sender)
    }

    /// Ceiling on how many plugin tools a channel dispatch will pre-load.
    /// Past this, a preloaded schema stops helping the small models the
    /// preload exists for and starts crowding their context, so the
    /// dispatch falls back to the deferred `capabilities_load` path.
    nonisolated static let maxPreloadedPluginTools = 40

    /// Plugin tools to pre-load into a channel-dispatched session. `granted`
    /// is the agent's manual-selection allowlist; `nil` means the agent uses
    /// the global enabled registry, so every registered plugin tool applies.
    /// Sorted so successive dispatches into a reattached session append a
    /// stable set. Past `maxPreloadedPluginTools` the set is TRUNCATED to
    /// the sorted prefix, not dropped: the same leading tools preload on
    /// every dispatch (deterministic → reattached sessions stay
    /// byte-stable), and "the first 40 work" degrades far better for the
    /// small models the preload exists for than every tool silently
    /// vanishing behind `capabilities_load` the moment one extra plugin is
    /// installed. The overflow is deferred, not lost — the model can still
    /// load it explicitly; `preloadOverflowCount` sizes the settings
    /// warning that tells the operator to narrow the grant.
    nonisolated static func preloadedPluginToolNames(
        registered: Set<String>,
        granted: [String]?
    ) -> [String] {
        let applicable = granted.map { registered.intersection($0) } ?? registered
        return Array(applicable.sorted().prefix(maxPreloadedPluginTools))
    }

    /// How many applicable plugin tools exceed the preload ceiling and fall
    /// back to deferred loading. Non-zero means the operator should narrow
    /// the agent's tool grant; surfaced in channel settings rather than
    /// left as a silent behavior change.
    nonisolated static func preloadOverflowCount(
        registered: Set<String>,
        granted: [String]?
    ) -> Int {
        let applicable = granted.map { registered.intersection($0) } ?? registered
        return max(0, applicable.count - maxPreloadedPluginTools)
    }

    /// Header of the attachment trailer appended to the channel content.
    /// Shared with `ChannelMessageEnvelope`, which splits the trailer off for
    /// display, so the producer and the parser can never drift apart.
    nonisolated static let attachmentContextHeader = "Attachments supplied by the channel (untrusted metadata):"

    private static func attachmentContext(_ attachments: [AgentChannelStoredAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        let lines = attachments.map { attachment in
            let details = [
                attachment.filename,
                attachment.contentType,
                attachment.sizeBytes.map { "\($0) bytes" },
            ].compactMap(\.self).joined(separator: ", ")
            return "- \(attachment.kind.rawValue): \(attachment.providerId)"
                + (details.isEmpty ? "" : " (\(details))")
        }
        return "\n\n" + attachmentContextHeader + "\n"
            + lines.joined(separator: "\n")
    }

    private enum TerminalReply {
        case reply(String, awaitingClarification: Bool, artifacts: [SharedArtifact])
        case failed(String)
    }

    /// Upper bound on artifacts forwarded per reply so a runaway agent can't
    /// flood a chat with media sends.
    private static let maxReplyArtifacts = 5

    /// Machine reason recorded when a completed run's reply stays local
    /// because auto-reply is off. Must keep a guidance mapping in
    /// `AgentChannelInboundActivityPresentation`: with channel-triggered runs
    /// barred from proactive publishing, this is a silently dropped reply
    /// unless the activity UI explains it.
    nonisolated static let autoReplyDisabledReason = "auto_reply_disabled"

    /// Machine reason recorded when a reply stays local because Settings →
    /// Channels → Sending → Allow Agents to Send Messages is off. Shares the
    /// code the publish path uses for the same gate.
    nonisolated static let globalWritesDisabledReason = "global_writes_disabled"

    private func waitForReply(taskId: UUID, runStartedAt: Date) async -> TerminalReply {
        let deadline = Date().addingTimeInterval(Self.maxReplyWait)
        while !Task.isCancelled {
            if Date() >= deadline {
                taskManager.cancelTask(taskId)
                return .failed("The channel task timed out before producing a reply.")
            }
            guard let state = taskManager.taskState(for: taskId) else {
                if let stored = ChatSessionStore.load(id: taskId),
                   let text = Self.latestAssistantReply(in: stored.turns) {
                    return .reply(
                        text,
                        awaitingClarification: false,
                        artifacts: Self.replyArtifacts(
                            stored.turns.flatMap(\.sharedArtifacts),
                            createdAfter: runStartedAt
                        )
                    )
                }
                return .failed("The channel task disappeared before producing a reply.")
            }
            switch state.status {
            case .queued, .running:
                try? await Task.sleep(for: .milliseconds(250))
            case .waitingForInput:
                if let clarification = state.chatSession?.awaitingClarify {
                    var text = clarification.question
                    if !clarification.options.isEmpty {
                        text += "\n\n" + clarification.options.map { "• \($0)" }.joined(separator: "\n")
                    }
                    return .reply(text, awaitingClarification: true, artifacts: [])
                }
                return .failed("The agent is waiting for input but did not provide a clarification question.")
            case .completed:
                if let text = Self.latestAssistantReply(in: state.chatSession?.turns ?? []) {
                    return .reply(
                        text,
                        awaitingClarification: false,
                        artifacts: Self.replyArtifacts(
                            (state.chatSession?.turns ?? []).flatMap(\.sharedArtifacts),
                            createdAfter: runStartedAt
                        )
                    )
                }
                return .failed("The agent completed without a visible reply.")
            case .failed(let summary):
                return .failed(summary)
            case .cancelled:
                return .failed("The channel task was cancelled.")
            }
        }
        return .failed("The channel task was cancelled.")
    }

    /// The visible reply of a finished channel turn: the last assistant turn
    /// with non-blank content. Shared by the relay's reply wait and the
    /// pull-based `/channels/{kind}/{id}/tasks/{task_id}` poll route so both
    /// surfaces agree on what "the reply" is.
    nonisolated static func latestAssistantReply(in turns: [ChatTurnData]) -> String? {
        turns.last(where: {
            $0.role == .assistant
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content
    }

    /// Live-session twin of `latestAssistantReply(in:)`.
    static func latestAssistantReply(in turns: [ChatTurn]) -> String? {
        turns.last(where: { $0.role == .assistant && !$0.contentIsBlank })?.content
    }

    /// Artifacts eligible for channel delivery: created by this run, backed by
    /// a real host file (not a directory), deduplicated by host path.
    static func replyArtifacts(
        _ artifacts: [SharedArtifact],
        createdAfter runStartedAt: Date
    ) -> [SharedArtifact] {
        var seenPaths = Set<String>()
        return artifacts.filter { artifact in
            guard artifact.createdAt >= runStartedAt,
                !artifact.isDirectory,
                !artifact.hostPath.isEmpty
            else { return false }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: artifact.hostPath, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { return false }
            return seenPaths.insert(artifact.hostPath).inserted
        }
    }

    // MARK: - Activity log (auto-reply egress)

    /// One auto-reply about to leave this Mac. Resolves the connection and
    /// attribution up-front; `finish` writes the Insights row once.
    struct ReplyActivity: Sendable {
        let connection: AgentChannelConnection?
        let connectionId: String
        let roomId: String
        let threadId: String?
        let attribution: InsightsService.ActivityAttribution
        let started = Date()

        func finish(contentLength: Int, outcome: String, error: String?, extraDetails: [String: String]) {
            ChannelActivityLogger.logDelivery(
                connection: connection,
                connectionId: connectionId,
                roomId: roomId,
                threadId: threadId,
                contentLength: contentLength,
                outcome: outcome,
                trigger: .autoReply,
                error: error,
                durationMs: Date().timeIntervalSince(started) * 1000,
                attribution: attribution,
                source: .channel,
                extraDetails: extraDetails
            )
        }
    }

    static func replyActivity(
        for request: AgentChannelInboundRelayRequest,
        agentId: UUID?,
        sessionId: UUID,
        connection: AgentChannelConnection? = nil
    ) -> ReplyActivity {
        let resolved = connection
            ?? (try? AgentChannelConnectionService.shared.resolvedConnectionView(id: request.connectionId))
        return ReplyActivity(
            connection: resolved,
            connectionId: request.connectionId,
            roomId: request.providerRoute.conversationId,
            threadId: request.providerRoute.threadId,
            attribution: InsightsService.ActivityAttribution(agentId: agentId, sessionId: sessionId)
        )
    }

    private func recordFailure(
        _ request: AgentChannelInboundRelayRequest,
        agentId: UUID?,
        sessionId: UUID,
        code: AgentChannelFailureCode,
        message: String
    ) async {
        await auditLog.record(
            AgentChannelAuditEvent(
                kind: .taskFailed,
                status: .failed,
                connectionId: request.connectionId,
                agentId: agentId,
                sessionId: sessionId,
                auditKey: request.providerEventId,
                failure: AgentChannelFailure(
                    code: code,
                    message: message,
                    retryable: code == .providerUnavailable
                )
            )
        )
        await activityCenter.record(
            connectionId: request.connectionId,
            providerEventId: request.providerEventId,
            stage: .failed,
            reason: message
        )
    }
}
