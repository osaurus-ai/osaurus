//
//  FileChangesPanel.swift
//  osaurus
//
//  Session-scoped File Changes pane of the chat inspector (see
//  `ChatInspectorPanel`, the card that holds it). The header carries
//  "File Changes" over the "N files changed · M changes" summary, with
//  Revert All in its overflow menu; under it the Timeline | Files tabs,
//  each with its count. Row actions show on hover (and in each row's
//  context menu), so the list reads calm until you point at a row. The list sizes to its content up to `maxListHeight`, so a
//  short history makes a short card. Timeline lists every change set
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
    /// Tallest the list may grow before it scrolls; nil fills the height
    /// the host gives it.
    var maxListHeight: CGFloat? = nil

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(38, authoritative: true) }

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
    @State private var listContentHeight: CGFloat = 0

    private var journal: FileChangeJournal { .shared }

    /// Nothing recorded for this chat (or no chat at all): the pane is one
    /// empty state under the title, no summary or switcher over nothing.
    private var isEmpty: Bool {
        sessionId == nil || (!isLoading && sets.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            if isEmpty {
                SidebarEmptyState(
                    icon: "checkmark.circle",
                    title: "No file changes",
                    hint: "Files this chat creates, edits, or deletes appear here, and every change can be reverted."
                )
            } else if isLoading && sets.isEmpty {
                // First load: keep the pane quiet rather than flashing a
                // "0 files changed" header before the journal answers.
                Color.clear.frame(height: theme.space.s48)
            } else {
                viewPicker
                Rectangle()
                    .fill(theme.border.subtle)
                    .frame(height: theme.stroke.default)
                if hasActiveJob { activeJobBanner }
                if let maxListHeight {
                    content.frame(height: min(max(listContentHeight, CGFloat(theme.space.s48)), maxListHeight))
                } else {
                    content.frame(maxHeight: .infinity)
                }
            }
            if let toast { toastView(toast) }
        }
        .environment(\.theme, theme)
        .background(theme.surface.raised)
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

    // MARK: - Header and tabs

    /// Title over the summary, and the overflow menu holding Revert All
    /// (the one action over the whole chat, so it stays out of the way).
    private var titleRow: some View {
        HStack(alignment: .center, spacing: theme.space.s8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("File Changes", bundle: .module)
                    .textStyle(.label, weight: 600)
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)
                if !isEmpty, !sets.isEmpty {
                    Text(summaryLine)
                        .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                        .foregroundStyle(theme.text.tertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: theme.space.s8)
            if !net.isEmpty {
                Menu {
                    Button(role: .destructive) {
                        Task { await requestRevert(.all) }
                    } label: {
                        Label(L("Revert All"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(isBusy || hasActiveJob)
                } label: {
                    Image(systemName: "ellipsis")
                        .glyphSize(12, weight: .semibold)
                        .foregroundStyle(theme.text.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .localizedHelp("More")
                .accessibilityLabel(Text("More", bundle: .module))
            }
        }
        .padding(.leading, theme.space.s16)
        .padding(.trailing, theme.space.s12)
        .padding(.top, theme.space.s12)
        .padding(.bottom, theme.space.s8)
    }

    /// Timeline | Files on one quiet track, each with its count.
    private var viewPicker: some View {
        HStack(spacing: 2) {
            tabButton(.timeline, title: L("Timeline"), count: changeCount)
            tabButton(.files, title: L("Files"), count: net.count)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous).fill(theme.surface.subtle))
        .padding(.horizontal, theme.space.s12)
        .padding(.bottom, theme.space.s12)
    }

    private func tabButton(_ value: Tab, title: String, count: Int) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(theme.motion.quick) { tab = value }
        } label: {
            HStack(spacing: theme.space.s6) {
                Text(verbatim: title)
                    .componentInspectionText(38, role: .label, fallback: .footnote, weight: selected ? 600 : 500, theme: theme)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                        .monospacedDigit()
                        .foregroundStyle(theme.text.tertiary)
                }
            }
            .foregroundStyle(selected ? theme.text.primary : theme.text.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                        .fill(theme.surface.raised)
                        .themeElevation(theme.elevation.raised)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var changeCount: Int {
        sets.filter { $0.origin != .userRevert }.count
    }

    private var summaryLine: String {
        let files = net.count
        let changes = sets.filter { $0.origin != .userRevert }.count
        return (files == 1 ? L("1 file changed") : L("\(files) files changed")) + " · "
            + (changes == 1 ? L("1 change") : L("\(changes) changes"))
    }

    private var activeJobBanner: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.activeJobBanner.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 8, theme))) {
            ProgressView().controlSize(.small)
            Text("The chat is still running a command — revert is paused until it finishes.", bundle: .module)
                .componentInspectionText(38, role: .body, fallback: .footnote, theme: theme)
                .foregroundColor(theme.text.secondary)
            Spacer()
        }.catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.activeJobBanner.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.activeJobBanner.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 12, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.activeJobBanner.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.activeJobBanner.paddingY", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 8, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.activeJobBanner.paddingY")
        .background(theme.surface.hover)
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
                .padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.content.paddingY", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 6, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.content.paddingY")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listContentHeight = $0 }
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
            Text(set.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .componentInspectionText(38, role: .caption, fallback: .micro, weight: 600, theme: theme)
                .foregroundColor(theme.text.tertiary)
            if let prompt = set.turnId.flatMap(userPrompt), !prompt.isEmpty {
                Text(L("You: \(prompt)"))
                    .componentInspectionText(38, role: .body, fallback: .footnote, theme: theme)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Text(prompt))
            }
        }
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.turnHeader.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 16, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.turnHeader.paddingX")
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var files: some View {
        if net.isEmpty {
            Text("Every file is back to how it was before this chat.", bundle: .module)
                .componentInspectionText(38, role: .caption, fallback: .caption, theme: theme)
                .foregroundColor(theme.text.secondary)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.files.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 14, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.files.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 14, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.files.padding.horizontal").catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.files.padding.vertical")
        } else {
            ForEach(net) { change in
                NetFileRow(
                    change: change,
                    actionsDisabled: isBusy || hasActiveJob,
                    onRevert: { Task { await requestRevert(.file(change.key)) } }
                )
            }
        }
    }

    // MARK: - Toast

    private func toastView(_ toast: Toast) -> some View {
        HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.toastView.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 8, theme))) {
            Image(systemName: toast.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .glyphSize(12)
                .foregroundColor(toast.isWarning ? theme.status.warning.foreground : theme.status.success.foreground)
                .padding(.top, 1)
            Text(toast.message)
                .componentInspectionText(38, role: .body, fallback: .footnote, theme: theme)
                .foregroundColor(theme.text.primary)
                .lineLimit(toast.isWarning ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if let undo = toast.undoSetId {
                Button {
                    Task { await requestRevert(.set(undo)) }
                } label: {
                    Text("Undo", bundle: .module).componentInspectionText(38, role: .label, fallback: .footnote, weight: 600, theme: theme)
                }
                .buttonStyle(PanelPillButtonStyle(tint: theme.text.primary))
                .disabled(isBusy)
                .help(Text("Put the reverted files back the way they were", bundle: .module))
            }
            Button {
                self.toast = nil
            } label: {
                Image(systemName: "xmark").glyphSize(9, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.text.tertiary)
            .accessibilityLabel(Text("Dismiss", bundle: .module))
        }.catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.toastView.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.toastView.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.fileChangesPanel.toastView.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.toastView.padding.horizontal").catalogLayoutTarget("component.library.38.elements.layout.fileChangesPanel.toastView.padding.vertical")
        .background(theme.surface.hover)
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
            return n == 1 ? L("Revert 1 file?") : L("Revert \(n) files?")
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
                case .set, .file: title = others == 1 ? L("Revert 1 file") : L("Revert \(others) files")
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
            withAnimation(theme.motion.quick) { proxy.scrollTo(id, anchor: .top) }
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
        var parts = [summary.restored == 1 ? L("Reverted 1 file.") : L("Reverted \(summary.restored) files.")]
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

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(38, authoritative: true) }

    private static let maxRows = 12

    var body: some View {
        let items = pending.preview.items
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.revertOutcomeList.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 4, theme))) {
            ForEach(items.prefix(Self.maxRows)) { item in
                HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.revertOutcomeList.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 6, theme))) {
                    Image(systemName: icon(item))
                        .glyphSize(10, weight: .semibold)
                        .foregroundColor(color(item))
                        .frame(width: 12)
                    Text(item.key.shortDisplayPath)
                        .componentInspectionText(38, role: .body, fallback: .footnote, theme: theme)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(item.key.hostURL.path))
                    Spacer(minLength: 4)
                    Text(outcome(item))
                        .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                        .foregroundColor(color(item))
                        .lineLimit(1)
                }.catalogLayoutTarget("component.library.38.elements.layout.revertOutcomeList.body.horizontalGap")
                .accessibilityElement(children: .combine)
            }
            if items.count > Self.maxRows {
                Text(L("and \(items.count - Self.maxRows) more"))
                    .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                    .foregroundColor(theme.text.tertiary)
            }
        }.catalogLayoutTarget("component.library.38.elements.layout.revertOutcomeList.body.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.revertOutcomeList.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.revertOutcomeList.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).catalogLayoutTarget("component.library.38.elements.layout.revertOutcomeList.body.padding.horizontal").catalogLayoutTarget("component.library.38.elements.layout.revertOutcomeList.body.padding.vertical")
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radius.medium).fill(theme.surface.raised))
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
        if item.isConflict || item.isUnrestorable { return theme.status.warning.foreground }
        if item.target == nil { return theme.status.error.foreground }
        if item.expected == nil { return theme.status.success.foreground }
        return theme.text.secondary
    }
}

