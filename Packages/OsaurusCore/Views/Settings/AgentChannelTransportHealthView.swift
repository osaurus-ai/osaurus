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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
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
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .disabled(isRefreshing)
                .help(Text("Refresh receive status", bundle: .module))
            }

            if let state {
                Text(state.summary)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = state.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(state.severity == .info ? theme.tertiaryText : theme.warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                metricsRow(state)
            } else {
                Text(LocalizedStringKey(notRunningHint), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
        .task(id: refreshToken) {
            await refresh()
        }
    }

    @ViewBuilder
    private func metricsRow(_ state: AgentChannelTransportHealthState) -> some View {
        let parts = Self.metrics(for: state, now: Date())
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
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
