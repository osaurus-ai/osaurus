//
//  IssueTrackerPanel.swift
//  osaurus
//
//  Sidebar panel displaying issues for the current work task with status indicators.
//

import AppKit
import SwiftUI

struct IssueTrackerPanel: View {
    let issues: [Issue]
    let activeIssueId: String?
    let selectedIssueId: String?
    let finalArtifact: SharedArtifact?
    let sharedArtifacts: [SharedArtifact]
    let fileOperations: [WorkFileOperation]
    let onDismiss: () -> Void
    let onIssueSelect: (Issue) -> Void
    let onIssueRun: (Issue) -> Void
    let onIssueClose: (String) -> Void
    let onArtifactView: (SharedArtifact) -> Void
    let onArtifactOpen: (SharedArtifact) -> Void
    let onUndoOperation: (UUID) -> Void
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
                            LazyVStack(spacing: 8) {
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }

                        if let artifact = finalArtifact { resultSection(artifact: artifact) }

                        let additionalArtifacts = sharedArtifacts.filter { !$0.isFinalResult }
                        if !additionalArtifacts.isEmpty { artifactsSection(artifacts: additionalArtifacts) }

                        if !fileOperations.isEmpty { changedFilesSection }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(panelBorder)
    }

    // MARK: - Panel Styling

    @ViewBuilder
    private var panelBackground: some View {
        if theme.glassEnabled {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.secondaryBackground)
        }
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
    }

    // MARK: - Sections

    private var sectionDivider: some View {
        Spacer().frame(height: 20)
    }

    private func resultSection(artifact: SharedArtifact) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.successColor)
                Text("Result", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Spacer()

                Button {
                    onArtifactView(artifact)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(Text("View artifact", bundle: .module))

                Button {
                    onArtifactOpen(artifact)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(Text("Reveal in Finder", bundle: .module))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            ArtifactPreviewCard(artifact: artifact, onView: { onArtifactView(artifact) })
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
    }

    private func artifactsSection(artifacts: [SharedArtifact]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text("Artifacts", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            VStack(spacing: 6) {
                ForEach(artifacts) { artifact in
                    ArtifactRow(
                        artifact: artifact,
                        onView: { onArtifactView(artifact) },
                        onOpen: { onArtifactOpen(artifact) }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Changed Files Section

    private var changedFilesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Text("Changed Files", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Button {
                    onUndoAllOperations()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Undo All", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(theme.warningColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.warningColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .help(Text("Undo all file changes", bundle: .module))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            VStack(spacing: 6) {
                ForEach(groupedOperations, id: \.path) { group in
                    FileOperationRow(
                        operation: group.latestOperation,
                        operationCount: group.operations.count,
                        onUndo: { onUndoOperation(group.latestOperation.id) }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    /// Group operations by path, showing the latest operation for each file
    private var groupedOperations: [FileOperationGroup] {
        var groups: [String: [WorkFileOperation]] = [:]
        for op in fileOperations {
            groups[op.path, default: []].append(op)
        }
        return groups.map { path, ops in
            FileOperationGroup(path: path, operations: ops.sorted { $0.timestamp < $1.timestamp })
        }.sorted { $0.latestOperation.timestamp > $1.latestOperation.timestamp }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Progress", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Close progress panel", bundle: .module))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundColor(theme.tertiaryText.opacity(0.6))

            Text("Ready to start", bundle: .module)
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
        HStack(alignment: .top, spacing: 10) {
            statusIndicator
                .frame(width: 16, height: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                if issue.type != .task {
                    typeBadge
                }

                Text(displayText)
                    .font(.system(size: 13, weight: isActive || isSelected ? .medium : .regular))
                    .foregroundColor(isActive || isSelected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(4)
                    .lineSpacing(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isHovered && issue.status != .closed {
                actionButtons
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        MorphingStatusIcon(state: statusIconState, accentColor: statusIconColor, size: 14)
    }

    private var statusIconState: StatusIconState {
        switch issue.status {
        case .open:
            return .pending
        case .inProgress:
            return isActive ? .active : .pending
        case .blocked:
            return .pending
        case .closed:
            return .completed
        }
    }

    private var statusIconColor: Color {
        switch issue.status {
        case .open:
            return theme.tertiaryText
        case .inProgress:
            return theme.accentColor
        case .blocked:
            return theme.warningColor
        case .closed:
            return theme.successColor
        }
    }

    // MARK: - Type Badge

    private var typeBadge: some View {
        Text(issue.type.displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(typeColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(typeColor.opacity(0.12))
            )
    }

    private var typeColor: Color {
        switch issue.type {
        case .bug: return theme.errorColor
        case .discovery: return theme.warningColor
        case .task: return theme.secondaryText
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if (issue.status == .open || issue.status == .inProgress) && !isActive {
                Button(action: onRun) {
                    Image(systemName: issue.status == .inProgress ? "arrow.clockwise" : "play.fill")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(issue.status == .inProgress ? "Resume" : "Run")
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("Close", bundle: .module))
        }
        .padding(6)
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.accentColor.opacity(0.08))
        } else if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.accentColor.opacity(0.05))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.tertiaryBackground.opacity(0.3))
        } else {
            Color.clear
        }
    }
}

// MARK: - Artifact Preview Card

private struct ArtifactPreviewCard: View {
    let artifact: SharedArtifact
    let onView: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    var body: some View {
        Button {
            onView()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: artifactIconName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Text(artifact.filename)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                }

                if artifact.isImage, !artifact.hostPath.isEmpty,
                    let nsImage = NSImage(contentsOf: URL(fileURLWithPath: artifact.hostPath))
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if artifact.isText, let content = artifact.content, !content.isEmpty {
                    let lines = content.components(separatedBy: .newlines)
                    let preview = lines.prefix(6).joined(separator: "\n") + (lines.count > 6 ? "\n..." : "")
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(6)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: artifactIconName)
                            .font(.system(size: 14))
                            .foregroundColor(theme.tertiaryText)
                        Text(formatPreviewSize(artifact.fileSize))
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.5 : 0.3))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var artifactIconName: String {
        if artifact.isDirectory { return "folder.fill" }
        if artifact.isImage { return "photo" }
        if artifact.isAudio { return "waveform" }
        if artifact.isHTML { return "globe" }
        if artifact.mimeType == "text/markdown" { return "doc.richtext" }
        if artifact.isText { return "doc.text" }
        return "doc"
    }

    private func formatPreviewSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Artifact Row

private struct ArtifactRow: View {
    let artifact: SharedArtifact
    let onView: () -> Void
    let onOpen: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    private var rowIconName: String {
        if artifact.isDirectory { return "folder.fill" }
        if artifact.isImage { return "photo" }
        if artifact.isAudio { return "waveform" }
        if artifact.isHTML { return "globe" }
        if artifact.mimeType == "text/markdown" { return "doc.richtext" }
        if artifact.isText { return "doc.text" }
        return "doc"
    }

    var body: some View {
        Button {
            onView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: rowIconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Text(artifact.filename)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 4) {
                    Button(action: onView) {
                        Image(systemName: "eye")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("View", bundle: .module))

                    Button(action: onOpen) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Reveal in Finder", bundle: .module))
                }
                .opacity(isHovered ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.tertiaryBackground.opacity(0.3) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - File Operation Group

private struct FileOperationGroup {
    let path: String
    let operations: [WorkFileOperation]

    var latestOperation: WorkFileOperation {
        operations.last!
    }
}

// MARK: - File Operation Row

private struct FileOperationRow: View {
    let operation: WorkFileOperation
    let operationCount: Int
    let onUndo: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false

    private var fullURL: URL? {
        WorkFolderContextService.shared.currentContext?.rootPath.appendingPathComponent(operation.path)
    }

    private var fileExists: Bool {
        guard let url = fullURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var isClickable: Bool {
        operation.type != .delete && fileExists
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: operation.type.iconName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(operation.filename)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isClickable ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(operation.type.displayName)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(theme.tertiaryText)

                    if operationCount > 1 {
                        Text("\u{00B7} \(operationCount) changes", bundle: .module)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if isClickable {
                    Button(action: openFile) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Open file", bundle: .module))
                }

                Button(action: onUndo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Undo this change", bundle: .module))
            }
            .opacity(isHovered ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? theme.tertiaryBackground.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering && isClickable {
                NSCursor.pointingHand.push()
            } else if !hovering {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            if isClickable {
                openFile()
            }
        }
        .contextMenu {
            if isClickable {
                Button {
                    openFile()
                } label: {
                    Label { Text("Open File", bundle: .module) } icon: { Image(systemName: "arrow.up.forward.square") }
                }
                Button {
                    revealInFinder()
                } label: {
                    Label { Text("Reveal in Finder", bundle: .module) } icon: { Image(systemName: "folder") }
                }
                Divider()
            }
            Button {
                onUndo()
            } label: {
                Label { Text("Undo Change", bundle: .module) } icon: { Image(systemName: "arrow.uturn.backward") }
            }
        }
    }

    // MARK: - Actions

    private func openFile() {
        guard let url = fullURL, fileExists else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url = fullURL,
            let rootPath = WorkFolderContextService.shared.currentContext?.rootPath
        else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: rootPath.path)
    }
}
