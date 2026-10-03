//
//  ProjectInspectorPanel.swift
//  osaurus
//
//  The chat window's right rail while a project is on screen: the
//  project's settings (instructions, knowledge, working folder, shared
//  memory, default agent), in the same container, width and resize seam
//  as the chat inspector. "About what's on screen" is the rail's job on
//  both kinds of content; the settings of a project are that.
//

import AppKit
import SwiftUI

struct ProjectInspectorPanel: View {
    let project: Project
    /// The hosting window's active agent — the effective default when the
    /// project hasn't pinned one.
    let currentAgentId: UUID?
    /// Live width of the rail (the parent's resize handle drives it).
    var width: CGFloat = SidebarStyle.width

    @Environment(\.theme) private var theme
    @ObservedObject private var knowledgeManager = KnowledgeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    /// Draft of the instructions editor. Auto-saved (debounced) as the
    /// user types; `autoSaveTask` holds the pending write and the
    /// `justSaved` flash gives quiet confirmation.
    @State private var instructionsDraft: String = ""
    @State private var instructionsAutoSaveTask: Task<Void, Never>?
    @State private var instructionsJustSaved: Bool = false
    @State private var loadedProjectId: UUID?
    @State private var isAgentPickerPresented = false
    /// A few lines of this project's shared memory, for the at-a-glance
    /// snippet (the full view lives in Memory settings).
    @State private var memoryPreviewLines: [String] = []
    @State private var memoryItemCount: Int = 0
    /// Display path of the project's working folder, mirrored from the model
    /// so the section updates the instant the user picks or clears one.
    @State private var folderDisplayPath: String?

    var body: some View {
        SidebarContainer(attachedEdge: .trailing, topPadding: 40, width: width) {
            SidebarTitleRow("Project Settings")

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    instructionsSection
                    knowledgeSection
                    folderSection
                    memorySection
                    defaultAgentSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { syncDraft() }
        // The knowledge registry loads lazily off-main (launch-hang fix);
        // in a chat window this rail may be its first consumer, so settle
        // it here or the Knowledge section stays hidden behind an empty
        // `collections`.
        .task { await knowledgeManager.ensureLoaded() }
        // Same view instance can be repointed at another project (sidebar
        // click while the page is open) — reload the draft for the new one.
        .onChange(of: project.id) { _, _ in syncDraft() }
    }

    private func syncDraft() {
        guard loadedProjectId != project.id else { return }
        // Edits still pending for the project we are leaving land on it,
        // not on the one arriving.
        flushInstructionsSave(to: loadedProjectId)
        loadedProjectId = project.id
        instructionsDraft = project.instructions
        instructionsJustSaved = false
        folderDisplayPath = project.folderPath
        loadMemoryPreview()
    }

    // MARK: - Section chrome

    /// Section title with an optional trailing control and a one-line
    /// explainer beneath: the rail's caption scale (12pt / 11pt).
    private func sectionHeader<Trailing: View>(
        _ title: LocalizedStringKey,
        caption: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer(minLength: 8)
                trailing()
            }
            Text(caption, bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The rail's one card surface: input background with a hairline.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.inputBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.inputBorder, lineWidth: 1)
            )
    }