/// Inherit deliberate legacy spacing edits while giving each row its own default rhythm.
private func fileHistorySpacing(_ property: String, _ fallback: CGFloat, theme: any ThemeProtocol) -> CGFloat {
    #if OSAURUS_DESIGN_SYSTEM
    let key = NativeComponentInspectionStyle.key(38, property)
    if let snapshot = DesignThemeOverlay.shared.current(),
       snapshot.reassignedProperties.contains(CatalogElementAssignments.routed(key, mappings: snapshot.document.mappings)) {
        return NativeComponentInspectionStyle.metric(38, property, fallback, theme)
    }
    #endif
    return fallback
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
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(38, authoritative: true) }

    private var isRevert: Bool { changeSet.origin == .userRevert }
    private var canAct: Bool { changeSet.isRevertible && changeSet.status != .reverted }
    private var canRollBack: Bool { !isLatest && !isRevert && changeSet.status != .untracked }
    private var headerInset: CGFloat {
        theme.catalogLayoutMetric("component.library.38.elements.layout.changeSetRow.header.paddingX", inheriting: fileHistorySpacing("padding", theme.space.s12, theme: theme))
    }
    private var headerItemGap: CGFloat {
        theme.catalogLayoutMetric("component.library.38.elements.layout.changeSetRow.header.horizontalGap2", inheriting: fileHistorySpacing("gap", theme.space.s8, theme: theme))
    }
    private var detailsInset: CGFloat { headerInset + 26 + 2 * headerItemGap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    if let note = changeSet.note, !isRevert {
                        Text(note)
                            .componentInspectionText(38, role: .body, fallback: .footnote, theme: theme)
                            .foregroundColor(theme.status.warning.foreground)
                            .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.changeSetRow.body.paddingX", inheriting: 0)).catalogLayoutTarget("component.library.38.elements.layout.changeSetRow.body.paddingX")
                    }
                    ForEach(changeSet.entries.sorted { $0.ordinal < $1.ordinal }) { entry in
                        EntryRow(entry: entry)
                    }
                    if canRollBack {
                        Button(action: onRollback) {
                            Label(L("Roll Back to Before This"), systemImage: "clock.arrow.circlepath")
                                .componentInspectionText(38, role: .body, fallback: .footnote, weight: 500, theme: theme)
                        }
                        .buttonStyle(PanelPillButtonStyle(tint: theme.text.secondary))
                        .disabled(actionsDisabled)
                        .help(Text("Undo this change and every change made after it", bundle: .module))
                        .padding(.top, theme.space.s4)
                    }
                }
                .padding(.leading, detailsInset)
                .padding(.trailing, headerInset)
                .padding(.bottom, theme.space.s12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(isFocused ? theme.surface.selected : isHovered ? theme.surface.hover : .clear)
        )
        .padding(.horizontal, theme.space.s6)
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.changeSetRow.header.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 8, theme))) {
            Button(action: onToggle) {
                HStack(spacing: headerItemGap) {
                    Image(systemName: "chevron.right")
                        .glyphSize(9, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: icon)
                        .glyphSize(11, weight: .medium)
                        .foregroundColor(isRevert ? theme.text.primary : theme.text.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.changeSetRow.header.horizontalGap3", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 6, theme))) {
                            Text(changeSet.displayTitle)
                                .componentInspectionText(38, role: .bodyEmphasis, fallback: .caption, weight: 600, theme: theme)
                                .foregroundColor(
                                    changeSet.status == .reverted ? theme.text.secondary : theme.text.primary
                                )
                                .strikethrough(changeSet.status == .reverted && !isRevert, color: theme.text.tertiary)
                                .lineLimit(1)
                            statusPill.fixedSize()
                        }.catalogLayoutTarget("component.library.38.elements.layout.changeSetRow.header.horizontalGap3")
                        Text(fileSummary)
                            .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }.catalogLayoutTarget("component.library.38.elements.layout.changeSetRow.header.horizontalGap2")
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityTitle))
            .accessibilityHint(Text(isExpanded ? L("Collapse") : L("Expand to see files and differences")))
            if canAct {
                Button(action: onRevert) {
                    Text(isRevert ? "Undo" : "Revert", bundle: .module)
                        .componentInspectionText(38, role: .body, fallback: .footnote, weight: 500, theme: theme)
                }
                .buttonStyle(PanelPillButtonStyle(tint: theme.text.primary))
                .disabled(actionsDisabled)
                .opacity(isHovered || isFocused ? 1 : 0)
                .help(Text(isRevert ? L("Put this change back") : L("Restore these files to how they were before this change")))
                .accessibilityLabel(Text(isRevert ? L("Undo This Revert") : L("Revert This Change")))
            }
        }.catalogLayoutTarget("component.library.38.elements.layout.changeSetRow.header.horizontalGap")
        .padding(.horizontal, headerInset).catalogLayoutTarget("component.library.38.elements.layout.changeSetRow.header.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.changeSetRow.header.paddingY", inheriting: fileHistorySpacing("padding", theme.space.s8, theme: theme))).catalogLayoutTarget("component.library.38.elements.layout.changeSetRow.header.paddingY")
        .assignedContextMenu {
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
            PanelStatusPill(text: L("Reverted"), color: theme.text.secondary)
        case .partiallyReverted:
            PanelStatusPill(text: L("Partly reverted"), color: theme.status.warning.foreground)
        case .untracked:
            PanelStatusPill(text: L("Not tracked"), color: theme.status.warning.foreground)
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
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(38, authoritative: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.entryRow.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 4, theme))) {
            Button {
                if entry.entryType != .directory { isExpanded.toggle() }
            } label: {
                HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.entryRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 6, theme))) {
                    Image(systemName: entry.entryType == .directory ? "folder" : kindIcon)
                        .glyphSize(10, weight: .semibold)
                        .foregroundColor(kindColor(entry.kind, theme))
                        .frame(width: 14)
                    Text(entry.pathKey.shortDisplayPath)
                        .componentInspectionText(38, role: .body, fallback: .footnote, theme: theme)
                        .foregroundColor(entry.state == .reverted ? theme.text.tertiary : theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let from = entry.fromPath {
                        Text("← \(from)")
                            .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if entry.state == .reverted {
                        PanelStatusPill(text: L("Reverted"), color: theme.text.secondary)
                    } else if entry.state == .conflicted {
                        PanelStatusPill(text: L("Edited since"), color: theme.status.warning.foreground)
                    }
                }.catalogLayoutTarget("component.library.38.elements.layout.entryRow.body.horizontalGap")
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(entry.pathKey.hostURL.path))
            .accessibilityLabel(Text("\(kindLabel): \(entry.pathKey.shortDisplayPath)"))
            .accessibilityHint(Text(entry.entryType == .directory ? "" : L("Shows what changed in this file")))
            if isExpanded {
                FileDiffPanelView(key: entry.pathKey, before: entry.before, after: entry.after)
            }
        }.catalogLayoutTarget("component.library.38.elements.layout.entryRow.body.verticalGap")
        .padding(.vertical, theme.space.s2)
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
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(38, authoritative: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.netFileRow.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 6, theme))) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.netFileRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 8, theme))) {
                Button {
                    if change.entryType != .directory { isExpanded.toggle() }
                } label: {
                    HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.netFileRow.body.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 8, theme))) {
                        Image(systemName: "chevron.right")
                            .glyphSize(9, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                            .opacity(change.entryType == .directory ? 0 : 1)
                        Image(systemName: kindIcon)
                            .glyphSize(9, weight: .bold)
                            .foregroundColor(kindColor(change.kind, theme))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(kindColor(change.kind, theme).opacity(0.14)))
                            .help(Text(kindLabel))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.key.filename)
                                .componentInspectionText(38, role: .bodyEmphasis, fallback: .caption, weight: 600, theme: theme)
                                .foregroundColor(theme.text.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            let folder = (change.key.shortDisplayPath as NSString).deletingLastPathComponent
                            if !folder.isEmpty {
                                Text(folder)
                                    .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                                    .foregroundColor(theme.text.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }.catalogLayoutTarget("component.library.38.elements.layout.netFileRow.body.horizontalGap2")
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(kindLabel): \(change.key.shortDisplayPath)"))
                .accessibilityHint(Text(isExpanded ? L("Collapse") : L("Shows what changed in this file")))
                HStack(spacing: 0) {
                    if change.latest != nil {
                        SidebarHeaderIconButton(icon: "folder", help: "Reveal in Finder", size: 12) {
                            NSWorkspace.shared.activateFileViewerSelecting([change.key.hostURL])
                        }
                        .accessibilityLabel(Text("Reveal in Finder", bundle: .module))
                    }
                    SidebarHeaderIconButton(icon: "arrow.uturn.backward", help: "Return this file to how it was before this chat", size: 12, action: onRevert)
                        .disabled(actionsDisabled)
                        .accessibilityLabel(Text("Revert File", bundle: .module))
                }
                .opacity(isHovered ? 1 : 0)
            }.catalogLayoutTarget("component.library.38.elements.layout.netFileRow.body.horizontalGap")
            .assignedContextMenu {
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
        }.catalogLayoutTarget("component.library.38.elements.layout.netFileRow.body.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.netFileRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).catalogLayoutTarget("component.library.38.elements.layout.netFileRow.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.netFileRow.body.paddingY", inheriting: fileHistorySpacing("padding", theme.space.s8, theme: theme))).catalogLayoutTarget("component.library.38.elements.layout.netFileRow.body.paddingY")
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(isHovered ? theme.surface.hover : .clear)
        )
        .padding(.horizontal, theme.space.s6)
        .onHover { isHovered = $0 }
        .help(Text(hoverHelp))
    }

    private var hoverHelp: String {
        let changes = change.setIds.count == 1 ? L("1 change") : L("\(change.setIds.count) changes")
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

    private var kindIcon: String {
        switch change.kind {
        case .created: return "plus"
        case .modified: return "pencil"
        case .deleted: return "minus"
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
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(38, authoritative: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content {
                if let caption = content.caption {
                    Text(caption)
                        .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                        .foregroundColor(theme.text.tertiary)
                        .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.body.paddingX")
                        .padding(.top, 6)
                }
                bodyView(content)
                openBar(content)
            } else {
                HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 8, theme))) {
                    ProgressView().controlSize(.small)
                    Text("Loading diff…", bundle: .module)
                        .componentInspectionText(38, role: .body, fallback: .footnote, theme: theme)
                        .foregroundColor(theme.text.tertiary)
                }.catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.body.horizontalGap")
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.body.padding.horizontal").catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.body.padding.vertical")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radius.medium).fill(theme.surface.raised))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
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
            HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.bodyView.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 8, theme))) {
                DiffImageSide(url: content.beforeURL, label: L("Before"))
                DiffImageSide(url: content.afterURL, label: L("After"))
            }.catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.bodyView.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.bodyView.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 8, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.bodyView.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 8, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.bodyView.padding.horizontal").catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.bodyView.padding.vertical")
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
            .componentInspectionText(38, role: .body, fallback: .footnote, theme: theme)
            .foregroundColor(theme.text.tertiary)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.notice.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.notice.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.notice.padding.horizontal").catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.notice.padding.vertical")
    }

    @ViewBuilder
    private func openBar(_ content: FileDiffContent) -> some View {
        if content.beforeURL != nil || content.afterURL != nil {
            HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.openBar.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 12, theme))) {
                if let url = content.beforeURL {
                    openButton(L("Open before"), url)
                }
                if let url = content.afterURL {
                    openButton(L("Open after"), url)
                }
                Spacer()
            }.catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.openBar.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.openBar.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.openBar.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.fileDiffPanelView.openBar.paddingY", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 6, theme))).catalogLayoutTarget("component.library.38.elements.layout.fileDiffPanelView.openBar.paddingY")
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
    }

    private func openButton(_ title: String, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        } label: {
            Label(title, systemImage: "arrow.up.right.square")
                .componentInspectionText(38, role: .caption, fallback: .micro, weight: 500, theme: theme)
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.text.link)
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
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(38, authoritative: true) }

    var body: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.diffImageSide.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 4, theme))) {
            Text(label)
                .componentInspectionText(38, role: .caption, fallback: .micro, weight: 600, theme: theme)
                .foregroundColor(theme.text.tertiary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .accessibilityLabel(Text(label))
            } else if url == nil || failed {
                Text("—").foregroundColor(theme.text.tertiary).frame(height: 40)
            } else {
                ProgressView().controlSize(.small).frame(height: 40)
            }
        }.catalogLayoutTarget("component.library.38.elements.layout.diffImageSide.body.verticalGap")
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

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(38, authoritative: true) }

    private static let maxRows = 400

    var body: some View {
        let highlighted = FileDiffEngine.wordHighlights(for: Array(diff.lines.prefix(Self.maxRows)))
        VStack(alignment: .leading, spacing: 0) {
            if diff.addedCount > 0 || diff.removedCount > 0 {
                HStack(spacing: theme.catalogLayoutMetric("component.library.38.elements.layout.diffLinesView.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(38, "gap", 6, theme))) {
                    if diff.addedCount > 0 {
                        Text(verbatim: "+\(diff.addedCount)").foregroundColor(theme.status.success.foreground)
                    }
                    if diff.removedCount > 0 {
                        Text(verbatim: "−\(diff.removedCount)").foregroundColor(theme.status.error.foreground)
                    }
                    Spacer()
                }.catalogLayoutTarget("component.library.38.elements.layout.diffLinesView.body.horizontalGap")
                .componentInspectionText(38, role: .code, fallback: .micro, weight: 500, family: .code, theme: theme)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.diffLinesView.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 10, theme))).catalogLayoutTarget("component.library.38.elements.layout.diffLinesView.body.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.diffLinesView.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 5, theme))).catalogLayoutTarget("component.library.38.elements.layout.diffLinesView.body.paddingY")
                .accessibilityLabel(
                    Text(
                        (diff.addedCount == 1 ? L("1 line added") : L("\(diff.addedCount) lines added")) + ", "
                            + (diff.removedCount == 1 ? L("1 line removed") : L("\(diff.removedCount) lines removed"))))
            }
            ForEach(Array(diff.lines.prefix(Self.maxRows).enumerated()), id: \.offset) { index, line in
                row(line, ranges: highlighted[index] ?? [])
            }
            if diff.lines.count > Self.maxRows || diff.truncated {
                Text("Showing the first changes only — open the file to see everything.", bundle: .module)
                    .componentInspectionText(38, role: .caption, fallback: .micro, theme: theme)
                    .foregroundColor(theme.text.tertiary)
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.diffLinesView.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 8, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.diffLinesView.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 8, theme))).catalogLayoutTarget("component.library.38.elements.layout.diffLinesView.body.padding.horizontal").catalogLayoutTarget("component.library.38.elements.layout.diffLinesView.body.padding.vertical")
            }
        }
        .padding(.bottom, 4)
    }

    private func row(_ line: FileDiff.Line, ranges: [Range<String.Index>]) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(bar(line.kind)).frame(width: 2)
            Text(verbatim: line.kind == .added ? "+" : line.kind == .removed ? "−" : "")
                .componentInspectionText(38, role: .code, fallback: .micro, family: .code, theme: theme)
                .foregroundColor(bar(line.kind))
                .frame(width: theme.space.s16, alignment: .trailing)
            Text(attributed(line, ranges: ranges))
                .componentInspectionText(38, role: .code, fallback: .micro, family: .code, theme: theme)
                .foregroundColor(
                    line.kind == .meta
                        ? theme.text.tertiary : line.kind == .context ? theme.text.secondary : theme.text.primary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.diffLinesView.row.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 8, theme))).catalogLayoutTarget("component.library.38.elements.layout.diffLinesView.row.paddingX")
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
        let strong = (line.kind == .added ? theme.status.success.foreground : theme.status.error.foreground).opacity(
            0.35
        )
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                let upper = AttributedString.Index(range.upperBound, within: out)
            else { continue }
            out[lower..<upper].backgroundColor = strong
            #if OSAURUS_DESIGN_SYSTEM
            out[lower..<upper].font = theme.font(for: theme.scaledTextStyle(.code))
            #else
            out[lower..<upper].font = theme.font(
                for: ThemeTextStyleModifier.style(.micro, weight: 600, family: .code, in: theme))
            #endif
        }
        return out
    }

    private func bar(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .added: return theme.status.success.foreground
        case .removed: return theme.status.error.foreground
        case .context, .meta: return .clear
        }
    }

    private func fill(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .added: return theme.status.success.background
        case .removed: return theme.status.error.background
        case .meta: return theme.surface.hover
        case .context: return .clear
        }
    }
}

