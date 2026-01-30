//
//  BackgroundTaskToastView.swift
//  osaurus
//
//  Toast view for background agent tasks with support for running,
//  clarification, and completed states.
//

import SwiftUI

// MARK: - Background Task Toast View

/// A toast notification for background agent tasks
struct BackgroundTaskToastView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var taskState: BackgroundTaskState
    let onDismiss: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var showCancelConfirmation = false
    @State private var selectedOption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            contentSection
        }
        .background(toastBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(toastBorder)
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity),
            radius: isHovering ? 18 : 12,
            x: 0,
            y: isHovering ? 8 : 5
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .themedAlert(
            "Cancel Background Task?",
            isPresented: $showCancelConfirmation,
            message: "The agent task is still running. Dismissing will cancel the task.",
            primaryButton: .destructive("Cancel Task") {
                BackgroundTaskManager.shared.cancelTask(taskState.id)
                onDismiss()
            },
            secondaryButton: .cancel("Keep Running"),
            presentationStyle: .window
        )
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 10) {
            // Status icon
            statusIcon

            // Task title
            VStack(alignment: .leading, spacing: 2) {
                Text(taskState.taskTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(taskState.status.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer(minLength: 4)

            // Dismiss button
            dismissButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(theme.isDark ? 0.14 : 0.10))
                .frame(width: 28, height: 28)

            MorphingStatusIcon(
                state: statusIconState,
                accentColor: accentColor,
                size: 14
            )
        }
    }

    private var statusIconState: StatusIconState {
        switch taskState.status {
        case .running:
            return .active
        case .awaitingClarification:
            return .pending
        case .completed(let success, _):
            return success ? .completed : .failed
        case .cancelled:
            return .failed
        }
    }

    @ViewBuilder
    private var dismissButton: some View {
        Button {
            handleDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(theme.tertiaryBackground.opacity(isHovering ? 0.9 : 0.6))
                )
                .overlay(
                    Circle()
                        .strokeBorder(theme.primaryBorder.opacity(isHovering ? 0.25 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(isHovering ? 1 : 0.6)
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        switch taskState.status {
        case .running:
            runningContent
        case .awaitingClarification:
            clarificationContent
        case .completed(_, let summary):
            completedContent(summary: summary)
        case .cancelled:
            cancelledContent
        }
    }

    // MARK: - Running State

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            runningHeaderRow
            runningProgressRow
            activityFeedView(showTypingIndicator: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
    }

    private var runningHeaderRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(taskState.currentStep ?? "Working…")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let plan = taskState.currentPlan, !plan.steps.isEmpty {
                AnimatedStepCounter(
                    current: min(taskState.currentPlanStep + 1, plan.steps.count),
                    total: plan.steps.count,
                    color: accentColor
                )
                .fixedSize()
            } else if taskState.progress >= 0 {
                Text("\(Int(taskState.progress * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .contentTransition(.numericText())
                    .animation(theme.springAnimation(responseMultiplier: 0.8), value: taskState.progress)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var runningProgressRow: some View {
        if taskState.progress >= 0 {
            ShimmerProgressBar(progress: taskState.progress, color: accentColor, height: 3.5, showGlow: true)
        } else {
            IndeterminateShimmerProgress(color: accentColor, height: 3.5)
        }
    }

    // MARK: - Activity Feed (Mini Log)

    private func activityFeedView(showTypingIndicator: Bool) -> some View {
        let maxLines = isHovering ? 6 : 3
        let items = collapsedActivityItems(maxLines: maxLines)
        let ids = items.map(\.id)

        return VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                HStack(spacing: 8) {
                    ConfigurableTypingIndicator(color: theme.tertiaryText.opacity(0.6), dotSize: 5, spacing: 3)
                    Text("Starting…")
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
        // Newest row should read as the “hero” line; older lines fade out quickly.
        // Clamp so older lines remain legible but visually secondary.
        max(0.45, 1.0 - Double(index) * 0.16)
    }

    private struct CollapsedActivityItem: Identifiable {
        let id: UUID
        let item: BackgroundTaskActivityItem
        let count: Int
    }

    private func collapsedActivityItems(maxLines: Int) -> [CollapsedActivityItem] {
        // Newest first (top of the mini-log)
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
                // Collapse consecutive identical entries (common for repeated tool calls)
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

            if out.count >= maxLines {
                break
            }
        }

        // Flush the last accumulator if we still have room
        if out.count < maxLines {
            flushCurrent()
        }

        return out
    }

    private var activityBackground: some View {
        ZStack {
            theme.secondaryBackground.opacity(theme.isDark ? 0.45 : 0.6)
            LinearGradient(
                colors: [
                    accentColor.opacity(theme.isDark ? 0.10 : 0.06),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Clarification State

    @ViewBuilder
    private var clarificationContent: some View {
        if let clarification = taskState.pendingClarification {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.warningColor.opacity(0.9))
                        .frame(width: 7, height: 7)
                    Text("Needs input")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }

                activityFeedView(showTypingIndicator: false)

                // Question
                Text(clarification.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(3)

                // Options or prompt to open window for text input
                if let options = clarification.options, !options.isEmpty {
                    optionsView(options: options)

                    // Submit button for options
                    HStack {
                        Spacer()
                        submitButton
                    }
                } else {
                    // For text input, prompt user to open the window
                    // (Toast panel can't receive keyboard focus)
                    Button {
                        onOpen()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 11))
                            Text("Click to respond")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.isDark ? theme.primaryBackground : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(accentColor)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(accentColor.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func optionsView(options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                optionButton(option)
            }
        }
    }

    private func optionButton(_ option: String) -> some View {
        let isSelected = selectedOption == option

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedOption = isSelected ? nil : option
            }
        } label: {
            HStack(spacing: 8) {
                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? accentColor : theme.tertiaryText.opacity(0.4),
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(option)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.1) : theme.tertiaryBackground.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
    }

    private var submitButton: some View {
        let canSubmit = selectedOption != nil

        return Button {
            if let option = selectedOption {
                BackgroundTaskManager.shared.submitClarification(taskState.id, response: option)
                selectedOption = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text("Continue")
                    .font(.system(size: 11, weight: .semibold))

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(canSubmit ? .white : theme.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(canSubmit ? accentColor : theme.tertiaryBackground)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    // MARK: - Completed State

    private func completedContent(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)

            activityFeedView(showTypingIndicator: false)

            Button {
                onOpen()
                // Finalize since user is viewing the completed task
                BackgroundTaskManager.shared.finalizeTask(taskState.id)
            } label: {
                Text("View Details")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(accentColor.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(accentColor.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Cancelled State

    private var cancelledContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Task was cancelled")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            activityFeedView(showTypingIndicator: false)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Helpers

    private func handleDismiss() {
        // If task is still active, show confirmation
        if taskState.status.isActive {
            showCancelConfirmation = true
        } else {
            // Task is completed or cancelled, just dismiss and finalize
            BackgroundTaskManager.shared.finalizeTask(taskState.id)
            onDismiss()
        }
    }

    private var toastBackground: some View {
        ZStack {
            if theme.glassEnabled {
                Rectangle().fill(.ultraThinMaterial)
            }

            theme.cardBackground.opacity(theme.glassEnabled ? (theme.isDark ? 0.78 : 0.88) : 1.0)

            LinearGradient(
                colors: [
                    accentColor.opacity(theme.isDark ? 0.08 : 0.05),
                    Color.clear,
                    theme.primaryBackground.opacity(theme.isDark ? 0.08 : 0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var toastBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(theme.isDark ? 0.22 : 0.35),
                        theme.primaryBorder.opacity(theme.isDark ? 0.18 : 0.28),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay(
                // subtle leading “energy” edge
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accentColor.opacity(isHovering ? 0.22 : 0.12), lineWidth: 1)
                    .mask(
                        LinearGradient(
                            colors: [Color.white, Color.white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
    }

    private var accentColor: Color {
        switch taskState.status {
        case .running:
            return theme.accentColorLight
        case .awaitingClarification:
            return theme.warningColor
        case .completed(let success, _):
            return success ? theme.successColor : theme.errorColor
        case .cancelled:
            return theme.tertiaryText
        }
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
        case .tool: return accent.opacity(0.9)
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
                Text("Preview requires runtime BackgroundTaskState")
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: 420)
            .background(Color.black.opacity(0.8))
        }
    }
#endif
