//
//  IssueTrackerPanel.swift
//  osaurus
//
//  Sidebar panel displaying issues for the current agent task with status indicators.
//

import SwiftUI

struct IssueTrackerPanel: View {
    let issues: [Issue]
    /// ID of the issue currently being executed
    let activeIssueId: String?
    /// ID of the issue currently selected for viewing
    let selectedIssueId: String?
    /// Binding to control collapse state
    @Binding var isCollapsed: Bool
    /// Called when user clicks to view an issue's details
    let onIssueSelect: (Issue) -> Void
    /// Called when user clicks to run/execute an issue
    let onIssueRun: (Issue) -> Void
    /// Called when user closes an issue
    let onIssueClose: (String) -> Void

    @Environment(\.theme) private var theme: ThemeProtocol

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerView

            // Scrollable issues list
            if issues.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(theme.primaryBackground.opacity(0.5))
        .overlay(alignment: .leading) {
            // Left border
            Rectangle()
                .fill(theme.primaryBorder.opacity(0.2))
                .frame(width: 1)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Text("Progress")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            // Progress indicator
            if !issues.isEmpty {
                HStack(spacing: 4) {
                    Text("\(completedCount)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.successColor)
                    Text("/")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Text("\(issues.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.tertiaryBackground.opacity(0.5))
                )
            }

            // Collapse button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed = true
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide progress")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(0.3))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundColor(theme.tertiaryText.opacity(0.6))

            Text("Ready to start")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed Properties

    /// Stable sorting: status first, then priority, then creation date
    private var sortedIssues: [Issue] {
        issues.sorted { lhs, rhs in
            // Active issue always first
            if (lhs.id == activeIssueId) != (rhs.id == activeIssueId) {
                return lhs.id == activeIssueId
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
}

// MARK: - Issue Row

private struct IssueRow: View {
    let issue: Issue
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onRun: () -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    /// Display text - use description (full text) if available, otherwise title
    private var displayText: String {
        if let description = issue.description, !description.isEmpty {
            return description
        }
        return issue.title
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Status indicator
            statusIndicator
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Priority + status label
                HStack(spacing: 6) {
                    priorityBadge

                    if isActive {
                        Text("Running")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    } else if issue.status == .closed {
                        Text("Done")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(theme.successColor)
                    }
                }

                // Text content (max 4 lines)
                Text(displayText)
                    .font(.system(size: 12, weight: isActive || isSelected ? .medium : .regular))
                    .foregroundColor(isActive || isSelected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(4)
                    .lineSpacing(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: isActive || isSelected ? 1 : 0)
        )
        .overlay(alignment: .topTrailing) {
            // Actions on hover
            if isHovered && issue.status != .closed {
                actionButtons
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch issue.status {
        case .open:
            Circle()
                .stroke(theme.secondaryText.opacity(0.4), lineWidth: 1.5)
        case .inProgress:
            ZStack {
                Circle()
                    .stroke(theme.accentColor.opacity(0.2), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(theme.accentColor, lineWidth: 1.5)
                    .rotationEffect(.degrees(-90))
            }
        case .blocked:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(theme.warningColor)
        case .closed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(theme.successColor)
        }
    }

    // MARK: - Priority Badge

    private var priorityBadge: some View {
        Text(issue.priority.shortName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(priorityColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(priorityColor.opacity(0.12))
            )
    }

    private var priorityColor: Color {
        switch issue.priority {
        case .p0: return theme.errorColor
        case .p1: return theme.warningColor
        case .p2: return theme.accentColor
        case .p3: return theme.secondaryText
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if issue.status == .open && !isActive {
                Button(action: onRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundColor(theme.successColor)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(theme.primaryBackground))
                        .overlay(Circle().stroke(theme.successColor.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Run")
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(theme.primaryBackground))
                    .overlay(Circle().stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(6)
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.accentColor.opacity(0.08))
        } else if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.accentColor.opacity(0.05))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground.opacity(0.4))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.clear)
        }
    }

    private var borderColor: Color {
        if isActive {
            return theme.accentColor.opacity(0.4)
        } else if isSelected {
            return theme.accentColor.opacity(0.25)
        }
        return Color.clear
    }
}