// MARK: - Small shared pieces

private func kindColor(_ kind: FileChangeEntryKind, _ theme: ThemeProtocol) -> Color {
    switch kind {
    case .created: return theme.status.success.foreground
    case .modified: return theme.status.info.foreground
    case .deleted: return theme.status.error.foreground
    }
}

struct PanelStatusPill: View {
    @Environment(\.theme) private var theme
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .componentInspectionText(38, role: .caption, fallback: .micro, weight: 600, theme: theme)
            .foregroundColor(color)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.panelStatusPill.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 6, theme))).catalogLayoutTarget("component.library.38.elements.layout.panelStatusPill.body.paddingX")
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct PanelPillButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        let fill = theme.assignedColor(NativeComponentInspectionStyle.key(38, isEnabled ? "background" : "disabledBackground"), fallback: theme.surface.raised)
        let ink = isEnabled ? tint : theme.assignedColor(NativeComponentInspectionStyle.key(38, "disabledForeground"), fallback: theme.text.disabled)
        let shape = RoundedRectangle(cornerRadius: theme.assignedMetric(NativeComponentInspectionStyle.key(38, "radius"), fallback: theme.radius.medium))
        configuration.label
            .foregroundColor(ink)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.38.elements.layout.panelPillButtonStyle.makeBody.paddingX", inheriting: NativeComponentInspectionStyle.metric(38, "padding", 9, theme))).catalogLayoutTarget("component.library.38.elements.layout.panelPillButtonStyle.makeBody.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.38.elements.layout.panelPillButtonStyle.makeBody.paddingY", inheriting: fileHistorySpacing("padding", theme.space.s4, theme: theme))).catalogLayoutTarget("component.library.38.elements.layout.panelPillButtonStyle.makeBody.paddingY")
            .frame(minHeight: NativeComponentInspectionStyle.metric(38, "height", 0, theme))
            .background(shape.fill(fill))
            .overlay(shape.fill(configuration.isPressed && isEnabled ? tint.opacity(0.1) : .clear).allowsHitTesting(false))
            .contentShape(shape)
        #else
        configuration.label
            .foregroundColor(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        #endif
    }
}

