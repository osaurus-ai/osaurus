//
//  BackgroundTaskToastView.swift
//  osaurus
//
//  Toast view for background tasks with support for running,
//  running and completed states for backgrounded chat tasks.
//

import SwiftUI

// MARK: - Background Task Toast View

/// A toast notification for background tasks (chat and work)
struct BackgroundTaskToastView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var taskState: BackgroundTaskState

    let onDismiss: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var showCancelConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            contentSection
        }
        .background(ToastBackground(accentColor: accentColor))
        .clipShape(RoundedRectangle(cornerRadius: ToastStyle.cornerRadius, style: .continuous))
        .overlay(ToastBorder(accentColor: accentColor, isHovering: isHovering))
        .toastShadow(theme: theme, isHovering: isHovering)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovering = hovering
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .themedAlert(
            "Cancel Background Task?",
            isPresented: $showCancelConfirmation,
            message: "The task is still running. Dismissing will cancel it.",
            primaryButton: .destructive("Cancel Task") {
                BackgroundTaskManager.shared.cancelTask(taskState.id)
                onOpen()
                onDismiss()
            },
            secondaryButton: .cancel("Keep Running"),
            presentationStyle: .window
        )
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 10) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(taskState.taskTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(headerSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            ToastDismissButton(isHovering: isHovering, action: handleDismiss)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(theme.isDark ? 0.14 : 0.10))
                .frame(width: 28, height: 28)

            MorphingStatusIcon(state: statusIconState, accentColor: accentColor, size: 14)
        }
    }

    private var statusIconState: StatusIconState {
        switch taskState.status {
        case .running: return .active
        case .awaitingClarification: return .pending
        case .completed(let success, _): return success ? .completed : .failed
        case .cancelled: return .failed
        }
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        switch taskState.status {
        case .running, .awaitingClarification:
            // Chat tasks never enter `awaitingClarification` from the manager —
            // chat clarifications surface inline via the `clarify` agent
            // intercept rendered in the chat window. Treat the case as a
            // running task here for back-compat with any legacy state.
            runningContent
        case .completed(_, let summary):
            completedContent(summary: summary)
        case .cancelled:
            cancelledContent
        }
    }

    // MARK: - Running State

    /// Indeterminate progress + activity feed for an in-flight chat task.
    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(taskState.currentStep ?? "Running...")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)

            IndeterminateShimmerProgress(color: accentColor, height: 3.5)

            if hasActivityItems {
                activityFeedView
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    // MARK: - Activity Feed

    private var activityFeedView: some View {
        let maxLines = isHovering ? 6 : 3
        let items = collapsedActivityItems(maxLines: maxLines)
        let ids = items.map(\.id)

        return VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                HStack(spacing: 8) {
                    ConfigurableTypingIndicator(color: theme.tertiaryText.opacity(0.6), dotSize: 5, spacing: 3)
                    Text("Starting…", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ActivityRow(item: item.item, accent: accentColor, count: item.count)
                        .opacity(activityOpacity(forRow: index))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(activityBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.12), lineWidth: 1)
        )
        .animation(theme.springAnimation(responseMultiplier: 0.9), value: ids)
        .animation(theme.springAnimation(responseMultiplier: 0.9), value: isHovering)
    }

    private func activityOpacity(forRow index: Int) -> Double {
        max(0.45, 1.0 - Double(index) * 0.16)
    }

    private struct CollapsedActivityItem: Identifiable {
        let id: UUID
        let item: BackgroundTaskActivityItem
        let count: Int
    }

    private func collapsedActivityItems(maxLines: Int) -> [CollapsedActivityItem] {
        let recent = taskState.activityFeed.reversed()
        var out: [CollapsedActivityItem] = []
        out.reserveCapacity(maxLines)

        var current: BackgroundTaskActivityItem?
        var currentCount: Int = 0

        func flushCurrent() {
            guard let item = current else { return }
            out.append(CollapsedActivityItem(id: item.id, item: item, count: currentCount))
            current = nil
            currentCount = 0
        }

        for item in recent {
            if let currentItem = current {
                if currentItem.kind == item.kind, currentItem.title == item.title, currentItem.detail == item.detail {
                    currentCount += 1
                } else {
                    flushCurrent()
                    current = item
                    currentCount = 1
                }
            } else {
                current = item
                currentCount = 1
            }

            if out.count >= maxLines { break }
        }

        if out.count < maxLines { flushCurrent() }
        return out
    }

    private var activityBackground: some View {
        ZStack {
            theme.secondaryBackground.opacity(theme.isDark ? 0.45 : 0.6)
            LinearGradient(
                colors: [accentColor.opacity(theme.isDark ? 0.10 : 0.06), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Completed State

    private func completedContent(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)

            if hasActivityItems {
                activityFeedView
            }

            ToastActionButton(
                title: "View Chat",
                accentColor: accentColor
            ) {
                onOpen()
                BackgroundTaskManager.shared.finalizeTask(taskState.id)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Cancelled State

    private var cancelledContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Task was cancelled", bundle: .module)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Button {
                    BackgroundTaskManager.shared.finalizeTask(taskState.id)
                    onDismiss()
                } label: {
                    Text("Dismiss", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            if hasActivityItems {
                activityFeedView
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Helpers

    /// Whether there are meaningful activity items beyond the initial "Running in background" seed.
    private var hasActivityItems: Bool {
        taskState.activityFeed.count > 1
            || (taskState.activityFeed.count == 1 && taskState.activityFeed.first?.kind != .info)
    }

    private func handleDismiss() {
        if taskState.status.isActive {
            showCancelConfirmation = true
        } else {
            BackgroundTaskManager.shared.finalizeTask(taskState.id)
            onDismiss()
        }
    }

    private var accentColor: Color {
        switch taskState.status {
        case .running: return theme.accentColorLight
        case .awaitingClarification: return theme.warningColor
        case .completed(let success, _): return success ? theme.successColor : theme.errorColor
        case .cancelled: return theme.tertiaryText
        }
    }

    /// Status line under the task title. For non-`chat` sources we append
    /// the origin (e.g. "Running · via Telegram") so the user can tell at a
    /// glance which integration spawned the task.
    private var headerSubtitle: String {
        let status = taskState.status.displayName
        let pluginName = taskState.sourcePluginId.map(PluginDisplayNameResolver.displayName(for:))
        guard let origin = taskState.source.originLabel(pluginDisplayName: pluginName) else {
            return status
        }
        return "\(status) · \(origin)"
    }
}

// MARK: - Activity Row

private struct ActivityRow: View {
    @Environment(\.theme) private var theme

    let item: BackgroundTaskActivityItem
    let accent: Color
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(dotColor.opacity(theme.isDark ? 0.9 : 0.85))
                .frame(width: 6, height: 6)
                .padding(.top, 3)

            (Text(item.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                + Text(item.detail.map { " — \($0)" } ?? "")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                + Text(count > 1 ? " ×\(count)" : "")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.tertiaryText.opacity(0.85)))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var dotColor: Color {
        switch item.kind {
        case .progress: return accent
        case .tool, .toolCall, .toolResult: return accent.opacity(0.9)
        case .thinking, .writing: return accent.opacity(0.7)
        case .warning: return theme.warningColor
        case .success: return theme.successColor
        case .error: return theme.errorColor
        case .info: return theme.tertiaryText
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct BackgroundTaskToastView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                Text("Preview requires runtime BackgroundTaskState", bundle: .module)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: 420)
            .background(Color.black.opacity(0.8))
        }
    }
#endif
