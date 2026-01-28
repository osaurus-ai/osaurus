//
//  IssueTrackerPanel.swift
//  osaurus
//
//  Panel displaying issues for the current agent task with status indicators.
//

import SwiftUI

struct IssueTrackerPanel: View {
    let issues: [Issue]
    /// ID of the issue currently being executed
    let activeIssueId: String?
    /// ID of the issue currently selected for viewing
    let selectedIssueId: String?
    /// Called when user clicks to view an issue's details
    let onIssueSelect: (Issue) -> Void
    /// Called when user clicks to run/execute an issue
    let onIssueRun: (Issue) -> Void
    /// Called when user closes an issue
    let onIssueClose: (String) -> Void

    @Environment(\.theme) private var theme: ThemeProtocol

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Issues")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                // Progress summary
                HStack(spacing: 8) {
                    ProgressBadge(
                        count: completedCount,
                        total: issues.count,
                        color: .green,
                        label: "completed"
                    )

                    if blockedCount > 0 {
                        ProgressBadge(
                            count: blockedCount,
                            total: issues.count,
                            color: .orange,
                            label: "blocked"
                        )
                    }
                }
            }

            // Issues list
            if issues.isEmpty {
                emptyState
            } else {
                issuesList
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground.opacity(0.5))
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundColor(theme.tertiaryText)

            Text("No issues yet")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Issues List

    private var issuesList: some View {
        VStack(spacing: 8) {
            ForEach(sortedIssues) { issue in
                IssueRow(
                    issue: issue,
                    isActive: issue.id == activeIssueId,
                    isSelected: issue.id == selectedIssueId,
                    onSelect: { onIssueSelect(issue) },
                    onRun: { onIssueRun(issue) },
                    onClose: { onIssueClose(issue.id) }
                )
            }
        }
    }

    // MARK: - Computed Properties

    private var sortedIssues: [Issue] {
        issues.sorted { lhs, rhs in
            // Active issues first
            if (lhs.id == activeIssueId) != (rhs.id == activeIssueId) {
                return lhs.id == activeIssueId
            }
            // Selected issue next
            if (lhs.id == selectedIssueId) != (rhs.id == selectedIssueId) {
                return lhs.id == selectedIssueId
            }
            // Then by status (in_progress > open > blocked > closed)
            let statusOrder: [IssueStatus] = [.inProgress, .open, .blocked, .closed]
            let lhsOrder = statusOrder.firstIndex(of: lhs.status) ?? 4
            let rhsOrder = statusOrder.firstIndex(of: rhs.status) ?? 4
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            // Then by priority
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            // Then by creation date
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var completedCount: Int {
        issues.filter { $0.status == .closed }.count
    }

    private var blockedCount: Int {
        issues.filter { $0.status == .blocked }.count
    }
}

// MARK: - Issue Row

private struct IssueRow: View {
    let issue: Issue
    /// Whether this issue is currently being executed
    let isActive: Bool
    /// Whether this issue is selected for viewing details
    let isSelected: Bool
    /// Called when user clicks to view issue details
    let onSelect: () -> Void
    /// Called when user clicks to run/execute the issue
    let onRun: () -> Void
    /// Called when user closes the issue
    let onClose: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Status icon
            statusIcon
                .frame(width: 20, height: 20)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Issue ID
                    Text(issue.id)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)

                    // Priority badge
                    priorityBadge
                }

                // Title
                Text(issue.title)
                    .font(.system(size: 13, weight: (isActive || isSelected) ? .semibold : .regular))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Actions (visible on hover or when not closed)
            if isHovered && issue.status != .closed {
                HStack(spacing: 6) {
                    // Run button - only show for open issues that aren't already active
                    if issue.status == .open && !isActive {
                        Button(action: onRun) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                                .frame(width: 20, height: 20)
                                .background(
                                    Circle()
                                        .fill(Color.green.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Run this issue")
                    }

                    // Close button
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(theme.tertiaryBackground.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Close issue")
                }
            }

            // Type indicator (hidden when hovering to make room for actions)
            if !isHovered || issue.status == .closed {
                typeIndicator
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            // Tap always selects for viewing (any status)
            onSelect()
        }
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch issue.status {
        case .open:
            Circle()
                .stroke(Color.blue, lineWidth: 2)
        case .inProgress:
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.orange, lineWidth: 2)
                    .rotationEffect(.degrees(-90))
            }
        case .blocked:
            Image(systemName: "pause.circle.fill")
                .foregroundColor(.orange)
        case .closed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        }
    }

    // MARK: - Priority Badge

    @ViewBuilder
    private var priorityBadge: some View {
        Text(issue.priority.shortName)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(priorityColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(priorityColor.opacity(0.15))
            )
    }

    private var priorityColor: Color {
        switch issue.priority {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .blue
        case .p3: return .gray
        }
    }

    // MARK: - Type Indicator

    @ViewBuilder
    private var typeIndicator: some View {
        Image(systemName: typeIcon)
            .font(.system(size: 10))
            .foregroundColor(typeColor)
    }

    private var typeIcon: String {
        switch issue.type {
        case .task: return "checkmark.square"
        case .bug: return "ladybug"
        case .discovery: return "lightbulb"
        }
    }

    private var typeColor: Color {
        switch issue.type {
        case .task: return theme.tertiaryText
        case .bug: return .red
        case .discovery: return .yellow
        }
    }

    // MARK: - Background & Border

    private var backgroundColor: Color {
        if isActive {
            return Color.orange.opacity(0.1)
        } else if isSelected {
            return theme.accentColor.opacity(0.08)
        } else if isHovered {
            return theme.tertiaryBackground.opacity(0.5)
        } else if issue.status == .closed {
            return theme.tertiaryBackground.opacity(0.3)
        } else {
            return Color.clear
        }
    }

    private var borderColor: Color {
        if isActive {
            return Color.orange.opacity(0.5)
        } else if isSelected {
            return theme.accentColor.opacity(0.4)
        } else {
            return Color.clear
        }
    }

    private var borderWidth: CGFloat {
        (isActive || isSelected) ? 1.5 : 0
    }
}

// MARK: - Progress Badge

private struct ProgressBadge: View {
    let count: Int
    let total: Int
    let color: Color
    let label: String

    @Environment(\.theme) private var theme: ThemeProtocol

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)/\(total)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
        )
    }
}