#if OSAURUS_DESIGN_SYSTEM
/// Journal display values only: no journal write, revert or rollback is performed.
@MainActor @ViewBuilder func inspectorFileContextRow(_ kind: Int, disabled: Bool, action: @escaping (String) -> Void) -> some View {
    let setID = UUID()
    let before = FilePathState(type: .file, signature: "local-before", size: 10)
    let after = FilePathState(type: .file, signature: "local-after", size: 12)
    if kind == 5 {
        ChangeSetRow(changeSet: FileChangeSet(id: setID, sessionId: "local-menu", toolName: "file_edit", origin: .agent, entries: [FileChangeEntry(setId: setID, sessionId: "local-menu", rootKind: .hostFolder, rootId: "/tmp/osaurus-menu-check", path: "menu-sample.txt", kind: .modified, before: before, after: after, ordinal: 0)]), isExpanded: false, isFocused: false, isLatest: false, actionsDisabled: disabled, onToggle: { action("Change disclosure") }, onRevert: { action("Revert callback only") }, onRollback: { action("Rollback callback only") })
    } else {
        NetFileRow(change: FileNetChange(key: FilePathKey(rootKind: .hostFolder, rootId: "/tmp/osaurus-menu-check", path: "menu-sample.txt"), original: before, latest: after, setIds: [setID], lastChangedAt: Date(), lastTool: "file_edit"), actionsDisabled: disabled, onRevert: { action("Revert file callback only") })
    }
}
#endif

