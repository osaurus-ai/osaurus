//
//  WorkflowsPaneView.swift
//  osaurus
//
//  The chat inspector's Workflows lens: the workflows this chat's agent
//  can run, and the starters. Like File Changes and History it follows
//  the agent on screen. The header's + adds an installed workflow or a
//  starter to the agent; a row's menu removes it. Picking a workflow opens
//  its form in a new tab of this window, run by the same agent, so the
//  chat and sidebar stay put. In the Architect's chats the lens lists
//  every workflow on this Mac instead: picking one edits it there, and the
//  one this chat's draft edits shows selected.
//

import SwiftUI

/// What the Workflows lens lists for one agent, after the search query.
struct WorkflowListModel: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let status: String
        let needsSetup: Bool
    }

    /// The agent's workflows.
    var mine: [Row]
    /// Installed here but not the agent's: what + can add.
    var others: [Row]
    /// Built-in workflow templates not installed on this Mac.
    var starters: [Template]

    /// Past this many rows the lens offers a search field.
    static let searchThreshold = 8

    /// The workflows `agentId` can run: the Orchestrator's are those marked
    /// "Osaurus can run this for you" (what `run_workflow` resolves); a
    /// custom agent's are the ones turned on in its Abilities, in its order.
    @MainActor
    static func workflows(for agentId: UUID, installed: InstalledWorkflowStore = .shared) -> [InstalledWorkflow] {
        if agentId == Agent.defaultId { return installed.orchestratorVisible }
        guard let agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn else { return [] }
        return agent.settings.enabledWorkflowIDs.compactMap { installed.workflow(id: $0) }
    }

    /// Make `workflowID` one of `agentId`'s: for the Orchestrator that is
    /// "Osaurus can run this for you"; a custom agent turns it on.
    @MainActor
    static func add(_ workflowID: UUID, for agentId: UUID) {
        set(workflowID, available: true, for: agentId)
    }

    @MainActor
    static func remove(_ workflowID: UUID, for agentId: UUID) {
        set(workflowID, available: false, for: agentId)
    }

    @MainActor
    private static func set(_ workflowID: UUID, available: Bool, for agentId: UUID) {
        if agentId == Agent.defaultId {
            try? InstalledWorkflowStore.shared.setOrchestratorVisible(available, id: workflowID)
            return
        }
        guard let agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn else { return }
        let current = agent.settings.enabledWorkflowIDs.filter { $0 != workflowID }
        AgentManager.shared.updateEnabledWorkflowIDs(available ? current + [workflowID] : current, for: agentId)
    }

    @MainActor
    static func make(
        agentWorkflows: [InstalledWorkflow], installed: [InstalledWorkflow], builtIn: [Template], query: String,
        needsSetup: (InstalledWorkflow) -> Bool, isRunning: (UUID) -> Bool
    ) -> WorkflowListModel {
        let installedTemplates = Set(installed.map(\.templateID))
        func row(_ workflow: InstalledWorkflow) -> Row {
            let blocked = needsSetup(workflow)
            let status =
                isRunning(workflow.id) ? L("Running…") : blocked ? L("Needs setup") : (workflow.summary ?? L("Ready"))
            return Row(id: workflow.id, name: workflow.name, status: status, needsSetup: blocked)
        }
        let mineIDs = Set(agentWorkflows.map(\.id))
        let others = installed.filter { !mineIDs.contains($0.id) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let starters = builtIn.filter { $0.kind == .workflow && !installedTemplates.contains($0.id) }
        return WorkflowListModel(
            mine: ChatSessionSidebar.filterByName(agentWorkflows, query: query, name: \.searchText).map(row),
            others: others.map(row),
            starters: ChatSessionSidebar.filterByName(starters, query: query, name: \.name))
    }
}

struct WorkflowsPaneView: View {
    @ObservedObject var windowState: ChatWindowState

    @Environment(\.theme) private var theme
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var runs = WorkflowRunStore.shared
    @ObservedObject private var agents = AgentManager.shared
    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @State private var preview: Template?
    @State private var query = ""

    private var agentId: UUID { windowState.agentId }
    private var agent: Agent? { agents.agent(for: agentId) }
    private var agentName: String { agent?.displayName ?? windowState.cachedAgentDisplayName }

    private var model: WorkflowListModel {
        WorkflowListModel.make(
            agentWorkflows: WorkflowListModel.workflows(for: agentId, installed: installed),
            installed: installed.workflows, builtIn: TemplateStore.shared.builtIn,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            needsSetup: { $0.needsSetup || SetupChecker.check($0, secrets: .install, attended: true).hasBlockers },
            isRunning: { id in runs.live.values.contains { $0.workflowID == id && !$0.status.isTerminal } })
    }

