//
//  NotchView.swift
//  osaurus
//
//  Dynamic Island-inspired notch UI for background tasks.
//  Cup-shaped overlay that blends with the display bezel and expands on
//  hover into an agent-tabbed activity center: one tab per agent, that
//  agent's sessions in a rail beneath it, inline quick replies for
//  clarify pauses and completed runs, and one-click access to the full
//  chat window.
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

    /// Single hover flag driven by the notch body's own bounds. The hover
    /// region therefore always matches what's on screen: the compact pill,
    /// or the expanded card once open. (A previous split trigger-strip +
    /// body-content scheme let the collapsing card re-report hover from the
    /// area below the pill and ping-pong the expansion.)
    @State private var isHovering = false
    /// Id-based tab/session selection. Resolved against the live task set
    /// on every render (`resolvedSelection`), so a stale id after a task
    /// finalizes falls back gracefully instead of pointing at the wrong
    /// row the way the previous index-based selection could.
    @State private var selectedAgentId: UUID?
    @State private var selectedTaskId: UUID?
    @State private var showCancelConfirmation = false
    @State private var showCloseAgentConfirmation = false
    @State private var pendingCloseAgentId: UUID?
    @State private var contentRevealed = false
    @State private var absorbingTaskIds: Set<UUID> = []
    /// Pending debounced hover transition (dwell before expanding, grace
    /// period before collapsing). Cancelled whenever the hover state flips
    /// again before the deadline.
    @State private var hoverTransitionWorkItem: DispatchWorkItem?
    /// Draft text for the inline quick-reply composer. Reset whenever the
    /// surfaced session changes so a half-typed answer can't leak into
    /// another agent's conversation.
    @State private var quickReplyText = ""
    @State private var isQuickReplyFocused = false
    @State private var isQuickReplyComposing = false
    @State private var renamingTaskId: UUID?
    @State private var renameDraft = ""
    @FocusState private var isRenameFocused: Bool
    /// Selected options for a multi-select clarify prompt rendered inline.
    @State private var selectedClarifyOptions: Set<String> = []

    // MARK: - Metrics & Colors

    private var metrics: NotchScreenMetrics { windowController.metrics }
    private var notchPrimaryText: Color { .white }
    private var notchSecondaryText: Color { Color.white.opacity(0.7) }
    private var notchTertiaryText: Color { Color.white.opacity(0.45) }

    // MARK: - Derived Properties

    /// Render-ready, pre-sorted toast tasks. The ordering is computed once in
    /// `BackgroundTaskManager` when the task set or a task's state changes;
    /// reading it here avoids re-running filter+sort on every body access.
    private var sortedTasks: [BackgroundTaskState] { taskManager.sortedToastTasks }

    /// Tasks grouped into one tab per agent, ordered by each agent's
    /// highest-priority task.
    private var agentGroups: [NotchAgentGroup] { NotchTaskGrouping.groups(from: sortedTasks) }

    /// The stored selection resolved against the live groups, with
    /// fallback to the first group / its highest-priority task.
    private var resolvedSelection: (group: NotchAgentGroup, task: BackgroundTaskState)? {
        NotchTaskGrouping.resolveSelection(
            groups: agentGroups,
            selectedAgentId: selectedAgentId,
            selectedTaskId: selectedTaskId
        )
    }

    /// The session detailed in the expanded card.
    private var activeTask: BackgroundTaskState? { resolvedSelection?.task }

    /// The globally highest-priority task — drives the compact pill so the
    /// collapsed notch always reflects the most urgent work.
    private var compactTask: BackgroundTaskState? { sortedTasks.first }

    /// In-flight inline plugin call to surface when there's no dispatched
    /// `BackgroundTaskState` to render. Lets the user see that, e.g., the
    /// Telegram plugin is generating a reply via `complete_stream` even
    /// though the call never created a task.
    private var topPluginActivity: PluginActivityRecord? {
        guard sortedTasks.isEmpty else { return nil }
        return pluginActivity.topActivity
    }

    private var expansion: NotchExpansion {
        if !sortedTasks.isEmpty {
            return (isHovering || isQuickReplyFocused || isRenameFocused) ? .expanded : .compact
        }
        if topPluginActivity != nil { return isHovering ? .expanded : .compact }
        return .hidden
    }

    private func statusColor(for task: BackgroundTaskState?) -> Color {
        guard let task else { return theme.accentColorLight }
        switch task.status {
        case .queued: return notchTertiaryText
        case .running: return theme.accentColorLight
        case .waitingForInput: return theme.warningColor
        case .completed: return theme.successColor
        case .failed: return theme.errorColor
        case .cancelled: return notchTertiaryText
        }
    }

    /// Accent for the expanded card (selected session) or the compact pill
    /// (highest-priority session).
    private var accentColor: Color {
        statusColor(for: expansion == .compact ? compactTask : (activeTask ?? compactTask))
    }

    // MARK: - Sizing

    private var notchWidth: CGFloat {
        switch expansion {
        case .hidden: return 0
        case .compact: return metrics.notchWidth + 60
        case .expanded: return max(460, metrics.notchWidth + 210)
        }
    }

    /// Extra top inset for the expanded card when the overlay is anchored on
    /// the menu bar and the display has a physical notch. The panel's top edge
    /// then sits at the very top of the screen, so the hardware notch cutout
    /// overlaps the card's header; push the content down past it (issue #1951).
    /// Zero for below-the-menu-bar placement, non-notch displays, and the
    /// compact pill (whose icons are meant to straddle the cutout).
    private var hardwareNotchTopInset: CGFloat {
        guard expansion == .expanded,
            metrics.hasHardwareNotch,
            NotchOverlayPlacement.resolved(for: metrics) == .onMenuBar
        else { return 0 }
        return metrics.notchHeight
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

    /// Resolves the agent behind a task/tab so we can render its avatar
    /// and name. Falls back to the default agent when the id is missing
    /// or the agent has since been deleted.
    private func agent(withId agentId: UUID?) -> Agent {
        if let agentId,
            let match = AgentManager.shared.agents.first(where: { $0.id == agentId })
        {
            return match
        }
        return AgentManager.shared.agents.first(where: { $0.id == Agent.defaultId }) ?? .default
    }

    @ViewBuilder
    private func notchAvatar(agent: Agent, size: CGFloat) -> some View {
        if agent.isBuiltIn {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            }
            .frame(width: size, height: size)
        } else {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: agentColorFor(agent.name),
                diameter: size,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: size * 0.5,
                borderWidth: 1
            )
        }
    }

    private var currentShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    // MARK: - Animation

    private var swingSpring: Animation {
        .spring(response: 0.45, dampingFraction: 0.68, blendDuration: 0.1)
    }

    /// Collapse animation. The bouncy `swingSpring` reads as playful on the
    /// way open but as judder on the way closed — the card overshoots past
    /// pill size and rebounds after its content has already faded. Nearly
    /// critically damped so the collapse settles in one motion.
    private var settleSpring: Animation {
        .spring(response: 0.38, dampingFraction: 0.9, blendDuration: 0.1)
    }

    /// Direction-aware animation for expansion-state changes.
    private var expansionAnimation: Animation {
        expansion == .expanded ? swingSpring : settleSpring
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
        .padding(.top, windowController.alertContentTopPadding)
        .animation(expansionAnimation, value: expansion)
        .animation(swingSpring, value: sortedTasks.map(\.id))
        .animation(swingSpring, value: selectedAgentId)
        .animation(swingSpring, value: selectedTaskId)
        .onChange(of: sortedTasks.map(\.id)) { _, ids in
            // Drop stale stored selections so a later tap starts from the
            // resolved fallback rather than resurrecting a finalized id.
            if let taskId = selectedTaskId, !ids.contains(taskId) {
                selectedTaskId = nil
            }
            if let agentId = selectedAgentId,
                !sortedTasks.contains(where: { $0.agentId == agentId })
            {
                selectedAgentId = nil
            }
        }
        .onChange(of: activeTask?.id) { _, _ in
            // A different session is now surfaced — clear reply drafts so
            // they can't be submitted into the wrong conversation.
            quickReplyText = ""
            selectedClarifyOptions = []
            isQuickReplyFocused = false
            renamingTaskId = nil
            renameDraft = ""
            isRenameFocused = false
        }
        .onChange(of: isHovering) { _, _ in handleHoverChange() }
        .onChange(of: isQuickReplyFocused) { _, _ in handleHoverChange() }
        .onChange(of: isRenameFocused) { _, _ in handleHoverChange() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NotchWindowController.navigateToPreviousSessionNotification
            )
        ) { _ in
            navigateSession(by: -1)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NotchWindowController.navigateToNextSessionNotification
            )
        ) { _ in
            navigateSession(by: 1)
        }
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
            .onHover(perform: handleBodyHover)
            .shadow(
                color: Color.black.opacity(expansion == .compact ? 0 : (isHovering ? 0.6 : 0.4)),
                radius: expansion == .compact ? 0 : (isHovering ? 20 : 12),
                x: 0,
                y: expansion == .compact ? 0 : (isHovering ? 10 : 6)
            )
            .themedAlert(
                L("Cancel Background Task?"),
                isPresented: $showCancelConfirmation,
                message: L("The task is still running. Dismissing will cancel it."),
                primaryButton: .destructive(L("Cancel Task")) {
                    if let task = activeTask {
                        BackgroundTaskManager.shared.cancelTask(task.id)
                        BackgroundTaskManager.shared.openTaskWindow(task.id)
                    }
                },
                secondaryButton: .cancel(L("Keep Running")),
                presentationStyle: .window
            )
            .themedAlert(
                L("Close Agent Tab?"),
                isPresented: $showCloseAgentConfirmation,
                message: L("This agent still has active sessions. Closing the tab cancels all of them."),
                primaryButton: .destructive(L("Cancel Sessions")) {
                    if let agentId = pendingCloseAgentId {
                        closeAgentGroup(agentId: agentId)
                    }
                    pendingCloseAgentId = nil
                },
                secondaryButton: .cancel(L("Keep Running")) {
                    pendingCloseAgentId = nil
                },
                presentationStyle: .window
            )
    }

    /// Hover on the notch body — the only entry point for expansion, sized
    /// by whatever is actually rendered (compact pill or expanded card).
    /// Both directions are debounced. Expanding requires a short dwell: the
    /// pill floats over whatever window sits below (e.g. a browser's tab
    /// strip), so a cursor merely passing through on its way to that window
    /// must not balloon the card open and steal the click. Collapsing gets a
    /// grace period so skimming the card's edge (or the jitter of a hand
    /// coming to rest) doesn't slam it shut and replay the animation.
    private func handleBodyHover(_ hovering: Bool) {
        hoverTransitionWorkItem?.cancel()
        hoverTransitionWorkItem = nil
        guard hovering != isHovering else { return }
        let delay = hovering ? 0.15 : 0.2
        let work = DispatchWorkItem {
            withAnimation(hovering ? swingSpring : settleSpring) { isHovering = hovering }
        }
        hoverTransitionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
                    // Plain .opacity removal leaves a full-size ghost of the
                    // card cross-fading over the already-final-size pill, so
                    // the collapse reads as an abrupt size snap. Scaling the
                    // outgoing card toward its top anchor makes it visibly
                    // retract into the pill instead.
                    : .asymmetric(
                        insertion: .opacity,
                        removal: .scale(scale: 0.12, anchor: .top)
                            .combined(with: .opacity)
                    )
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
        if compactTask != nil || topPluginActivity != nil {
            notchAvatar(agent: agent(withId: compactTask?.agentId), size: orbSize)
                .overlay(alignment: .bottomTrailing) {
                    // Aggregate count so the collapsed pill signals there is
                    // more than the one surfaced session.
                    if sortedTasks.count > 1 {
                        Text("\(sortedTasks.count)")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.28)))
                            .offset(x: 7, y: 4)
                    }
                }
                .animation(swingSpring, value: orbSize)
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
        }
    }

    @ViewBuilder
    private var compactTrailing: some View {
        if let task = compactTask {
            switch task.status {
            case .queued, .running, .waitingForInput:
                // Chat tasks don't expose structured progress — show
                // indeterminate ring (passing -1 makes NotchProgressRing
                // animate continuously).
                NotchProgressRing(progress: -1, color: accentColor, size: 14, lineWidth: 1.5)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            case .completed:
                MorphingStatusIcon(
                    state: .completed,
                    accentColor: theme.successColor,
                    size: 14
                )
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            case .failed:
                MorphingStatusIcon(
                    state: .failed,
                    accentColor: theme.errorColor,
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
            VStack(alignment: .leading, spacing: 12) {
                if let selection = resolvedSelection {
                    activeAgentHeader(group: selection.group)

                    if agentGroups.count > 1 {
                        NotchAgentTabRail(
                            groups: agentGroups,
                            selectedAgentId: selection.group.agentId,
                            agentResolver: agent(withId:),
                            avatarBuilder: { agent, size in AnyView(notchAvatar(agent: agent, size: size)) },
                            statusColor: { statusColor(for: $0) },
                            onSelect: selectAgent,
                            onClose: requestCloseAgentGroup
                        )
                    }

                    if selection.group.tasks.count > 1 {
                        NotchSessionRail(
                            tasks: selection.group.tasks,
                            selectedTaskId: selection.task.id,
                            statusColor: { statusColor(for: $0) },
                            onSelect: selectTask,
                            onRename: beginRename,
                            onPrevious: { navigateSession(by: -1) },
                            onNext: { navigateSession(by: 1) }
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        expandedHeader(task: selection.task)
                        expandedBody(for: selection.task)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .id(selection.task.id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        )
                    )
                } else if let activity = topPluginActivity {
                    pluginActivityHeader(activity)
                    expandedPluginActivityBody(activity: activity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6 + hardwareNotchTopInset)
            .padding(.bottom, 14)
            .opacity(contentRevealed ? 1 : 0)
            .offset(y: contentRevealed ? 0 : 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A persistent agent identity band anchors the hierarchy. It remains
    /// visible even when there is only one agent (where an agent tab rail
    /// would otherwise disappear), making it unambiguous whose sessions
    /// the user is browsing.
    private func activeAgentHeader(group: NotchAgentGroup) -> some View {
        let selectedAgent = agent(withId: group.agentId)
        return HStack(spacing: 10) {
            notchAvatar(agent: selectedAgent, size: 34)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor(for: group.primaryTask))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedAgent.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(notchPrimaryText)
                    .lineLimit(1)

                Text(agentSummary(for: group))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(notchSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if agentGroups.count == 1 {
                Button(action: { requestCloseAgentGroup(group) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(notchTertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(L("Close agent tab"))
                .accessibilityLabel(Text("Close agent tab", bundle: .module))
            }
        }
    }

    private func expandedHeader(task: BackgroundTaskState) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if renamingTaskId == task.id {
                    TextField("", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(notchPrimaryText)
                        .focused($isRenameFocused)
                        .onSubmit { commitRename(task: task) }
                        .onExitCommand { cancelRename() }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(accentColor.opacity(0.55), lineWidth: 1)
                        )
                        .accessibilityLabel(Text("Rename session", bundle: .module))
                } else {
                    HStack(spacing: 5) {
                        Text(task.taskTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(notchPrimaryText)
                            .lineLimit(1)
                        Button(action: { beginRename(task) }) {
                            Image(systemName: "pencil")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundColor(notchTertiaryText)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help(L("Rename session"))
                        .accessibilityLabel(Text("Rename session", bundle: .module))
                    }
                }
                if let origin = headerOrigin(for: task) {
                    Text(origin)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(notchTertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Text(task.status.displayName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(statusColor(for: task))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(statusColor(for: task).opacity(0.12)))

            Button(action: handleDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(notchTertiaryText)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close session", bundle: .module))
        }
    }

    private func pluginActivityHeader(_ activity: PluginActivityRecord) -> some View {
        HStack(spacing: 8) {
            notchAvatar(agent: agent(withId: nil), size: orbSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.pluginDisplayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(notchPrimaryText)
                    .lineLimit(1)
                Text("Working", bundle: .module)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(notchTertiaryText)
            }

            Spacer(minLength: 4)
        }
    }

    // MARK: - Session Detail Bodies

    @ViewBuilder
    private func expandedBody(for task: BackgroundTaskState) -> some View {
        switch task.status {
        case .queued, .running:
            expandedRunningBody(task: task)
        case .waitingForInput:
            expandedWaitingBody(task: task)
        case .completed(let summary):
            expandedCompletedBody(summary: summary, task: task)
        case .failed(let summary):
            expandedFailedBody(summary: summary, task: task)
        case .cancelled:
            expandedCancelledBody(task: task)
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
            IndeterminateShimmerProgress(color: accentColor, height: 3)
            if hasActivityItems(for: task) { expandedActivityFeed(task: task) }

            notchActionButton("Open Chat") {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
        }
    }

    /// Waiting-for-input detail: the clarify question with inline answer
    /// controls (option chips / free-form field), mirroring the in-chat
    /// `ClarifyPromptOverlay` interaction modes. "Open Chat" stays
    /// available for answering with full conversation context.
    private func expandedWaitingBody(task: BackgroundTaskState) -> some View {
        let payload = task.chatSession?.awaitingClarify
        return VStack(alignment: .leading, spacing: 8) {
            if !contextMessages(for: task, maxMessages: 2).isEmpty {
                conversationContext(task: task, maxMessages: 2)
            }

            if let question = payload?.question, !question.isEmpty {
                Text(question)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(notchPrimaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let step = task.currentStep {
                Text(step)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(notchSecondaryText)
                    .lineLimit(2)
            }

            if let payload, !payload.options.isEmpty {
                clarifyOptionChips(payload: payload, task: task)
                if payload.allowMultiple {
                    clarifyMultiSelectSubmitRow(payload: payload, task: task)
                }
            }

            // Free-form input: the only path for optionless questions, and
            // the "my answer isn't on the menu" escape hatch alongside
            // single-select chips. Multi-select keeps the structured answer
            // unambiguous by omitting it, matching ClarifyPromptOverlay.
            if payload?.allowMultiple != true {
                quickReplyComposer(
                    task: task,
                    placeholder: (payload?.options.isEmpty ?? true)
                        ? "Type your answer…"
                        : "Or type a custom answer…"
                )
            }

            notchActionButton("Open Chat") {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
        }
    }

    private func expandedCompletedBody(summary: String, task: BackgroundTaskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !contextMessages(for: task, maxMessages: 4).isEmpty {
                conversationContext(task: task, maxMessages: 4)
            } else {
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(notchSecondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            quickReplyComposer(task: task, placeholder: "Reply to follow up…")

            notchActionButton("View Chat") {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
        }
    }

    private func conversationContext(task: BackgroundTaskState, maxMessages: Int) -> some View {
        let messages = contextMessages(for: task, maxMessages: maxMessages)
        let selectedAgent = agent(withId: task.agentId)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.bubble")
                    .font(.system(size: 9, weight: .semibold))
                Text("RECENT CONTEXT", bundle: .module)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.9)
                Spacer()
            }
            .foregroundColor(notchTertiaryText)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.role == "user" ? L("You") : selectedAgent.name)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(
                                    message.role == "user"
                                        ? notchTertiaryText
                                        : statusColor(for: task)
                                )
                            Text(message.content)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(notchSecondaryText)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: 128)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private func expandedFailedBody(summary: String, task: BackgroundTaskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(notchSecondaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasActivityItems(for: task) { expandedActivityFeed(task: task) }

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
            if hasActivityItems(for: task) { expandedActivityFeed(task: task) }

            notchActionButton("View Chat") {
                BackgroundTaskManager.shared.openTaskWindow(task.id)
            }
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Quick Reply

    private func quickReplyComposer(task: BackgroundTaskState, placeholder: String) -> some View {
        let canSubmit = !quickReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                EditableTextView(
                    text: $quickReplyText,
                    fontSize: 12,
                    textColor: notchPrimaryText,
                    cursorColor: accentColor,
                    isFocused: $isQuickReplyFocused,
                    isComposing: $isQuickReplyComposing,
                    maxHeight: 76,
                    onCommit: { submitQuickReplyText(task: task) },
                    onShiftCommit: nil,  // Shift+Enter inserts a newline.
                    onEscape: {
                        isQuickReplyFocused = false
                        return true
                    }
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 5)
                .padding(.vertical, 7)
                .overlay(alignment: .topLeading) {
                    if quickReplyText.isEmpty {
                        Text(LocalizedStringKey(placeholder), bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(notchTertiaryText)
                            .padding(.leading, 11)
                            .padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(isQuickReplyFocused ? 0.1 : 0.065))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isQuickReplyFocused ? accentColor.opacity(0.7) : Color.white.opacity(0.12),
                            lineWidth: isQuickReplyFocused ? 1.5 : 1
                        )
                )
                .shadow(color: isQuickReplyFocused ? accentColor.opacity(0.14) : .clear, radius: 8)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        windowController.prepareForTextInput()
                        DispatchQueue.main.async { isQuickReplyFocused = true }
                    }
                )
                .accessibilityLabel(Text("Quick reply", bundle: .module))

                Button(action: { submitQuickReplyText(task: task) }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(canSubmit ? .white : notchTertiaryText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSubmit ? accentColor.opacity(0.85) : Color.white.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(canSubmit ? 0.18 : 0.06), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityLabel(Text("Send reply", bundle: .module))
            }

            if isQuickReplyFocused {
                Text("↵ send  ·  ⇧↵ new line  ·  esc dismiss", bundle: .module)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundColor(notchTertiaryText)
                    .padding(.leading, 3)
                    .transition(.opacity)
            }
        }
    }

    private func clarifyOptionChips(payload: ClarifyPayload, task: BackgroundTaskState) -> some View {
        ChipFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(payload.options, id: \.self) { option in
                notchClarifyChip(option, allowMultiple: payload.allowMultiple, task: task)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notchClarifyChip(
        _ option: String,
        allowMultiple: Bool,
        task: BackgroundTaskState
    ) -> some View {
        let isSelected = selectedClarifyOptions.contains(option)
        return Button {
            if allowMultiple {
                if isSelected {
                    selectedClarifyOptions.remove(option)
                } else {
                    selectedClarifyOptions.insert(option)
                }
            } else {
                // Single-select: tapping IS the submission (matching the
                // in-chat clarify card).
                submitQuickReply(task: task, answer: option)
            }
        } label: {
            HStack(spacing: 4) {
                if allowMultiple {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isSelected ? accentColor : notchTertiaryText)
                }
                Text(option)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? notchPrimaryText : notchSecondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? accentColor.opacity(0.22) : Color.white.opacity(0.07))
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? accentColor.opacity(0.5) : Color.white.opacity(0.12),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option))
    }

    private func clarifyMultiSelectSubmitRow(
        payload: ClarifyPayload,
        task: BackgroundTaskState
    ) -> some View {
        HStack {
            Text(
                selectedClarifyOptions.isEmpty
                    ? L("Pick one or more above.")
                    : "\(selectedClarifyOptions.count) selected"
            )
            .font(.system(size: 9.5, weight: .medium))
            .foregroundColor(notchTertiaryText)

            Spacer()

            Button {
                // Preserve the order the model gave us so the submitted
                // answer reflects intent (matching ClarifyPromptOverlay).
                let ordered = payload.options.filter { selectedClarifyOptions.contains($0) }
                guard !ordered.isEmpty else { return }
                submitQuickReply(task: task, answer: ordered.joined(separator: ", "))
            } label: {
                Text("Submit", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(selectedClarifyOptions.isEmpty ? notchTertiaryText : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(
                            selectedClarifyOptions.isEmpty
                                ? Color.white.opacity(0.08)
                                : accentColor.opacity(0.85)
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedClarifyOptions.isEmpty)
            .accessibilityLabel(Text("Submit selected options", bundle: .module))
        }
    }

    private func submitQuickReplyText(task: BackgroundTaskState) {
        let trimmed = quickReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submitQuickReply(task: task, answer: trimmed)
    }

    private func submitQuickReply(task: BackgroundTaskState, answer: String) {
        if BackgroundTaskManager.shared.submitQuickReply(task.id, text: answer) {
            quickReplyText = ""
            selectedClarifyOptions = []
        }
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
    }

    // MARK: - Helpers

    private func selectAgent(_ group: NotchAgentGroup) {
        windowController.prepareForTextInput()
        withAnimation(swingSpring) {
            selectedAgentId = group.agentId
            selectedTaskId = nil
        }
    }

    private func selectTask(_ task: BackgroundTaskState) {
        windowController.prepareForTextInput()
        withAnimation(swingSpring) {
            selectedAgentId = task.agentId
            selectedTaskId = task.id
        }
    }

    private func beginRename(_ task: BackgroundTaskState) {
        windowController.prepareForTextInput()
        renamingTaskId = task.id
        renameDraft = task.taskTitle
        DispatchQueue.main.async { isRenameFocused = true }
    }

    private func commitRename(task: BackgroundTaskState) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelRename()
            return
        }
        _ = BackgroundTaskManager.shared.renameTask(task.id, title: trimmed)
        renamingTaskId = nil
        renameDraft = ""
        isRenameFocused = false
    }

    private func cancelRename() {
        renamingTaskId = nil
        renameDraft = ""
        isRenameFocused = false
    }

    private func contextMessages(
        for task: BackgroundTaskState,
        maxMessages: Int
    ) -> [BackgroundTaskContextMessage] {
        if let session = task.chatSession {
            return
                session.turns
                .filter { turn in
                    (turn.role == .user || turn.role == .assistant)
                        && !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .suffix(maxMessages)
                .map {
                    BackgroundTaskContextMessage(
                        role: $0.role.rawValue,
                        content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
        }
        return Array(task.contextPreview.suffix(maxMessages))
    }

    /// Cycle within the selected agent's sessions. Navigation wraps so the
    /// arrows and ⌘← / ⌘→ remain useful at either end of the rail.
    private func navigateSession(by offset: Int) {
        guard let selection = resolvedSelection,
            let currentIndex = selection.group.tasks.firstIndex(where: { $0.id == selection.task.id }),
            !selection.group.tasks.isEmpty
        else { return }
        let count = selection.group.tasks.count
        let nextIndex = (currentIndex + offset + count) % count
        selectTask(selection.group.tasks[nextIndex])
    }

    private func agentSummary(for group: NotchAgentGroup) -> String {
        if group.primaryTask?.status == .waitingForInput {
            return group.tasks.count == 1
                ? L("Needs your input")
                : "\(L("Needs your input")) · \(group.tasks.count) \(L("sessions"))"
        }
        if group.activeTaskCount > 0 {
            let sessionLabel = group.tasks.count == 1 ? L("session") : L("sessions")
            return "\(group.activeTaskCount) \(L("active")) · \(group.tasks.count) \(sessionLabel)"
        }
        return group.tasks.count == 1
            ? L("Recent session")
            : "\(group.tasks.count) \(L("recent sessions"))"
    }

    private func hasActivityItems(for task: BackgroundTaskState) -> Bool {
        task.activityFeed.count > 1
            || (task.activityFeed.count == 1 && task.activityFeed.first?.kind != .info)
    }

    /// Surfaces the dispatch origin when an integration is driving the task.
    /// Status already appears in the adjacent pill, so repeating it here
    /// would add noise for ordinary chat sessions.
    private func headerOrigin(for task: BackgroundTaskState) -> String? {
        let pluginName = task.sourcePluginId.map(PluginDisplayNameResolver.displayName(for:))
        return task.source.originLabel(pluginDisplayName: pluginName)
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
        if isHovering || isQuickReplyFocused || isRenameFocused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard isHovering || isQuickReplyFocused || isRenameFocused else { return }
                withAnimation(.easeOut(duration: 0.25)) { contentRevealed = true }
            }
        } else {
            // Fade the content over the same window as the frame's settle
            // spring. A fast fade makes the card read as "already collapsed"
            // the instant the content blinks out, so the frame's shrink looks
            // abrupt even though it animates — the eye tracks the content,
            // not the border.
            withAnimation(.easeInOut(duration: 0.3)) { contentRevealed = false }
        }
    }

    // MARK: - Close Actions

    /// Close one agent tab. Active work requires an explicit confirmation
    /// (mass-cancelling silently would be destructive); a tab holding only
    /// finished sessions closes immediately.
    private func requestCloseAgentGroup(_ group: NotchAgentGroup) {
        if group.hasActiveTasks {
            pendingCloseAgentId = group.agentId
            showCloseAgentConfirmation = true
        } else {
            closeAgentGroup(agentId: group.agentId)
        }
    }

    private func closeAgentGroup(agentId: UUID) {
        withAnimation(swingSpring) {
            BackgroundTaskManager.shared.closeAgentTaskGroup(agentId: agentId)
        }
        if selectedAgentId == agentId {
            selectedAgentId = nil
            selectedTaskId = nil
        }
    }

    /// Close the surfaced session: confirm-cancel for active work, absorb
    /// animation + finalize for finished work.
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
