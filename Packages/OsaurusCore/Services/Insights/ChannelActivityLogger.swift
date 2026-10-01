//
//  ChannelActivityLogger.swift
//  osaurus
//
//  Activity-log rows for messages that leave this Mac through an Agent
//  Channel — both proactive publishes (`AgentChannelPublishService`) and
//  reactive auto-replies to inbound messages (`AgentChannelInboundRelay`).
//  Both paths build their row here so a reviewer sees one shape.
//
//  Metadata only: provider kind, destination host, room/thread, size and
//  outcome. The message text itself lives in the channel audit ledger.
//

import Foundation

enum ChannelActivityLogger {

    /// Why the message was sent.
    enum Trigger: String, Sendable {
        /// Agent/tool-initiated publish through the outbox.
        case publish
        /// Reply to an inbound channel message (auto-reply).
        case autoReply = "auto_reply"
    }

    /// Bare host the provider API lives on; nil when the hop stays on this
    /// Mac (iMessage via Messages.app) or the kind is unknown.
    static func destinationHost(for connection: AgentChannelConnection?) -> String? {
        switch connection?.kind {
        case .discord: return "discord.com"
        case .slack: return "slack.com"
        case .telegram: return "api.telegram.org"
        case .whatsapp: return "graph.facebook.com"
        case .imessage: return nil
        case .n8n: return EgressInfo.host(from: connection?.n8n?.outbound.webhookURL)
        case .customHTTP: return EgressInfo.host(from: connection?.customHTTP?.baseURL)
        case nil: return nil
        }
    }

    static func destinationLabel(for connection: AgentChannelConnection?, fallback: String) -> String {
        switch connection?.kind {
        case .discord: return "Discord"
        case .slack: return "Slack"
        case .telegram: return "Telegram"
        case .whatsapp: return "WhatsApp"
        case .imessage: return "iMessage"
        case .n8n: return "n8n"
        case .customHTTP: return connection?.name ?? L("Custom HTTP channel")
        case nil: return connection?.name ?? fallback
        }
    }

    /// iMessage is delivered by Messages.app on this Mac; everything else
    /// is a network hop to the provider.
    static func locality(for connection: AgentChannelConnection?) -> DataLocality {
        connection?.kind == .imessage ? .local : .remote
    }

    static func egress(
        connection: AgentChannelConnection?,
        connectionId: String,
        roomId: String,
        threadId: String?,
        contentLength: Int,
        outcome: String,
        trigger: Trigger,
        extraDetails: [String: String] = [:]
    ) -> EgressInfo {
        var details: [String: String] = [
            "channel": connection?.kind.rawValue ?? "unknown",
            "connection": connection?.name ?? connectionId,
            "room": roomId,
            "outcome": outcome,
            "content_length": String(contentLength),
            "trigger": trigger.rawValue,
        ]
        if let threadId, !threadId.isEmpty { details["thread"] = threadId }
        for (key, value) in extraDetails { details[key] = value }
        var classes = ["channel_message"]
        if let sent = extraDetails["artifacts_sent"].flatMap(Int.init), sent > 0 {
            classes.append("attachments")
        }
        return EgressInfo(
            destinationLabel: destinationLabel(for: connection, fallback: connectionId),
            destinationHost: destinationHost(for: connection),
            bytesSent: contentLength,
            dataClasses: classes,
            details: details
        )
    }

    /// Write one `channelDelivery` row.
    static func logDelivery(
        connection: AgentChannelConnection?,
        connectionId: String,
        roomId: String,
        threadId: String?,
        contentLength: Int,
        outcome: String,
        trigger: Trigger,
        error: String?,
        durationMs: Double,
        attribution: InsightsService.ActivityAttribution,
        source: RequestSource,
        extraDetails: [String: String] = [:]
    ) {
        var details = extraDetails
        if let error { details["error"] = error }
        let egress = egress(
            connection: connection,
            connectionId: connectionId,
            roomId: roomId,
            threadId: threadId,
            contentLength: contentLength,
            outcome: outcome,
            trigger: trigger,
            extraDetails: details
        )
        InsightsService.logEgress(
            category: .channelDelivery,
            source: source,
            method: trigger == .publish ? "PUBLISH" : "REPLY",
            path: "/channels/\(connectionId)/\(roomId)",
            statusCode: error == nil ? 200 : 502,
            durationMs: durationMs,
            egress: egress,
            locality: locality(for: connection),
            errorMessage: error,
            attribution: attribution
        )
    }
}