    var body: some View {
        if agentId == Agent.architectId {
            architectBody
        } else {
            agentBody
        }
    }

    private var agentBody: some View {
        let model = model
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            HStack(spacing: theme.space.s4) {
                scopeLabel(count: model.mine.count)
                Spacer(minLength: 8)
                addMenu(model)
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.top, theme.space.s2)
            .padding(.bottom, theme.space.s8)
            .frame(minHeight: 32)

            if model.mine.isEmpty, model.starters.isEmpty, query.isEmpty {
                SidebarEmptyState(
                    icon: "flowchart", title: "No workflows yet",
                    hint: "Use + to add a workflow \(agentName) can run.")
            } else {
                list(model)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $preview) { template in
            WorkflowStarterPreviewSheet(
                template: template, onClose: { preview = nil },
                onAdded: { workflow in
                    preview = nil
                    WorkflowListModel.add(workflow.id, for: agentId)
                    if let example = template.workflow?.examples.first?.input.objectValue {
                        WorkflowRunLauncher.stagePrefill(example, for: workflow.id)
                    }
                    open(workflow.id)
                })
            .environment(\.theme, theme)
        }
    }

    // MARK: - Architect

    /// The workflow this chat's draft edits, once it has been saved.
    private var editingTemplateID: UUID? {
        guard windowState.activeTab?.workflowID == nil else { return nil }
        return drafts.draft(forSession: windowState.session.sessionId?.uuidString)?.templateID
    }

    private var architectBody: some View {
        let all = installed.workflows.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let shown = ChatSessionSidebar.filterByName(
            all, query: query.trimmingCharacters(in: .whitespacesAndNewlines), name: \.searchText)
        let editing = editingTemplateID
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            HStack(spacing: theme.space.s4) {
                Text(verbatim: L("On This Mac"))
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: "· " + (all.count == 1 ? L("1 workflow") : L("\(all.count) workflows")))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                Spacer(minLength: 8)
                SidebarHeaderIconButton(icon: "plus", help: "New Workflow") {
                    ArchitectLauncher.newWorkflow(in: windowState)
                }
            }
            .padding(.leading, theme.space.s16)
            .padding(.trailing, theme.space.s12)
            .padding(.top, theme.space.s2)
            .padding(.bottom, theme.space.s8)
            .frame(minHeight: 32)

            if all.isEmpty {
                SidebarEmptyState(
                    icon: "flowchart", title: "No workflows yet",
                    hint: "Describe one in the chat and the Architect builds it. Saved workflows show up here to edit.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        if all.count > WorkflowListModel.searchThreshold || !query.isEmpty {
                            SearchField(text: $query, placeholder: "Search workflows…", fillsAvailableWidth: true)
                                .padding(.horizontal, theme.space.s4)
                                .padding(.bottom, theme.space.s4)
                        }
                        ForEach(shown) { workflow in
                            WorkflowPaneRow(
                                icon: "flowchart", title: workflow.name,
                                subtitle: workflow.summary ?? L("Version \(workflow.templateVersion)"),
                                isSelected: workflow.templateID == editing,
                                action: { ArchitectLauncher.edit(workflow, in: windowState) },
                                menu: {
                                    Button {
                                        ArchitectLauncher.edit(workflow, in: windowState)
                                    } label: {
                                        Text("Edit with the Architect", bundle: .module)
                                    }
                                    Button {
                                        AppDelegate.shared?.showManagementWindow(initialTab: .workflows)
                                    } label: {
                                        Text("Manage Workflows…", bundle: .module)
                                    }
                                })
                        }
                        if !query.isEmpty, shown.isEmpty {
                            SidebarEmptyState(icon: "magnifyingglass", title: "No workflows match")
                                .padding(.top, theme.space.s24)
                        }
                    }
                    .padding(.bottom, theme.space.s8)
                    .padding(.horizontal, theme.space.s8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    /// Avatar + agent name + "· N workflows": whose workflows these are.
    private func scopeLabel(count: Int) -> some View {
        HStack(spacing: theme.space.s6) {
            AgentAvatarView(
                mascotId: agent?.avatar,
                name: agent?.displayName ?? "",
                tint: theme.dataInk(seed: agent?.name ?? ""),
                diameter: 16,
                customImageURL: agent?.customAvatarURL,
                monogramFontSize: 7,
                borderWidth: 0
            )
            Text(verbatim: agentName)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: "· " + (count == 1 ? L("1 workflow") : L("\(count) workflows")))
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
        }
        .padding(.leading, theme.space.s4)
        .accessibilityElement(children: .combine)
    }

