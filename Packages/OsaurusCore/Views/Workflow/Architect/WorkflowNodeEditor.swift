//
//  WorkflowNodeEditor.swift
//  osaurus
//
//  The Edit Step sheet: the everyday fields for a step's kind, with the
//  model it runs on picked by name. The slot id and the whole step as JSON
//  sit under Advanced. Edits land on Save, never per keystroke, and are
//  summarized for the Architect's next turn; a model pick applies at once,
//  to every step sharing the slot.
//

import SwiftUI

struct WorkflowNodeEditor: View {
    let draftID: UUID
    let node: WorkflowNode
    let onClose: () -> Void

    @State private var name = ""
    @State private var intent = ""
    @State private var slot = ""
    @State private var instructions = ""
    @State private var options = ""
    @State private var title = ""
    @State private var message = ""
    @State private var source = ""
    @State private var network = ""
    @State private var tool: ToolRef?
    @State private var arguments = ""
    @State private var stateTable = ""
    @State private var stateKey = ""
    @State private var stateValue = ""
    @State private var stateBy = ""
    @State private var replyText = ""
    @State private var replyFile = ""
    @State private var replyCaption = ""
    @State private var media = MediaSpec()
    @State private var agentName = ""
    @State private var agentRef: WorkspaceAgentRef?
    @State private var agentTask = ""
    @State private var bypassed = false
    @State private var json = ""
    @State private var editingJSON = false
    @State private var showsAdvanced = false
    @State private var error: String?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            HStack(spacing: theme.space.s10) {
                Image(systemName: WorkflowFlowStyle.icon(node))
                    .glyphSize(.body)
                    .foregroundColor(theme.text.link)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Edit Step", bundle: .module)
                        .textStyle(.heading)
                        .foregroundColor(theme.text.primary)
                    Text(verbatim: WorkflowSummary.kind(node))
                        .textStyle(.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
            }
            .padding(theme.space.s20)
            Divider()
            ScrollView {
                form
                    .padding(theme.space.s20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
                .padding(.horizontal, theme.space.s20)
                .padding(.vertical, theme.space.s14)
        }
        .fittedSheetFrame(width: 560, height: 620)
        .background(theme.surface.canvas)
        .onAppear { load(node) }
        .onChange(of: node) { _, updated in
            if updated != (try? editingJSON ? fromJSON() : fromFields()) { load(updated) }
        }
        .onChange(of: editingJSON) { _, on in
            if on, let edited = try? fromFields() { json = WorkflowDiff.pretty(edited) }
            if !on, let parsed = try? fromJSON() { load(parsed, keepJSON: true) }
        }
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            if editingJSON {
                codeEditor($json, minHeight: 320)
            } else {
                field("Name") { SettingsTextField(placeholder: L("Name"), text: $name) }
                if node.kind == nil {
                    field("What it should do") {
                        SettingsTextField(placeholder: L("What this step does"), text: $intent)
                    }
                }
                switch node.kind {
                case .inference(let spec):
                    field("Runs on") { WorkflowStepModelMenu(draftID: draftID, node: node, slotID: spec.modelSlot) }
                    field("Instructions") {
                        SettingsTextEditor(
                            text: $instructions, placeholder: L("Instructions"),
                            minHeight: theme.lineHeight(.bodySmall) * 6, maxHeight: theme.lineHeight(.bodySmall) * 18)
                    }
                    if case .decide = spec.mode {
                        field("Paths to pick from") {
                            SettingsTextField(placeholder: L("Comma-separated"), text: $options)
                        }
                    }
                case .dialog(let spec):
                    field("Title") { SettingsTextField(placeholder: L("Title"), text: $title) }
                    field("Message") {
                        longText($message, placeholder: L("Message"), lines: 6)
                    }
                    field("What you'll see") {
                        WorkflowDialogPreview(
                            title: title.isEmpty ? node.name : title, message: message, fields: spec.fields)
                    }
                    note(L("Edit the form's fields as JSON under Advanced."))
                case .code(let spec):
                    if spec.language == .javascript {
                        field("Allowed hosts") {
                            SettingsTextField(placeholder: "api.example.com", text: $network, monospaced: true)
                        }
                    } else {
                        note(L("Python runs in this workflow's sandbox, where its pip dependencies are installed."))
                    }
                    field("Source") { codeEditor($source, minHeight: 220) }
                case .tool:
                    field("Tool") { WorkflowToolMenu(selection: $tool) }
                    if let entry = tool.flatMap({ WorkflowToolCatalog.entry(named: $0.name) }) {
                        note(entry.description)
                    }
                    field("Arguments") { codeEditor($arguments, minHeight: 160) }
                    note(L("JSON passed to the tool. Use {{input.x}} or {{nodes.<id>.output.y}} for values from earlier steps."))
                case .http(let spec):
                    field("Request") {
                        Text(verbatim: "\(spec.method) \(spec.url)")
                            .textStyle(.code)
                            .textSelection(.enabled)
                    }
                    if let auth = spec.auth {
                        note(L("Authenticates with the secret \(spec.secretKeys.joined(separator: ", ")) (\(Self.authLabel(auth)))."))
                    }
                    note(L("Edit the method, URL, headers, body, and auth as JSON under Advanced."))
                case .wait(let spec):
                    if let seconds = spec.seconds {
                        note(L("Waits \(seconds) seconds."))
                    } else if let until = spec.until {
                        note(L("Waits until \(until)."))
                    }
                    note(L("Edit the wait as JSON under Advanced."))
                case .map(let spec):
                    field("For each item in") {
                        Text(verbatim: spec.items).textStyle(.code).textSelection(.enabled)
                    }
                    note(L("Runs its step once per item, \(spec.concurrency) at a time. Edit the step as JSON under Advanced."))
                case .workflow(let spec):
                    field("Workflow") {
                        Text(verbatim: spec.workflow).textSelection(.enabled)
                    }
                    field("Input") { codeEditor($arguments, minHeight: 160) }
                    note(L("JSON passed as that workflow's input. Use {{input.x}} or {{nodes.<id>.output.y}} for values from earlier steps."))
                case .state(let spec):
                    field("Action") {
                        Text(verbatim: spec.action.rawValue).textStyle(.code)
                    }
                    field("Table") { SettingsTextField(placeholder: StateSpec.defaultTable, text: $stateTable, monospaced: true) }
                    if spec.action != .list && spec.action != .clear {
                        field("Key") { SettingsTextField(placeholder: L("Key"), text: $stateKey, monospaced: true) }
                    }
                    if spec.action == .set {
                        field("Value") { codeEditor($stateValue, minHeight: 80) }
                    }
                    if spec.action == .increment {
                        field("By") { SettingsTextField(placeholder: "1", text: $stateBy, monospaced: true) }
                    }
                    note(L("Stored data stays with this workflow between runs. Table, key, and value may use {{input.x}} or {{nodes.<id>.output.y}}."))
                case .reply:
                    field("Message") {
                        longText($replyText, placeholder: L("Message"), lines: 8)
                    }
                    field("File") {
                        SettingsTextField(placeholder: "{{nodes.<id>.output.path}}", text: $replyFile, monospaced: true)
                    }
                    if !replyFile.trimmingCharacters(in: .whitespaces).isEmpty {
                        field("Caption") { SettingsTextField(placeholder: L("Caption"), text: $replyCaption) }
                    }
                    note(L("Posts into the channel conversation that started the run. Run from a tab or an agent, nothing is sent and the step outputs sent: false. Use {{caller.channel.sender_name}} or {{nodes.<id>.output.y}} for values from earlier steps."))
                case .media:
                    MediaStepEditor(
                        spec: $media,
                        inputKeys: WorkflowDraftStore.shared.draft(id: draftID).map {
                            Set($0.definition.inputSchema.objectValue?["properties"]?.objectValue?.keys ?? [:].keys)
                        })
                case .agent:
                    field("Agent") { WorkflowAgentMenu(name: $agentName, workspace: $agentRef) }
                    if let notAllowed = agentNotAllowedNote { note(notAllowed) }
                    field("Task") {
                        longText($agentTask, placeholder: L("What to ask the agent"), lines: 8)
                    }
                    note(
                        agentRef == nil
                            ? L("The agent works on its own model, tools, and permissions, and the step takes its answer as {{nodes.<id>.output.text}}. Only the task is sent.")
                            : L("A teammate's shared agent runs the task on their Mac, which pays for it. Only the task text leaves this Mac; the step takes the answer as {{nodes.<id>.output.text}}."))
                case nil:
                    EmptyView()
                }
                if node.kind != nil {
                    SettingsToggle(
                        title: "Bypass This Step",
                        description: node.bypassPassesData
                            ? L("Skips the step and hands its input to the next one. Turn it off to run it again.")
                            : L("Skips the step. It has no input to hand on, so later steps get an empty value."),
                        isOn: $bypassed)
                }
            }

            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    if case .inference = node.kind {
                        field("Slot id") {
                            SettingsTextField(placeholder: "main", text: $slot, monospaced: true)
                        }
                        note(L("Steps with the same slot id share one model."))
                    }
                    Toggle(isOn: $editingJSON) {
                        Text("Edit as JSON", bundle: .module)
                    }
                    .settingsSwitch(showsLabel: true)
                    Text(verbatim: L("Step id: \(node.id)"))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .textSelection(.enabled)
                }
                .padding(.top, theme.space.s6)
            } label: {
                Text("Advanced", bundle: .module)
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(theme.text.secondary)
            }

