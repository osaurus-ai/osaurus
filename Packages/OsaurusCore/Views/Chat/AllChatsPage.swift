//
//  AllChatsPage.swift
//  osaurus
//
//  The All chats page in the Chat destination's content column: every chat
//  on this Mac, newest first and grouped by day, with message search, the
//  All / Pinned / Untitled / Archived chips, an agent chip, and a floating
//  bar for the window's selection. The list itself is `AllChatsList`; what
//  it shows is `AllChatsModel`.
//

import AppKit
import SwiftUI

/// The row actions a chat window gives the All chats list, keeping the
/// window's live session in step with the store.
struct ChatHistoryWindowActions {
    let windowState: ChatWindowState
    let scope: ThemedAlertScope

    @MainActor
    func delete(_ id: UUID) {
        // Cancel a registry-owned run, detach this window, then delete.
        if let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: id) {
            BackgroundTaskManager.shared.cancelTask(liveTask.id)
        }
        windowState.prepareForSessionDeletion(id: id)
        ChatSessionsManager.shared.delete(id: id)
        windowState.refreshSessions()
    }

    @MainActor
    func rename(_ id: UUID, _ title: String) {
        ChatSessionsManager.shared.rename(id: id, title: title)
        if windowState.session.sessionId == id { windowState.session.title = title }
        windowState.refreshSessions()
    }

    @MainActor
    func setArchived(_ id: UUID, _ archived: Bool) {
        ChatSessionsManager.shared.setArchived(id: id, archived: archived)
        if windowState.session.sessionId == id { windowState.session.archived = archived }
        windowState.refreshSessions()
    }

    @MainActor
    func setPinned(_ id: UUID, _ pinned: Bool) {
        ChatSessionsManager.shared.setPinned(id: id, pinned: pinned)
        if windowState.session.sessionId == id { windowState.session.pinned = pinned }
        windowState.refreshSessions()
    }

    @MainActor
    func setProject(_ id: UUID, _ projectId: UUID?) {
        ChatSessionsManager.shared.setProject(id: id, projectId: projectId)
        if windowState.session.sessionId == id { windowState.session.projectId = projectId }
        windowState.refreshSessions()
    }

    @MainActor
    func export(_ metadata: ChatSessionData, _ format: ChatSessionSidebar.ExportFormat) {
        ChatSessionExportCoordinator.run(metadataSession: metadata, format: format, scope: scope)
    }

    @MainActor
    func stop(_ id: UUID) {
        if windowState.session.sessionId == id {
            windowState.session.stop()
        } else {
            SessionActivityMonitor.shared.stop(sessionId: id)
        }
    }

    @MainActor
    func openInNewWindow(_ data: ChatSessionData) {
        ChatWindowManager.shared.openSessionInNewWindow(data)
    }
}

struct AllChatsPage: View {
    @ObservedObject var windowState: ChatWindowState
    let request: AllChatsRequest
    let scope: ThemedAlertScope
    let onSelect: (ChatSessionData) -> Void
    let onOpenInNewTab: (ChatSessionData) -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    @State private var filter: AllChatsFilter = .all
    @State private var agentFilter: UUID?
    @State private var query = ""
    @State private var contentMatches: Set<UUID> = []
    @State private var contentSearchTask: Task<Void, Never>?
    @State private var isContentSearchInFlight = false
    @State private var limit = AllChatsModel.pageSize
    @State private var previews: [UUID: String] = [:]
    /// Chats whose preview was asked for, found or not, so a chat with no
    /// user message is not asked again on every page.
    @State private var previewRequested: Set<UUID> = []
    @FocusState private var isSearchFocused: Bool

    private var selection: Binding<ChatSelection> { $windowState.chatSelection }