#if OSAURUS_DESIGN_INSPECTOR
/// Original history rows and confirmation outcomes, with local display metadata.
/// No journal is mounted and no file/revert operation is performed.
struct InspectorFileHistoryVerification: View {
    @State private var mode: Variant = .files
    @State private var collapsed = true
    @State private var expanded: Set<FileChangeSetStatus> = [.applied]
    private let states: [FileChangeSetStatus] = [.applied, .reverted, .partiallyReverted, .untracked]
    private enum Variant: String, CaseIterable {
        case files = "File changes panel · current files"
        case history = "File changes panel · history"
        case outcomes = "File changes panel · revert outcomes"
        case streaming = "Chat · streaming diff"
        case collapsed = "Chat · collapsed diff"
        case expanded = "Chat · expanded diff"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Used in", selection: $mode) {
                ForEach(Variant.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: mode) { _, value in collapsed = value != .expanded }
            switch mode {
            case .files: currentFiles
            case .history: history
            case .outcomes: outcomes
            case .streaming, .collapsed, .expanded:
                InspectorNativeDiffDisplay(diff: diff, collapsed: $collapsed)
            }
            Text("Preview only. Revert actions are simulated.")
                .font(SettingsFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var currentFiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3) { index in
                let state = FilePathState(type: .file, signature: "local-\(index)", size: 12)
                NetFileRow(change: FileNetChange(key: .init(rootKind: .hostFolder, rootId: "/private/tmp/Project",
                    path: ["Sources/new-file.swift", "Sources/edited-file.swift", "Docs/removed-file.md"][index]),
                    original: index == 0 ? nil : state, latest: index == 2 ? nil : state, setIds: [UUID()],
                    lastChangedAt: Date(), lastTool: "file_edit"), actionsDisabled: false, onRevert: {})
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(states, id: \.self) { status in
                ChangeSetRow(changeSet: FileChangeSet(sessionId: "inspector-display", toolName: "file_edit", origin: .agent,
                    status: status, note: status == .untracked ? "No earlier version was saved." : nil,
                    entries: [.init(setId: UUID(), sessionId: "inspector-display", rootKind: .hostFolder, rootId: "/private/tmp/Project",
                        path: "Sources", kind: .created, before: nil, after: .init(type: .directory, signature: "dir"),
                        state: status == .reverted ? .reverted : .applied, ordinal: 0)]), isExpanded: expanded.contains(status),
                    isFocused: status == .applied, isLatest: false, actionsDisabled: false,
                    onToggle: {
                        if expanded.contains(status) { expanded.remove(status) }
                        else { expanded.insert(status) }
                    }, onRevert: {}, onRollback: {})
            }
        }
    }