            if let error {
                Text(error)
                    .textStyle(.caption)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: theme.space.s8) {
            Button(role: .destructive) {
                WorkflowStepActions.delete(node, in: draftID)
                onClose()
            } label: {
                Label {
                    Text("Delete Step", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
                .textStyle(.caption)
                .foregroundColor(theme.status.error.foreground)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            Spacer()
            Button(action: onClose) {
                Text("Cancel", bundle: .module)
            }
            .assignedSettingsButtonStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            Button {
                if apply() { onClose() }
            } label: {
                Text("Save", bundle: .module)
            }
            .assignedSettingsButtonStyle(.primary)
            .keyboardShortcut(.defaultAction)
            .disabled(!isDirty)
        }
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text(label, bundle: .module)
                .textStyle(.caption, weight: 500)
                .foregroundColor(theme.text.secondary)
            content()
        }
    }

    /// Why the chosen agent can't be asked from the Orchestrator yet.
    private var agentNotAllowedNote: String? {
        guard !agentName.isEmpty,
            case .target(let target) = AgentNodeExecutor.resolve(
                AgentNodeSpec(agent: agentName, workspace: agentRef, task: "").requirement, binding: nil, in: .live()),
            !AgentNodeExecutor.isAllowed(target)
        else { return nil }
        return L("\(AgentNodeExecutor.notAllowedMessage(target.name, isDefault: true)) Until it is, runs stop at this step.")
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .textStyle(.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func codeEditor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        SettingsTextEditor(text: text, minHeight: minHeight, monospaced: true)
    }

    /// A text view, not a vertical `TextField`: that one lays its whole value
    /// out on every measure, and the Architect writes long messages and tasks.
    private func longText(_ text: Binding<String>, placeholder: String, lines: CGFloat) -> some View {
        let line = theme.lineHeight(.bodySmall)
        return SettingsTextEditor(
            text: text, placeholder: placeholder, minHeight: line * min(3, lines), maxHeight: line * lines)
    }

    // MARK: - State

    private func load(_ node: WorkflowNode, keepJSON: Bool = false) {
        name = node.name
        intent = node.intent ?? ""
        slot = ""
        instructions = ""
        options = ""
        title = ""
        message = ""
        source = ""
        network = ""
        tool = nil
        arguments = ""
        stateTable = ""
        stateKey = ""
        stateValue = ""
        stateBy = ""
        replyText = ""
        replyFile = ""
        replyCaption = ""
        media = MediaSpec()
        agentName = ""
        agentRef = nil
        agentTask = ""
        bypassed = node.mode == .bypass
        switch node.kind {
        case .inference(let spec):
            slot = spec.modelSlot
            instructions = spec.instructions
            if case .decide(let opts) = spec.mode { options = opts.joined(separator: ", ") }
        case .dialog(let spec):
            title = spec.title
            message = spec.message
        case .code(let spec):
            source = spec.source
            network = spec.network.joined(separator: ", ")
        case .tool(let spec):
            tool = spec.tool
            arguments = WorkflowDiff.pretty(node.input)
        case .workflow:
            arguments = WorkflowDiff.pretty(node.input)
        case .state(let spec):
            stateTable = spec.table ?? ""
            stateKey = spec.key ?? ""
            stateValue = spec.value ?? ""
            stateBy = spec.by ?? ""
        case .reply(let spec):
            replyText = spec.text
            replyFile = spec.file ?? ""
            replyCaption = spec.caption ?? ""
        case .media(let spec):
            media = spec
        case .agent(let spec):
            agentName = spec.agent
            agentRef = spec.workspace
            agentTask = spec.task
        case .http, .wait, .map, nil:
            break
        }
        if editingJSON, !keepJSON { json = WorkflowDiff.pretty(node) }
        error = nil
    }

    private var isDirty: Bool {
        guard let edited = try? (editingJSON ? fromJSON() : fromFields()) else { return true }
        return edited != node
    }

    private func fromFields() throws -> WorkflowNode {
        var edited = node
        edited.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? node.id : name
        edited.intent = intent.isEmpty ? node.intent : intent
        func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        switch node.kind {
        case .inference(var spec):
            spec.modelSlot = slot.trimmingCharacters(in: .whitespaces)
            spec.instructions = instructions
            if case .decide = spec.mode { spec.mode = .decide(options: list(options)) }
            edited.kind = .inference(spec)
        case .dialog(var spec):
            spec.title = title
            spec.message = message
            edited.kind = .dialog(spec)
        case .code(var spec):
            spec.source = source
            spec.network = list(network)
            edited.kind = .code(spec)
        case .tool(var spec):
            if let tool { spec.tool = tool }
            edited.kind = .tool(spec)
            let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.input = text.isEmpty ? .object([:]) : try JSONDecoder().decode(WorkflowBinding.self, from: Data(text.utf8))
        case .workflow:
            let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.input = text.isEmpty ? .object([:]) : try JSONDecoder().decode(WorkflowBinding.self, from: Data(text.utf8))
        case .state(var spec):
            func blank(_ s: String) -> String? {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            spec.table = blank(stateTable)
            spec.key = blank(stateKey)
            spec.value = blank(stateValue)
            spec.by = blank(stateBy)
            edited.kind = .state(spec)
        case .reply(var spec):
            let file = replyFile.trimmingCharacters(in: .whitespacesAndNewlines)
            let caption = replyCaption.trimmingCharacters(in: .whitespacesAndNewlines)
            spec.text = replyText
            spec.file = file.isEmpty ? nil : file
            spec.caption = file.isEmpty || caption.isEmpty ? nil : caption
            edited.kind = .reply(spec)
        case .media:
            edited.kind = .media(media)
        case .agent:
            edited.kind = .agent(AgentNodeSpec(agent: agentName, workspace: agentRef, task: agentTask))
        case .http, .wait, .map, nil:
            break
        }
        if node.kind != nil { edited.mode = bypassed ? .bypass : .always }
        return edited
    }

    private static func authLabel(_ auth: HTTPAuth) -> String {
        switch auth {
        case .bearer: return "Bearer token"
        case .connection: return "Connection"
        case .basic: return "Basic"
        case .header(let name, _): return "\(name) header"
        case .query(let name, _): return "?\(name)= query"
        }
    }

    private func fromJSON() throws -> WorkflowNode {
        try JSONDecoder().decode(WorkflowNode.self, from: Data(json.utf8))
    }

    private func apply() -> Bool {
        let edited: WorkflowNode
        do {
            edited = try editingJSON ? fromJSON() : fromFields()
        } catch let DecodingError.dataCorrupted(ctx) {
            error = ctx.debugDescription
            return false
        } catch {
            self.error = WorkflowErrorText.text(error)
            return false
        }
        guard edited.id == node.id else {
            error = L("A step's id can't change.")
            return false
        }
        WorkflowDraftStore.shared.applyUserEdit(draftID) { draft in
            if let i = draft.definition.nodes.firstIndex(where: { $0.id == node.id }) {
                draft.definition.nodes[i] = edited
            }
        }
        error = nil
        return true
    }
}

@MainActor
enum WorkflowStepActions {
    static func delete(_ node: WorkflowNode, in draftID: UUID) {
        WorkflowDraftStore.shared.applyUserEdit(draftID) { draft in
            draft.definition.nodes.removeAll { $0.id == node.id }
            draft.definition.edges.removeAll { $0.from == node.id || $0.to == node.id }
            draft.selectedNodeID = nil
        }
    }

    static func setBypassed(_ bypassed: Bool, _ node: WorkflowNode, in draftID: UUID) {
        WorkflowDraftStore.shared.applyUserEdit(draftID) { draft in
            if let i = draft.definition.nodes.firstIndex(where: { $0.id == node.id }) {
                draft.definition.nodes[i].mode = bypassed ? .bypass : .always
            }
        }
    }

    /// "Undo the Architect's change to Flag anomalies", for the draft's
    /// most recent edit, in step names rather than field paths.
    static func undoTitle(_ draft: WorkflowDraft) -> String? {
        guard let last = draft.history.last else { return nil }
        var names: [String] = []
        for change in WorkflowDiff.changes(from: last.definition, to: draft.definition, details: false) {
            guard change.subject.hasPrefix("node ") else { continue }
            let id = String(change.subject.dropFirst("node ".count))
            let name = draft.definition.node(id)?.name ?? last.definition.node(id)?.name ?? id
            if !names.contains(name) { names.append(name) }
        }
        let architect = last.source == .architect
        if names.isEmpty {
            if last.name != draft.name { return L("Undo Rename") }
            return architect ? L("Undo the Architect's Last Change") : L("Undo Your Last Change")
        }
        let shown = names.count > 2 ? names.prefix(2) + [L("\(names.count - 2) more")] : names[...]
        let list = WorkflowSummary.list(Array(shown))
        return architect ? L("Undo the Architect's Change to \(list)") : L("Undo Your Change to \(list)")
    }
}

/// The tool a tool step calls, from the tools a workflow step may call on
/// this Mac, grouped by where they come from.
struct WorkflowToolMenu: View {
    @Binding var selection: ToolRef?
    @Environment(\.theme) private var theme

    var body: some View {
        let entries = WorkflowToolCatalog.entries()
        let groups = Dictionary(grouping: entries, by: \.providerLabel).sorted { lhs, rhs in
            lhs.key == "builtin" ? true : rhs.key == "builtin" ? false : lhs.key < rhs.key
        }
        SettingsActionMenu(accessibilityLabel: L("Choose a tool")) {
            ForEach(groups, id: \.key) { group in
                Section(group.key == "builtin" ? L("Built-in") : group.key) {
                    ForEach(group.value) { entry in
                        Button {
                            selection = entry.ref
                        } label: {
                            if entry.name == selection?.name {
                                Label(entry.name, systemImage: "checkmark")
                            } else {
                                Text(entry.name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: theme.space.s6) {
                Text(verbatim: selection?.name ?? L("Choose a tool"))
                    .textStyle(.code)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s4)
            .settingsChrome(.inset)
            .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).strokeBorder(theme.border.strong))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The agent an agent step asks: one of this Mac's, or one shared in a
/// workspace (your own shared agents included, so teammates who install the
/// workflow reach the same agent; on this Mac it still runs here).
struct WorkflowAgentMenu: View {
    @Binding var name: String
    @Binding var workspace: WorkspaceAgentRef?

    @ObservedObject private var agents = AgentManager.shared
    @ObservedObject private var rosters = WorkspaceRosterStore.shared

    var body: some View {
        SettingsActionMenu(accessibilityLabel: L("Choose an agent")) {
            Section(L("On This Mac")) {
                ForEach(agents.agents.filter { $0.id != Agent.defaultId }) { agent in
                    item(agent.name, selected: workspace == nil && agent.name == name) {
                        name = agent.name
                        workspace = nil
                    }
                }
            }
            ForEach(rosters.rosters) { roster in
                if !roster.agents.isEmpty {
                    Section(L("Shared in \(roster.workspace.name)")) {
                        ForEach(roster.agents, id: \.agentAddress) { shared in
                            let ref = WorkspaceAgentRef(workspaceId: roster.id, agentAddress: shared.agentAddress)
                            let label = shared.displayName ?? AgentTargetResolver.displayName(for: ref)
                            item(label, selected: workspace == ref) {
                                name = label
                                workspace = ref
                            }
                        }
                    }
                }
            }
        } label: {
            WorkflowEditorMenuLabel(
                text: name.isEmpty ? L("Choose an agent") : name, icon: workspace == nil ? nil : "person.2")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .task { if rosters.lastRefreshedAt == nil { await rosters.refresh(reason: .manual) } }
    }

    private func item(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
}

/// The pop-up face of the Edit Step menus (model, agent).
struct WorkflowEditorMenuLabel: View {
    let text: String
    var icon: String?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space.s6) {
            Text(verbatim: text)
                .textStyle(.bodySmall)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            if let icon {
                Image(systemName: icon).glyphSize(.tiny).foregroundColor(theme.text.tertiary)
            }
            Image(systemName: "chevron.up.chevron.down")
                .glyphSize(.tiny, weight: .semibold)
                .foregroundColor(theme.text.tertiary)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s4)
        .settingsChrome(.inset)
        .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).strokeBorder(theme.border.strong))
        .contentShape(Rectangle())
    }
}

/// The model a step's slot runs on in test runs (and once saved). Models
/// that can't run the step are left out; the caption under the field says
/// how many and why.
struct WorkflowStepModelMenu: View {
    let draftID: UUID
    let node: WorkflowNode
    let slotID: String

    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @Environment(\.theme) private var theme

    var body: some View {
        let draft = drafts.draft(id: draftID)
        let requirement =
            draft.map(DraftRevisionCache.template)?.requirements.models.first { $0.slot == slotID } ?? ModelRequirement(slot: slotID)
        let bound = draft?.bindings.models[slotID]
        let shared = (draft?.definition.nodes ?? []).filter { other in
            guard other.id != node.id, case .inference(let spec) = other.kind else { return false }
            return spec.modelSlot == slotID
        }
        VStack(alignment: .leading, spacing: theme.space.s4) {
            WorkflowModelSlotPicker(
                requirement: requirement, bound: bound, boundLabel: { WorkflowModelChoices.runsOn($0) }
            ) { pick($0) }
            if !shared.isEmpty {
                Text(verbatim: shared.count == 1
                        ? L("\(shared[0].name) uses this model too; changing it changes both.")
                        : L(
                            "\(WorkflowSummary.list(shared.map(\.name))) use this model too; changing it changes all of them."
                        )
                )
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pick(_ model: String?) {
        guard var bindings = drafts.draft(id: draftID)?.bindings else { return }
        bindings.models[slotID] = model
        drafts.setBindings(draftID, bindings)
        drafts.notePending(
            draftID,
            model.map { "The user set model slot \"\(slotID)\" to \($0)." }
                ?? "The user reset model slot \"\(slotID)\" to the workflow's choice.")
    }
}
