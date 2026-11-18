//
//  ChannelReplySink.swift
//  osaurus
//
//  Where a channel-triggered result goes back to: the provider's reply
//  closure for the conversation the message came from. Every send passes
//  the remote-result sanitizer and writes a channel-delivery activity row,
//  the same as an agent auto-reply. Attachments go through the provider's
//  attachment responder when it has one (iMessage, WhatsApp).
//

import Foundation

struct ChannelReplySink: Sendable {
    var connectionId: String
    var providerRoute: AgentChannelProviderRoute
    var reply: AgentChannelInboundReplyHandler
    var replyAttachment: AgentChannelInboundAttachmentReplyHandler? = nil
    var writeGate: ChannelWriteKillSwitch = .shared

    /// Whether this conversation can take a file.
    var supportsAttachments: Bool { replyAttachment != nil }

    static var writesPausedMessage: String {
        L("Sending is paused: Allow Agents to Send Messages is off in Channels.")
    }

    /// One text send: the error message on failure, and whether the text
    /// was cut to the channel's length cap.
    struct Delivered: Sendable, Equatable {
        var failure: String?
        var truncated: Bool
    }

    /// Sends `text` (sanitized, length-capped) and logs the delivery.
    /// Returns the error message on failure, including when the global
    /// write switch is off (nothing is sent then).
    @discardableResult
    func send(
        _ text: String, agentId: UUID?, sessionId: UUID?, extraDetails: [String: String] = [:],
        trigger: ChannelActivityLogger.Trigger = .autoReply
    ) async -> String? {
        await deliverText(text, agentId: agentId, sessionId: sessionId, extraDetails: extraDetails, trigger: trigger)
            .failure
    }

    /// `send`, also saying whether the text was truncated.
    func deliverText(
        _ text: String, agentId: UUID?, sessionId: UUID?, extraDetails: [String: String] = [:],
        trigger: ChannelActivityLogger.Trigger = .autoReply
    ) async -> Delivered {
        let sanitized = ChannelRemoteSafetyGate.sanitizeResult(ChannelRemoteResultPayload(text: text))
        var details = extraDetails
        details["redacted"] = sanitized.redacted ? "true" : "false"
        details["truncated"] = sanitized.truncated ? "true" : "false"
        let failure = await deliver(
            contentLength: sanitized.text.utf8.count, agentId: agentId, sessionId: sessionId, details: details,
            trigger: trigger
        ) {
            try await reply(sanitized.text)
        }
        return Delivered(failure: failure, truncated: sanitized.truncated)
    }

    /// Sends the file at `path` (a trusted host path inside the run's
    /// folders) with an optional caption, and logs the delivery. Returns
    /// the error message on failure; `nil` responder is reported as such.
    @discardableResult
    func sendAttachment(
        path: String, caption: String?, agentId: UUID?, sessionId: UUID?, extraDetails: [String: String] = [:],
        trigger: ChannelActivityLogger.Trigger = .autoReply
    ) async -> String? {
        guard let replyAttachment else {
            return L("This channel cannot take file attachments.")
        }
        let sanitizedCaption = caption.map {
            ChannelRemoteSafetyGate.sanitizeResult(ChannelRemoteResultPayload(text: $0)).text
        }
        var details = extraDetails
        details["attachment"] = "true"
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return await deliver(
            contentLength: size, agentId: agentId, sessionId: sessionId, details: details, trigger: trigger
        ) {
            try await replyAttachment(path, sanitizedCaption)
        }
    }

    private func deliver(
        contentLength: Int, agentId: UUID?, sessionId: UUID?, details: [String: String],
        trigger: ChannelActivityLogger.Trigger, _ body: @Sendable () async throws -> Void
    ) async -> String? {
        let connection = try? AgentChannelConnectionService.shared.resolvedConnectionView(id: connectionId)
        let attribution = InsightsService.ActivityAttribution(agentId: agentId, sessionId: sessionId)
        let started = Date()
        var details = details
        var failure: String?
        var outcome = "replied"
        if writeGate.snapshot().writeEnabled {
            do {
                try await body()
            } catch {
                failure = error.localizedDescription
                outcome = "failed"
            }
        } else {
            failure = Self.writesPausedMessage
            outcome = "blocked"
            details["reason"] = AgentChannelInboundRelay.globalWritesDisabledReason
        }
        ChannelActivityLogger.logDelivery(
            connection: connection,
            connectionId: connectionId,
            roomId: providerRoute.conversationId,
            threadId: providerRoute.threadId,
            contentLength: contentLength,
            outcome: outcome,
            trigger: trigger,
            error: failure,
            durationMs: Date().timeIntervalSince(started) * 1000,
            attribution: attribution,
            source: .channel,
            extraDetails: details
        )
        return failure
    }
}
