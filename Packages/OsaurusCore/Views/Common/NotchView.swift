//
//  NotchView.swift
//  osaurus
//
//  Dynamic Island-inspired notch UI for background tasks.
//  Cup-shaped overlay that blends with the display bezel and expands
//  on hover with a bouncy swing animation and staggered content reveal.
//

import SwiftUI

// MARK: - Notch Shape

/// Cup-shaped notch using cubic Bezier curves for smooth concave ears
/// at the top and convex rounded corners at the bottom.
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
        let earDepth = topR * 0.35

        var path = Path()
        path.move(to: CGPoint(x: topR, y: 0))
        path.addLine(to: CGPoint(x: w - topR, y: 0))

        // Top-right ear
        path.addCurve(
            to: CGPoint(x: w, y: topR),
            control1: CGPoint(x: w - earDepth, y: 0),
            control2: CGPoint(x: w, y: earDepth)
        )
        path.addLine(to: CGPoint(x: w, y: h - botR))

        // Bottom-right corner
        path.addCurve(
            to: CGPoint(x: w - botR, y: h),
            control1: CGPoint(x: w, y: h - botR * 0.45),
            control2: CGPoint(x: w - botR * 0.45, y: h)
        )
        path.addLine(to: CGPoint(x: botR, y: h))

        // Bottom-left corner
        path.addCurve(
            to: CGPoint(x: 0, y: h - botR),
            control1: CGPoint(x: botR * 0.45, y: h),
            control2: CGPoint(x: 0, y: h - botR * 0.45)
        )
        path.addLine(to: CGPoint(x: 0, y: topR))

        // Top-left ear
        path.addCurve(
            to: CGPoint(x: topR, y: 0),
            control1: CGPoint(x: 0, y: earDepth),
            control2: CGPoint(x: earDepth, y: 0)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Expansion State

private enum NotchExpansion: Equatable {
    case hidden, compact, expanded
}

// MARK: - Notch View

struct NotchView: View {
    @ObservedObject private var taskManager = BackgroundTaskManager.shared
    @ObservedObject private var pluginActivity = PluginActivityManager.shared
    @ObservedObject private var windowController = NotchWindowController.shared
    @Environment(\.theme) private var theme

    // MARK: - State

    /// Split hover tracking: trigger zone (top strip) + body (expanded content).
    @State private var isHoveringTrigger = false
    @State private var isHoveringBody = false
    @State private var activeTaskIndex: Int = 0
    @State private var showCancelConfirmation = false
    @State private var contentRevealed = false
    @State private var absorbingTaskIds: Set<UUID> = []

    private var isHovering: Bool { isHoveringTrigger || isHoveringBody }

    // MARK: - Metrics & Colors

    private var metrics: NotchScreenMetrics { windowController.metrics }
    private var notchPrimaryText: Color { .white }
    private var notchSecondaryText: Color { Color.white.opacity(0.7) }
    private var notchTertiaryText: Color { Color.white.opacity(0.45) }

    // MARK: - Derived Properties

    private var sortedTasks: [BackgroundTaskState] {
        Array(taskManager.backgroundTasks.values)
            // Headless dispatchers (e.g. webhook responders) opt out of the
            // notch by setting `showToast = false`. The task is still
            // tracked for completion signaling — it just doesn't render.
            .filter { $0.showToast }
            .sorted { a, b in
                let ap = statusPriority(a.status), bp = statusPriority(b.status)
                if ap != bp { return ap < bp }
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

    private var activeTask: BackgroundTaskState? {
        guard !sortedTasks.isEmpty else { return nil }
        let idx = min(activeTaskIndex, sortedTasks.count - 1)
        return sortedTasks[max(0, idx)]
    }

    /// In-flight inline plugin call to surface when there's no dispatched
    /// `BackgroundTaskState` to render. Lets the user see that, e.g., the
    /// Telegram plugin is generating a reply via `complete_stream` even
    /// though the call never created a task.
    private var topPluginActivity: PluginActivityRecord? {
        guard activeTask == nil else { return nil }
        return pluginActivity.topActivity
    }

    private var expansion: NotchExpansion {
        if activeTask != nil { return isHovering ? .expanded : .compact }
        if topPluginActivity != nil { return isHovering ? .expanded : .compact }
        return .hidden
    }

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
        case .compact: return metrics.notchWidth + 60
        case .expanded: return max(340, metrics.notchWidth + 140)
        }
    }

    /// Compact: flush with bezel. Expanded: content-driven via fixedSize.
    private var notchHeight: CGFloat {
        switch expansion {
        case .hidden: return 0
        case .compact: return metrics.notchHeight
        case .expanded: return 0
        }
    }

    private var topCornerRadius: CGFloat {
        switch expansion {
        case .hidden: return 4
        case .compact: return 5
        case .expanded: return 0  // square — looks like it slid out
        }
    }

    private var bottomCornerRadius: CGFloat {
        switch expansion {
        case .hidden: return 10
        case .compact: return 12
        case .expanded: return 22
        }
    }

    private var orbSize: CGFloat {
        switch expansion {
        case .hidden: return 10
        case .compact: return 14
        case .expanded: return 24
        }
    }

    private var currentShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    // MARK: - Animation

    private var swingSpring: Animation {
        .spring(response: 0.45, dampingFraction: 0.68, blendDuration: 0.1)
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
        .animation(swingSpring, value: expansion)
        .animation(swingSpring, value: sortedTasks.map(\.id))
        .animation(swingSpring, value: activeTaskIndex)
        .onChange(of: sortedTasks.count) { _, newCount in
            if activeTaskIndex >= newCount {
                activeTaskIndex = max(0, newCount - 1)
            }
        }
        .onChange(of: isHoveringTrigger) { _, _ in handleHoverChange() }
        .onChange(of: isHoveringBody) { _, _ in handleHoverChange() }
    }

    // MARK: - Notch Body

    private var notchBody: some View {
        notchContent
            .frame(width: notchWidth, alignment: .top)
            .frame(minHeight: notchHeight, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(notchBackground)
            .clipShape(currentShape)
            .contentShape(currentShape)
            .overlay(notchBorderOverlay)
            .overlay(alignment: .top) { hoverTriggerZone }
            .shadow(
                color: Color.black.opacity(expansion == .compact ? 0 : (isHovering ? 0.6 : 0.4)),
                radius: expansion == .compact ? 0 : (isHovering ? 20 : 12),
                x: 0,
                y: expansion == .compact ? 0 : (isHovering ? 10 : 6)
            )
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

    /// Thin strip at the top that triggers hover — the only entry point for expansion.
    private var hoverTriggerZone: some View {
        Color.clear
            .frame(width: metrics.notchWidth + 60, height: metrics.notchHeight)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(swingSpring) { isHoveringTrigger = hovering }
            }
    }

    // MARK: - Content Switching

    @ViewBuilder
    private var notchContent: some View {
        let isAbsorbing = activeTask.map { absorbingTaskIds.contains($0.id) } ?? false

        switch expansion {
        case .hidden:
            EmptyView()
        case .compact:
            compactContent.transition(.opacity)
        case .expanded:
            expandedContent.transition(
                isAbsorbing
                    ? .asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .top)
                            .combined(with: .scale(scale: 0.6, anchor: .top))
                            .combined(with: .opacity)
                    )
                    : .opacity
            )
        }
    }

    // MARK: - Compact Content

    private var compactContent: some View {
        HStack(spacing: 0) {
            compactLeading.frame(width: 24, alignment: .center)
            Spacer(minLength: 0)
            compactTrailing.frame(width: 24, alignment: .center)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var compactLeading: some View {
        if activeTask != nil || topPluginActivity != nil {
            AnimatedOrb(
                color: accentColor,
                size: .custom(orbSize),
                showGlow: false,
                showFloat: false,
                isInteractive: false
            )
            .animation(swingSpring, value: orbSize)
            .transition(.opacity.combined(with: .scale(scale: 0.5)))
        }
    }

    @ViewBuilder
    private var compactTrailing: some View {
        if let task = activeTask {
            switch task.status {
            case .running, .awaitingClarification:
                // Chat tasks don't expose structured progress — show
                // indeterminate ring (passing -1 makes NotchProgressRing
                // animate continuously).
                NotchProgressRing(progress: -1, color: accentColor, size: 14, lineWidth: 1.5)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            case .completed(let success, _):
                MorphingStatusIcon(
                    state: success ? .completed : .failed,
                    accentColor: success ? theme.successColor : theme.errorColor,
                    size: 14
                )
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            case .cancelled:
                MorphingStatusIcon(state: .failed, accentColor: notchTertiaryText, size: 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        } else if topPluginActivity != nil {
            NotchProgressRing(progress: -1, color: accentColor, size: 14, lineWidth: 1.5)
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)

            VStack(alignment: .leading, spacing: 8) {
                expandedHeader

                if let task = activeTask {
                    switch task.status {
                    case .running, .awaitingClarification:
                        expandedRunningBody(task: task)
                    case .completed(_, let summary):
                        expandedCompletedBody(summary: summary, task: task)
                    case .cancelled:
                        expandedCancelledBody(task: task)
                    }
                } else if let activity = topPluginActivity {
                    expandedPluginActivityBody(activity: activity)
                }

                if sortedTasks.count > 1 { taskDotIndicators }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .opacity(contentRevealed ? 1 : 0)
            .offset(y: contentRevealed ? 0 : 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            withAnimation(swingSpring) { isHoveringBody = hovering }
        }
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            AnimatedOrb(
                color: accentColor,
                size: .custom(orbSize),
                showGlow: false,
                showFloat: false,
                isInteractive: false
            )

            if let task = activeTask {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.taskTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(notchPrimaryText)
                        .lineLimit(1)
                    Text(headerSubtitle(for: task))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(notchTertiaryText)
                        .lineLimit(1)
                }
            } else if let activity = topPluginActivity {
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.pluginDisplayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(notchPrimaryText)
                        .lineLimit(1)
                    Text("Working", bundle: .module)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(notchTertiaryText)
                }
            }

            Spacer(minLength: 4)

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

    private func expandedRunningBody(task: BackgroundTaskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step = task.currentStep {
                Text(step)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(notchSecondaryText)
                    .lineLimit(2)
            }
            expandedProgress(task: task)
            if hasActivityItems { expandedActivityFeed(task: task) }

            notchActionButton("Open Chat") {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
        }
    }

    private func expandedCompletedBody(summary: String, task: BackgroundTaskState) -> some View {
        VStack(spacing: 8) {
            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(notchSecondaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasActivityItems { expandedActivityFeed(task: task) }

            notchActionButton("View Chat") {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
        }
    }

    private func expandedPluginActivityBody(activity: PluginActivityRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inline plugin inference \u{2014} \(activity.kind.rawValue)", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(notchSecondaryText)
                .lineLimit(2)
            IndeterminateShimmerProgress(color: accentColor, height: 3)
        }
    }

    private func expandedCancelledBody(task: BackgroundTaskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Task was cancelled", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(notchSecondaryText)
            if hasActivityItems { expandedActivityFeed(task: task) }

            notchActionButton("View Chat") {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
        }
    }

    @ViewBuilder
    private func expandedProgress(task: BackgroundTaskState) -> some View {
        // Chat tasks have no structured progress signal, so always show
        // an indeterminate shimmer while the task is running.
        IndeterminateShimmerProgress(color: accentColor, height: 3)
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Multi-Task Dots

    private var taskDotIndicators: some View {
        HStack(spacing: 6) {
            Spacer()
            ForEach(Array(sortedTasks.enumerated()), id: \.element.id) { index, _ in
                Circle()
                    .fill(index == activeTaskIndex ? accentColor : notchTertiaryText)
                    .frame(width: 6, height: 6)
                    .scaleEffect(index == activeTaskIndex ? 1.2 : 1.0)
                    .onTapGesture {
                        withAnimation(swingSpring) { activeTaskIndex = index }
                    }
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Background & Border

    private var notchBackground: some View {
        ZStack {
            Color.black
            if expansion == .expanded {
                LinearGradient(colors: [.clear, Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.clear, accentColor.opacity(0.06)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private var notchBorderOverlay: some View {
        currentShape
            .stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.0), Color.white.opacity(expansion == .compact ? 0.06 : 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .mask(
                VStack(spacing: 0) {
                    Color.clear.frame(height: max(metrics.notchHeight - 6, 0))
                    LinearGradient(colors: [Color.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: 10)
                    Color.white
                }
            )
    }

    // MARK: - Helpers

    private var hasActivityItems: Bool {
        guard let task = activeTask else { return false }
        return task.activityFeed.count > 1
            || (task.activityFeed.count == 1 && task.activityFeed.first?.kind != .info)
    }

    /// Builds the second line of the expanded header, surfacing the
    /// dispatch origin (e.g. "Running · via Telegram") so the user can tell
    /// at a glance which integration is driving the task.
    private func headerSubtitle(for task: BackgroundTaskState) -> String {
        let status = task.status.displayName
        let pluginName = task.sourcePluginId.map(PluginDisplayNameResolver.displayName(for:))
        guard let origin = task.source.originLabel(pluginDisplayName: pluginName) else {
            return status
        }
        return "\(status) · \(origin)"
    }

    private func notchActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(accentColor.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(accentColor.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func handleHoverChange() {
        if isHovering {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard isHovering else { return }
                withAnimation(.easeOut(duration: 0.25)) { contentRevealed = true }
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) { contentRevealed = false }
        }
    }

    private func handleDismiss() {
        guard let task = activeTask else { return }
        if task.status.isActive {
            showCancelConfirmation = true
        } else {
            _ = withAnimation(swingSpring) { absorbingTaskIds.insert(task.id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                BackgroundTaskManager.shared.finalizeTask(task.id)
                absorbingTaskIds.remove(task.id)
            }
        }
    }

    // MARK: - Activity Collapsing

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
        var currentCount = 0

        func flush() {
            guard let item = current else { return }
            out.append(CollapsedActivityItem(id: item.id, item: item, count: currentCount))
            current = nil
            currentCount = 0
        }

        for item in recent {
            if let cur = current,
                cur.kind == item.kind, cur.title == item.title, cur.detail == item.detail
            {
                currentCount += 1
            } else {
                flush()
                current = item
                currentCount = 1
            }
            if out.count >= maxLines { break }
        }
        if out.count < maxLines { flush() }
        return out
    }
}

// MARK: - Notch Progress Ring

private struct NotchProgressRing: View {
    let progress: Double
    let color: Color
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
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
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            }
        }
    }
}

// MARK: - Notch Activity Row

private struct NotchActivityRow: View {
    let item: BackgroundTaskActivityItem
    let accent: Color
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(dotColor).frame(width: 5, height: 5).padding(.top, 3)

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
        case .tool, .toolCall, .toolResult: return accent.opacity(0.9)
        case .thinking, .writing: return accent.opacity(0.7)
        case .warning: return Color.orange
        case .success: return Color.green
        case .error: return Color.red
        case .info: return Color.white.opacity(0.4)
        }
    }
}

// MARK: - Window Root

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
                Text("NotchView requires runtime BackgroundTaskState", bundle: .module)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: 420)
            .background(Color.black.opacity(0.8))
        }
    }
#endif