    /// Adds a workflow already on this Mac to the agent, or previews a
    /// starter to add.
    private func addMenu(_ model: WorkflowListModel) -> some View {
        SettingsActionMenu(accessibilityLabel: L("Add workflow")) {
            if !model.others.isEmpty {
                Section {
                    ForEach(model.others) { row in
                        Button { WorkflowListModel.add(row.id, for: agentId) } label: { Text(verbatim: row.name) }
                    }
                } header: {
                    Text("On This Mac", bundle: .module)
                }
            }
            if !model.starters.isEmpty {
                Section {
                    ForEach(model.starters) { template in
                        Button { preview = template } label: { Text(verbatim: template.name) }
                    }
                } header: {
                    Text("Starters", bundle: .module)
                }
            }
            if model.others.isEmpty, model.starters.isEmpty {
                Text("Every workflow on this Mac is already here", bundle: .module)
            }
            Divider()
            Button {
                AppDelegate.shared?.showManagementWindow(initialTab: .workflows)
            } label: {
                Text("Manage Workflows…", bundle: .module)
            }
        } label: {
            Image(systemName: "plus")
                .glyphSize(.label, weight: .medium)
                .foregroundColor(theme.text.secondary)
                .padding(theme.space.s4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .localizedHelp("Add Workflow")
        .accessibilityLabel(Text("Add Workflow", bundle: .module))
    }

    // MARK: - List

    private func list(_ model: WorkflowListModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                if model.mine.count + model.starters.count > WorkflowListModel.searchThreshold || !query.isEmpty {
                    SearchField(text: $query, placeholder: "Search workflows…", fillsAvailableWidth: true)
                        .padding(.horizontal, theme.space.s4)
                        .padding(.bottom, theme.space.s4)
                }
                if model.mine.isEmpty, query.isEmpty {
                    Text("No workflows yet. Use + to add one \(agentName) can run, or try a starter.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, theme.space.s8)
                        .padding(.vertical, theme.space.s6)
                }
                ForEach(model.mine) { row in
                    WorkflowPaneRow(
                        icon: row.needsSetup ? "exclamationmark.triangle" : "flowchart",
                        title: row.name, subtitle: row.status, isWarning: row.needsSetup,
                        action: { open(row.id) },
                        menu: { rowMenu(row) })
                }
                if !model.starters.isEmpty {
                    sectionHeader(L("Starters"))
                    ForEach(model.starters) { template in
                        WorkflowPaneRow(
                            icon: "sparkles", title: template.name, subtitle: template.summary ?? "",
                            action: { preview = template },
                            menu: { EmptyView() })
                    }
                }
                if !query.isEmpty, model.mine.isEmpty, model.starters.isEmpty {
                    SidebarEmptyState(icon: "magnifyingglass", title: "No workflows match")
                        .padding(.top, theme.space.s24)
                }
            }
            .padding(.bottom, theme.space.s8)
            .padding(.horizontal, theme.space.s8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func rowMenu(_ row: WorkflowListModel.Row) -> some View {
        Button { open(row.id) } label: { Text("Open", bundle: .module) }
        Divider()
        Button { WorkflowListModel.remove(row.id, for: agentId) } label: {
            Text("Remove from \(agentName)", bundle: .module)
        }
    }

    /// A new tab with the workflow's form, run by this chat's agent.
    private func open(_ workflowID: UUID) {
        windowState.openWorkflowTab(workflowID: workflowID, agentId: agentId)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(SettingsFont.compactLabel)
            .foregroundColor(theme.text.secondary)
            .lineLimit(1)
            .padding(.horizontal, theme.space.s8)
            .padding(.top, theme.space.s12)
            .padding(.bottom, theme.space.s4)
    }
}

private struct WorkflowPaneRow<RowMenu: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var isWarning = false
    var isSelected = false
    let action: () -> Void
    @ViewBuilder let menu: () -> RowMenu

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var hasMenu: Bool { RowMenu.self != EmptyView.self }

    var body: some View {
        HStack(spacing: theme.space.s6) {
            Button(action: action) {
                HStack(spacing: theme.space.s10) {
                    ZStack {
                        Circle()
                            .fill(
                                isWarning ? theme.status.warning.background : theme.status.info.background
                            )
                            .frame(width: 26, height: 26)
                        Image(systemName: icon)
                            .glyphSize(.footnote, weight: .medium)
                            .foregroundColor(isWarning ? theme.status.warning.foreground : theme.text.link)
                    }
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        Text(verbatim: title)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(verbatim: subtitle)
                                .font(SettingsFont.footnote)
                                .foregroundColor(theme.text.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hasMenu {
                SettingsActionMenu(accessibilityLabel: L("More"), content: menu) {
                    Image(systemName: "ellipsis")
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isHovered ? 1 : 0)
                .localizedHelp("More")
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered)
        .assignedContextMenu(menuItems: menu)
        .onHover { hovering in
            withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) { isHovered = hovering }
        }
    }
}
