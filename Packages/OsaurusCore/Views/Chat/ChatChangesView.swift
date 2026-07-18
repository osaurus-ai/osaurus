//
//  ChatChangesView.swift
//  osaurus
//
//  Session-scoped sheet listing every outstanding workspace change the
//  current chat produced — sandbox roots and the selected host folder alike.
//  Rows expand to a baseline-vs-live diff, with
//  per-file undo and Undo All. Built on the shared sheet chrome
//  (AgentSheetHeader/Footer, shared button styles) so it reads like the rest
//  of the app's modals.
//

import AppKit
import SwiftUI

struct ChatChangesView: View {
    let sessionId: UUID
    let onClose: () -> Void

    @Environment(\.theme) private var theme

    @State private var changes: [SandboxWorkspaceChange] = []
    @State private var hasActiveJob: Bool = false
    @State private var isLoading: Bool = true
    @State private var showUndoAllConfirm: Bool = false
    /// Non-nil while a per-row or bulk undo is running (disables actions).
    @State private var undoInFlight: Bool = false
    /// User-facing outcome of the last undo action (partial failures etc.).
    @State private var statusMessage: String?

    /// Rows whose diff is disclosed.
    @State private var expandedIds: Set<UUID> = []
    /// Lazily-fetched diffs, keyed by change id and pinned to the content
    /// signature they were computed for so a re-edit invalidates the cache.
    @State private var diffCache: [UUID: CachedDiff] = [:]

    struct CachedDiff {
        let signature: String?
        let result: SandboxChangeDiffResult
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "clock.arrow.circlepath",
                title: "File Changes",
                subtitle: "Files this chat created, edited, or deleted in the sandbox or selected folder.",
                onClose: onClose
            )

            content
                .frame(maxHeight: .infinity)
                .background(theme.primaryBackground)

            if let statusMessage {
                statusBanner(statusMessage)
            }

