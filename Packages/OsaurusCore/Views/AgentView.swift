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
                    .frame(width: 240)
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

                        // Input card
                        agentInputCard
                    }
                }
            }
        }
        .frame(minWidth: 800, idealWidth: 950)
    }

    // MARK: - Background

    @ViewBuilder
    private var agentBackground: some View {
        if let bgImage = windowState.cachedBackgroundImage {
            Image(nsImage: bgImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        } else if let custom = theme.customThemeConfig {
            switch custom.background.type {
            case .solid:
                if let solidColor = custom.background.solidColor {
                    Color(themeHex: solidColor).ignoresSafeArea()
                } else {
                    theme.primaryBackground.ignoresSafeArea()
                }
            case .gradient:
                if let gradientColors = custom.background.gradientColors {
                    LinearGradient(
                        colors: gradientColors.map { Color(themeHex: $0) },
                        startPoint: .top,
                        endPoint: .bottom
                    ).ignoresSafeArea()
                } else {
                    theme.primaryBackground.ignoresSafeArea()
                }
            case .image:
                theme.primaryBackground.ignoresSafeArea()
            }
        } else {
            theme.primaryBackground.ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var agentHeader: some View {
        ZStack {
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                // Sidebar toggle
                HeaderActionButton(
                    icon: "sidebar.left",
                    help: showSidebar ? "Hide sidebar" : "Show sidebar",
                    action: {
                        withAnimation(theme.animationQuick()) {
                            showSidebar.toggle()
                        }
                    }
                )

                // Mode indicator
                HStack(spacing: 6) {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundColor(.orange)
                    Text("Agent Mode")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.15))
                )

                // Task title
                if let task = session.currentTask {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Mode toggle - switch back to chat
                Button(action: {
                    windowState.switchMode(to: .chat)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text("Chat")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(theme.secondaryBackground.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                .help("Switch to Chat mode")
            }
            .padding(.leading, 20)
            .padding(.trailing, 56)
        }
        .frame(height: 72)
    }

    // MARK: - Empty State

    private var agentEmptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bolt.circle")
                .font(.system(size: 64))
                .foregroundColor(theme.tertiaryText)

            Text("Osaurus Agent")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text(
                "Enter a task to get started. The agent will break it down into\nactionable issues and execute them step by step."
            )
            .font(.system(size: 14))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)

            if !windowState.agentTasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Tasks")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.tertiaryText)

                    ForEach(windowState.agentTasks.prefix(3)) { task in
                        Button(action: {
                            Task {
                                await session.loadTask(task)
                            }
                        }) {
                            HStack {
                                Image(systemName: statusIcon(for: task.status))
                                    .foregroundColor(statusColor(for: task.status))
                                Text(task.title)
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.secondaryBackground.opacity(0.5))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 400)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Task Execution View

    private func taskExecutionView(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Progress bar
            if session.isExecuting {
                ProgressView(value: session.currentPlan?.progress ?? 0)
                    .tint(.orange)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            // Issue tracker panel
            IssueTrackerPanel(
                issues: session.issues,
                activeIssueId: session.activeIssue?.id,
                onIssueSelect: { issue in
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
            .frame(maxWidth: min(width - 40, 800))
            .padding(.horizontal, 20)

            // Streaming content / Results
            if !session.streamingContent.isEmpty || session.isExecuting {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.streamingContent.isEmpty ? "Starting..." : session.streamingContent)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)

                            // Anchor for auto-scroll
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                    }
                    .onChange(of: session.streamingContent) { _, _ in
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.secondaryBackground.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            // Error message with retry button
            if let error = session.errorMessage {
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

            // Cancel button during execution
            if session.isExecuting {
                HStack {
                    Spacer()
                    Button {
                        session.stopExecution()
                    } label: {
                        Label(session.isRetrying ? "Cancel Retry" : "Stop Execution", systemImage: "stop.fill")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Spacer()
                }
                .padding(.top, 12)
            }

            Spacer()
        }
    }

    // MARK: - Input Card

    private var agentInputCard: some View {
        VStack(spacing: 0) {
            // Input field
            HStack(spacing: 12) {
                TextField("Enter a task for the agent...", text: $session.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit {
                        Task {
                            await session.startNewTask()
                        }
                    }

                if session.isExecuting {
                    Button(action: {
                        session.stopExecution()
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop execution")
                } else {
                    Button(action: {
                        Task {
                            await session.startNewTask()
                        }
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(session.input.isEmpty ? theme.tertiaryText : .orange)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.input.isEmpty)
                    .help("Start task")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.secondaryBackground)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
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

// MARK: - Header Action Button

private struct HeaderActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