    private var outcomes: some View {
        let file = FilePathState(type: .file, signature: "inspector", size: 12)
        return RevertOutcomeList(pending: .init(scope: .all, preview: .init(items: [
            .init(key: .init(rootKind: .hostFolder, rootId: "/private/tmp/Project", path: "new-file.swift"), target: nil,
                expected: file, isConflict: false, isUnrestorable: false),
            .init(key: .init(rootKind: .hostFolder, rootId: "/private/tmp/Project", path: "removed-file.md"), target: file,
                expected: nil, isConflict: false, isUnrestorable: false),
            .init(key: .init(rootKind: .hostFolder, rootId: "/private/tmp/Project", path: "edited-file.swift"), target: file,
                expected: file, isConflict: false, isUnrestorable: false),
            .init(key: .init(rootKind: .hostFolder, rootId: "/private/tmp/Project", path: "conflict.txt"), target: nil,
                expected: nil, isConflict: true, isUnrestorable: false),
            .init(key: .init(rootKind: .hostFolder, rootId: "/private/tmp/Project", path: "unrestorable.txt"), target: nil,
                expected: nil, isConflict: false, isUnrestorable: true)])))
    }

    private var diff: FileDiff {
        let patch = """
            @@ -1,4 +1,5 @@
             struct Settings {
            -    let retryLimit = 2
            +    let retryLimit = 3
            +    let timeout = 30
                 let loggingEnabled = true
             }
            """
        var result = FileDiff.fromUnifiedDiff(patch, path: "Sources/Settings.swift", isPreview: mode != .collapsed)
        result.isStreamingPreview = mode == .streaming
        return result
    }
}

private struct InspectorNativeDiffDisplay: NSViewRepresentable {
    let diff: FileDiff
    @Binding var collapsed: Bool
    @Environment(\.theme) private var theme
    func makeNSView(context: Context) -> NativeFileDiffView { NativeFileDiffView() }
    func updateNSView(_ view: NativeFileDiffView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) };
        view.onToggleCollapse = { collapsed.toggle() }
        view.configure(diff: diff, collapsed: collapsed, width: view.bounds.width > 1 ? view.bounds.width : 500, theme: theme)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeFileDiffView, context: Context) -> CGSize? {
        let width = proposal.width ?? 760
        nsView.configure(diff: diff, collapsed: collapsed, width: width, theme: theme)
        return CGSize(width: width, height: nsView.measuredCardHeight(cardWidth: width))
    }
}
#endif
