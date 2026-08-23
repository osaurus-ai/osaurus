//
//  AgentChannelInboundRelay.swift
//  osaurus
//
//  Provider-neutral bridge from verified channel messages to headless agents.
//

import Foundation

typealias AgentChannelInboundReplyHandler = @Sendable (String) async throws -> Void

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
    var settings: AgentChannelInboundDispatchConfiguration
    var sourceLabel: String
    var reply: AgentChannelInboundReplyHandler?
    var replyAttachment: AgentChannelInboundAttachmentReplyHandler?

    init(
        identity: ChannelIdentity,
        connectionId: String,
        providerEventId: String,
        providerRoute: AgentChannelProviderRoute,
        content: String,
        attachments: [AgentChannelStoredAttachment] = [],
        settings: AgentChannelInboundDispatchConfiguration,
        sourceLabel: String,
        reply: AgentChannelInboundReplyHandler? = nil,
        replyAttachment: AgentChannelInboundAttachmentReplyHandler? = nil
    ) {
        self.identity = identity
        self.connectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerEventId = providerEventId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerRoute = providerRoute
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.attachments = attachments
        self.settings = settings
        self.sourceLabel = sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reply = reply
        self.replyAttachment = replyAttachment
    }
}

enum AgentChannelInboundRelaySubmission: Equatable, Sendable {
    /// The message was handed to `agentId`; `rule` is the matched routing
    /// rule ("alias:<alias>", "room:<roomId>", or "default") for telemetry.
    case dispatched(agentId: UUID, rule: String)
    case suppressed(String)

    var dispatchAttempted: Int {
        if case .dispatched = self { return 1 }
        return 0
    }

