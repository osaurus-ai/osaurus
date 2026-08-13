//
//  ProjectDetailView.swift
//  osaurus
//
//  Full-content project page: name, shared instructions, and the
//  conversations grouped under the project. Shown in the chat window's
//  content area when a project is opened from the sidebar's Projects tab.
//

import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    /// The hosting window's active agent — the effective default when the
    /// project hasn't pinned one.
    let currentAgentId: UUID?
    /// Open a conversation (the host closes this page and loads it).
    let onOpenSession: (ChatSessionData) -> Void
    /// Start a new chat inside this project.
    let onNewChat: () -> Void
    /// Delete the project (host detaches member chats and closes the page).
    /// Called after this view's own confirmation dialog.
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared
    @ObservedObject private var knowledgeManager = KnowledgeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    /// Draft of the instructions editor. Auto-saved (debounced) as the
    /// user types; `autoSaveTask` holds the pending write and the
    /// `justSaved` flash gives quiet confirmation.
    @State private var instructionsDraft: String = ""
    @State private var instructionsAutoSaveTask: Task<Void, Never>?
    @State private var instructionsJustSaved: Bool = false
    @State private var loadedProjectId: UUID?
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool
    /// Member session ids whose message bodies match the query, resolved
    /// asynchronously against the chat-history database (debounced per
    /// keystroke), mirroring the sidebar's content search.
    @State private var contentMatchedSessionIds: Set<UUID> = []
    @State private var contentSearchTask: Task<Void, Never>?
    @State private var isContentSearchInFlight: Bool = false
    @State private var isAgentPickerPresented = false

    private var memberSessions: [ChatSessionData] {
        sessionsManager.sessions.filter { $0.projectId == project.id && !$0.archived }
    }

    /// Members after applying the search query (title + full-text content).
    private var visibleSessions: [ChatSessionData] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return memberSessions }
        return memberSessions.filter { session in
            SearchService.matches(query: trimmed, in: session.title)
                || contentMatchedSessionIds.contains(session.id)
        }
    }

    /// Debounced full-text lookup, same contract as the sidebar's: the
    /// in-memory sessions are metadata-only, so content matching goes to
    /// the chat-history database.
    private func scheduleContentSearch(_ query: String) {
        contentSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            contentMatchedSessionIds = []
            isContentSearchInFlight = false
            return
        }
        isContentSearchInFlight = true
        contentSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let ids = await ChatSessionStore.sessionIds(withContentContaining: trimmed)
            guard !Task.isCancelled else { return }
            contentMatchedSessionIds = ids
            isContentSearchInFlight = false
        }
    }

    private var hasEdits: Bool {
        instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                instructionsSection
                defaultAgentSection
                knowledgeSection
                conversationsSection
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 32)
            .padding(.top, 64)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear { syncDraft() }
        // The knowledge registry loads lazily off-main (launch-hang fix);
        // in a chat window this page may be its first consumer, so settle
        // it here or the Knowledge section stays hidden behind an empty
        // `collections`.
        .task { await knowledgeManager.ensureLoaded() }
        // Same view instance can be repointed at another project (sidebar
        // click while the page is open) — reload the draft for the new one.
        .onChange(of: project.id) { _, _ in syncDraft() }
    }

    private func syncDraft() {
        guard loadedProjectId != project.id else { return }
        loadedProjectId = project.id
        instructionsDraft = project.instructions
        searchQuery = ""
        contentSearchTask?.cancel()
        contentMatchedSessionIds = []
        isContentSearchInFlight = false
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.accentColor.opacity(theme.isDark ? 0.2 : 0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: "folder.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: project.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text("\(memberSessions.count) conversations", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Menu {
                Button(action: requestRename) { Text("Rename", bundle: .module) }
                Divider()
                Button(role: .destructive, action: requestDelete) {
                    Text("Delete", bundle: .module)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.secondaryBackground.opacity(0.5)))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Instructions", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if instructionsJustSaved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("Saved", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .transition(.opacity)
                }
            }

            Text("Shared context added to every chat in this project.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            TextEditor(text: $instructionsDraft)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 180)
                .padding(8)
                // TextEditor has no prompt; overlay one until text arrives.
                // allowsHitTesting(false) keeps clicks landing in the editor.
                .overlay(alignment: .topLeading) {
                    if instructionsDraft.isEmpty {
                        Text(
                            "Add instructions the assistant should follow in every chat in this project…",
                            bundle: .module
                        )
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.35 : 0.5))
                )
                // Debounced auto-save: writes ~0.6s after the user stops
                // typing, so instructions can never be lost by navigating
                // away without hitting a Save button.
                .onChange(of: instructionsDraft) { _, _ in scheduleInstructionsAutoSave() }
        }
        .animation(theme.animationQuick(), value: instructionsJustSaved)
        // Persist immediately if the user leaves before the debounce fires.
        .onDisappear { flushInstructionsSave() }
    }

    private func scheduleInstructionsAutoSave() {
        guard hasEdits else { return }
        instructionsJustSaved = false
        instructionsAutoSaveTask?.cancel()
        instructionsAutoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, hasEdits else { return }
            saveInstructions()
        }
    }

    private func flushInstructionsSave() {
        instructionsAutoSaveTask?.cancel()
        instructionsAutoSaveTask = nil
        if hasEdits { saveInstructions() }
    }

    private func saveInstructions() {
        var updated = project
        updated.instructions = instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        ProjectManager.shared.update(updated)
        withAnimation(theme.animationQuick()) { instructionsJustSaved = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(theme.animationQuick()) { instructionsJustSaved = false }
        }
    }

    // MARK: - Default Agent

    /// Picker for the agent new chats in this project start with. A nudge
    /// toward one-agent projects (shared memory, consistent capabilities),
    /// never a restriction — chats from any agent can still be moved in.
    private var defaultAgentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Agent", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("New chats started from this project use this agent.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            // Button + popover rather than Menu: macOS measures a Menu's
            // label at its image's intrinsic size, which blows a resizable
            // mascot up to full resolution regardless of frames (the agent
            // pill avoids Menu for the same reason).
            Button {
                isAgentPickerPresented.toggle()
            } label: {
                HStack(spacing: 8) {
                    if let agent = effectiveDefaultAgent {
                        AgentAvatarView(
                            mascotId: agent.avatar,
                            name: agent.name,
                            tint: theme.accentColor,
                            diameter: 18,
                            customImageURL: agent.customAvatarURL,
                            monogramFontSize: 8,
                            borderWidth: 0
                        )
                        Text(verbatim: agent.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.35 : 0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.secondaryText.opacity(0.15), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .popover(isPresented: $isAgentPickerPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(selectableAgents) { agent in
                        defaultAgentPickerRow(agent)
                    }
                }
                .padding(6)
                .frame(minWidth: 280)
            }
        }
    }

    private func defaultAgentPickerRow(_ agent: Agent) -> some View {
        let isSelected = agent.id == effectiveDefaultAgent?.id
        return Button {
            isAgentPickerPresented = false
            setDefaultAgent(agent.id)
        } label: {
            HStack(spacing: 8) {
                AgentAvatarView(
                    mascotId: agent.avatar,
                    name: agent.name,
                    tint: theme.accentColor,
                    diameter: 18,
                    customImageURL: agent.customAvatarURL,
                    monogramFontSize: 8,
                    borderWidth: 0
                )
                Text(verbatim: agent.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    /// Agents offered as project defaults: the built-in Osaurus setup agent
    /// is excluded — it exists to configure the app, not to own project work.
    private var selectableAgents: [Agent] {
        agentManager.agents.filter { $0.id != Agent.defaultId }
    }

    /// What the dropdown shows ticked: the pinned default when set and
    /// still existing, otherwise the hosting window's current agent.
    private var effectiveDefaultAgent: Agent? {
        if let id = project.defaultAgentId,
            let pinned = agentManager.agents.first(where: { $0.id == id })
        {
            return pinned
        }
        guard let currentAgentId else { return nil }
        return agentManager.agents.first { $0.id == currentAgentId }
    }

    private func setDefaultAgent(_ agentId: UUID?) {
        var updated = project
        updated.defaultAgentId = agentId
        ProjectManager.shared.update(updated)
    }

    // MARK: - Knowledge

    /// Toggle rows granting knowledge collections to this project. Granted
    /// collections are searchable from every chat in the project (unioned
    /// with the agent's own grants at request time).
    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Knowledge", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button {
                    // One-shot request consumed by KnowledgeView so the create
                    // sheet pops as soon as the tab shows, saving a click. The
                    // created collection is named after this project and
                    // granted to it automatically.
                    ManagementStateManager.shared.pendingKnowledgeCreate = .init(
                        prefillName: "\(project.name) Collection",
                        grantProjectId: project.id
                    )
                    AppDelegate.shared?.showManagementWindow(initialTab: .knowledge)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("New Collection", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Text("Collections every chat in this project can search.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            if knowledgeManager.collections.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "No collections yet. Create one to give this project's chats shared knowledge.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.35 : 0.5))
                )
            } else {
                VStack(spacing: 2) {
                    ForEach(knowledgeManager.collections) { collection in
                        knowledgeToggleRow(collection)
                    }
                }
            }
        }
    }

    private func knowledgeToggleRow(_ collection: KnowledgeCollection) -> some View {
        let isGranted = project.knowledgeCollectionIds.contains(collection.id)
        return Button {
            toggleCollection(collection.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isGranted ? theme.accentColor : theme.secondaryText.opacity(0.6))
                Image(systemName: "books.vertical")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 16)
                Text(verbatim: collection.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer()
                Button {
                    ManagementStateManager.shared.pendingKnowledgeDetailId = collection.id
                    AppDelegate.shared?.showManagementWindow(initialTab: .knowledge)
                } label: {
                    // A plain chevron, not the filled circle variant: the
                    // circular glyph read as a second selection control next
                    // to the leading checkmark. Tertiary gray keeps it a quiet
                    // "opens detail" affordance.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("View collection details")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isGranted ? theme.accentColor.opacity(theme.isDark ? 0.10 : 0.07) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggleCollection(_ id: UUID) {
        var updated = project
        if let index = updated.knowledgeCollectionIds.firstIndex(of: id) {
            updated.knowledgeCollectionIds.remove(at: index)
        } else {
            updated.knowledgeCollectionIds.append(id)
        }
        ProjectManager.shared.update(updated)
    }

    // MARK: - Conversations

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversations", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: onNewChat) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text("New Chat", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            if !memberSessions.isEmpty {
                SidebarSearchField(
                    text: $searchQuery,
                    placeholder: "Search conversations...",
                    isFocused: $isSearchFocused,
                    isSearching: isContentSearchInFlight,
                    showsRestingBorder: true
                )
                .padding(.vertical, 6)
                .onChange(of: searchQuery) { _, query in
                    scheduleContentSearch(query)
                }
            }

            if memberSessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22))
                        .foregroundColor(theme.secondaryText.opacity(0.5))
                    Text("No conversations yet", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else if visibleSessions.isEmpty, isContentSearchInFlight {
                // Don't claim "no matches" while the async content lookup
                // is still running.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching conversations…", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else if visibleSessions.isEmpty {
                Text("No matches found", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 2) {
                    ForEach(visibleSessions) { session in
                        ProjectConversationRow(
                            session: session,
                            onOpen: { onOpenSession(session) },
                            onRemove: {
                                ChatSessionsManager.shared.setProject(
                                    id: session.id, projectId: nil)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Rename / Delete

    private func requestRename() {
        let requestId = UUID()
        let scope = alertScope
        let sheet = ProjectNamePromptSheet(
            initialName: project.name,
            submitLabel: "Save"
        ) { name in
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            var updated = project
            updated.name = name
            ProjectManager.shared.update(updated)
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Rename Project",
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 360,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    private func requestDelete() {
        let requestId = UUID()
        let scope = alertScope
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Delete Project?",
                message: L(
                    "\"\(project.name)\" will be removed. Its conversations are kept and move out of the project."
                ),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete")) { onDelete() },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }
}

// MARK: - Conversation Row

private struct ProjectConversationRow: View {
    let session: ChatSessionData
    let onOpen: () -> Void
    /// Detach this chat from the project (the chat itself is kept).
    let onRemove: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var isHovered = false
    @State private var isRemoveHovered = false

    /// The chat's agent, surfaced on the row because a project can mix
    /// agents with different capabilities — the variance should be visible.
    private var agent: Agent? {
        guard let agentId = session.agentId else { return nil }
        return agentManager.agents.first { $0.id == agentId }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                if let agent {
                    AgentAvatarView(
                        mascotId: agent.avatar,
                        name: agent.name,
                        tint: theme.accentColor,
                        diameter: 24,
                        customImageURL: agent.customAvatarURL,
                        monogramFontSize: 10,
                        borderWidth: 0
                    )
                } else {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 24, height: 24)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: session.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if let agent {
                        Text(verbatim: agent.displayName)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(action: onRemove) {
                    Image(systemName: "folder.badge.minus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isRemoveHovered ? .red : theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .onHover { isRemoveHovered = $0 }
                .localizedHelp("Remove from Project")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.secondaryBackground.opacity(0.5) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