            AgentSheetFooter(
                primary: changes.isEmpty
                    ? nil
                    : AgentSheetFooter.Action(
                        label: "Undo All",
                        isEnabled: !hasActiveJob,
                        isLoading: undoInFlight,
                        isDestructive: true,
                        handler: { showUndoAllConfirm = true }
                    ),
                secondary: AgentSheetFooter.Action(
                    label: "Done",
                    handler: onClose
                )
            )
        }
        .frame(width: 600, height: 620)
        .background(theme.cardBackground)
        .task { await reload() }
        .onReceive(
            NotificationCenter.default.publisher(for: .sandboxWorkspaceChangesDidChange)
        ) { notification in
            let changed = notification.userInfo?["sessionId"] as? String
            guard changed == nil || changed == sessionId.uuidString else { return }
            Task { await reload() }
        }
        // `.contained` so the confirmation overlays this sheet instead of the
        // chat window behind it (same reasoning as ShareAgentSheet).
        .themedAlert(
            L("Undo all changes?"),
            isPresented: $showUndoAllConfirm,
            message: L(
                "Files created by this chat will be removed, and edited or deleted files restored to their previous state. Changes made outside this chat are never overwritten."
            ),
            primaryButton: .destructive(L("Undo All")) {
                Task { await undoAll() }
            },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && changes.isEmpty {
            Color.clear
        } else if changes.isEmpty {
            VStack {
                Spacer()
                AgentSectionEmptyState(
                    icon: "checkmark.circle",
                    title: "No outstanding file changes",
                    hint: "Files this chat creates, edits, or deletes in the sandbox or selected folder appear here."
                )
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                if hasActiveJob {
                    activeJobBanner
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(changes) { change in
                            ChangeRow(
                                change: change,
                                isExpanded: expandedIds.contains(change.id),
                                diff: cachedDiff(for: change),
                                undoDisabled: undoInFlight || hasActiveJob,
                                onToggle: { toggleExpanded(change) },
                                onUndo: { Task { await undo(change) } },
                                onOpen: { open(change) },
                                onReveal: { reveal(change) }
                            )
                            if change.id != changes.last?.id {
                                Divider()
                                    .opacity(0.5)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                }
            }
        }
    }

    private var activeJobBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(
                LocalizedStringKey(
                    "A background job from this chat is still running — undo is paused until it finishes."
                ),
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(theme.tertiaryBackground.opacity(0.5))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(theme.tertiaryBackground.opacity(0.5))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    // MARK: - Diff loading

    /// The cached diff for a row, or nil when not fetched yet / stale.
    private func cachedDiff(for change: SandboxWorkspaceChange) -> SandboxChangeDiffResult? {
        guard let cached = diffCache[change.id], cached.signature == change.currentSignature
        else { return nil }
        return cached.result
    }

    private func toggleExpanded(_ change: SandboxWorkspaceChange) {
        if expandedIds.contains(change.id) {
            expandedIds.remove(change.id)
            return
        }
        expandedIds.insert(change.id)
        guard cachedDiff(for: change) == nil else { return }
        let signature = change.currentSignature
        Task {
            let result = await SandboxWorkspaceChangeTracker.shared.diffText(
                for: change.id, sessionId: sessionId.uuidString)
            await MainActor.run {
                diffCache[change.id] = CachedDiff(signature: signature, result: result)
            }
        }
    }

    // MARK: - Open / reveal

    /// Open the live file with its default app (Finder for directories).
    /// Deleted entries have nothing on disk to open — callers hide the action.
    private func open(_ change: SandboxWorkspaceChange) {
        guard change.kind != .deleted else { return }
        if change.entryType == .directory {
            NSWorkspace.shared.activateFileViewerSelecting([change.hostURL])
        } else {
            // Configuration variant dispatches asynchronously — the plain
            // `open(_:)` does a synchronous LaunchServices XPC round-trip that
            // can hang the main thread on a cold app launch.
            NSWorkspace.shared.open(change.hostURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func reveal(_ change: SandboxWorkspaceChange) {
        guard change.kind != .deleted else { return }
        NSWorkspace.shared.activateFileViewerSelecting([change.hostURL])
    }

    // MARK: - Actions

    private func reload() async {
        let sid = sessionId.uuidString
        let loaded = await SandboxWorkspaceChangeTracker.shared.changes(for: sid)
        let activeJob = await SandboxWorkspaceChangeTracker.shared.hasActiveBackgroundJobs(
            sessionId: sid)
        await MainActor.run {
            changes = loaded
            hasActiveJob = activeJob
            isLoading = false
            let ids = Set(loaded.map(\.id))
            expandedIds.formIntersection(ids)
            diffCache = diffCache.filter { ids.contains($0.key) }
        }
    }

    private func undo(_ change: SandboxWorkspaceChange) async {
        undoInFlight = true
        defer { undoInFlight = false }
        let result = await SandboxWorkspaceChangeTracker.shared.undoChange(
            id: change.id, sessionId: sessionId.uuidString)
        switch result {
        case .undone:
            statusMessage = nil
        case .conflicted:
            statusMessage = L(
                "\(change.filename) was changed outside this chat and was left untouched.")
        case .blockedByActiveJob:
            statusMessage = L("Undo is unavailable while a background job is running.")
        case .failed(let reason):
            statusMessage = L("Couldn't undo \(change.filename): \(reason)")
        }
        await reload()
    }

    private func undoAll() async {
        undoInFlight = true
        defer { undoInFlight = false }
        let summary = await SandboxWorkspaceChangeTracker.shared.undoAll(
            sessionId: sessionId.uuidString)
        if summary.conflicted == 0 && summary.failed == 0 {
            statusMessage = nil
        } else {
            var parts: [String] = [L("Undid \(summary.undone) change(s).")]
            if summary.conflicted > 0 {
                parts.append(L("\(summary.conflicted) skipped (changed outside this chat)."))
            }
            if summary.failed > 0 {
                parts.append(L("\(summary.failed) failed."))
            }
            statusMessage = parts.joined(separator: " ")
        }
        await reload()
    }
}

// MARK: - Row

private struct ChangeRow: View {
    let change: SandboxWorkspaceChange
    let isExpanded: Bool
    /// nil while the diff hasn't been fetched (or was invalidated).
    let diff: SandboxChangeDiffResult?
    let undoDisabled: Bool
    let onToggle: () -> Void
    let onUndo: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    /// Directories and symlinks have no content diff to disclose.
    private var isExpandable: Bool { change.entryType == .file }

    /// Deleted entries have nothing on disk to open or reveal.
    private var canOpen: Bool { change.kind != .deleted }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded && isExpandable {
                ChangeDiffBlock(result: diff)
                    .padding(.leading, 42)
                    .padding(.trailing, 20)
                    .padding(.bottom, 10)
            }
        }
        .contentShape(Rectangle())
        .background(isHovered ? theme.tertiaryBackground.opacity(0.4) : Color.clear)
        .onHover { hovering in isHovered = hovering }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
                .opacity(isExpandable ? 1 : 0)

            Image(systemName: change.kind.iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(kindColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(change.filename)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if change.state == .conflicted {
                        ChangeStatePill(
                            text: "Conflict",
                            color: theme.warningColor,
                            help:
                                "This file was changed outside this chat after the last tracked edit; undo won't overwrite it."
                        )
                    }
                }
                Text(change.displayPath)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            ChangeStatePill(text: kindLabel, color: kindColor, help: nil)

            if canOpen {
                HeaderActionButton(
                    icon: "arrow.up.right.square",
                    help: "Open file",
                    action: onOpen
                )
            }

            HeaderActionButton(
                icon: "arrow.uturn.backward",
                help: "Undo this change",
                action: onUndo
            )
            .disabled(undoDisabled)
            .opacity(undoDisabled ? 0.4 : 1)
        }
        .padding(.leading, 20)
        // HeaderActionButton carries 4pt of its own horizontal padding; 16
        // here lands its visual edge on the sheet's 20pt gutter.
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // Double-click opens; declared first so the single-click expand
        // waits to disambiguate instead of firing twice.
        .onTapGesture(count: 2) { if canOpen { onOpen() } }
        .onTapGesture { if isExpandable { onToggle() } }
        .contextMenu {
            if canOpen {
                Button(action: onOpen) {
                    Label(L("Open"), systemImage: "arrow.up.right.square")
                }
                Button(action: onReveal) {
                    Label(L("Reveal in Finder"), systemImage: "folder")
                }
                Divider()
            }
            Button(action: onUndo) {
                Label(
                    change.kind == .deleted ? L("Restore") : L("Undo Change"),
                    systemImage: "arrow.uturn.backward"
                )
            }
            .disabled(undoDisabled)
        }
        .help(Text(sourceLine))
    }

    private var kindColor: Color {
        switch change.kind {
        case .created: return theme.successColor
        case .modified: return theme.accentColor
        case .deleted: return theme.errorColor
        }
    }

    private var kindLabel: LocalizedStringKey {
        switch change.kind {
        case .created: return "Created"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        }
    }

    private var sourceLine: String {
        let time = change.lastChangedAt.formatted(date: .omitted, time: .shortened)
        return "\(change.sourceTool) · \(time)"
    }
}

// MARK: - Diff block

/// Inline unified-diff rendering for an expanded row: added/removed lines
/// tinted with the same colors and 3pt accent bar as the chat's diff card.
private struct ChangeDiffBlock: View {
    /// nil while loading.
    let result: SandboxChangeDiffResult?

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch result {
            case nil:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(LocalizedStringKey("Loading diff…"), bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                }
                .padding(10)
            case .binary:
                metaNotice("Binary file — no text diff.")
            case .tooLarge:
                metaNotice("File is too large to diff.")
            case .unavailable:
                metaNotice("No diff available for this change.")
            case .diff(let text):
                diffLines(FileDiff.fromUnifiedDiff(text, path: ""))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.inputBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metaNotice(_ key: LocalizedStringKey) -> some View {
        HStack {
            Text(key, bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Spacer()
        }
        .padding(10)
    }

    @ViewBuilder
    private func diffLines(_ diff: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if diff.addedCount > 0 || diff.removedCount > 0 {
                HStack(spacing: 6) {
                    if diff.addedCount > 0 {
                        Text(verbatim: "+\(diff.addedCount)")
                            .foregroundColor(theme.successColor)
                    }
                    if diff.removedCount > 0 {
                        Text(verbatim: "−\(diff.removedCount)")
                            .foregroundColor(theme.errorColor)
                    }
                    Spacer()
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.tertiaryBackground.opacity(0.4))
                Divider().opacity(0.5)
            }
            // The diff text is already line-capped upstream
            // (WorkspaceWriteSafety.maxDiffLines), so the sheet's outer scroll
            // view can own scrolling without a janky nested region.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                    diffLine(line)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func diffLine(_ line: FileDiff.Line) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(barColor(line.kind))
                .frame(width: 3)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor(line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        }
        .background(backgroundColor(line.kind))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func barColor(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .added: return theme.successColor.opacity(0.6)
        case .removed: return theme.errorColor.opacity(0.6)
        case .context, .meta: return .clear
        }
    }

    private func backgroundColor(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .added: return theme.successColor.opacity(0.14)
        case .removed: return theme.errorColor.opacity(0.14)
        case .context, .meta: return .clear
        }
    }

    private func textColor(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .meta: return theme.tertiaryText
        case .context: return theme.secondaryText
        case .added, .removed: return theme.primaryText
        }
    }
}

// MARK: - Status pill

/// Tinted capsule pill used for the change kind and conflict state — matches
/// the status-badge convention (capsules are for status, not actions).
private struct ChangeStatePill: View {
    let text: LocalizedStringKey
    let color: Color
    let help: LocalizedStringKey?

    var body: some View {
        let pill = Text(text, bundle: .module)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
        if let help {
            pill.help(Text(help, bundle: .module))
        } else {
            pill
        }
    }
}