    private var agentNames: [UUID: String] {
        Dictionary(agentManager.agents.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private var model: AllChatsModel {
        AllChatsModel.build(
            sessions: sessionsManager.sessions,
            agentNames: agentNames,
            query: query,
            filter: filter,
            agentId: agentFilter,
            contentMatches: contentMatches,
            limit: limit
        )
    }

    var body: some View {
        let model = self.model
        let pageIds = model.groups.flatMap { $0.rows.map(\.id) }
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                header
                SidebarSearchField(
                    text: $query,
                    placeholder: "Search titles and messages",
                    isFocused: $isSearchFocused,
                    isSearching: isContentSearchInFlight,
                    chrome: .field
                )
                filterChips(model)
                agentChips
                if model.groups.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    AllChatsList(
                        groups: model.groups,
                        hasMore: model.hasMore,
                        onLoadMore: { limit += AllChatsModel.pageSize },
                        currentSessionId: windowState.session.sessionId,
                        selection: selection,
                        previews: previews,
                        actions: ChatHistoryWindowActions(windowState: windowState, scope: scope),
                        onSelect: onSelect,
                        onOpenInNewTab: onOpenInNewTab
                    )
                }
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.top, theme.space.s16)

            if showsBatchBar(model) {
                floatingBatchBar(model)
                    .padding(.bottom, theme.space.s16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(theme.motion.quick, value: showsBatchBar(model))
        .onAppear { apply(request) }
        .onChange(of: request.id) { _, _ in apply(request) }
        .onChange(of: query) { _, newQuery in
            limit = AllChatsModel.pageSize
            scheduleContentSearch(newQuery)
        }
        .onChange(of: filter) { _, _ in limit = AllChatsModel.pageSize }
        .onChange(of: agentFilter) { _, _ in limit = AllChatsModel.pageSize }
        .task(id: pageIds) { await loadPreviews(for: pageIds) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("All chats", bundle: .module)
                    .textStyle(.title)
                    .foregroundStyle(theme.text.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: subtitle)
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.secondary)
            }
            Spacer(minLength: theme.space.s8)
            SettingsButton(.secondary, "Import", icon: "square.and.arrow.down", size: .compact) {
                ConversationImportRequest.present(
                    agentId: agentFilter ?? windowState.agentId, scope: scope, onOpen: onSelect)
            }
            if windowState.chatSelection.isActive {
                SettingsButton(.secondary, "Done", size: .compact) { windowState.chatSelection.clear() }
            } else {
                SettingsButton(.secondary, "Select", size: .compact) { windowState.chatSelection.requestMode() }
            }
        }
    }

    /// "N chats on this Mac" or "N chats with <Agent>": the chats the agent
    /// chip covers, archived ones aside.
    private var subtitle: String {
        let count = ChatSessionSidebar.allChatsCount(sessionsManager.sessions, agentId: agentFilter)
        if let agentFilter, let name = agentNames[agentFilter] {
            return count == 1
                ? L("1 chat with \(name), newest first.")
                : L("\(count) chats with \(name), newest first.")
        }
        return count == 1 ? L("1 chat on this Mac, newest first.") : L("\(count) chats on this Mac, newest first.")
    }

    // MARK: Chips

