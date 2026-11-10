//
//  WorkflowChannelReplier.swift
//  osaurus
//
//  How a workflow run talks back to the channel conversation that started
//  it. Prefers the live reply closure the platform handed the event layer
//  (`ChannelReplyRegistry`); after a relaunch, when no closure survives, it
//  posts through the connection service to the room recorded on the
//  caller, under the same write allowlists an agent's send obeys (files
//  only on iMessage and WhatsApp). A run that no message started has no
//  conversation, and says so instead of failing. A run posts at most
//  `ReplySpec.maximumRepliesPerRun` replies.
//

import Foundation

struct WorkflowChannelReplier: Sendable {

    /// What became of one message.
    struct Delivery: Sendable, Equatable {
        enum Path: String, Sendable {
            /// The platform's reply closure for the triggering message.
            case live
            /// The connection service, addressed by the recorded room.
            case connection
            case none
        }

        var sent: Bool
        var path: Path
        /// Why nothing was sent, as a stable code: `no_conversation`,
        /// `unsupported_on_<platform>`, `no_live_connection`, `reply_cap`,
        /// `send_failed`, `writes_paused`.
        var reason: String?
        /// The error text when the platform refused.
        var error: String?
        /// The text was cut to the channel's length cap.
        var truncated = false

        static let noConversation = Delivery(sent: false, path: .none, reason: "no_conversation")
        static let replyCap = Delivery(sent: false, path: .none, reason: "reply_cap")
    }

    /// The live sink for a run, if any.
    var resolveSink: @Sendable (_ runID: UUID, _ caller: WorkflowCaller) async -> ChannelReplyRegistry.Resolved?
    /// Posts `text` to the recorded room when no live sink exists.
    var sendThroughConnection: @Sendable (_ target: WorkflowChannelReplyTarget, _ text: String) async throws -> Void
    /// Notes that the run replied, so the automatic final post stands down.
    var markReplied: @Sendable (_ runID: UUID) async -> Void
    /// Sends a file to the recorded room when no live sink exists, on the
    /// platforms whose connection can (`connectionSendsFiles`).
    var sendAttachmentThroughConnection:
        @Sendable (_ target: WorkflowChannelReplyTarget, _ path: String, _ caption: String?) async throws -> Void =
            Self.liveAttachmentThroughConnection
    /// Replies the run has posted so far.
    var replyCount: @Sendable (_ runID: UUID) async -> Int = { runID in
        await MainActor.run { ChannelReplyRegistry.shared.replyCount(runID: runID) }
    }

    /// Platforms whose connection service sends files without the
    /// triggering message's reply closure.
    static func connectionSendsFiles(_ kind: AgentChannelKind) -> Bool {
        kind == .imessage || kind == .whatsapp
    }

