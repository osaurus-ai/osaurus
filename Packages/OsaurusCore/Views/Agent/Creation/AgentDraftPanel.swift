//
//  AgentDraftPanel.swift
//  osaurus
//
//  The agent half of a New Agent chat: a card that fills in as the
//  Configurator drafts. It starts with just a name and look, and each part
//  (instructions, tools, model) joins it once it is drafted or the person
//  adds it. Every part edits in place; an edit wins over the Configurator,
//  which hears about it on its next turn. Create saves the agent; nothing
//  else does.
//

import SwiftUI

struct AgentDraftPanel: View {
    let sessionId: UUID?
    var isGenerating = false
    /// Messages the person has sent this chat, for telemetry.
    var userMessageCount = 0
    /// Opens a chat with the created agent.
    var onStartChat: (UUID) -> Void = { _ in }
    /// When set, Create hands the new agent here instead of showing the
    /// done state (Settings opens the agent's page).
    var onCreated: ((UUID) -> Void)?
    /// Opened to fill in by hand: starts on the name.
    var startsEditing = false

    /// The card's parts, in the order they join it.
    enum Section: String, CaseIterable, Identifiable {
        case identity, instructions, tools, model

        var id: String { rawValue }

        var title: String {
            switch self {
            case .identity: return L("Name and look")
            case .instructions: return L("Instructions")
            case .tools: return L("Tools")
            case .model: return L("Model")
            }
        }

        var icon: String {
            switch self {
            case .identity: return "person.text.rectangle"
            case .instructions: return "text.alignleft"
            case .tools: return "wrench.and.screwdriver"
            case .model: return "cube"
            }
        }

        var fields: [AgentDraft.Field] {
            switch self {
            case .identity: return [.name, .description, .avatar]
            case .instructions: return [.instructions]
            case .tools: return [.tools]
            case .model: return [.model]
            }
        }
    }

    static let avatarSize: CGFloat = 48
    static let toolsSheetHeight: CGFloat = 560

    @ObservedObject private var store = AgentDraftStore.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var pickerItems: [ModelPickerItem] = []
    @State private var editing: Section?
    /// Parts the person added before the Configurator drafted them.
    @State private var added: Set<Section> = []
    /// The part the Configurator just changed, briefly marked.
    @State private var highlighted: Section?
    @State private var signatures: [Section: Int] = [:]
    @State private var customizingTools = false
    /// Create is installing queued imports.
    @State private var creating = false
    @State private var createError: String?
    @Environment(\.theme) private var theme

    private var draft: AgentDraft? { store.draft(forSession: sessionId?.uuidString) }

    var body: some View {
        Group {
            if let draft {
                if let agentId = draft.createdAgentId {
                    doneState(draft, agentId: agentId)
                } else {
                    builder(draft)
                }
            } else {
                Text("This draft is no longer available. Start a new agent from Agents.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { pickerItems = $0 }
        .onAppear {
            if let agent = draft?.agent { signatures = Self.signatures(agent) }
            if startsEditing, draft?.isEmpty == true { editing = .identity }
        }
        .onChange(of: draft?.agent.name) { _, name in
            guard draft?.isCreated == false else { return }
            AgentCreatorLauncher.retitle(sessionId: sessionId, name: name ?? "")
        }
        .onChange(of: draft?.agent) { _, agent in
            if let agent { noteChanges(agent) }
        }
        .sheet(isPresented: $customizingTools) {
            if let draft { toolsSheet(draft) }
        }
    }

    // MARK: - Builder

    private func builder(_ draft: AgentDraft) -> some View {
        let shown = shownSections(draft)
        let upcoming = Section.allCases.filter { !shown.contains($0) }
        return VStack(spacing: theme.space.s0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space.s16) {
                        AgentCreationStepper(stage: stage(draft))
                        card(draft, shown: shown)
                        if !draft.queuedImports.isEmpty { importsSection(draft) }
                        if !upcoming.isEmpty { upNext(upcoming) }
                    }
                    .padding(.vertical, theme.space.s4)
                    .animation(theme.motion.springAnimation, value: shown)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: highlighted) { _, section in
                    guard let section else { return }
                    withAnimation(theme.motion.standard) { proxy.scrollTo(section, anchor: .center) }
                }
            }
            footer(draft)
                .padding(.top, theme.space.s12)
        }
    }

