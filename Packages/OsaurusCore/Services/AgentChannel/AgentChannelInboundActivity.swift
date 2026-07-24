//
//  AgentChannelInboundActivity.swift
//  osaurus
//
//  Per-event inbound stage telemetry for Agent Channel receive transports.
//
//  Transport health answers "is the connection alive"; this answers "what
//  happened to the message I just sent". Each inbound provider event leaves a
//  short trail of stage records (received → stored → dispatched → replied, or
//  the rejection/suppression reason at the boundary that stopped it) so the
//  settings UI can point at the exact failing stage instead of a generic
//  "connected" status. Records carry provider event ids and machine reasons
//  only — never message content, sender text, or secrets.
//

import Foundation

enum AgentChannelInboundActivityStage: String, Codable, CaseIterable, Sendable {
    /// The transport received a provider event envelope.
    case received
    /// Normalization or authorization refused the event before storage.
    case rejected
    /// The message was verified and stored; dispatch decision pending.
    case stored
    /// The relay declined to start an agent turn (reason attached).
    case dispatchSuppressed = "dispatch_suppressed"
    /// The message was handed to the configured agent.
    case dispatched
    /// The agent produced a reply but auto-reply is off, so it stays local.
    case agentReplied = "agent_replied"
    /// The agent's reply was posted back to the channel.
    case replySent = "reply_sent"
    /// Dispatch, the agent turn, or the reply post failed.
    case failed
}

struct AgentChannelInboundActivityEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let connectionId: String
    let providerEventId: String
    let stage: AgentChannelInboundActivityStage
    let reason: String?
    let recordedAt: Date

    init(
        connectionId: String,
        providerEventId: String,
        stage: AgentChannelInboundActivityStage,
        reason: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = UUID()
        self.connectionId = AgentChannelConnection.normalizedId(connectionId)
        self.providerEventId = providerEventId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stage = stage
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = (trimmedReason?.isEmpty ?? true) ? nil : trimmedReason
        self.recordedAt = recordedAt
    }
}

/// In-memory ring of recent inbound stage records per connection. Session
/// scoped by design, like `AgentChannelTransportHealthCenter`.
actor AgentChannelInboundActivityCenter {
    static let shared = AgentChannelInboundActivityCenter()
    static let maxEventsPerConnection = 100

    private var eventsByConnection: [String: [AgentChannelInboundActivityEvent]] = [:]

    @discardableResult
    func record(
        connectionId: String,
        providerEventId: String,
        stage: AgentChannelInboundActivityStage,
        reason: String? = nil,
        at recordedAt: Date = Date()
    ) -> AgentChannelInboundActivityEvent {
        let event = AgentChannelInboundActivityEvent(
            connectionId: connectionId,
            providerEventId: providerEventId,
            stage: stage,
            reason: reason,
            recordedAt: recordedAt
        )
        var rows = eventsByConnection[event.connectionId] ?? []
        rows.append(event)
        if rows.count > Self.maxEventsPerConnection {
            rows.removeFirst(rows.count - Self.maxEventsPerConnection)
        }
        eventsByConnection[event.connectionId] = rows
        return event
    }

    /// Newest-first recent records for a connection.
    func recent(connectionId: String, limit: Int = 20) -> [AgentChannelInboundActivityEvent] {
        let normalized = AgentChannelConnection.normalizedId(connectionId)
        let rows = eventsByConnection[normalized] ?? []
        return Array(rows.suffix(max(0, limit)).reversed())
    }

    /// Records newer than `since`, oldest first. Used by the settings
    /// verifier to watch a fresh test message travel through the stages.
    func events(connectionId: String, since: Date) -> [AgentChannelInboundActivityEvent] {
        let normalized = AgentChannelConnection.normalizedId(connectionId)
        return (eventsByConnection[normalized] ?? []).filter { $0.recordedAt > since }
    }

    func clear(connectionId: String) {
        eventsByConnection.removeValue(forKey: AgentChannelConnection.normalizedId(connectionId))
    }
}

/// Pure stage/reason → user-facing text mapping so the settings UI and the
/// verifier report actionable recovery steps instead of machine codes.
enum AgentChannelInboundActivityPresentation {
    static func label(for stage: AgentChannelInboundActivityStage) -> String {
        switch stage {
        case .received:
            return L("Event received")
        case .rejected:
            return L("Rejected before storage")
        case .stored:
            return L("Stored")
        case .dispatchSuppressed:
            return L("Not sent to an agent")
        case .dispatched:
            return L("Sent to the agent")
        case .agentReplied:
            return L("Agent replied (auto-reply off)")
        case .replySent:
            return L("Reply posted to the channel")
        case .failed:
            return L("Failed")
        }
    }

    /// Actionable recovery guidance for a machine reason, or nil when the
    /// stage is self-explanatory.
    static func guidance(stage: AgentChannelInboundActivityStage, reason: String?) -> String? {
        switch reason {
        case "sender_not_allowlisted", "sender_not_authorized":
            return L("The sender is not in the Authorized Senders list. Add them in the channel settings.")
        case "channel_not_readable", "room_not_allowlisted":
            return L("The channel is not in the readable allowlist. Enable Read for it in the channel settings.")
        case "team_not_allowlisted", "space_not_allowlisted":
            return L("The workspace is not allowlisted. Select it in the channel settings and save.")
        case "bot_identity_unknown":
            return L("Osaurus has not confirmed the bot identity yet. Run Test Connection once.")
        case "own_message", "self_message":
            return L("Osaurus ignores the bot's own messages.")
        case "duplicate_event", "duplicate_event_acknowledge_without_dispatch",
             "duplicate_message_acknowledge_without_dispatch":
            return L("This event was already processed; the provider redelivered it.")
        case "not_a_channel_message":
            return L("The event was not a plain channel message (edits, joins, and system events are ignored).")
        case "undecodable_envelope":
            return L("The provider sent an envelope Osaurus could not decode.")
        case "mention_required":
            return L("Mentions are required to start a conversation. Mention the bot user (not the Osaurus agent name) in your message.")
        case "inbound_dispatch_disabled", "inbound_dispatch_not_configured":
            return L("Dispatch to an agent is turned off. Enable it and pick an agent in the channel settings.")
        case "inbound_agent_unavailable":
            return L("The selected agent no longer exists. Pick a different agent in the channel settings.")
        case "conversation_already_running":
            return L("This conversation already has an agent turn in flight; the message will need to be re-sent once it finishes.")
        case "invalid_dispatch_payload":
            return L("The message had no usable content to dispatch.")
        case "rate_limited":
            return L("Inbound handling is rate limited right now. Wait a moment and try again.")
        default:
            if stage == .failed, let reason, !reason.isEmpty {
                return reason
            }
            return nil
        }
    }
}