    /// The Telegram message a fallback send threads under: the recorded
    /// thread id, when it is a message id.
    static func telegramReplyTo(_ target: WorkflowChannelReplyTarget) -> Int? {
        guard target.kind == .telegram else { return nil }
        return target.threadId.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static let live = WorkflowChannelReplier(
        resolveSink: { runID, caller in
            await MainActor.run {
                ChannelReplyRegistry.shared.resolve(
                    runID: runID, target: caller.channelReply, parentRunID: caller.parentRunID)
            }
        },
        sendThroughConnection: { target, text in
            let service = AgentChannelConnectionService.shared
            let sanitized = ChannelRemoteSafetyGate.sanitizeResult(ChannelRemoteResultPayload(text: text)).text
            switch target.kind {
            case .email:
                guard let threadId = target.threadId ?? target.conversationId.nonEmptyOrNil else {
                    throw WorkflowChannelReplyError.noRoute
                }
                _ = try await service.replyThread(
                    connectionId: target.connectionId, threadId: threadId, content: sanitized, confirmSend: true)
            case .discord, .slack:
                if let threadId = target.threadId {
                    _ = try await service.replyThread(
                        connectionId: target.connectionId, threadId: threadId, content: sanitized, confirmSend: true)
                } else {
                    _ = try await service.sendMessage(
                        connectionId: target.connectionId, roomId: target.conversationId, content: sanitized,
                        confirmSend: true)
                }
            case .telegram:
                _ = try await service.sendMessage(
                    connectionId: target.connectionId, roomId: target.conversationId, content: sanitized,
                    confirmSend: true, telegramReplyToMessageId: telegramReplyTo(target))
            case .imessage, .whatsapp, .n8n, .customHTTP:
                _ = try await service.sendMessage(
                    connectionId: target.connectionId, roomId: target.conversationId, content: sanitized,
                    confirmSend: true)
            }
        },
        markReplied: { runID in
            await MainActor.run { ChannelReplyRegistry.shared.markReplied(runID: runID) }
        }
    )

    private static let liveAttachmentThroughConnection:
        @Sendable (WorkflowChannelReplyTarget, String, String?) async throws -> Void = { target, path, caption in
            let service = AgentChannelConnectionService.shared
            let caption = caption?.nonEmptyOrNil.map {
                ChannelRemoteSafetyGate.sanitizeResult(ChannelRemoteResultPayload(text: $0)).text
            }
            switch target.kind {
            case .imessage:
                _ = try await service.imessageSendAttachment(
                    connectionId: target.connectionId, roomId: target.conversationId, path: path, confirmSend: true)
                if let caption {
                    _ = try await service.sendMessage(
                        connectionId: target.connectionId, roomId: target.conversationId, content: caption,
                        confirmSend: true)
                }
            case .whatsapp:
                _ = try await service.whatsappSendAttachment(
                    connectionId: target.connectionId, roomId: target.conversationId, path: path, caption: caption,
                    confirmSend: true)
            default:
                throw WorkflowChannelReplyError.noRoute
            }
        }

    /// Posts `text` into the run's conversation. `marksReplied` false keeps
    /// the rule's automatic final post (a relayed dialog question is not
    /// the workflow's answer) and does not count toward the reply cap.
    func send(
        _ text: String, runID: UUID, caller: WorkflowCaller, marksReplied: Bool = true,
        extraDetails: [String: String] = [:]
    ) async -> Delivery {
        let target = caller.channelReply
        let resolved = await resolveSink(runID, caller)
        guard resolved != nil || target != nil else { return .noConversation }
        if marksReplied, await reachedCap(runID: runID, resolved: resolved) { return .replyCap }
        let truncated = ChannelRemoteSafetyGate.sanitizeResult(ChannelRemoteResultPayload(text: text)).truncated
        if let resolved {
            var details = extraDetails
            details["workflow_run"] = runID.uuidString
            let delivered = await resolved.sink.deliverText(
                text, agentId: caller.agentID, sessionId: nil, extraDetails: details, trigger: .workflowReply)
            if let failure = delivered.failure {
                return Delivery(
                    sent: false, path: .live, reason: Self.reason(forFailure: failure), error: failure,
                    truncated: delivered.truncated)
            }
            if marksReplied { await noteReplied(resolved, runID: runID) }
            return Delivery(sent: true, path: .live, truncated: delivered.truncated)
        }
        guard let target else { return .noConversation }
        do {
            try await sendThroughConnection(target, text)
            if marksReplied { await markReplied(runID) }
            return Delivery(sent: true, path: .connection, truncated: truncated)
        } catch AgentChannelConnectionServiceError.globalWritesDisabled {
            return Delivery(
                sent: false, path: .connection, reason: "writes_paused", error: ChannelReplySink.writesPausedMessage)
        } catch {
            let message = error.localizedDescription
            return Delivery(sent: false, path: .connection, reason: Self.reason(forFailure: message), error: message)
        }
    }

    /// Sends the file at `path` into the run's conversation. A live sink
    /// carries it when the platform takes files (`unsupported_on_<platform>`
    /// otherwise). Without one, iMessage and WhatsApp send through the
    /// connection; other platforms report `no_live_connection`.
    func sendAttachment(
        path: String, caption: String?, runID: UUID, caller: WorkflowCaller, extraDetails: [String: String] = [:]
    ) async -> Delivery {
        let target = caller.channelReply
        let resolved = await resolveSink(runID, caller)
        guard resolved != nil || target != nil else { return .noConversation }
        if await reachedCap(runID: runID, resolved: resolved) { return .replyCap }
        guard let resolved else {
            guard let target else { return .noConversation }
            guard Self.connectionSendsFiles(target.kind) else {
                return Delivery(sent: false, path: .none, reason: "no_live_connection")
            }
            do {
                try await sendAttachmentThroughConnection(target, path, caption)
                await markReplied(runID)
                return Delivery(sent: true, path: .connection)
            } catch AgentChannelConnectionServiceError.globalWritesDisabled {
                return Delivery(
                    sent: false, path: .connection, reason: "writes_paused", error: ChannelReplySink.writesPausedMessage)
            } catch {
                let message = error.localizedDescription
                return Delivery(sent: false, path: .connection, reason: "send_failed", error: message)
            }
        }
        guard resolved.sink.supportsAttachments else {
            let platform = target?.kind.rawValue ?? "channel"
            return Delivery(sent: false, path: .live, reason: "unsupported_on_\(platform)")
        }
        var details = extraDetails
        details["workflow_run"] = runID.uuidString
        let failure = await resolved.sink.sendAttachment(
            path: path, caption: caption, agentId: caller.agentID, sessionId: nil, extraDetails: details,
            trigger: .workflowReply)
        if let failure {
            return Delivery(sent: false, path: .live, reason: Self.reason(forFailure: failure), error: failure)
        }
        await noteReplied(resolved, runID: runID)
        return Delivery(sent: true, path: .live)
    }

    /// The run, or the run it speaks for, already posted the most replies
    /// one run may.
    private func reachedCap(runID: UUID, resolved: ChannelReplyRegistry.Resolved?) async -> Bool {
        if await replyCount(runID) >= ReplySpec.maximumRepliesPerRun { return true }
        guard let resolved, resolved.speaksForOwner, resolved.ownerRunID != runID else { return false }
        return await replyCount(resolved.ownerRunID) >= ReplySpec.maximumRepliesPerRun
    }

    /// The run replied, and so did the run that registered the sink when
    /// it is this run's parent.
    private func noteReplied(_ resolved: ChannelReplyRegistry.Resolved, runID: UUID) async {
        await markReplied(runID)
        if resolved.speaksForOwner, resolved.ownerRunID != runID { await markReplied(resolved.ownerRunID) }
    }

    private static func reason(forFailure message: String) -> String {
        message == ChannelReplySink.writesPausedMessage ? "writes_paused" : "send_failed"
    }
}

enum WorkflowChannelReplyError: Error, LocalizedError {
    case noRoute

    var errorDescription: String? {
        switch self {
        case .noRoute: return L("The conversation to reply to is no longer known.")
        }
    }
}
