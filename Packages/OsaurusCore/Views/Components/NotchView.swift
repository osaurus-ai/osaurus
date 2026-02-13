//
//  NotchView.swift
//  osaurus
//
//  Dynamic Island-inspired notch UI for background tasks.
//  Extends from the top edge of the screen with a custom notch shape
//  (flat top, ear curves, rounded bottom) and black background that
//  blends with the display bezel.
//

import SwiftUI

// MARK: - Notch Shape

/// Custom shape that mimics the MacBook hardware notch: flat top edge,
/// small "ear" curves at the top corners, and larger rounded bottom corners.
/// Both corner radii are animatable for smooth morphing between states.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let topR = min(topCornerRadius, min(w, h) / 2)
        let botR = min(bottomCornerRadius, min(w, h) / 2)

        var path = Path()

        // Start just after the top-left ear
        path.move(to: CGPoint(x: topR, y: 0))

        // Flat top edge
        path.addLine(to: CGPoint(x: w - topR, y: 0))

        // Top-right ear curve
        path.addQuadCurve(
            to: CGPoint(x: w, y: topR),
            control: CGPoint(x: w, y: 0)
        )

        // Right side
        path.addLine(to: CGPoint(x: w, y: h - botR))

        // Bottom-right corner
        path.addQuadCurve(
            to: CGPoint(x: w - botR, y: h),
            control: CGPoint(x: w, y: h)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: botR, y: h))

        // Bottom-left corner
        path.addQuadCurve(
            to: CGPoint(x: 0, y: h - botR),
            control: CGPoint(x: 0, y: h)
        )

        // Left side
        path.addLine(to: CGPoint(x: 0, y: topR))

        // Top-left ear curve
        path.addQuadCurve(
            to: CGPoint(x: topR, y: 0),
            control: CGPoint(x: 0, y: 0)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Notch Expansion State

/// Controls the visual expansion level of the notch.
private enum NotchExpansion: Equatable {
    case hidden
    case compact
    case expanded
    case interactive
}

// MARK: - Notch View

/// A Dynamic Island-inspired background task indicator that morphs between states.
/// Uses a black background and custom NotchShape to blend with the display bezel.
struct NotchView: View {
    @ObservedObject private var taskManager = BackgroundTaskManager.shared
    @ObservedObject private var windowController = NotchWindowController.shared
    @Environment(\.theme) private var theme

    // MARK: - Local State

    @State private var isHovering = false
    @State private var activeTaskIndex: Int = 0
    @State private var selectedOption: String?
    @State private var showCancelConfirmation = false

    // MARK: - Screen Metrics

    private var metrics: NotchScreenMetrics { windowController.metrics }

    // MARK: - Notch Colors (white-based for dark notch surface)

    private var notchPrimaryText: Color { .white }
    private var notchSecondaryText: Color { Color.white.opacity(0.7) }
    private var notchTertiaryText: Color { Color.white.opacity(0.45) }

    // MARK: - Computed

    /// Sorted tasks: clarification first, then running (newest first), then completed.
    private var sortedTasks: [BackgroundTaskState] {
        Array(taskManager.backgroundTasks.values)
            .sorted { a, b in
                let aPriority = statusPriority(a.status)
                let bPriority = statusPriority(b.status)
                if aPriority != bPriority { return aPriority < bPriority }
                return a.createdAt > b.createdAt
            }
    }

    private func statusPriority(_ status: BackgroundTaskStatus) -> Int {
        switch status {
        case .awaitingClarification: return 0
        case .running: return 1
        case .completed: return 2
        case .cancelled: return 3
        }
    }

    /// The currently featured task.
    private var activeTask: BackgroundTaskState? {
        guard !sortedTasks.isEmpty else { return nil }
        let idx = min(activeTaskIndex, sortedTasks.count - 1)
        return sortedTasks[max(0, idx)]
    }

    /// Current expansion state of the notch.
    private var expansion: NotchExpansion {
        guard let task = activeTask else { return .hidden }
        if case .awaitingClarification = task.status { return .interactive }
        if isHovering { return .expanded }
        return .compact
    }

    /// Accent color derived from active task status.
    private var accentColor: Color {
        guard let task = activeTask else { return theme.accentColorLight }
        switch task.status {
        case .running: return theme.accentColorLight
        case .awaitingClarification: return theme.warningColor
        case .completed(let success, _): return success ? theme.successColor : theme.errorColor
        case .cancelled: return notchTertiaryText
        }
    }

    // MARK: - Sizing

    private var notchWidth: CGFloat {
        switch expansion {
        case .hidden: return 0
        // Compact extends slightly beyond the hardware notch so it's subtly visible
        case .compact: return metrics.notchWidth + 60
        case .expanded: return max(340, metrics.notchWidth + 140)
        case .interactive: return max(340, metrics.notchWidth + 140)
        }
    }

    private var notchHeight: CGFloat {
        switch expansion {
        case .hidden: return 0
        // Compact uses exact hardware notch height to stay flush
        case .compact: return metrics.notchHeight
        case .expanded: return expandedHeight
        case .interactive: return interactiveHeight
        }
    }

    private var expandedHeight: CGFloat {
        guard let task = activeTask else { return metrics.notchHeight + 100 }
        let isTerminal = !task.status.isActive
        let base: CGFloat = isTerminal ? 130 : 160
        let activityExtra: CGFloat = hasActivityItems ? 80 : 0
        let multiExtra: CGFloat = sortedTasks.count > 1 ? 24 : 0
        // Add notch height so content starts below the bezel area
        return metrics.notchHeight + base + activityExtra + multiExtra
    }

    private var interactiveHeight: CGFloat {
        guard let task = activeTask, let clarification = task.pendingClarification else { return expandedHeight }
        let optionCount = CGFloat(clarification.options?.count ?? 0)
        let base: CGFloat = 170
        let optionsHeight = optionCount * 36
        let submitHeight: CGFloat = optionCount > 0 ? 36 : 40
        // Add notch height so content starts below the bezel area
        return metrics.notchHeight + base + optionsHeight + submitHeight
    }

    // MARK: - Shape Radii

    private var topCornerRadius: CGFloat {
        switch expansion {
        case .hidden: return 4
        // Compact: very small ear curves to blend seamlessly with bezel
        case .compact: return 5
        // Expanded: slightly larger ears for the wider shape
        case .expanded: return 10
        case .interactive: return 10
        }
    }

    private var bottomCornerRadius: CGFloat {
        switch expansion {
        case .hidden: return 10
        // Compact: moderate rounding for the small visible bottom edge
        case .compact: return 12
        // Expanded: larger rounding for the full-size notch
        case .expanded: return 20
        case .interactive: return 20
        }
    }

    private var currentShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            if expansion != .hidden {
                notchBody
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                        )
                    )
            }
        }
        .animation(notchSpring, value: expansion)
        .animation(notchSpring, value: sortedTasks.map(\.id))
        .animation(notchSpring, value: activeTaskIndex)
        .onChange(of: sortedTasks.count) { _, newCount in
            if activeTaskIndex >= newCount {
                activeTaskIndex = max(0, newCount - 1)
            }
        }
    }

    // MARK: - Notch Body

    private var notchBody: some View {
        notchContent
            .frame(width: notchWidth)
            .frame(minHeight: notchHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(notchBackground)
            .clipShape(currentShape)
            .overlay(notchBorderOverlay)
            // Shadow only cast downward and only when expanded (compact blends with bezel)
            .shadow(
                color: Color.black.opacity(expansion == .compact ? 0 : (isHovering ? 0.6 : 0.4)),
                radius: expansion == .compact ? 0 : (isHovering ? 20 : 12),
                x: 0,
                y: expansion == .compact ? 0 : (isHovering ? 10 : 6)
            )
            .glow(color: accentColor, radius: expansion == .interactive ? 10 : 0, isActive: expansion == .interactive)
            .onHover { hovering in
                withAnimation(notchSpring) {
                    isHovering = hovering
                }
            }
            .themedAlert(
                "Cancel Background Task?",
                isPresented: $showCancelConfirmation,
                message: "The task is still running. Dismissing will cancel it.",
                primaryButton: .destructive("Cancel Task") {
                    if let task = activeTask {
                        BackgroundTaskManager.shared.cancelTask(task.id)
                        BackgroundTaskManager.shared.openTaskWindow(task.id)
                    }
                },
                secondaryButton: .cancel("Keep Running"),
                presentationStyle: .window
            )
    }

    /// Switches between expansion-specific content with smooth transitions.
    @ViewBuilder
    private var notchContent: some View {
        switch expansion {
        case .hidden:
            EmptyView()
        case .compact:
            compactContent
                .transition(.opacity)
        case .expanded:
            expandedContent
                .transition(.opacity)
        case .interactive:
            interactiveContent
                .transition(.opacity)
        }
    }

    // MARK: - Compact Content

    private var compactContent: some View {
        HStack(spacing: 8) {
            // Status icon
            MorphingStatusIcon(state: statusIconState, accentColor: accentColor, size: 14)

            // Task title or completion summary
            if let task = activeTask {
                compactLabel(for: task)
            }

            Spacer(minLength: 4)

            // Progress ring / count badge
            compactTrailing
        }
        .padding(.horizontal, 16)
        // Center content vertically within the hardware notch height
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if let task = activeTask {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
        }
    }

    @ViewBuilder
    private func compactLabel(for task: BackgroundTaskState) -> some View {
        switch task.status {
        case .completed(let success, _):
            Text(success ? "Completed" : "Failed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accentColor)
                .lineLimit(1)
        case .cancelled:
            Text("Cancelled")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(notchTertiaryText)
                .lineLimit(1)
        default:
            Text(task.taskTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(notchPrimaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var compactTrailing: some View {
        if sortedTasks.count > 1 {
            Text("\(sortedTasks.count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(accentColor))
        } else if let task = activeTask {
            if task.status.isActive {
                NotchProgressRing(
                    progress: task.progress,
                    color: accentColor,
                    size: 16,
                    lineWidth: 2
                )
            }
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Reserve the hardware notch area as empty black at the top
            // so content only appears below the bezel line
            Color.clear
                .frame(height: metrics.notchHeight)

            VStack(alignment: .leading, spacing: 8) {
                expandedHeader

                if let task = activeTask {
                    switch task.status {
                    case .running:
                        expandedRunningBody(task: task)
                    case .completed(_, let summary):
                        expandedCompletedBody(summary: summary, task: task)
                    case .cancelled:
                        expandedCancelledBody(task: task)
                    case .awaitingClarification:
                        expandedRunningBody(task: task)
                    }
                }

                if sortedTasks.count > 1 {
                    taskDotIndicators
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let task = activeTask {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
        }
    }

    private func expandedRunningBody(task: BackgroundTaskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step = task.currentStep {
                Text(step)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(notchSecondaryText)
                    .lineLimit(2)
            }

            expandedProgress(task: task)

            if hasActivityItems {
                expandedActivityFeed(task: task)
            }
        }
    }

    private func expandedCompletedBody(summary: String, task: BackgroundTaskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(notchSecondaryText)
                .lineLimit(3)

            if hasActivityItems {
                expandedActivityFeed(task: task)
            }

            // View details button
            Button {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
                BackgroundTaskManager.shared.finalizeTask(task.id)
            } label: {
                Text(task.mode == .chat ? "View Chat" : "View Details")
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
                            .strokeBorder(accentColor.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func expandedCancelledBody(task: BackgroundTaskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Task was cancelled")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(notchSecondaryText)

            if hasActivityItems {
                expandedActivityFeed(task: task)
            }
        }
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            MorphingStatusIcon(state: statusIconState, accentColor: accentColor, size: 14)

            if let task = activeTask {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.taskTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(notchPrimaryText)
                        .lineLimit(1)

                    Text(task.status.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(notchTertiaryText)
                }
            }

            Spacer(minLength: 4)

            if let task = activeTask {
                expandedStepInfo(task: task)
            }

            // Dismiss button (notch-styled)
            Button(action: handleDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(notchTertiaryText)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func expandedStepInfo(task: BackgroundTaskState) -> some View {
        if let ls = task.loopState, ls.iteration > 0 {
            AnimatedStepCounter(current: ls.iteration, total: ls.maxIterations, color: accentColor)
                .fixedSize()
        } else if task.progress >= 0 {
            Text("\(Int(task.progress * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(notchTertiaryText)
                .contentTransition(.numericText())
                .animation(notchSpring, value: task.progress)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func expandedProgress(task: BackgroundTaskState) -> some View {
        if task.progress >= 0 {
            ShimmerProgressBar(progress: task.progress, color: accentColor, height: 3, showGlow: true)
        } else {
            IndeterminateShimmerProgress(color: accentColor, height: 3)
        }
    }

    private func expandedActivityFeed(task: BackgroundTaskState) -> some View {
        let items = collapsedActivityItems(from: task, maxLines: 3)

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                NotchActivityRow(item: item.item, accent: accentColor, count: item.count)
                    .opacity(max(0.5, 1.0 - Double(index) * 0.2))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Interactive Content (Clarification)

    @ViewBuilder
    private var interactiveContent: some View {
        if let task = activeTask, let clarification = task.pendingClarification {
            VStack(alignment: .leading, spacing: 0) {
                // Reserve the hardware notch area as empty black
                Color.clear
                    .frame(height: metrics.notchHeight)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        PulsingStatusDot(color: theme.warningColor, isPulsing: true, size: 7)

                        Text(task.taskTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(notchPrimaryText)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text("Needs input")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                    }

                    Text(clarification.question)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(notchPrimaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if let options = clarification.options, !options.isEmpty {
                        notchOptionsView(options: options)
                        HStack {
                            Spacer()
                            notchSubmitButton(taskId: task.id)
                        }
                    } else {
                        notchRespondButton(taskId: task.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notchOptionsView(options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { option in
                notchOptionButton(option)
            }
        }
    }

    private func notchOptionButton(_ option: String) -> some View {
        let isSelected = selectedOption == option

        return Button {
            withAnimation(theme.animationQuick()) {
                selectedOption = isSelected ? nil : option
            }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? accentColor : notchTertiaryText, lineWidth: 1.5)
                        .frame(width: 14, height: 14)

                    if isSelected {
                        Circle().fill(accentColor).frame(width: 7, height: 7)
                    }
                }

                Text(option)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? notchPrimaryText : notchSecondaryText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.15) : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private func notchSubmitButton(taskId: UUID) -> some View {
        let canSubmit = selectedOption != nil

        return Button {
            if let option = selectedOption {
                BackgroundTaskManager.shared.submitClarification(taskId, response: option)
                selectedOption = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text("Continue")
                    .font(.system(size: 10.5, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(canSubmit ? .white : notchTertiaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(canSubmit ? accentColor : Color.white.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    private func notchRespondButton(taskId: UUID) -> some View {
        Button {
            BackgroundTaskManager.shared.openTaskWindow(taskId)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "keyboard").font(.system(size: 10))
                Text("Click to respond").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accentColor))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Multi-Task Dot Indicators

    private var taskDotIndicators: some View {
        HStack(spacing: 6) {
            Spacer()
            ForEach(Array(sortedTasks.enumerated()), id: \.element.id) { index, _ in
                Circle()
                    .fill(index == activeTaskIndex ? accentColor : notchTertiaryText)
                    .frame(width: 6, height: 6)
                    .scaleEffect(index == activeTaskIndex ? 1.2 : 1.0)
                    .onTapGesture {
                        withAnimation(notchSpring) {
                            activeTaskIndex = index
                        }
                    }
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Background & Border

    private var notchBackground: some View {
        ZStack {
            // Pure black base — blends with the display bezel / hardware notch
            Color.black

            // Only add a subtle surface tint BELOW the hardware notch line
            // so the upper portion stays pure black and seamless
            if expansion == .expanded || expansion == .interactive {
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(0.04),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Very subtle accent bleed at the bottom
                LinearGradient(
                    colors: [
                        Color.clear,
                        accentColor.opacity(0.06),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    /// Border that only appears on the bottom and sides -- the top edge stays
    /// invisible so the notch blends seamlessly with the hardware bezel.
    private var notchBorderOverlay: some View {
        currentShape
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.0),
                        Color.white.opacity(expansion == .compact ? 0.06 : 0.14),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            // Mask away the top portion so no border is visible at the screen edge
            .mask(
                VStack(spacing: 0) {
                    Color.clear.frame(height: max(metrics.notchHeight - 6, 0))
                    LinearGradient(
                        colors: [Color.white.opacity(0), Color.white],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 10)
                    Color.white
                }
            )
    }

    // MARK: - Helpers

    private var statusIconState: StatusIconState {
        guard let task = activeTask else { return .pending }
        switch task.status {
        case .running: return .active
        case .awaitingClarification: return .pending
        case .completed(let success, _): return success ? .completed : .failed
        case .cancelled: return .failed
        }
    }

    private var hasActivityItems: Bool {
        guard let task = activeTask else { return false }
        return task.activityFeed.count > 1
            || (task.activityFeed.count == 1 && task.activityFeed.first?.kind != .info)
    }

    private func handleDismiss() {
        guard let task = activeTask else { return }
        if task.status.isActive {
            showCancelConfirmation = true
        } else {
            BackgroundTaskManager.shared.finalizeTask(task.id)
        }
    }

    private var notchSpring: Animation {
        .spring(response: 0.4, dampingFraction: 0.82)
    }

    // MARK: - Activity Item Collapsing

    private struct CollapsedActivityItem: Identifiable {
        let id: UUID
        let item: BackgroundTaskActivityItem
        let count: Int
    }

    private func collapsedActivityItems(from task: BackgroundTaskState, maxLines: Int) -> [CollapsedActivityItem] {
        let recent = task.activityFeed.reversed()
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
}

// MARK: - Notch Progress Ring

/// A small circular progress indicator for the compact notch state.
private struct NotchProgressRing: View {
    let progress: Double
    let color: Color
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2

    @State private var indeterminateRotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: lineWidth)
                .frame(width: size, height: size)

            if progress >= 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(indeterminateRotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                            indeterminateRotation = 360
                        }
                    }
            }
        }
    }
}

// MARK: - Notch Activity Row

/// Compact activity row styled for the dark notch surface.
private struct NotchActivityRow: View {
    let item: BackgroundTaskActivityItem
    let accent: Color
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
                .padding(.top, 3)

            (Text(item.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.7))
                + Text(item.detail.map { " — \($0)" } ?? "")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.45))
                + Text(count > 1 ? " ×\(count)" : "")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.4)))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var dotColor: Color {
        switch item.kind {
        case .progress: return accent
        case .tool: return accent.opacity(0.9)
        case .warning: return Color.orange
        case .success: return Color.green
        case .error: return Color.red
        case .info: return Color.white.opacity(0.4)
        }
    }
}

// MARK: - Notch Content View (Window Root)

/// Root content view hosted by the NotchWindowController.
/// Aligns the NotchView to the top with zero padding so the flat top
/// sits flush with the screen edge.
struct NotchContentView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        NotchView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .themedAlertScope(.notchOverlay)
            .overlay(ThemedAlertHost(scope: .notchOverlay))
            .environment(\.theme, themeManager.currentTheme)
    }
}

// MARK: - Preview

#if DEBUG
    struct NotchView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                Text("NotchView requires runtime BackgroundTaskState")
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: 420)
            .background(Color.black.opacity(0.8))
        }
    }
#endif
