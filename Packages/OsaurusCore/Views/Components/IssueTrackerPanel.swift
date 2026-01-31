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
    /// Final artifact from task completion
    let finalArtifact: Artifact?
    /// All generated artifacts
    let artifacts: [Artifact]
    /// File operations for undo tracking
    let fileOperations: [AgentFileOperation]
    /// Binding to control collapse state
    @Binding var isCollapsed: Bool
    /// Called when user clicks to view an issue's details
    let onIssueSelect: (Issue) -> Void
    /// Called when user clicks to run/execute an issue
    let onIssueRun: (Issue) -> Void
    /// Called when user closes an issue
    let onIssueClose: (String) -> Void
    /// Called when user wants to view an artifact
    let onArtifactView: (Artifact) -> Void
    /// Called when user wants to download an artifact
    let onArtifactDownload: (Artifact) -> Void
    /// Called when user wants to undo a file operation
    let onUndoOperation: (UUID) -> Void
    /// Called when user wants to undo all file operations
    let onUndoAllOperations: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            if issues.isEmpty && finalArtifact == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if !issues.isEmpty {
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

                        if let artifact = finalArtifact { resultSection(artifact: artifact) }

                        let additionalArtifacts = artifacts.filter { !$0.isFinalResult }
                        if !additionalArtifacts.isEmpty { artifactsSection(artifacts: additionalArtifacts) }

                        if !fileOperations.isEmpty { changedFilesSection }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: theme.shadowColor.opacity(theme.shadowOpacity * 0.5), radius: 8, x: 0, y: 2)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if theme.glassEnabled {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.primaryBackground.opacity(0.7))
            }
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.secondaryBackground.opacity(0.95))
        }
    }

    // MARK: - Sections

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.primaryBorder.opacity(0.2))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func resultSection(artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").font(.system(size: 12)).foregroundColor(theme.successColor)
                Text("Result").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.primaryText)
                Spacer()

                HStack(spacing: 4) {
                    Button {
                        onArtifactView(artifact)
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 4).fill(theme.accentColor.opacity(0.1)))
                    }
                    .buttonStyle(.plain).help("View artifact")

                    Button {
                        onArtifactDownload(artifact)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryBackground.opacity(0.5)))
                    }
                    .buttonStyle(.plain).help("Download artifact")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ArtifactPreviewCard(artifact: artifact, onView: { onArtifactView(artifact) })
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    private func artifactsSection(artifacts: [Artifact]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundColor(theme.secondaryText)
                Text("Artifacts").font(.system(size: 12, weight: .medium)).foregroundColor(theme.secondaryText)
                Text("(\(artifacts.count))").font(.system(size: 11)).foregroundColor(theme.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            VStack(spacing: 6) {
                ForEach(artifacts) { artifact in
                    ArtifactRow(
                        artifact: artifact,
                        onView: { onArtifactView(artifact) },
                        onDownload: { onArtifactDownload(artifact) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Changed Files Section

    private var changedFilesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "doc.badge.clock")
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                Text("Changed Files")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text("(\(fileOperations.count))")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                Spacer()

                // Undo All button
                Button {
                    onUndoAllOperations()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .medium))
                        Text("Undo All")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(theme.warningColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.warningColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .help("Undo all file changes")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(groupedOperations, id: \.path) { group in
                    FileOperationRow(
                        operation: group.latestOperation,
                        operationCount: group.operations.count,
                        onUndo: { onUndoOperation(group.latestOperation.id) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    /// Group operations by path, showing the latest operation for each file
    private var groupedOperations: [FileOperationGroup] {
        var groups: [String: [AgentFileOperation]] = [:]
        for op in fileOperations {
            groups[op.path, default: []].append(op)
        }
        return groups.map { path, ops in
            FileOperationGroup(path: path, operations: ops.sorted { $0.timestamp < $1.timestamp })
        }.sorted { $0.latestOperation.timestamp > $1.latestOperation.timestamp }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Text("Progress")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

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

            Spacer()

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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            // Subtle bottom divider
            Rectangle()
                .fill(theme.primaryBorder.opacity(0.1))
                .frame(height: 1)
        }
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

// MARK: - Artifact Preview Card

private struct ArtifactPreviewCard: View {
    let artifact: Artifact
    let onView: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    /// Preview of content (first few lines)
    private var contentPreview: String {
        let lines = artifact.content.components(separatedBy: .newlines)
        let previewLines = lines.prefix(6)
        let preview = previewLines.joined(separator: "\n")
        if lines.count > 6 {
            return preview + "\n..."
        }
        return preview
    }

    var body: some View {
        Button {
            onView()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Filename badge
                HStack(spacing: 4) {
                    Image(systemName: artifact.contentType == .markdown ? "doc.richtext" : "doc.text")
                        .font(.system(size: 9))
                        .foregroundColor(theme.accentColor)

                    Text(artifact.filename)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.accentColor.opacity(0.1))
                )

                // Content preview - plain text
                Text(contentPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(6)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.6 : 0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.primaryBorder.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Artifact Row

private struct ArtifactRow: View {
    let artifact: Artifact
    let onView: () -> Void
    let onDownload: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    var body: some View {
        Button {
            onView()
        } label: {
            HStack(spacing: 8) {
                // File icon
                Image(systemName: artifact.contentType == .markdown ? "doc.richtext" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                // Filename
                Text(artifact.filename)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                // Action buttons - always rendered, opacity controlled by hover
                // This prevents layout jiggle when hovering
                HStack(spacing: 4) {
                    Button(action: onView) {
                        Image(systemName: "eye")
                            .font(.system(size: 9))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(theme.primaryBackground))
                            .overlay(Circle().stroke(theme.accentColor.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("View")

                    Button(action: onDownload) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(theme.primaryBackground))
                            .overlay(Circle().stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Download")
                }
                .opacity(isHovered ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? theme.tertiaryBackground.opacity(0.4) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - File Operation Group

private struct FileOperationGroup {
    let path: String
    let operations: [AgentFileOperation]

    var latestOperation: AgentFileOperation {
        operations.last!
    }
}

// MARK: - File Operation Row

private struct FileOperationRow: View {
    let operation: AgentFileOperation
    let operationCount: Int
    let onUndo: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Operation type icon
            Image(systemName: operation.type.iconName)
                .font(.system(size: 10))
                .foregroundColor(iconColor)
                .frame(width: 16, height: 16)

            // Filename and path
            VStack(alignment: .leading, spacing: 1) {
                Text(operation.filename)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                if operationCount > 1 {
                    Text("\(operationCount) changes")
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text(operation.type.displayName)
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer()

            // Undo button (visible on hover)
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.warningColor)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(theme.primaryBackground))
                    .overlay(Circle().stroke(theme.warningColor.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Undo this change")
            .opacity(isHovered ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? theme.tertiaryBackground.opacity(0.4) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private var iconColor: Color {
        switch operation.type {
        case .create, .dirCreate:
            return theme.successColor
        case .write:
            return theme.accentColor
        case .move, .copy:
            return theme.secondaryText
        case .delete:
            return theme.errorColor
        }
    }
}