    private func filterChips(_ model: AllChatsModel) -> some View {
        FilterChipScroller(reveal: AnyHashable(filter)) {
            ForEach(AllChatsFilter.allCases, id: \.self) { chip in
                FilterChip(Self.title(for: chip), count: model.counts[chip] ?? 0, isSelected: filter == chip) {
                    withAnimation(theme.motion.quick) { filter = chip }
                }
                .id(AnyHashable(chip))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Filter", bundle: .module))
    }

    nonisolated static func title(for filter: AllChatsFilter) -> String {
        switch filter {
        case .all: return L("All")
        case .pinned: return L("Pinned")
        case .untitled: return L("Untitled")
        case .archived: return L("Archived")
        }
    }

    private var agentChips: some View {
        let names = agentNames
        return FilterChipRow(
            agentManager.agents.map(\.id),
            selection: $agentFilter,
            allTitle: L("All agents"),
            title: { names[$0] ?? "" }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Agent", bundle: .module))
    }

    // MARK: Empty state

    private var emptyState: some View {
        SettingsEmptyState(
            inline: "magnifyingglass",
            title: "No chats match",
            hint: "Try a different word, or clear the filters.",
            action: .init(title: L("Clear filters"), icon: "xmark.circle") {
                withAnimation(theme.motion.quick) {
                    query = ""
                    filter = .all
                    agentFilter = nil
                }
            }
        )
        .padding(.top, theme.space.s24)
    }

    // MARK: Batch bar

    /// In selection mode, and whenever a chip or the search narrows the
    /// list, so `Select all M` is one click away from a filter.
    private func showsBatchBar(_ model: AllChatsModel) -> Bool {
        windowState.chatSelection.isActive
            || (Self.isNarrowed(filter: filter, agentId: agentFilter, query: query) && !model.matchingIds.isEmpty)
    }

    nonisolated static func isNarrowed(filter: AllChatsFilter, agentId: UUID?, query: String) -> Bool {
        filter != .all || agentId != nil || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func floatingBatchBar(_ model: AllChatsModel) -> some View {
        let ids = windowState.chatSelection.selectedIds
        let sessions = sessionsManager.sessions
        let allPinned = ChatBatchActions.allPinned(ids, in: sessions)
        let allArchived = ChatBatchActions.allArchived(ids, in: sessions)
        let everyMatchSelected = !model.matchingIds.isEmpty && model.matchingIds.allSatisfy(ids.contains)
        return HStack(spacing: theme.space.s8) {
            Text(verbatim: ids.isEmpty ? L("Tick chats to select") : L("\(ids.count) selected"))
                .textStyle(.label, weight: 600)
                .monospacedDigit()
                .foregroundStyle(ids.isEmpty ? theme.text.secondary : theme.text.primary)
                .lineLimit(1)
            if !everyMatchSelected, !model.matchingIds.isEmpty {
                SettingsButton(.tertiary, L("Select all \(model.matchingIds.count)"), size: .compact, verbatim: true) {
                    windowState.chatSelection.select(model.matchingIds)
                }
            }
            if !ids.isEmpty {
                SettingsButton(.secondary, allPinned ? "Unpin" : "Pin", size: .compact) {
                    ChatBatchActions.setPinned(ids, pinned: !allPinned)
                    windowState.chatSelection.clear()
                }
                SettingsButton(.secondary, allArchived ? "Unarchive" : "Archive", size: .compact) {
                    ChatBatchActions.setArchived(ids, archived: !allArchived)
                    windowState.chatSelection.clear()
                }
                SettingsButton(.destructive, "Delete", size: .compact) {
                    ChatBatchActions.requestDelete(ids, scope: scope) { windowState.chatSelection.clear() }
                }
            }
            if windowState.chatSelection.isActive {
                SettingsIconButton("xmark", help: "Clear selection", size: .compact, role: .tertiary) {
                    windowState.chatSelection.clear()
                }
            }
        }
        .padding(.horizontal, theme.space.s14)
        .padding(.vertical, theme.space.s8)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .fill(theme.surface.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .themeElevation(theme.elevation.overlay)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Selected chats", bundle: .module))
    }

    // MARK: Loading

    private func apply(_ request: AllChatsRequest) {
        filter = request.filter
        agentFilter = request.agentId
        query = request.query
        limit = AllChatsModel.pageSize
        scheduleContentSearch(request.query)
    }

    private func loadPreviews(for ids: [UUID]) async {
        let missing = ids.filter { !previewRequested.contains($0) }
        guard !missing.isEmpty else { return }
        previewRequested.formUnion(missing)
        let found = await ChatSessionStore.firstUserMessagePreviews(ids: missing)
        previews.merge(found) { _, new in new }
    }

    /// Debounced full-text lookup over message bodies.
    private func scheduleContentSearch(_ query: String) {
        contentSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            contentMatches = []
            isContentSearchInFlight = false
            return
        }
        isContentSearchInFlight = true
        contentSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let ids = await ChatSessionStore.sessionIds(withContentContaining: trimmed)
            guard !Task.isCancelled else { return }
            contentMatches = ids
            isContentSearchInFlight = false
        }
    }
}

/// The Import Conversations flow: the first-time provider guide, then the
/// picker, scoped to `agentId` (the Default agent imports unscoped).
enum ConversationImportRequest {
    @MainActor
    static func present(agentId: UUID, scope: ThemedAlertScope, onOpen: @escaping (ChatSessionData) -> Void) {
        let startImport = {
            ChatSessionImportCoordinator.run(
                agentId: agentId == Agent.defaultId ? nil : agentId,
                scope: scope,
                source: .sidebar,
                onOpen: { onOpen($0) }
            )
        }
        if ImportGuidePreference.shared.skip {
            startImport()
            return
        }
        let requestId = UUID()
        let sheet = ImportGuideSheet {
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            startImport()
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Import Conversations",
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 470,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }
}
