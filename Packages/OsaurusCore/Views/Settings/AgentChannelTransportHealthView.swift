//
//  AgentChannelTransportHealthView.swift
//  osaurus
//
//  Inline receive-transport health for native Agent Channel settings.
//

import SwiftUI

/// Shows the live health of a receive transport runtime (Slack Socket Mode,
/// Telegram long polling) inside the channel's settings pane, so users can
/// tell whether receive is running, failed, backing off, or in conflict
/// without calling the diagnostics tool.
struct AgentChannelTransportHealthView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let connectionId: String
    let transportId: String
    let title: String
    /// Shown when the runtime has not published any state this session.
    let notRunningHint: String
    /// Bump from the parent (save/test actions) to re-fetch the health state.
    var refreshToken: Int = 0

    @State private var state: AgentChannelTransportHealthState?
    @State private var isRefreshing = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                AgentChannelStatusBadge(presentation: statusPresentation)
                Spacer(minLength: 0)
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .glyphSize(11, weight: .medium)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.text.secondary)
                .disabled(isRefreshing)
                .help(Text("Refresh receive status", bundle: .module))
            }

            if let state {
                Text(state.summary)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = state.detail, !detail.isEmpty {
                    Text(detail)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(
                            state.severity == .info ? theme.text.tertiary : theme.status.warning.foreground
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                metricsRow(state)
            } else {
                Text(LocalizedStringKey(notRunningHint), bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.control)
        .task(id: refreshToken) {
            await refresh()
        }
    }

    @ViewBuilder
    private func metricsRow(_ state: AgentChannelTransportHealthState) -> some View {
        let parts = Self.metrics(for: state, now: Date())
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func metrics(for state: AgentChannelTransportHealthState, now: Date) -> [String] {
        var parts: [String] = []
        if let lastSuccessAt = state.lastSuccessAt {
            parts.append("last success \(Self.relative(lastSuccessAt, now: now))")
        }
        if let lastFailureAt = state.lastFailureAt {
            parts.append("last failure \(Self.relative(lastFailureAt, now: now))")
        }
        if state.consecutiveFailures > 0 {
            parts.append("failures \(state.consecutiveFailures)")
        }
        if let nextRetryAt = state.nextRetryAt, nextRetryAt > now {
            parts.append("next retry \(Self.relative(nextRetryAt, now: now))")
        }
        if state.lastReceivedCount > 0 || state.lastStoredCount > 0 {
            parts.append("received \(state.lastReceivedCount), stored \(state.lastStoredCount)")
        }
        if state.dispatchAttemptedCount > 0 || state.dispatchSuppressedCount > 0 {
            parts.append(
                "dispatched \(state.dispatchAttemptedCount), suppressed \(state.dispatchSuppressedCount)"
            )
        }
        return parts
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private var statusPresentation: AgentChannelStatusPresentation {
        guard let state else { return .transportNotRunning }
        return .transport(status: state.status)
    }

    private var statusColor: Color {
        statusPresentation.tone.color(theme)
    }

    @discardableResult
    func refresh() async -> AgentChannelTransportHealthState? {
        isRefreshing = true
        defer { isRefreshing = false }
        let refreshed = await AgentChannelTransportHealthCenter.shared.state(
            connectionId: connectionId,
            transportId: transportId
        )
        state = refreshed
        return refreshed
    }
}

/// Recent per-event inbound stages (received → stored → dispatched → replied,
/// or the exact rejection/suppression boundary) so users can see what
/// happened to the message they just sent instead of a generic "connected".
struct AgentChannelInboundActivityListView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let connectionId: String
    let emptyHint: String
    var limit: Int = 8
    /// Bump from the parent to re-fetch the activity records.
    var refreshToken: Int = 0

    @State private var events: [AgentChannelInboundActivityEvent] = []
    /// The newest messages in this connection's local inbox (what agent read
    /// tools see).
    @State private var messages: [AgentChannelInboxMessage] = []

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent incoming events", bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)

            if events.isEmpty {
                Text(LocalizedStringKey(emptyHint), bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(events) { event in
                    eventRow(event)
                }
            }

            if !messages.isEmpty {
                Text("Recent Messages", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                    .padding(.top, theme.space.s6)
                VStack(spacing: 0) {
                    ForEach(messages) { message in
                        AgentChannelInboxMessageRow(message: message)
                        if message.id != messages.last?.id { Divider() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
            }
        }
        .task(id: refreshToken) {
            events = await AgentChannelInboundActivityCenter.shared.recent(
                connectionId: connectionId,
                limit: limit
            )
            messages =
                (try? AgentChannelAuditWorkbenchService().snapshot(
                    connectionId: connectionId, messageLimit: 5, auditLimit: 0
                ).messages) ?? []
        }
    }

    private func eventRow(_ event: AgentChannelInboundActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(for: event.stage))
                    .glyphSize(9, weight: .semibold)
                    .foregroundColor(Self.tone(for: event.stage).color(theme))
                    .frame(width: 14)
                Text(AgentChannelInboundActivityPresentation.label(for: event.stage))
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.primary)
                Spacer(minLength: 6)
                Text(event.recordedAt, style: .time)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }
            if let guidance = AgentChannelInboundActivityPresentation.guidance(
                stage: event.stage,
                reason: event.reason
            ) {
                Text(guidance)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, theme.space.s16)
            }
        }
        .padding(.vertical, theme.space.s2)
    }

    static func icon(for stage: AgentChannelInboundActivityStage) -> String {
        switch stage {
        case .received:
            return "tray.and.arrow.down"
        case .rejected:
            return "hand.raised.fill"
        case .stored:
            return "internaldrive"
        case .dispatchSuppressed:
            return "pause.circle"
        case .dispatched:
            return "paperplane"
        case .agentReplied:
            return "text.bubble"
        case .replySent:
            return "checkmark.bubble"
        case .failed:
            return "xmark.octagon"
        }
    }

    static func tone(for stage: AgentChannelInboundActivityStage) -> AgentChannelStatusTone {
        switch stage {
        case .received, .stored, .dispatched, .agentReplied, .replySent:
            return .success
        case .dispatchSuppressed:
            return .warning
        case .rejected, .failed:
            return .error
        }
    }
}
