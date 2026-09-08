//
//  HostedRunNotice.swift
//  osaurus
//
//  Composer-area notice for a conversation this instance hosts for a remote
//  caller (a workspace teammate or an invite-link peer driving one of our
//  shared agents). The composer is hidden for these read-only rows, so this
//  notice is the tab's status line and its only Stop affordance:
//
//  - while the run is live: "Alice is using Research Agent · Writing…" with
//    a spinner and a Stop button (routes through `BackgroundTaskManager.
//    cancelTask`, which ends the SSE run on the host);
//  - afterwards: "This is Alice's conversation with Research Agent through
//    your workspace — read-only here." (or "…through your shared agent…").
//
//  Kept as its own view so only it re-renders on background-task ticks.
//

import SwiftUI

struct HostedRunNotice: View {
    let sessionId: UUID?
    let callerName: String?
    let agentName: String
    let isWorkspace: Bool

    @Environment(\.theme) private var theme
    @ObservedObject private var taskManager = BackgroundTaskManager.shared
    @State private var isStopHovered = false

    /// The live inbound-run task hosting this conversation, if any.
    private var liveTask: BackgroundTaskState? {
        guard let sessionId else { return nil }
        return taskManager.taskState(for: sessionId).flatMap { $0.isInboundRun && $0.status.isActive ? $0 : nil }
    }

    private var caller: String { callerName ?? L("a teammate") }

    var body: some View {
        if let task = liveTask {
            noticeRow(tint: theme.accentColor) {
                ProgressView()
                    .controlSize(.small)
                Text(liveText(step: task.currentStep))
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: { taskManager.cancelTask(task.id) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .bold))
                        Text(L("Stop"))
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    }
                    .foregroundColor(isStopHovered ? theme.errorColor : theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(isStopHovered ? theme.errorColor.opacity(0.12) : theme.secondaryBackground)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { isStopHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isStopHovered)
                .localizedHelp("Stop this run — the caller sees it end")
                .accessibilityIdentifier("hosted-run-stop")
            }
        } else {
            noticeRow(tint: theme.secondaryText) {
                Image(systemName: isWorkspace ? "rectangle.3.group.fill" : "person.2.fill")
                    .font(.system(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Text(readOnlyText)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func liveText(step: String?) -> String {
        let base = String(format: L("%@ is using %@"), caller, agentName)
        if let step, !step.isEmpty { return "\(base) · \(step)" }
        return base
    }

    private var readOnlyText: String {
        if isWorkspace {
            return String(
                format: L("This is %@'s conversation with %@ through your workspace — read-only here."),
                caller,
                agentName
            )
        }
        return String(
            format: L("This is %@'s conversation with %@ through your shared agent — read-only here."),
            caller,
            agentName
        )
    }

    /// Same chrome as `ChatView.remoteAgentNoticeRow`.
    private func noticeRow<Content: View>(
        tint: Color,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(theme.isDark ? 0.14 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
