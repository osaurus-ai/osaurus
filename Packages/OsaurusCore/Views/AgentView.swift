//
//  AgentView.swift
//  osaurus
//
//  Main view for agent mode - displays task execution with issue tracking.
//

import SwiftUI

struct AgentView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: AgentSession

    @State private var showSidebar: Bool = false
    @State private var isPinnedToBottom: Bool = true

    // Progress sidebar state (right side)
    @State private var progressSidebarWidth: CGFloat = 280
    @State private var isProgressSidebarCollapsed: Bool = false
    private let minProgressSidebarWidth: CGFloat = 200
    private let maxProgressSidebarWidth: CGFloat = 400

    private var theme: ThemeProtocol { windowState.theme }

    var body: some View {
        GeometryReader { proxy in
            let sidebarWidth: CGFloat = showSidebar ? 240 : 0
            let mainWidth = proxy.size.width - sidebarWidth

            HStack(alignment: .top, spacing: 0) {
                // Sidebar - Task list
                if showSidebar {
                    AgentTaskSidebar(
                        tasks: windowState.agentTasks,
                        currentTaskId: session.currentTask?.id,
                        onSelect: { task in
                            Task {
                                await session.loadTask(task)
                            }
                        },
                        onDelete: { taskId in
                            Task {
                                try? await IssueManager.shared.deleteTask(taskId)
                                windowState.refreshAgentTasks()
                                if session.currentTask?.id == taskId {
                                    session.currentTask = nil
                                    session.issues = []
                                }
                            }
                        }
                    )
                    .transition(.move(edge: .leading))
                }

                // Main content
                ZStack {
                    // Background
                    agentBackground

                    VStack(spacing: 0) {
                        // Header
                        agentHeader

                        // Content
                        if session.currentTask == nil {
                            // Empty state - no task selected
                            agentEmptyState
                        } else {
                            // Task execution view
                            taskExecutionView(width: mainWidth)
                        }

                        // Input card - reuse FloatingInputCard for consistency
                        FloatingInputCard(
                            text: $session.input,
                            selectedModel: $session.selectedModel,
                            pendingImages: .constant([]),
                            isContinuousVoiceMode: .constant(false),
                            voiceInputState: .constant(.idle),
                            showVoiceOverlay: .constant(false),
                            modelOptions: session.modelOptions,
                            isStreaming: session.isExecuting,
                            supportsImages: false,
                            estimatedContextTokens: session.estimatedContextTokens,
                            onSend: { Task { await session.handleUserInput() } },
                            onStop: { session.stopExecution() },
                            personaId: windowState.personaId,
                            windowId: windowState.windowId
                        )
                    }
                }
            }
        }
        .frame(minWidth: 800, idealWidth: 950)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            windowControls
        }
        .ignoresSafeArea()
        .animation(theme.animationQuick(), value: showSidebar)
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
    }

    // MARK: - Window Controls

    private var windowControls: some View {
        HStack(spacing: 8) {
            if session.currentTask == nil {
                SettingsButton(action: {
                    AppDelegate.shared?.showManagementWindow(initialTab: .settings)
                })
            } else {
                HeaderActionButton(
                    icon: "plus",
                    help: "New task",
                    action: {
                        session.currentTask = nil
                        session.issues = []
                        session.clearSelection()
                    }
                )
            }
            PinButton(windowId: windowState.windowId)
            CloseButton(action: closeWindow)
        }
        .padding(16)
    }

    /// Close this window via ChatWindowManager
    private func closeWindow() {
        ChatWindowManager.shared.closeWindow(id: windowState.windowId)
    }

    // MARK: - Background

    private var agentBackground: some View {
        ZStack {
            // Layer 1: Base background (solid, gradient, or image)
            baseBackgroundLayer
                .clipShape(backgroundShape)

            // Layer 2: Glass effect (if enabled)
            if theme.glassEnabled {
                ThemedGlassSurface(
                    cornerRadius: 24,
                    topLeadingRadius: showSidebar ? 0 : nil,
                    bottomLeadingRadius: showSidebar ? 0 : nil
                )
                .allowsHitTesting(false)

                // Solid backing layer for text contrast
                let baseBackingOpacity = theme.isDark ? 0.6 : 0.7
                let themeBoost = theme.glassOpacityPrimary * 0.8
                let backingOpacity = min(0.92, baseBackingOpacity + themeBoost)

                backgroundShape
                    .fill(theme.primaryBackground.opacity(backingOpacity))
                    .allowsHitTesting(false)

                // Gradient overlay for depth and polish
                LinearGradient(
                    colors: [
                        theme.primaryBackground.opacity(theme.glassOpacityPrimary * 1.5),
                        theme.primaryBackground.opacity(theme.glassOpacitySecondary),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(backgroundShape)
                .allowsHitTesting(false)
            }
        }
    }

    private var backgroundShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: showSidebar ? 0 : 24,
            bottomLeadingRadius: showSidebar ? 0 : 24,
            bottomTrailingRadius: 24,
            topTrailingRadius: 24,
            style: .continuous
        )
    }

    @ViewBuilder
    private var baseBackgroundLayer: some View {
        if let customTheme = theme.customThemeConfig {
            switch customTheme.background.type {
            case .solid:
                Color(themeHex: customTheme.background.solidColor ?? customTheme.colors.primaryBackground)

            case .gradient:
                let colors = (customTheme.background.gradientColors ?? ["#000000", "#333333"])
                    .map { Color(themeHex: $0) }
                LinearGradient(
                    colors: colors,
                    startPoint: .top,
                    endPoint: .bottom
                )

            case .image:
                if let image = windowState.cachedBackgroundImage {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(customTheme.background.imageOpacity ?? 1.0)

                        // Overlay tint for contrast
                        theme.primaryBackground.opacity(0.7)
                    }
                } else {
                    theme.primaryBackground
                }
            }
        } else {
            theme.primaryBackground
        }
    }

    // MARK: - Header

    private var agentHeader: some View {
        ZStack {
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                // Sidebar toggle - far left
                HeaderActionButton(
                    icon: "sidebar.left",
                    help: showSidebar ? "Hide sidebar" : "Show sidebar",
                    action: {
                        withAnimation(theme.animationQuick()) {
                            showSidebar.toggle()
                        }
                    }
                )

                // Mode toggle - Chat mode (to the right of sidebar toggle)
                ModeToggleButton(currentMode: .agent) {
                    windowState.switchMode(to: .chat)
                }

                // Task title
                if let task = session.currentTask {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.leading, 20)
            .padding(.trailing, 56)
        }
        .frame(height: 72)
    }

    // MARK: - Empty State

    private var agentEmptyState: some View {
        AgentEmptyState(
            hasModels: session.modelOptions.count > 0,
            selectedModel: session.selectedModel,
            personas: windowState.personas,
            activePersonaId: windowState.personaId,
            onOpenModelManager: {
                AppDelegate.shared?.showManagementWindow(initialTab: .models)
            },
            onUseFoundation: windowState.foundationModelAvailable
                ? {
                    session.selectedModel = session.modelOptions.first?.id ?? "foundation"
                } : nil,
            onSelectPersona: { newPersonaId in
                windowState.switchPersona(to: newPersonaId)
            }
        )
    }

    // MARK: - Task Execution View

    private func taskExecutionView(width: CGFloat) -> some View {
        let collapsedWidth: CGFloat = 36
        let sidebarWidth = isProgressSidebarCollapsed ? collapsedWidth : progressSidebarWidth
        let chatWidth = width - sidebarWidth

        return HStack(spacing: 0) {
            // Main chat area
            VStack(spacing: 0) {
                // Issue detail view with MessageThreadView
                if session.selectedIssueId != nil && !session.issueBlocks.isEmpty {
                    issueDetailView(width: chatWidth)
                } else if session.selectedIssueId != nil {
                    // Selected issue but no blocks yet (loading or empty)
                    issueEmptyDetailView
                } else {
                    // No issue selected - show prompt
                    noIssueSelectedView
                }

                // Error message with retry button
                if let error = session.errorMessage {
                    errorView(error: error)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            // Resize handle + Progress sidebar (right side)
            if !isProgressSidebarCollapsed {
                // Resize handle
                ProgressSidebarResizeHandle(
                    width: $progressSidebarWidth,
                    minWidth: minProgressSidebarWidth,
                    maxWidth: maxProgressSidebarWidth
                )

                // Progress sidebar
                IssueTrackerPanel(
                    issues: session.issues,
                    activeIssueId: session.activeIssue?.id,
                    selectedIssueId: session.selectedIssueId,
                    isCollapsed: $isProgressSidebarCollapsed,
                    onIssueSelect: { issue in
                        session.selectIssue(issue)
                    },
                    onIssueRun: { issue in
                        Task {
                            await session.executeIssue(issue)
                        }
                    },
                    onIssueClose: { issueId in
                        Task {
                            await session.closeIssue(issueId, reason: "Manually closed")
                        }
                    }
                )
                .frame(width: progressSidebarWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                // Collapsed state - thin expand button
                collapsedProgressSidebar
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(theme.animationQuick(), value: isProgressSidebarCollapsed)
        .onChange(of: isProgressSidebarCollapsed) { _, _ in
            // Clear height cache when sidebar state changes to prevent layout glitches
            MessageHeightCache.shared.clear()
        }
    }

    // MARK: - No Issue Selected View

    private var noIssueSelectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.point.right")
                .font(.system(size: 32))
                .foregroundColor(theme.tertiaryText)

            Text("Select an issue to view details")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Collapsed Progress Sidebar

    private var collapsedProgressSidebar: some View {
        VStack {
            Button {
                withAnimation(theme.animationQuick()) {
                    isProgressSidebarCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show progress")
            .padding(.top, 10)

            Spacer()
        }
        .frame(width: 36)
        .background(theme.primaryBackground.opacity(0.5))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.primaryBorder.opacity(0.2))
                .frame(width: 1)
        }
    }

    // MARK: - Issue Detail View

    /// Maximum content width for chat readability
    private let maxChatContentWidth: CGFloat = 700

    private func issueDetailView(width: CGFloat) -> some View {
        let personaName = windowState.cachedPersonaDisplayName
        // Use available width minus padding, capped at max for readability
        let contentWidth = min(width - 40, maxChatContentWidth)

        return ZStack(alignment: .bottomTrailing) {
            MessageThreadView(
                blocks: session.issueBlocks,
                width: contentWidth,
                personaName: personaName,
                isStreaming: session.isExecuting && session.activeIssue?.id == session.selectedIssueId,
                turnsCount: session.issueBlocks.count,
                lastAssistantTurnId: session.issueBlocks.last?.turnId,
                onCopy: { _ in },
                onRegenerate: { _ in },
                onScrolledToBottom: { isPinnedToBottom = true },
                onScrolledAwayFromBottom: { isPinnedToBottom = false }
            )

            // Scroll to bottom button
            ScrollToBottomButton(
                isPinnedToBottom: isPinnedToBottom,
                hasTurns: !session.issueBlocks.isEmpty,
                onTap: { isPinnedToBottom = true }
            )
        }
        .frame(maxWidth: contentWidth)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var issueEmptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(theme.tertiaryText)

            Text("No execution history")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Text("Select an issue to view its details, or run it to see live execution.")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Error View

    private func errorView(error: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                Spacer()
            }

            if let failedIssue = session.failedIssue {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            session.errorMessage = nil
                            await session.executeIssue(failedIssue, withRetry: true)
                        }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        session.errorMessage = nil
                        session.failedIssue = nil
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Helpers

    private func statusIcon(for status: AgentTaskStatus) -> String {
        switch status {
        case .active: return "play.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private func statusColor(for status: AgentTaskStatus) -> Color {
        switch status {
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .gray
        }
    }
}

// MARK: - Progress Sidebar Resize Handle

private struct ProgressSidebarResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isHovered ? theme.accentColor.opacity(0.5) : theme.primaryBorder.opacity(0.3))
            .frame(width: isHovered ? 3 : 1)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.width
                    }
                    .onChanged { value in
                        // Dragging left increases width, dragging right decreases
                        let newWidth = width - value.translation.width
                        width = min(maxWidth, max(minWidth, newWidth))
                    }
            )
            .animation(theme.animationQuick(), value: isHovered)
    }
}

// MARK: - Shared Header Components
// HeaderActionButton, ModeToggleButton, ModeIndicatorBadge are now in SharedHeaderComponents.swift
