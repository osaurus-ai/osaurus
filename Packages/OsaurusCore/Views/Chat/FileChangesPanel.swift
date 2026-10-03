//
//  FileChangesPanel.swift
//  osaurus
//
//  Session-scoped File Changes pane of the chat inspector (see
//  `ChatInspectorPanel`, which owns the rail chrome and lens bar). The
//  header row carries the "N files changed · M changes" summary and Revert
//  All; the row under it the Timeline | Files chips. Timeline lists every change set
//  (one per tool call, plus reverts) with its files and diffs, revertible
//  per set or rolled back to any point; Files shows the net state of each
//  touched path, revertible per file. Every revert
//  previews first — multi-file reverts confirm with a per-file outcome
//  list, conflicts ask before overwriting — and ends with an Undo toast,
//  because a revert is itself recorded and reversible.
//

import AppKit
import SwiftUI

enum WorkspaceFileExporter {
    static func export(source: URL, destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".osaurus-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

struct FileChangesPanel: View {
    let sessionId: UUID?
    @Binding var focusSetId: UUID?
    /// First line of the user's request that produced `turnId`, for the
    /// Timeline's turn headers. Nil when the transcript can't be resolved.
    var userPrompt: (UUID) -> String? = { _ in nil }

    @Environment(\.theme) private var theme

    enum Tab: Hashable { case timeline, files }

    struct PendingRevert: Identifiable {
        let id = UUID()
        let scope: FileChangeJournal.RevertScope
        let preview: FileRevertPreview
    }

    struct Toast: Equatable {
        let id = UUID()
        let message: String
        let undoSetId: UUID?
        let isWarning: Bool
    }

    @State private var tab: Tab = .timeline
    @State private var sets: [FileChangeSet] = []
    @State private var net: [FileNetChange] = []
    @State private var hasActiveJob = false
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var expandedSets: Set<UUID> = []
    @State private var pendingRevert: PendingRevert?
    @State private var toast: Toast?

    private var journal: FileChangeJournal { .shared }

    /// Nothing recorded for this chat (or no chat at all): the pane is one
    /// empty state under the lens bar, no summary or chips to filter nothing.
    private var isEmpty: Bool {
        sessionId == nil || (!isLoading && sets.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                SidebarEmptyState(
                    icon: "checkmark.circle",
                    title: "No file changes",
                    hint: "Files this chat creates, edits, or deletes appear here, and every change can be reverted."
                )
            } else if isLoading && sets.isEmpty {
                // First load: keep the pane quiet rather than flashing a
                // "0 files changed" header before the journal answers.
                Color.clear.frame(maxHeight: .infinity)
            } else {
                headerRow
                viewChips
                if hasActiveJob { activeJobBanner }
                content
                    .frame(maxHeight: .infinity)
            }
            if let toast { toastView(toast) }
        }
        .task(id: sessionId) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .fileChangesDidChange)) { note in
            let changed = note.userInfo?["sessionId"] as? String
            guard changed == nil || changed == sessionId?.uuidString else { return }
            Task { await reload() }
        }
        .onChange(of: focusSetId) { _, id in reveal(id) }
        .themedAlert(
            pendingRevert.map(confirmTitle) ?? "",
            isPresented: Binding(
                get: { pendingRevert != nil },
                set: { if !$0 { pendingRevert = nil } }
            ),
            message: pendingRevert.map(confirmMessage),
            accessory: pendingRevert.map { AnyView(RevertOutcomeList(pending: $0)) },
            buttons: confirmButtons,
            presentationStyle: .contained
        )
    }

    // MARK: - Header and chips rows

    /// Mirror of the History pane's header: the "N files changed · M
    /// changes" summary where History shows its scope label, Revert All —
    /// the one action over the whole chat — where History has New Chat and
    /// Import.
    private var headerRow: some View {
        SidebarHeaderRow(summary: summaryLine) {
            if !net.isEmpty {
                SidebarHeaderIconButton(
                    icon: "arrow.uturn.backward",
                    help: "Revert All",
                    tint: theme.errorColor,
                    label: "Revert All"
                ) {
                    Task { await requestRevert(.all) }
                }
                .disabled(isBusy || hasActiveJob)
                .accessibilityHint(Text("Asks for confirmation and lists every file first", bundle: .module))
            }
        }
    }

    /// Timeline | Files as chips (not a second lens bar — they are two
    /// views of this pane, one level below the rail's lenses). Sits where
    /// the History pane has its search + Filter row, with the same insets.
    private var viewChips: some View {
        HStack(spacing: 6) {
            SidebarFilterChip(
                label: "Timeline",
                icon: "clock",
                isOn: tab == .timeline,
                help: "Every change in order, with the files and differences it touched"
            ) {
                tab = .timeline
            }
            SidebarFilterChip(
                label: "Files",
                icon: "doc.on.doc",
                isOn: tab == .files,
                help: "Where each file stands now, compared to before this chat"
            ) {
                tab = .files
            }
            Spacer(minLength: 0)
        }
        // The History pane's search row is 28pt tall; match it so the
        // list starts at the same y on both panes.
        .frame(minHeight: 28)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var summaryLine: String {
        let files = net.count
        let changes = sets.filter { $0.origin != .userRevert }.count
        return L("\(files) files changed") + " · " + L("\(changes) changes")
    }

    private var activeJobBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("The chat is still running a command — revert is paused until it finishes.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.tertiaryBackground.opacity(0.5))
    }

    // MARK: - Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .timeline: timeline
                    case .files: files
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear { scrollToFocus(proxy) }
            .onChange(of: focusSetId) { _, _ in scrollToFocus(proxy) }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let newestFirst = Array(sets.reversed())
        ForEach(Array(newestFirst.enumerated()), id: \.element.id) { index, set in
            if index == 0 || !sameTurn(newestFirst[index - 1], set) {
                turnHeader(set)
            }
            ChangeSetRow(
                changeSet: set,
                isExpanded: expandedSets.contains(set.id),
                isFocused: focusSetId == set.id,
                isLatest: index == 0,
                actionsDisabled: isBusy || hasActiveJob,
                onToggle: { toggle(set.id) },
                onRevert: { Task { await requestRevert(.set(set.id)) } },
                onRollback: { Task { await requestRevert(.rollback(fromSet: set.id)) } }
            )
            .id(set.id)
        }
    }

    private func sameTurn(_ a: FileChangeSet, _ b: FileChangeSet) -> Bool {
        guard let ta = a.turnId, let tb = b.turnId else { return false }
        return ta == tb
    }

    private func turnHeader(_ set: FileChangeSet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(set.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
            if let prompt = set.turnId.flatMap(userPrompt), !prompt.isEmpty {
                Text(L("You: \(prompt)"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Text(prompt))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var files: some View {
        if net.isEmpty {
            Text("Every file is back to how it was before this chat.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .padding(14)
        } else {
            ForEach(net) { change in
                NetFileRow(
                    change: change,
                    actionsDisabled: isBusy || hasActiveJob,
                    onRevert: { Task { await requestRevert(.file(change.key)) } }
                )
                Divider().opacity(0.4).padding(.leading, 14)
            }
        }
    }

    // MARK: - Toast

    private func toastView(_ toast: Toast) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: toast.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(toast.isWarning ? theme.warningColor : theme.successColor)
                .padding(.top, 1)
            Text(toast.message)
                .font(.system(size: 11))
                .foregroundColor(theme.primaryText)
                .lineLimit(toast.isWarning ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if let undo = toast.undoSetId {
                Button {
                    Task { await requestRevert(.set(undo)) }
                } label: {
                    Text("Undo", bundle: .module).font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(PanelPillButtonStyle(tint: theme.accentColor))
                .disabled(isBusy)
                .help(Text("Put the reverted files back the way they were", bundle: .module))
            }
            Button {
                self.toast = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.tertiaryText)
            .accessibilityLabel(Text("Dismiss", bundle: .module))
        }
        .padding(10)
        .background(theme.tertiaryBackground)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .accessibilityElement(children: .contain)
        .task(id: toast.id) {
            // Warnings stay until dismissed so nothing is missed.
            guard !toast.isWarning else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    // MARK: - Confirmation / conflict dialog

    private func confirmTitle(_ pending: PendingRevert) -> String {
        if pending.preview.conflictCount > 0 {
            return L("Some files were edited after this change")
        }
        switch pending.scope {
        case .all: return L("Revert all changes from this chat?")
        case .rollback: return L("Roll back to this point?")
        case .set, .file:
            let n = pending.preview.items.count
            return L("Revert \(n) files?")
        }
    }

    private func confirmMessage(_ pending: PendingRevert) -> String {
        var lines: [String] = []
        if pending.preview.conflictCount > 0 {
            lines.append(
                L("Files marked “edited since” were changed outside this chat after it touched them. Skip them to revert everything else, or overwrite them."))
        }
        if pending.preview.unrestorableCount > 0 {
            lines.append(L("Files marked “can't be restored” were too large to keep in history and will be left as they are."))
        }
        lines.append(L("Every revert is recorded, so you can undo it afterwards."))
        return lines.joined(separator: "\n\n")
    }

    private var confirmButtons: [AlertButtonConfig] {
        guard let pending = pendingRevert else { return [.cancel(L("Cancel"))] }
        var buttons: [AlertButtonConfig] = [.cancel(L("Cancel"))]
        let others = pending.preview.items.count - pending.preview.conflictCount - pending.preview.unrestorableCount
        if others > 0 {
            let title: String
            if pending.preview.conflictCount > 0 {
                title = L("Skip Edited Files")
            } else {
                switch pending.scope {
                case .all: title = L("Revert All")
                case .rollback: title = L("Roll Back")
                case .set, .file: title = L("Revert \(others) files")
                }
            }
            buttons.append(.primary(title) { Task { await perform(pending.scope, force: false) } })
        }
        if pending.preview.conflictCount > 0 {
            buttons.append(
                .destructive(L("Overwrite Edited Files")) {
                    Task { await perform(pending.scope, force: true) }
                })
        }
        return buttons
    }

    // MARK: - Actions

    private func reload() async {
        guard let sid = sessionId?.uuidString else {
            sets = []
            net = []
            isLoading = false
            return
        }
        let loadedSets = await journal.changeSets(for: sid)
        let loadedNet = await journal.netChanges(for: sid)
        let job = await journal.hasActiveCaptures(sessionId: sid)
        guard sid == sessionId?.uuidString else { return }
        sets = loadedSets
        net = loadedNet
        hasActiveJob = job
        isLoading = false
        expandedSets.formIntersection(Set(loadedSets.map(\.id)))
        reveal(focusSetId)
    }

    private func toggle(_ id: UUID) {
        if expandedSets.contains(id) { expandedSets.remove(id) } else { expandedSets.insert(id) }
    }

    private func reveal(_ id: UUID?) {
        guard let id, sets.contains(where: { $0.id == id }) else { return }
        tab = .timeline
        expandedSets.insert(id)
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let id = focusSetId else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
        }
    }

    /// Whether a revert needs a look-before-you-leap dialog: anything that
    /// touches several files, every Revert All / Roll Back, and any conflict
    /// or unrestorable file. Single-file, single-change reverts stay
    /// one-click because they are undoable from the toast.
    static func needsConfirmation(_ scope: FileChangeJournal.RevertScope, preview: FileRevertPreview) -> Bool {
        if preview.conflictCount > 0 || preview.unrestorableCount > 0 { return true }
        switch scope {
        case .all, .rollback: return true
        case .set, .file: return preview.items.count > 1
        }
    }

    private func requestRevert(_ scope: FileChangeJournal.RevertScope) async {
        guard let sid = sessionId?.uuidString else { return }
        let preview = await journal.previewRevert(scope, sessionId: sid)
        if preview.items.isEmpty {
            toast = Toast(message: L("Nothing to revert."), undoSetId: nil, isWarning: false)
            return
        }
        if Self.needsConfirmation(scope, preview: preview) {
            pendingRevert = PendingRevert(scope: scope, preview: preview)
        } else {
            await perform(scope, force: false)
        }
    }

    private func perform(_ scope: FileChangeJournal.RevertScope, force: Bool) async {
        guard let sid = sessionId?.uuidString else { return }
        pendingRevert = nil
        isBusy = true
        let summary = await journal.revert(scope, sessionId: sid, force: force)
        isBusy = false
        toast = Self.toast(for: summary)
        await reload()
    }

    static func toast(for summary: FileRevertSummary) -> Toast {
        if let blocked = summary.blockedReason {
            return Toast(message: blocked, undoSetId: nil, isWarning: true)
        }
        var parts = [L("Reverted \(summary.restored) files.")]
        if summary.conflicted > 0 {
            parts.append(L("\(summary.conflicted) left untouched because they were edited since."))
        }
        if summary.failed > 0 {
            parts.append(L("\(summary.failed) couldn't be restored:") + " " + summary.failures.joined(separator: "; "))
        }
        return Toast(
            message: parts.joined(separator: " "),
            undoSetId: summary.revertSetId,
            isWarning: summary.conflicted + summary.failed > 0)
    }
}

// MARK: - Confirmation outcome list

/// Plain-language, per-file outcomes shown inside the confirmation dialog.
private struct RevertOutcomeList: View {
    let pending: FileChangesPanel.PendingRevert

    @Environment(\.theme) private var theme

    private static let maxRows = 12

    var body: some View {
        let items = pending.preview.items
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.prefix(Self.maxRows)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(item))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color(item))
                        .frame(width: 12)
                    Text(item.key.shortDisplayPath)
                        .font(.system(size: 11))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(item.key.hostURL.path))
                    Spacer(minLength: 4)
                    Text(outcome(item))
                        .font(.system(size: 10.5))
                        .foregroundColor(color(item))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            if items.count > Self.maxRows {
                Text(L("and \(items.count - Self.maxRows) more"))
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.inputBackground))
    }

    private func outcome(_ item: FileRevertPreviewItem) -> String {
        if item.isConflict { return L("edited since") }
        if item.isUnrestorable { return L("can't be restored") }
        if item.target == nil { return L("will be deleted") }
        if item.expected == nil { return L("will be recreated") }
        switch pending.scope {
        case .all, .file:
            return item.isTruncated ? L("back to the oldest change still in history") : L("back to before this chat")
        case .set, .rollback: return L("back to before this change")
        }
    }

    private func icon(_ item: FileRevertPreviewItem) -> String {
        if item.isConflict { return "exclamationmark.triangle.fill" }
        if item.isUnrestorable { return "xmark.circle" }
        if item.target == nil { return "minus.circle" }
        if item.expected == nil { return "plus.circle" }
        return "arrow.uturn.backward.circle"
    }

    private func color(_ item: FileRevertPreviewItem) -> Color {
        if item.isConflict || item.isUnrestorable { return theme.warningColor }
        if item.target == nil { return theme.errorColor }
        if item.expected == nil { return theme.successColor }
        return theme.secondaryText
    }
}

// MARK: - Change set row

private struct ChangeSetRow: View {
    let changeSet: FileChangeSet
    let isExpanded: Bool
    let isFocused: Bool
    let isLatest: Bool
    let actionsDisabled: Bool
    let onToggle: () -> Void
    let onRevert: () -> Void
    let onRollback: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    private var isRevert: Bool { changeSet.origin == .userRevert }
    private var canAct: Bool { changeSet.isRevertible && changeSet.status != .reverted }
    private var canRollBack: Bool { !isLatest && !isRevert && changeSet.status != .untracked }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if let note = changeSet.note, !isRevert {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }
                    ForEach(changeSet.entries.sorted { $0.ordinal < $1.ordinal }) { entry in
                        EntryRow(entry: entry)
                    }
                    if canRollBack {
                        Button(action: onRollback) {
                            Label(L("Roll Back to Before This"), systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(PanelPillButtonStyle(tint: theme.secondaryText))
                        .disabled(actionsDisabled)
                        .help(Text("Undo this change and every change made after it", bundle: .module))
                        .padding(.leading, 38)
                        .padding(.top, 6)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(
            (isFocused ? theme.accentColor.opacity(0.08) : isHovered ? theme.tertiaryBackground.opacity(0.4) : .clear)
        )
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isRevert ? theme.accentColor : theme.secondaryText)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(changeSet.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(changeSet.status == .reverted ? theme.secondaryText : theme.primaryText)
                                .strikethrough(changeSet.status == .reverted && !isRevert, color: theme.tertiaryText)
                                .lineLimit(1)
                            statusPill
                        }
                        Text(fileSummary)
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityTitle))
            .accessibilityHint(Text(isExpanded ? L("Collapse") : L("Expand to see files and differences")))
            if canAct {
                Button(action: onRevert) {
                    Text(isRevert ? "Undo" : "Revert", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PanelPillButtonStyle(tint: theme.accentColor))
                .disabled(actionsDisabled)
                .opacity(isHovered || isFocused ? 1 : 0.7)
                .help(Text(isRevert ? L("Put this change back") : L("Restore these files to how they were before this change")))
                .accessibilityLabel(Text(isRevert ? L("Undo This Revert") : L("Revert This Change")))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contextMenu {
            Button(action: onRevert) {
                Label(isRevert ? L("Undo This Revert") : L("Revert This Change"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!canAct || actionsDisabled)
            if canRollBack {
                Button(action: onRollback) {
                    Label(L("Roll Back to Before This"), systemImage: "clock.arrow.circlepath")
                }
                .disabled(actionsDisabled)
            }
        }
        .help(Text(changeSet.createdAt.formatted(date: .omitted, time: .standard)))
    }

    private var accessibilityTitle: String {
        var parts = [changeSet.displayTitle, fileSummary]
        switch changeSet.status {
        case .reverted where !isRevert: parts.append(L("Reverted"))
        case .partiallyReverted: parts.append(L("Partly reverted"))
        case .untracked: parts.append(L("Not tracked"))
        default: break
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var icon: String {
        switch changeSet.origin {
        case .userRevert: return "arrow.uturn.backward"
        case .externalJob: return "gearshape"
        case .imported: return "tray"
        case .agent:
            switch changeSet.toolName {
            case "shell_run", "sandbox_exec", "sandbox_exec_background": return "terminal"
            case "file_copy": return "doc.on.doc"
            default: return "pencil"
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch changeSet.status {
        case .reverted where !isRevert:
            PanelStatusPill(text: L("Reverted"), color: theme.secondaryText)
        case .partiallyReverted:
            PanelStatusPill(text: L("Partly reverted"), color: theme.warningColor)
        case .untracked:
            PanelStatusPill(text: L("Not tracked"), color: theme.warningColor)
        default:
            EmptyView()
        }
    }

    private var fileSummary: String {
        let names = changeSet.entries.filter { $0.entryType != .directory }.map(\.filename)
        let shown = names.isEmpty ? changeSet.entries.map(\.filename) : names
        guard let first = shown.first else { return changeSet.note ?? "" }
        return shown.count == 1 ? first : L("\(first) and \(shown.count - 1) more")
    }
}

// MARK: - Entry row (file within a set)

private struct EntryRow: View {
    let entry: FileChangeEntry

    @State private var isExpanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if entry.entryType != .directory { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: entry.entryType == .directory ? "folder" : kindIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(kindColor(entry.kind, theme))
                        .frame(width: 14)
                    Text(entry.pathKey.shortDisplayPath)
                        .font(.system(size: 11.5))
                        .foregroundColor(entry.state == .reverted ? theme.tertiaryText : theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let from = entry.fromPath {
                        Text("← \(from)")
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if entry.state == .reverted {
                        PanelStatusPill(text: L("Reverted"), color: theme.secondaryText)
                    } else if entry.state == .conflicted {
                        PanelStatusPill(text: L("Edited since"), color: theme.warningColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(entry.pathKey.hostURL.path))
            .accessibilityLabel(Text("\(kindLabel): \(entry.pathKey.shortDisplayPath)"))
            .accessibilityHint(Text(entry.entryType == .directory ? "" : L("Shows what changed in this file")))
            if isExpanded {
                FileDiffPanelView(key: entry.pathKey, before: entry.before, after: entry.after)
            }
        }
        .padding(.leading, 38)
        .padding(.trailing, 14)
        .padding(.vertical, 3)
    }

    private var kindIcon: String {
        switch entry.kind {
        case .created: return "plus"
        case .modified: return "pencil"
        case .deleted: return "minus"
        }
    }

    private var kindLabel: String {
        switch entry.kind {
        case .created: return L("Created")
        case .modified: return L("Modified")
        case .deleted: return L("Deleted")
        }
    }
}

// MARK: - Net file row

private struct NetFileRow: View {
    let change: FileNetChange
    let actionsDisabled: Bool
    let onRevert: () -> Void

    @State private var isExpanded = false
    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if change.entryType != .directory { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                            .opacity(change.entryType == .directory ? 0 : 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(change.key.filename)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                                PanelStatusPill(text: kindLabel, color: kindColor(change.kind, theme))
                            }
                            Text(change.key.shortDisplayPath)
                                .font(.system(size: 10.5))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(kindLabel): \(change.key.shortDisplayPath)"))
                .accessibilityHint(Text(isExpanded ? L("Collapse") : L("Shows what changed in this file")))
                if change.latest != nil {
                    HeaderActionButton(icon: "folder", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([change.key.hostURL])
                    }
                    .opacity(isHovered ? 1 : 0.5)
                }
                Button(action: onRevert) {
                    Text("Revert File", bundle: .module).font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PanelPillButtonStyle(tint: theme.accentColor))
                .disabled(actionsDisabled)
                .opacity(isHovered ? 1 : 0.7)
                .help(Text("Return this file to how it was before this chat", bundle: .module))
            }
            .contextMenu {
                Button(action: onRevert) {
                    Label(L("Revert File"), systemImage: "arrow.uturn.backward")
                }
                .disabled(actionsDisabled)
                if change.latest != nil {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([change.key.hostURL])
                    } label: {
                        Label(L("Reveal in Finder"), systemImage: "folder")
                    }
                }
            }
            if isExpanded {
                FileDiffPanelView(key: change.key, before: change.original, after: change.latest)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? theme.tertiaryBackground.opacity(0.4) : .clear)
        .onHover { isHovered = $0 }
        .help(Text(hoverHelp))
    }

    private var hoverHelp: String {
        let changes = L("\(change.setIds.count) changes")
        let last = L("last by \(FileChangeSet.displayName(forTool: change.lastTool))")
        return change.key.hostURL.path + "\n" + changes + " · " + last
    }

    private var kindLabel: String {
        switch change.kind {
        case .created: return L("Created")
        case .modified: return L("Modified")
        case .deleted: return L("Deleted")
        }
    }
}

// MARK: - Diff view

/// Lazily computed diff for one before/after pair: text/document lines,
/// images side by side, or a size summary, with Open before/after.
struct FileDiffPanelView: View {
    let key: FilePathKey
    let before: FilePathState?
    let after: FilePathState?

    @State private var content: FileDiffContent?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content {
                if let caption = content.caption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                }
                bodyView(content)
                openBar(content)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading diff…", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.inputBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(key.displayPath)|\(before?.signature ?? "-")|\(after?.signature ?? "-")") {
            content = await FileDiffEngine.diff(key: key, before: before, after: after)
        }
    }

    @ViewBuilder
    private func bodyView(_ content: FileDiffContent) -> some View {
        switch content.body {
        case .text(let diff):
            DiffLinesView(diff: diff)
        case .image:
            HStack(alignment: .top, spacing: 8) {
                DiffImageSide(url: content.beforeURL, label: L("Before"))
                DiffImageSide(url: content.afterURL, label: L("After"))
            }
            .padding(8)
        case .binary:
            notice(L("Binary file · \(sizeText(content.beforeSize)) → \(sizeText(content.afterSize))"))
        case .directory:
            notice(L("Folder"))
        case .symlink(let before, let after):
            notice(L("Link: \(before ?? "—") → \(after ?? "—")"))
        case .unavailable(let reason):
            notice(reason)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .padding(10)
    }

    @ViewBuilder
    private func openBar(_ content: FileDiffContent) -> some View {
        if content.beforeURL != nil || content.afterURL != nil {
            HStack(spacing: 12) {
                if let url = content.beforeURL {
                    openButton(L("Open before"), url)
                }
                if let url = content.afterURL {
                    openButton(L("Open after"), url)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
    }

    private func openButton(_ title: String, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        } label: {
            Label(title, systemImage: "arrow.up.right.square")
                .font(.system(size: 10.5, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.accentColor)
    }

    private func sizeText(_ size: Int64?) -> String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// One side of an image comparison. Decodes off the render path so a
/// large photo doesn't stall the panel while it expands.
private struct DiffImageSide: View {
    let url: URL?
    let label: String

    @State private var image: NSImage?
    @State private var failed = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .accessibilityLabel(Text(label))
            } else if url == nil || failed {
                Text("—").foregroundColor(theme.tertiaryText).frame(height: 40)
            } else {
                ProgressView().controlSize(.small).frame(height: 40)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { return }
            let decoded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            if let decoded { image = decoded } else { failed = true }
        }
    }
}

/// Unified-diff rows tinted like the chat's diff card, with changed words
/// emphasized inside replaced line pairs.
struct DiffLinesView: View {
    let diff: FileDiff

    @Environment(\.theme) private var theme

    private static let maxRows = 400

    var body: some View {
        let highlighted = FileDiffEngine.wordHighlights(for: Array(diff.lines.prefix(Self.maxRows)))
        VStack(alignment: .leading, spacing: 0) {
            if diff.addedCount > 0 || diff.removedCount > 0 {
                HStack(spacing: 6) {
                    if diff.addedCount > 0 {
                        Text(verbatim: "+\(diff.addedCount)").foregroundColor(theme.successColor)
                    }
                    if diff.removedCount > 0 {
                        Text(verbatim: "−\(diff.removedCount)").foregroundColor(theme.errorColor)
                    }
                    Spacer()
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .accessibilityLabel(Text(L("\(diff.addedCount) lines added") + ", " + L("\(diff.removedCount) lines removed")))
            }
            ForEach(Array(diff.lines.prefix(Self.maxRows).enumerated()), id: \.offset) { index, line in
                row(line, ranges: highlighted[index] ?? [])
            }
            if diff.lines.count > Self.maxRows || diff.truncated {
                Text("Showing the first changes only — open the file to see everything.", bundle: .module)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.tertiaryText)
                    .padding(8)
            }
        }
        .padding(.bottom, 4)
    }

    private func row(_ line: FileDiff.Line, ranges: [Range<String.Index>]) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(bar(line.kind)).frame(width: 3)
            Text(attributed(line, ranges: ranges))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(line.kind == .meta ? theme.tertiaryText : line.kind == .context ? theme.secondaryText : theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .textSelection(.enabled)
        }
        .background(fill(line.kind))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func attributed(_ line: FileDiff.Line, ranges: [Range<String.Index>]) -> AttributedString {
        let text = line.text.isEmpty ? " " : line.text
        var out = AttributedString(text)
        guard !ranges.isEmpty else { return out }
        let strong = (line.kind == .added ? theme.successColor : theme.errorColor).opacity(0.35)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                let upper = AttributedString.Index(range.upperBound, within: out)
            else { continue }
            out[lower..<upper].backgroundColor = strong
            out[lower..<upper].font = .system(size: 10.5, weight: .semibold, design: .monospaced)
        }
        return out
    }

    private func bar(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .added: return theme.successColor.opacity(0.6)
        case .removed: return theme.errorColor.opacity(0.6)
        case .context, .meta: return .clear
        }
    }

    private func fill(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .added: return theme.successColor.opacity(0.14)
        case .removed: return theme.errorColor.opacity(0.14)
        case .meta: return theme.tertiaryBackground.opacity(0.4)
        case .context: return .clear
        }
    }
}

// MARK: - Small shared pieces

private func kindColor(_ kind: FileChangeEntryKind, _ theme: ThemeProtocol) -> Color {
    switch kind {
    case .created: return theme.successColor
    case .modified: return theme.accentColor
    case .deleted: return theme.errorColor
    }
}

struct PanelStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct PanelPillButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}