    private func shownSections(_ draft: AgentDraft) -> [Section] {
        let named = !draft.agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Section.allCases.filter { section in
            if section == .identity || added.contains(section) || editing == section { return true }
            if section.fields.contains(where: draft.touched.contains) { return true }
            switch section {
            case .instructions:
                return !draft.agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .model:
                // Has a working default, so it joins once the rest is under way.
                return named && (draft.touched.contains(.instructions) || draft.touched.contains(.tools))
            default:
                return false
            }
        }
    }

    private func stage(_ draft: AgentDraft) -> AgentCreationStage {
        if draft.isEmpty, editing == nil { return .describe }
        return blocker(draft) == nil ? .create : .shape
    }

    private func card(_ draft: AgentDraft, shown: [Section]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            identity(draft)
                .id(Section.identity)
            ForEach(shown.filter { $0 != .identity }) { section in
                ThemeHairlineDivider(color: theme.border.subtle)
                sectionView(section, draft)
                    .id(section)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card)
    }

    private func upNext(_ sections: [Section]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            WorkflowSectionHeader(title: L("Still to come"))
            Text("The Configurator adds these as you talk, or add them yourself.", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: theme.space.s6) {
                ForEach(sections) { section in
                    SettingsButton(.secondary, section.title, icon: "plus", size: .small, verbatim: true) {
                        withAnimation(theme.motion.springAnimation) {
                            added.insert(section)
                            if section == .tools { customizingTools = true } else { editing = section }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, theme.space.s4)
    }

    // MARK: - Imports

    private func importsSection(_ draft: AgentDraft) -> some View {
        let items = draft.queuedImports.filter { $0.kind != .manualStep }
        let steps = draft.queuedImports.filter { $0.kind == .manualStep }
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            WorkflowSectionHeader(title: L("Installs When You Create"))
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { ThemeHairlineDivider(color: theme.border.subtle) }
                        importRow(item, draft: draft)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.card)
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Do these yourself. Osaurus doesn't run them.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                    ForEach(steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                            Image(systemName: "hand.point.right")
                                .glyphSize(.micro, weight: .medium)
                                .foregroundStyle(theme.text.tertiary)
                                .accessibilityHidden(true)
                            Text(verbatim: step.name)
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: theme.space.s4)
                            removeImportButton(step, draft: draft)
                        }
                    }
                }
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.status(.info))
            }
        }
    }

    private func importRow(_ item: ChatImportItem, draft: AgentDraft) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: Self.importIcon(item.kind))
                    .glyphSize(.footnote, weight: .medium)
                    .foregroundStyle(theme.text.tertiary)
                    .accessibilityHidden(true)
                Text(verbatim: item.name)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                StatusChip(Self.importKindLabel(item.kind), tone: .neutral)
                if item.state == .updateAvailable { StatusChip(L("Update"), tone: .accent) }
                if item.state == .nameClash { StatusChip(L("Name in use, keeps both"), tone: .neutral) }
                Spacer(minLength: theme.space.s8)
                removeImportButton(item, draft: draft)
            }
            Text(verbatim: L("From \(Self.host(item.origin))"))
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
            ForEach(item.risks + item.warnings, id: \.self) { line in
                Text(verbatim: line)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.needsSetup.isEmpty {
                Text(verbatim: L("Needs setup after: \(item.needsSetup.joined(separator: ", "))"))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space.s12)
    }

    private func removeImportButton(_ item: ChatImportItem, draft: AgentDraft) -> some View {
        SettingsButton(.tertiary, L("Remove"), size: .extraSmall, verbatim: true) {
            withAnimation(theme.motion.quick) { store.removePendingImport(draft.id, itemId: item.id) }
        }
        .disabled(creating)
        .accessibilityLabel(Text(verbatim: L("Remove \(item.name)")))
    }

    static func importIcon(_ kind: ChatImportItemKind) -> String {
        switch kind {
        case .skill: return "book.closed"
        case .agent: return "person.crop.circle"
        case .mcpServer: return "server.rack"
        case .command: return "slash.circle"
        case .plugin: return "puzzlepiece.extension"
        case .manualStep: return "hand.point.right"
        }
    }

    static func importKindLabel(_ kind: ChatImportItemKind) -> String {
        switch kind {
        case .skill: return L("Skill for this agent")
        case .agent: return L("Separate agent")
        case .mcpServer: return L("MCP server")
        case .command: return L("Command")
        case .plugin: return L("Plugin")
        case .manualStep: return L("Manual step")
        }
    }

    static func host(_ origin: String) -> String {
        URL(string: origin)?.host ?? origin
    }

    // MARK: - Identity

    private func identity(_ draft: AgentDraft) -> some View {
        let agent = draft.agent
        let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = agent.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack(alignment: .top, spacing: theme.space.s12) {
                avatar(agent, name: name)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: name.isEmpty ? (isGenerating ? L("Naming…") : L("Unnamed agent")) : name)
                        .font(SettingsFont.cardTitle)
                        .foregroundColor(name.isEmpty ? theme.text.tertiary : theme.text.primary)
                        .lineLimit(1)
                    Text(verbatim: description.isEmpty ? L("What it does shows here.") : description)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(description.isEmpty ? theme.text.tertiary : theme.text.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                editButton(.identity)
            }
            if editing != .identity, nameTaken(name) {
                nameTakenNote
                    .transition(.opacity)
            }
            if editing == .identity {
                identityEditor(draft)
                    .transition(.opacity)
            }
        }
        .padding(theme.space.s16)
        .background(highlighted == .identity ? theme.surface.selected : Color.clear)
        .overlay(Rectangle().strokeBorder(highlighted == .identity ? theme.selectionBorder : .clear, lineWidth: theme.selectionStroke).allowsHitTesting(false))
    }

    @ViewBuilder
    private func avatar(_ agent: Agent, name: String) -> some View {
        if name.isEmpty, agent.avatar == nil {
            Circle()
                .strokeBorder(theme.border.default, style: StrokeStyle(lineWidth: theme.stroke.default, dash: [3, 3]))
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .overlay {
                    Image(systemName: "sparkles")
                        .glyphSize(.medium, weight: .medium)
                        .foregroundStyle(theme.text.tertiary)
                }
                .accessibilityHidden(true)
        } else {
            AgentAvatarView(mascotId: agent.avatar, name: name, tint: theme.dataInk(seed: name), diameter: Self.avatarSize)
                .animation(theme.motion.springAnimation, value: agent.avatar)
        }
    }

    private var nameTakenNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
            Image(systemName: "exclamationmark.circle.fill")
                .glyphSize(.footnote, weight: .semibold)
                .accessibilityHidden(true)
            Text("Another agent already has this name.", bundle: .module)
                .font(SettingsFont.rowDescription)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(theme.status.error.foreground)
    }

    private func identityEditor(_ draft: AgentDraft) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                fieldHeader(L("Name"), field: .name, draft: draft)
                SettingsTextField(
                    placeholder: L("e.g., Research Assistant"), text: text(draft, .name, \.name), icon: "textformat",
                    isInvalid: nameTaken(draft.agent.name))
                if nameTaken(draft.agent.name) {
                    nameTakenNote
                }
            }
            VStack(alignment: .leading, spacing: theme.space.s6) {
                fieldHeader(L("Description"), field: .description, draft: draft)
                SettingsTextField(
                    placeholder: L("What it does, in one sentence"), text: text(draft, .description, \.description),
                    axis: .vertical, lineLimit: 3)
            }
            VStack(alignment: .leading, spacing: theme.space.s6) {
                fieldHeader(L("Avatar"), field: .avatar, draft: draft)
                FlowLayout(spacing: theme.space.s8) {
                    avatarChip(nil, draft: draft)
                    ForEach(AgentMascot.allCases) { mascot in
                        avatarChip(mascot.id, draft: draft)
                    }
                }
                reason(AgentDraft.Field.avatar.rawValue, in: draft)
            }
        }
    }

    private func avatarChip(_ mascotId: String?, draft: AgentDraft) -> some View {
        let isSelected = draft.agent.avatar == mascotId
        return Button {
            store.applyUserEdit(draft.id, .avatar) { $0.avatar = mascotId }
        } label: {
            AgentAvatarView(
                mascotId: mascotId, name: draft.agent.name, tint: theme.dataInk(seed: draft.agent.name), diameter: 28,
                monogramFontSize: 12, borderWidth: theme.stroke.default)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? theme.action.primary.default.background : Color.clear,
                            lineWidth: theme.stroke.focus
                        )
                        .padding(-theme.space.s2)
                )
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: mascotId ?? L("Initial")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Sections

    private func sectionView(_ section: Section, _ draft: AgentDraft) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: section.icon)
                    .glyphSize(.footnote, weight: .medium)
                    .foregroundStyle(theme.text.tertiary)
                    .accessibilityHidden(true)
                Text(verbatim: section.title)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                    .accessibilityAddTraits(.isHeader)
                if section.fields.contains(where: draft.userEdited.contains) {
                    StatusChip(L("Edited by you"), tone: .neutral)
                }
                Spacer(minLength: theme.space.s8)
                editButton(section)
            }
            if editing == section {
                sectionEditor(section, draft)
                    .transition(.opacity)
            } else {
                sectionSummary(section, draft)
            }
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted == section ? theme.surface.selected : Color.clear)
        .overlay(Rectangle().strokeBorder(highlighted == section ? theme.selectionBorder : .clear, lineWidth: theme.selectionStroke).allowsHitTesting(false))
    }

    private func editButton(_ section: Section) -> some View {
        let isEditing = editing == section
        let title = isEditing ? L("Done") : (section == .tools ? L("Customize") : L("Edit"))
        return SettingsButton(.tertiary, title, size: .extraSmall, verbatim: true) {
            withAnimation(theme.motion.springAnimation) {
                if section == .tools {
                    customizingTools = true
                } else {
                    editing = isEditing ? nil : section
                }
            }
        }
        .accessibilityLabel(Text(verbatim: "\(title) \(section.title)"))
    }

    @ViewBuilder
    private func sectionSummary(_ section: Section, _ draft: AgentDraft) -> some View {
        let agent = draft.agent
        switch section {
        case .identity:
            EmptyView()
        case .instructions:
            let prompt = agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(verbatim: prompt.isEmpty ? (isGenerating ? L("Being written…") : L("How the agent should work.")) : prompt)
                .font(SettingsFont.rowDescription)
                .foregroundColor(prompt.isEmpty ? theme.text.tertiary : theme.text.secondary)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tools:
            toolsSummary(draft)
        case .model:
            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text(verbatim: agent.defaultModel.map(Self.shortModelName) ?? L("Default (from global settings)"))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                reason(AgentDraft.Field.model.rawValue, in: draft)
            }
        }
    }

    @ViewBuilder
    private func sectionEditor(_ section: Section, _ draft: AgentDraft) -> some View {
        switch section {
        case .identity, .tools:
            EmptyView()
        case .instructions:
            SettingsTextEditor(
                text: text(draft, .instructions, \.systemPrompt),
                placeholder: L("How the agent should work…"), minHeight: 140, maxHeight: 280)
        case .model:
            VStack(alignment: .leading, spacing: theme.space.s6) {
                ModelSearchablePicker(
                    items: pickerItems,
                    selection: Binding(
                        get: { store.draft(id: draft.id)?.agent.defaultModel },
                        set: { value in store.applyUserEdit(draft.id, .model) { $0.defaultModel = value } }
                    ),
                    noneTitle: L("Default (from global settings)"),
                    actions: [
                        .init(id: "add-model", title: L("Add Model"), icon: "plus") {
                            AppDelegate.shared?.showManagementWindow(initialTab: .models)
                        }
                    ]
                )
                reason(AgentDraft.Field.model.rawValue, in: draft)
            }
        }
    }

    private func toolsSummary(_ draft: AgentDraft) -> some View {
        let agent = draft.agent
        let isAuto = (agent.toolSelectionMode ?? .auto) == .auto
        let count = agent.manualToolNames?.count ?? 0
        let abilities = AgentDraftTool.enabledCapabilities(agent)
        let explained = abilities.filter { draft.reasons[$0] != nil }
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(
                isAuto
                    ? L("Picks from \(count) installed tools as it needs them.")
                    : L("Uses the \(count) tools picked for it.")
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            if !abilities.isEmpty {
                FlowLayout(spacing: theme.space.s6) {
                    ForEach(abilities, id: \.self) { key in
                        StatusChip(Self.capabilityLabel(key), tone: .accent, help: draft.reasons[key])
                    }
                }
            }
            ForEach(explained, id: \.self) { key in
                (Text(Self.capabilityLabel(key) + ": ").foregroundColor(theme.text.secondary)
                    + Text(draft.reasons[key] ?? "").foregroundColor(theme.text.tertiary))
                    .font(SettingsFont.rowDescription)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Fields

    private func fieldHeader(_ title: String, field: AgentDraft.Field, draft: AgentDraft) -> some View {
        HStack(spacing: theme.space.s6) {
            SettingsFieldLabel(verbatim: title)
            if draft.userEdited.contains(field) {
                StatusChip(L("Edited by you"), tone: .neutral)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func reason(_ key: String, in draft: AgentDraft) -> some View {
        if let why = draft.reasons[key] {
            Text(why)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(_ draft: AgentDraft, _ field: AgentDraft.Field, _ keyPath: WritableKeyPath<Agent, String>)
        -> Binding<String>
    {
        Binding(
            get: { store.draft(id: draft.id)?.agent[keyPath: keyPath] ?? "" },
            set: { value in store.applyUserEdit(draft.id, field) { $0[keyPath: keyPath] = value } }
        )
    }

    // MARK: - Tools sheet

    private func toolsSheet(_ draft: AgentDraft) -> some View {
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(icon: Section.tools.icon, title: "Tools", onClose: { customizingTools = false })
            AgentCapabilityManagerView(
                draftMode: Binding(
                    get: { store.draft(id: draft.id)?.agent.toolSelectionMode ?? .auto },
                    set: { mode in store.applyUserEdit(draft.id, .tools) { $0.toolSelectionMode = mode } }
                ),
                draftTools: Binding(
                    get: { Set(store.draft(id: draft.id)?.agent.manualToolNames ?? []) },
                    set: { names in store.applyUserEdit(draft.id, .tools) { $0.manualToolNames = names.sorted() } }
                ),
                draftAppleApps: Binding(
                    get: { store.draft(id: draft.id)?.agent.settings.enabledAppleApps ?? [] },
                    set: { apps in store.applyUserEdit(draft.id, .tools) { $0.settings.enabledAppleApps = apps } }
                ),
                onDismiss: nil
            )
            SettingsSheetFooter(primary: .init(label: "Done") { customizingTools = false })
        }
        .frame(width: SettingsSheetWidth.wide, height: Self.toolsSheetHeight)
        .settingsSheetSurface()
        .environment(\.theme, ThemeManager.shared.currentTheme)
    }

    // MARK: - Changes

    /// Marks the part the Configurator just changed, so the eye follows it.
    private func noteChanges(_ agent: Agent) {
        let next = Self.signatures(agent)
        let changed = Section.allCases.last { section in
            guard let before = signatures[section], before != next[section] else { return false }
            return section != editing && !(section == .tools && customizingTools)
        }
        signatures = next
        guard let changed else { return }
        withAnimation(theme.motion.quick) { highlighted = changed }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard highlighted == changed else { return }
            withAnimation(theme.motion.standard) { highlighted = nil }
        }
    }

    private static func signatures(_ agent: Agent) -> [Section: Int] {
        var result: [Section: Int] = [:]
        for section in Section.allCases {
            var hasher = Hasher()
            switch section {
            case .identity:
                hasher.combine(agent.name)
                hasher.combine(agent.description)
                hasher.combine(agent.avatar)
            case .instructions:
                hasher.combine(agent.systemPrompt)
            case .tools:
                hasher.combine(agent.toolSelectionMode?.rawValue)
                hasher.combine(agent.manualToolNames)
                hasher.combine(AgentDraftTool.enabledCapabilities(agent))
            case .model:
                hasher.combine(agent.defaultModel)
            }
            result[section] = hasher.finalize()
        }
        return result
    }

    // MARK: - Create

    private func nameTaken(_ name: String) -> Bool {
        agentManager.isCustomAgentNameTaken(name)
    }

    private func blocker(_ draft: AgentDraft) -> String? {
        let name = draft.agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return L("Give it a name to create it.") }
        if nameTaken(name) { return L("Pick a name no other agent uses.") }
        if isGenerating { return L("Wait for the Configurator to finish.") }
        if creating { return L("Installing what it needs…") }
        return nil
    }

    private func footer(_ draft: AgentDraft) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            if let createError {
                Text(verbatim: createError)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footerBar(draft)
        }
    }

    private func footerBar(_ draft: AgentDraft) -> some View {
        let blocker = blocker(draft)
        // Something only the person (or the Configurator) can fix, as
        // opposed to waiting for a reply or an install.
        let needsFix = nameTaken(draft.agent.name)
        let ink: Color = blocker == nil ? theme.text.secondary : needsFix ? theme.status.error.foreground : theme.text.tertiary
        return HStack(spacing: theme.space.s12) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                Image(systemName: blocker == nil ? "checkmark.circle.fill" : needsFix ? "exclamationmark.circle.fill" : "info.circle")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundStyle(blocker == nil ? theme.statusInk(.success) : ink)
                    .accessibilityHidden(true)
                Text(verbatim: blocker ?? L("Ready. Keep refining, or create it now."))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: theme.space.s8)
            SettingsButton(.primary, L("Create Agent"), icon: "checkmark", verbatim: true) { create(draft) }
                .disabled(blocker != nil)
        }
        .animation(theme.motion.quick, value: blocker)
    }

    private static func prepared(_ draft: AgentDraft) -> Agent {
        var agent = draft.agent
        agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.description = AgentDescriptionPolicy.normalized(agent.description)
        agent.systemPrompt = agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.updatedAt = Date()
        return agent
    }

    private func create(_ draft: AgentDraft) {
        guard blocker(draft) == nil, !creating else { return }
        let pending = draft.queuedImports.filter { $0.kind != .manualStep }
        guard !pending.isEmpty else {
            let agent = Self.prepared(draft)
            agentManager.add(agent)
            finishCreate(draft, agent: agent)
            return
        }
        creating = true
        createError = nil
        Task { @MainActor in
            defer { creating = false }
            let choices = Dictionary(
                uniqueKeysWithValues: pending.map {
                    ($0.id, ChatImportItemChoice(included: true, kind: $0.kind, clash: $0.clashChoice))
                })
            let outcome = await ChatImportApplier.apply(
                items: pending, choices: choices,
                context: ChatImportApplier.Context(caller: OsaurusConfigTool.historyCaller(template: nil)))
            guard outcome.succeeded else {
                createError =
                    L("Nothing was created. ")
                    + ChatImportSummary.text(results: outcome.results.filter { $0.status != .rolledBack })
                return
            }
            var agent = Self.prepared(draft)
            let skills = pending.filter { $0.kind == .skill }.compactMap { outcome.finalNames[$0.id] }
            if let names = agent.skillNames, !skills.isEmpty { agent.skillNames = names + skills }
            agentManager.add(agent)
            let servers = pending.filter { $0.kind == .mcpServer }.compactMap { outcome.finalNames[$0.id] }
            if !servers.isEmpty {
                _ = await ChatImportConnectionTest.run(serverNames: servers, agentId: agent.id)
                if agent.toolSelectionMode == .manual {
                    let groups = ToolRegistry.shared.portableToolGroups()
                    let tools = servers.flatMap { groups[.mcpServer($0)] ?? [] }
                    var names = agent.manualToolNames ?? []
                    names += tools.filter { !names.contains($0) }
                    agent.manualToolNames = names
                    agentManager.update(agent)
                }
            }
            store.clearPendingImports(draft.id)
            finishCreate(draft, agent: agentManager.agent(for: agent.id) ?? agent)
        }
    }

    private func finishCreate(_ draft: AgentDraft, agent: Agent) {
        store.markCreated(draft.id, agentId: agent.id)
        AgentCreatorLauncher.noteCreated(agent, sessionId: sessionId)
        FeatureTelemetry.agentCreationFinished(
            userMessages: userMessageCount, editedFields: draft.userEdited.count,
            neededSetup: SetupChecker.check(agent).hasBlockers)
        onCreated?(agent.id)
    }

    // MARK: - Done

    private func doneState(_ draft: AgentDraft, agentId: UUID) -> some View {
        let agent = agentManager.agent(for: agentId) ?? draft.agent
        let setup = SetupChecker.check(agent)
        return ScrollView {
            VStack(spacing: theme.space.s16) {
                AgentAvatarView(mascotId: agent.avatar, name: agent.name, tint: theme.dataInk(seed: agent.name), diameter: 64)
                VStack(spacing: theme.space.s4) {
                    Text("\(agent.name) is ready", bundle: .module)
                        .font(SettingsFont.cardTitle)
                        .foregroundColor(theme.text.primary)
                        .multilineTextAlignment(.center)
                    Text("Change anything later in its settings.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .multilineTextAlignment(.center)
                }
                if setup.hasBlockers {
                    VStack(alignment: .leading, spacing: theme.space.s8) {
                        ForEach(setup.blocking) { item in
                            Text(item.detail)
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SettingsButton(.secondary, L("Finish Setup"), icon: "checklist", size: .small, verbatim: true) {
                            ManagementStateManager.shared.pendingAgentSetupId = agentId
                            AppDelegate.shared?.showManagementWindow(initialTab: .agents)
                        }
                    }
                    .padding(theme.space.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsChrome(.status(.warning))
                }
                HStack(spacing: theme.space.s8) {
                    SettingsButton(.secondary, L("Open in Settings"), icon: "gearshape", verbatim: true) {
                        ManagementStateManager.shared.pendingAgentDetailId = agentId
                        AppDelegate.shared?.showManagementWindow(initialTab: .agents)
                    }
                    SettingsButton(.primary, L("Start Chatting"), icon: "bubble.left", verbatim: true) {
                        onStartChat(agentId)
                    }
                }
            }
            .padding(theme.space.s24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Labels

    static func shortModelName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    /// A capability key from `agent_draft` as the panel names it.
    static func capabilityLabel(_ key: String) -> String {
        if key.hasPrefix("apple_apps.") {
            let raw = String(key.dropFirst("apple_apps.".count))
            return AppleApp(rawValue: raw)?.displayName ?? raw
        }
        switch key {
        case "web_search_enabled": return L("Web Search")
        case "browser_use_enabled": return L("Browser")
        case "computer_use_enabled": return L("Computer Use")
        case "applescript_enabled": return L("AppleScript")
        case "memory_enabled": return L("Memory")
        case "search_memory_enabled": return L("Search Memory")
        case "knowledge_enabled": return L("Knowledge")
        case "db_enabled": return L("Database")
        case "self_scheduling_enabled": return L("Scheduling")
        case "image_enabled": return L("Images")
        case "render_chart_enabled": return L("Charts")
        case "calculator_enabled": return L("Calculator")
        case "speak_enabled": return L("Speech")
        case "task_checklist_enabled": return L("Checklist")
        case "clarify_enabled": return L("Questions")
        case "artifacts_enabled": return L("Sharing Files")
        case "redaction_tools_enabled": return L("Redaction")
        default: return key
        }
    }
}
