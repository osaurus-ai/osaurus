//
//  AgentChannelStatusPresentation.swift
//  osaurus
//
//  Human-readable presentation for Agent Channel diagnostics status codes
//  and receive-transport health states.
//

import Foundation

/// Visual tone for a channel status, mapped to theme colors in the view layer.
enum AgentChannelStatusTone: Equatable, Sendable {
    case neutral
    case success
    case warning
    case error
}

/// A localized, human-readable label plus tone for a machine status code.
///
/// Provider diagnostics report codes like `connected_needs_allowlist` and the
/// transport health center reports enum states like `.degraded`. Users should
/// never have to read those raw values, so every UI surface renders statuses
/// through this mapping instead.
struct AgentChannelStatusPresentation: Equatable, Sendable {
    let label: String
    let tone: AgentChannelStatusTone
    /// False when the status code was unknown and `label` is the raw code.
    let isRecognized: Bool

    init(label: String, tone: AgentChannelStatusTone, isRecognized: Bool = true) {
        self.label = label
        self.tone = tone
        self.isRecognized = isRecognized
    }
}

extension AgentChannelStatusPresentation {
    /// Present a provider diagnostics status code (Discord, Slack, Telegram,
    /// custom). Unknown codes fall back to the raw code with a neutral tone so
    /// new backend statuses degrade gracefully instead of crashing or hiding.
    static func diagnostics(status code: String) -> AgentChannelStatusPresentation {
        switch code {
        case "not_configured":
            return .init(label: L("Not configured"), tone: .neutral)
        case "configured":
            return .init(label: L("Configured"), tone: .success)
        case "token_invalid_or_unavailable":
            return .init(
                label: L("Bot token rejected or unavailable"),
                tone: .error
            )
        case "connected_team_not_allowlisted":
            return .init(
                label: L("Connected — the bot's workspace is not in the workspace allowlist"),
                tone: .warning
            )
        case "connected_needs_allowlist":
            return .init(
                label: L("Connected — add readable channel or chat IDs to finish setup"),
                tone: .warning
            )
        case "connected_receive_needs_sender_allowlist":
            return .init(
                label: L("Connected — add authorized sender IDs to enable receive"),
                tone: .warning
            )
        case "connected_read_only_write_needs_channels":
            return .init(
                label: L("Connected — writes are on but no writable channels are allowlisted"),
                tone: .warning
            )
        case "connected_read_only_write_needs_chats":
            return .init(
                label: L("Connected — writes are on but no writable chats are allowlisted"),
                tone: .warning
            )
        case "connected_long_poll_webhook_conflict":
            return .init(
                label: L("Connected — a registered webhook is blocking long polling"),
                tone: .error
            )
        case "connected_read_write":
            return .init(label: L("Connected — reads and writes enabled"), tone: .success)
        case "connected_read_only":
            return .init(label: L("Connected — read-only"), tone: .success)
        default:
            return .init(label: code, tone: .neutral, isRecognized: false)
        }
    }

    /// Present a receive-transport health status (Socket Mode, long polling).
    static func transport(status: AgentChannelTransportHealthStatus) -> AgentChannelStatusPresentation {
        switch status {
        case .disabled:
            return .init(label: L("Off"), tone: .neutral)
        case .idle:
            return .init(label: L("Idle"), tone: .neutral)
        case .healthy:
            return .init(label: L("Healthy"), tone: .success)
        case .degraded:
            return .init(label: L("Backing off"), tone: .warning)
        case .conflict:
            return .init(label: L("Conflict"), tone: .error)
        case .failed:
            return .init(label: L("Failed"), tone: .error)
        }
    }

    /// Shown when a transport has published no health state this session.
    static var transportNotRunning: AgentChannelStatusPresentation {
        .init(label: L("Not running"), tone: .neutral)
    }
}