    var dispatchSuppressed: Int {
        if case .dispatched = self { return 0 }
        return 1
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
    private var activePartitions = Set<String>()

    init(
        substrate: AgentChannelAsyncSubstrate = .shared,
        safetyGate: ChannelRemoteSafetyGate = .shared,
        auditLog: AgentChannelAuditLog = .shared,
        taskManager: BackgroundTaskManager = .shared,
        activityCenter: AgentChannelInboundActivityCenter = .shared
    ) {
        self.substrate = substrate
        self.safetyGate = safetyGate
        self.auditLog = auditLog
        self.taskManager = taskManager
        self.activityCenter = activityCenter
    }

    func submit(_ request: AgentChannelInboundRelayRequest) async -> AgentChannelInboundRelaySubmission {
        guard request.settings.enabled else {
            return .suppressed("inbound_dispatch_disabled")
        }
        guard let resolution = AgentChannelDispatchRouter.resolve(
            settings: request.settings,
            roomId: request.providerRoute.conversationId,
            content: request.content
        ) else {
            return .suppressed("no_route_matched")
        }
        let agentId = resolution.agentId
        guard let agent = AgentManager.shared.agent(for: agentId),
              !agent.isBuiltIn
        else {
            return .suppressed("inbound_agent_unavailable")
        }
        let content = resolution.content
        guard (!content.isEmpty || !request.attachments.isEmpty),
              !request.connectionId.isEmpty,
              !request.providerEventId.isEmpty,
              !request.providerRoute.conversationId.isEmpty
        else {
            return .suppressed("invalid_dispatch_payload")
        }

        let partition = substrate.makeSessionPartition(
            agentId: agentId,
            connectionId: request.connectionId,
            providerRoute: request.providerRoute
        )
        guard activePartitions.insert(partition.externalSessionKey).inserted else {
            return .suppressed("conversation_already_running")
        }

        let safety = await safetyGate.authorize(
            ChannelRemoteSafetyRequest(
                identity: request.identity,
                action: .dispatch,
                content: content,
                taskId: request.providerEventId
            )
        )
        guard safety.allowed else {
            activePartitions.remove(partition.externalSessionKey)
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
            return .suppressed(safety.reason.rawValue)
        }

        let prompt = ChannelRemoteSafetyGate.wrapUntrustedContent(
            content + Self.attachmentContext(request.attachments),
            source: request.sourceLabel,
            assessment: safety.contentAssessment
        )
        await auditLog.record(
            AgentChannelAuditEvent(
                kind: .dispatchStarted,
                status: .dispatched,
                connectionId: request.connectionId,
                agentId: agentId,
                sessionId: partition.sessionId,
                auditKey: request.providerEventId,
                metadata: [
                    "conversation_hash": partition.conversationHash,
                    "external_session_key": partition.externalSessionKey,
                    "dispatch_rule": resolution.matchedRule,
                ]
            )
        )

        Task { @MainActor [weak self] in
            await self?.run(
                request,
                agentId: agentId,
                partition: partition,
                prompt: prompt
            )
        }
        return .dispatched(agentId: agentId, rule: resolution.matchedRule)
    }

    private func run(
        _ request: AgentChannelInboundRelayRequest,
        agentId: UUID,
        partition: AgentChannelSessionPartition,
        prompt: String
    ) async {
        defer {
            activePartitions.remove(partition.externalSessionKey)
            Task {
                await safetyGate.finishRemoteTask(
                    identity: request.identity,
                    taskId: request.providerEventId
                )
            }
        }

        // Artifacts created before this run belong to earlier turns of a
        // reused channel session and must not be re-sent with this reply.
        let runStartedAt = Date()

        let taskId: UUID
        if let replyableId = taskManager.replyableTaskId(
            source: .channel,
            externalSessionKey: partition.externalSessionKey,
            agentId: agentId
        ), taskManager.submitQuickReply(replyableId, text: prompt) {
            taskId = replyableId
            try? await Task.sleep(for: .milliseconds(100))
        } else {
            let dispatch = DispatchRequest(
                id: partition.sessionId,
                prompt: prompt,
                agentId: agentId,
                title: request.providerRoute.displayName ?? "Channel conversation",
                // Channel turns surface in the notch like any other background
                // work so the user can watch (and cancel) remote-triggered runs.
                showToast: true,
                source: .channel,
                externalSessionKey: partition.externalSessionKey,
                // Plugin tools are deferred behind `capabilities_load`, and a
                // channel dispatch starts each message with an empty
                // loaded-tools set. Pre-load the agent's granted plugin tools
                // so calendar/mail/etc. work without the model having to
                // discover and load them itself every turn (#2443).
                requestedToolNames: Self.preloadedPluginToolNames(
                    registered: ToolRegistry.shared.registeredPluginToolNames,
                    granted: AgentManager.shared.effectiveEnabledToolNames(for: agentId)
                ),
                externalSurface: true,
                loadIntent: .background
            )
            guard let handle = await taskManager.dispatchChat(dispatch) else {
                await recordFailure(
                    request,
                    agentId: agentId,
                    sessionId: partition.sessionId,
                    code: .dispatchUnavailable,
                    message: "The selected agent could not accept this channel message."
                )
                return
            }
            taskId = handle.id
        }

        let terminal = await waitForReply(taskId: taskId, runStartedAt: runStartedAt)
        switch terminal {
        case .reply(let text, let awaitingClarification, let artifacts):
            guard request.settings.autoReplyEnabled, let responder = request.reply else {
                await auditLog.record(
                    AgentChannelAuditEvent(
                        kind: .taskCompleted,
                        status: awaitingClarification ? .awaitingClarification : .completed,
                        connectionId: request.connectionId,
                        agentId: agentId,
                        sessionId: taskId,
                        auditKey: request.providerEventId,
                        metadata: ["auto_reply": "disabled"]
                    )
                )
                await activityCenter.record(
                    connectionId: request.connectionId,
                    providerEventId: request.providerEventId,
                    stage: .agentReplied,
                    reason: Self.autoReplyDisabledReason
                )
                return
            }
            let sanitized = ChannelRemoteSafetyGate.sanitizeResult(
                ChannelRemoteResultPayload(text: text)
            )
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
            } catch {
                await recordFailure(
                    request,
                    agentId: agentId,
                    sessionId: taskId,
                    code: .providerUnavailable,
                    message: error.localizedDescription
                )
            }
        case .failed(let message):
            await recordFailure(
                request,
                agentId: agentId,
                sessionId: taskId,
                code: .internalFailure,
                message: message
            )
        }
    }

    /// Plugin tools to pre-load into a channel-dispatched session. `granted`
    /// is the agent's manual-selection allowlist; `nil` means the agent uses
    /// the global enabled registry, so every registered plugin tool applies.
    /// Sorted so successive dispatches into a reattached session append a
    /// stable set.
    nonisolated static func preloadedPluginToolNames(
        registered: Set<String>,
        granted: [String]?
    ) -> [String] {
        guard let granted else { return registered.sorted() }
        return registered.intersection(granted).sorted()
    }

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
        return "\n\nAttachments supplied by the channel (untrusted metadata):\n"
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

    private func waitForReply(taskId: UUID, runStartedAt: Date) async -> TerminalReply {
        let deadline = Date().addingTimeInterval(Self.maxReplyWait)
        while !Task.isCancelled {
            if Date() >= deadline {
                taskManager.cancelTask(taskId)
                return .failed("The channel task timed out before producing a reply.")
            }
            guard let state = taskManager.taskState(for: taskId) else {
                if let stored = ChatSessionStore.load(id: taskId),
                   let text = stored.turns.last(where: {
                       $0.role == .assistant
                           && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   })?.content {
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
                if let text = state.chatSession?.turns.last(where: {
                    $0.role == .assistant
                        && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })?.content {
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

    private func recordFailure(
        _ request: AgentChannelInboundRelayRequest,
        agentId: UUID,
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