    /// Small accent text button used for section-level links
    /// ("New Collection", "Open in Memory", "Change").
    private func linkButton(_ title: LocalizedStringKey, icon: String? = nil, action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title, bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(theme.accentColor)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Instructions", caption: "Shared context added to every chat in this project.") {
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

            TextEditor(text: $instructionsDraft)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 180)
                .padding(6)
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
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                    }
                }
                .background(cardBackground)
                // Debounced auto-save: writes ~0.6s after the user stops
                // typing, so instructions can never be lost by navigating
                // away without hitting a Save button.
                .onChange(of: instructionsDraft) { _, _ in scheduleInstructionsAutoSave() }
        }
        .animation(theme.animationQuick(), value: instructionsJustSaved)
        // Persist immediately if the user leaves before the debounce fires.
        .onDisappear { flushInstructionsSave(to: loadedProjectId) }
    }

    private var hasEdits: Bool {
        instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Write the draft to `projectId` now (the project the draft was
    /// loaded for) if it differs from what is stored.
    private func flushInstructionsSave(to projectId: UUID?) {
        instructionsAutoSaveTask?.cancel()
        instructionsAutoSaveTask = nil
        guard let projectId, var stored = ProjectManager.shared.project(for: projectId) else { return }
        let trimmed = instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != stored.instructions.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        stored.instructions = trimmed
        ProjectManager.shared.update(stored)
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

    // MARK: - Knowledge

    /// Toggle rows granting knowledge collections to this project. Granted
    /// collections are searchable from every chat in the project (unioned
    /// with the agent's own grants at request time).
    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Knowledge", caption: "Collections every chat in this project can search.") {
                linkButton("New Collection", icon: "plus") {
                    // One-shot request consumed by KnowledgeView so the create
                    // sheet pops as soon as the tab shows, saving a click. The
                    // created collection is named after this project and
                    // granted to it automatically.
                    ManagementStateManager.shared.pendingKnowledgeCreate = .init(
                        prefillName: "\(project.name) Collection",
                        grantProjectId: project.id
                    )
                    AppDelegate.shared?.showManagementWindow(initialTab: .knowledge)
                }
            }

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
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(knowledgeManager.collections.enumerated()), id: \.element.id) { index, collection in
                        if index > 0 { Divider().opacity(0.4).padding(.leading, 34) }
                        knowledgeToggleRow(collection)
                    }
                }
                .background(cardBackground)
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
                    .frame(width: 16)
                Text(verbatim: collection.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    ManagementStateManager.shared.pendingKnowledgeDetailId = collection.id
                    AppDelegate.shared?.showManagementWindow(initialTab: .knowledge)
                } label: {
                    // A plain chevron, not the filled circle variant: the
                    // circular glyph read as a second selection control next
                    // to the leading checkmark. Tertiary gray keeps it a quiet
                    // "opens detail" affordance.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("View collection details")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
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

    // MARK: - Working Folder

    /// Picker for the folder new chats in this project open with. A default,
    /// not a lock: chats can still pick their own folder, and existing chats
    /// are untouched. Answers the "select a folder every time" gripe.
    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Spell out the sandbox side effect: a chat works in either its
            // folder or the sandbox, never both, so applying this folder
            // turns the sandbox off for the chat's agent (same as the
            // composer's folder chip).
            sectionHeader(
                "Working Folder",
                caption:
                    "New chats in this project open with this folder. Their agent's sandbox is turned off, since a chat uses either a folder or the sandbox."
            )

            if let path = folderDisplayPath, !path.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: (path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    linkButton("Change", action: chooseFolder)
                    Button(action: clearFolder) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .localizedHelp("Remove folder")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(cardBackground)
            } else {
                Button(action: chooseFolder) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 16)
                        Text("Choose Folder…", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(cardBackground)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L("Select Working Directory")
        panel.message = L("Choose a folder new chats in this project open with")
        panel.prompt = L("Select")

        let projectId = project.id
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let path = await ProjectManager.shared.setFolder(url, for: projectId) {
                    folderDisplayPath = path
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    private func clearFolder() {
        ProjectManager.shared.clearFolder(for: project.id)
        folderDisplayPath = nil
    }

    // MARK: - Shared Memory

    /// At-a-glance snippet of what the project's chats have learned, with a
    /// jump into the full view in Memory settings. Surfaces project memory
    /// on the page instead of burying it in Settings → Memory → Agents.
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "Shared Memory",
                caption: "What chats in this project have learned, shared across every agent."
            ) {
                linkButton("Open in Memory", action: openProjectMemory)
            }

            if memoryPreviewLines.isEmpty {
                Text("Chats in this project will build shared memory here.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(cardBackground)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(memoryPreviewLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(theme.accentColor.opacity(0.6))
                                .frame(width: 4, height: 4)
                                .padding(.top, 6)
                            Text(verbatim: line)
                                .font(.system(size: 11))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(cardBackground)
            }
        }
    }

    /// Load a small snippet of the project's shared memory for the rail.
    /// Prefers curated facts, then episode summaries, then raw turns, so the
    /// snippet reads as cleanly as what's available. Off-main (DB reads).
    private func loadMemoryPreview() {
        let key = MemoryNamespace.project(project.id).key
        Task.detached {
            let facts = (try? MemoryDatabase.shared.loadPinnedFacts(agentId: key, limit: 20)) ?? []
            let episodes =
                (try? MemoryDatabase.shared.loadEpisodes(agentId: key, days: 3650, limit: 20)) ?? []
            let transcripts =
                (try? MemoryDatabase.shared.loadTranscript(agentId: key, days: 3650, limit: 20)) ?? []
            let count = facts.count + episodes.count + transcripts.count

            var raw: [String] = facts.map(\.content)
            if raw.count < 3 { raw += episodes.map(\.summary) }
            if raw.count < 3 { raw += transcripts.map(\.content) }
            let lines = raw.prefix(3).map { line -> String in
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.count > 110 ? String(t.prefix(110)) + "…" : t
            }

            await MainActor.run {
                memoryItemCount = count
                memoryPreviewLines = Array(lines)
            }
        }
    }

    private func openProjectMemory() {
        ManagementStateManager.shared.pendingMemoryProjectPreview =
            MemoryNamespace.project(project.id).key
        AppDelegate.shared?.showManagementWindow(initialTab: .memory)
    }

    // MARK: - Default Agent

    /// Picker for the agent new chats in this project start with. A nudge
    /// toward one-agent projects (shared memory, consistent capabilities),
    /// never a restriction — chats from any agent can still be moved in.
    private var defaultAgentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Default Agent", caption: "New chats started from this project use this agent.")

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
                .background(cardBackground)
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
}
