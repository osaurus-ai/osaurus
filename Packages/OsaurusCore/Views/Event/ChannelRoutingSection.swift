//
//  ChannelRoutingSection.swift
//  osaurus
//
//  A channel's Routing and Posting, edited where the channel is set up.
//
//  Routing is a flat table with one row per channel automation: where it
//  listens (rooms or any room), who answers (an agent or a workflow), how
//  it replies, and whether it is on. Many agents across many rooms is just
//  more rows. A plain-language summary under the table says where each
//  message goes and warns when a message would reach no one or several.
//
//  Posting lists the agents that may start a message here on their own
//  (posting bindings).
//

import SwiftUI

// MARK: - Shared data

/// Rooms and names a channel sheet's routing controls offer.
@MainActor
struct ChannelRoomChoices {
    let connectionId: String
    /// Rooms the bot reads (the Receiving allowlist).
    let readable: [String]
    /// Rooms the bot may post in (empty when sending is off).
    let writable: [String]
    let label: (String) -> String

    static func live(connectionId: String) -> ChannelRoomChoices {
        let view = try? AgentChannelConnectionService.shared.resolvedConnectionView(id: connectionId)
        let directory = AgentChannelRoomDirectory.shared
        directory.prepare(connectionIds: [connectionId])
        return ChannelRoomChoices(
            connectionId: connectionId,
            readable: view?.readRoomAllowlist ?? [],
            writable: ChannelAgentRoster.liveWritableRoomIds(connectionId: connectionId),
            label: labeler(connectionId: connectionId))
    }

    /// Room names from the session room directory ("#support"), ids until
    /// the connection's rooms have loaded.
    static func labeler(connectionId: String) -> (String) -> String {
        let directory = AgentChannelRoomDirectory.shared
        return { roomId in
            guard let descriptor = directory.descriptor(connectionId: connectionId, roomId: roomId),
                descriptor.name != roomId
            else { return roomId }
            return descriptor.formattedName
        }
    }
}

@MainActor
enum ChannelRoutingNames {
    static func target(_ target: ChannelAgentRoster.Target) -> String {
        switch target {
        case .agent(let dispatch): EventInspection.targetName(dispatch)
        case .workflow(let id): InstalledWorkflowStore.shared.workflow(id: id)?.name ?? L("Missing workflow")
        }
    }

    static func isMissing(_ target: ChannelAgentRoster.Target?) -> Bool {
        switch target {
        case .none: true
        case .agent(.local(let id)): AgentManager.shared.agent(for: id) == nil
        case .agent(.workspace): false
        case .workflow(let id): InstalledWorkflowStore.shared.workflow(id: id) == nil
        }
    }

    static func list(_ targets: [ChannelAgentRoster.Target]) -> String {
        let names = targets.map(target)
        switch names.count {
        case 0: return L("no one")
        case 1: return names[0]
        case 2: return L("\(names[0]) and \(names[1])")
        default: return L("\(names.dropLast().joined(separator: ", ")) and \(names.last ?? "")")
        }
    }

    /// "#support", "#ops, #incidents", or "Any room".
    static func rooms(_ ids: [String], label: (String) -> String) -> String {
        ids.isEmpty ? L("Any room") : ids.map(label).joined(separator: ", ")
    }
}

// MARK: - Routing

struct ChannelRoutingSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var workflowStore = InstalledWorkflowStore.shared
    @ObservedObject private var roomDirectory = AgentChannelRoomDirectory.shared
    private var manager = EventManager.shared

    let kind: AgentChannelKind
    let connectionId: String
    /// Shown in generated rule names.
    let connectionName: String

    @State private var roster = ChannelAgentRoster(rules: [], posting: [])
    @State private var rooms = ChannelRoomChoices(connectionId: "", readable: [], writable: [], label: { $0 })
    @State private var showAdd = false
    @State private var roomsFor: UUID?
    @State private var duplicateFor: UUID?
    @State private var editor: EventEditorRequest?
    @State private var pendingDelete: OsaurusEvent?

    init(kind: AgentChannelKind, connectionId: String, connectionName: String? = nil) {
        self.kind = kind
        self.connectionId = connectionId
        self.connectionName = connectionName ?? kind.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Who answers messages", bundle: .module)
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    Text(
                        "One row per rule. A message goes to the rules for its room; rooms without their own rule go to Any room.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    showAdd = true
                } label: {
                    Label(L("Add Rule"), systemImage: "plus")
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
                .settingsLandingAnchor("agentChannels.addRule")
                .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                    ChannelAddRulePopover(
                        rooms: rooms,
                        onAdd: { target, roomIds in
                            addRule(target: target, roomIds: roomIds)
                            showAdd = false
                        },
                        onCancel: { showAdd = false })
                }
            }

            table
                .settingsLandingAnchor("agentChannels.routing")

            if !roster.rules.isEmpty || !rooms.readable.isEmpty {
                summary
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .eventsChanged).receive(on: DispatchQueue.main)) { _ in
            reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentChannelConfigurationChanged).receive(on: DispatchQueue.main)
        ) { _ in reload() }
        .onChange(of: roomDirectory.version) { _, _ in reload() }
        .sheet(item: $editor) { request in
            EventEditorSheet(
                request: request,
                onSave: { event in
                    if request.existing == nil { _ = manager.create(event) } else { manager.update(event) }
                    editor = nil
                    reload()
                },
                onCancel: { editor = nil }
            )
            .themedAlertSheetHost()
        }
        .themedAlert(
            L("Delete this rule?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            message: L("Messages it answered go to the remaining rules. Its run history is removed."),
            primaryButton: .destructive(L("Delete")) {
                if let event = pendingDelete { _ = manager.delete(id: event.id) }
                pendingDelete = nil
                reload()
            },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .window
        )
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                columnTitle(L("Where")).frame(maxWidth: .infinity, alignment: .leading)
                columnTitle(L("Who answers")).frame(width: 150, alignment: .leading)
                columnTitle(L("Replies")).frame(width: 128, alignment: .leading)
                Color.clear.frame(width: 64, height: 1)
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .background(theme.surface.hover)

            if roster.rules.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundColor(theme.text.tertiary)
                    Text(
                        "No rules yet. Messages wait in this channel's inbox until a rule sends them to an agent or workflow.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Array(roster.rules.enumerated()), id: \.element.id) { index, rule in
                if index > 0 { Divider().opacity(0.5) }
                ruleRow(rule)
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(SettingsFont.compactLabel)
            .foregroundColor(theme.text.tertiary)
    }

    private func ruleRow(_ rule: ChannelAgentRoster.Rule) -> some View {
        HStack(alignment: .center, spacing: 10) {
            whereCell(rule).frame(maxWidth: .infinity, alignment: .leading)
            whoCell(rule).frame(width: 150, alignment: .leading)
            repliesCell(rule).frame(width: 128, alignment: .leading)
            HStack(spacing: 6) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { rule.isEnabled },
                        set: { manager.setEnabled(rule.id, enabled: $0); reload() })
                )
                .settingsSwitch()
                .help(rule.isEnabled ? L("On: this rule answers messages") : L("Off: this rule is skipped"))
                rowMenu(rule)
            }
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .opacity(rule.isEnabled ? 1 : 0.55)
        .contentShape(Rectangle())
    }

    private func whereCell(_ rule: ChannelAgentRoster.Rule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                roomsFor = rule.id
            } label: {
                HStack(spacing: 4) {
                    if rule.roomIds.isEmpty {
                        roomChip(L("Any room"), muted: true)
                    } else {
                        // As many whole chips as fit, then "+N".
                        ViewThatFits(in: .horizontal) {
                            ForEach(Array(stride(from: min(rule.roomIds.count, 4), through: 1, by: -1)), id: \.self) {
                                shown in
                                HStack(spacing: 4) {
                                    ForEach(rule.roomIds.prefix(shown), id: \.self) { room in
                                        roomChip(rooms.label(room), muted: false)
                                    }
                                    if rule.roomIds.count > shown { moreCount(rule.roomIds.count - shown) }
                                }
                            }
                        }
                    }
                    Image(systemName: "chevron.down")
                        .glyphSize(7, weight: .bold)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help(L("Choose the rooms this rule answers in"))
            .popover(
                isPresented: Binding(get: { roomsFor == rule.id }, set: { if !$0 { roomsFor = nil } }),
                arrowEdge: .bottom
            ) {
                ChannelRoomPickerPopover(
                    title: L("Where does this rule answer?"),
                    confirmTitle: L("Save"),
                    rooms: rooms,
                    initial: rule.roomIds,
                    onDone: { picked in
                        manager.update(ChannelAgentRoster.withRooms(rule.event, roomIds: picked))
                        roomsFor = nil
                        reload()
                    },
                    onCancel: { roomsFor = nil })
            }

            let badges = triggerBadges(rule)
            if !badges.isEmpty {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(stride(from: badges.count, through: 1, by: -1)), id: \.self) { shown in
                        HStack(spacing: 4) {
                            ForEach(badges.prefix(shown), id: \.self) { badge in
                                Text(badge)
                                    .font(SettingsFont.chip)
                                    .foregroundColor(theme.text.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, theme.space.s6)
                                    .padding(.vertical, theme.space.s2)
                                    .background(Capsule().stroke(theme.border.subtle, lineWidth: theme.stroke.default))
                            }
                            if badges.count > shown { moreCount(badges.count - shown) }
                        }
                        .help(badges.joined(separator: " · "))
                    }
                }
            }
        }
    }

    private func moreCount(_ count: Int) -> some View {
        Text("+\(count)")
            .font(SettingsFont.chip)
            .foregroundColor(theme.text.tertiary)
            .fixedSize()
    }

    private func roomChip(_ text: String, muted: Bool) -> some View {
        StatusChip(text, tone: muted ? .neutral : .accent)
    }

    private func triggerBadges(_ rule: ChannelAgentRoster.Rule) -> [String] {
        var badges = rule.aliases.map { L("Starts with “\($0)”") }
        if rule.requireMention { badges.append(L("Only when mentioned")) }
        if rule.hasFilter { badges.append(L("Filtered")) }
        return badges
    }

    private func whoCell(_ rule: ChannelAgentRoster.Rule) -> some View {
        let missing = ChannelRoutingNames.isMissing(rule.target)
        return HStack(spacing: 6) {
            Image(
                systemName: rule.target?.isAgent == false
                    ? "point.3.connected.trianglepath.dotted" : "person.crop.circle"
            )
            .textStyle(.caption)
            .foregroundColor(missing ? theme.status.warning.foreground : theme.text.secondary)
            Text(rule.target.map(ChannelRoutingNames.target) ?? L("No agent selected"))
                .font(SettingsFont.compactLabel)
                .foregroundColor(missing ? theme.status.warning.foreground : theme.text.primary)
                .lineLimit(1)
                .help(rule.event.name)
        }
    }

    private func repliesCell(_ rule: ChannelAgentRoster.Rule) -> some View {
        let isAgent = rule.event.action.kind == .agent
        let on = rule.repliesAutomatically
        let stepReplies =
            rule.event.action.workflow.flatMap { InstalledWorkflowStore.shared.workflow(id: $0.workflowID) }?
            .definition.hasReplyStep == true
        let onLabel = isAgent ? L("Automatically") : L("Posts the output")
        let offLabel = isAgent ? L("After approval") : stepReplies ? L("Replies from its steps") : L("Doesn't reply")
        return SettingsMenuPicker(
            selection: Binding(get: { on }, set: { setReplies($0, rule: rule) })
        ) {
            Text(onLabel).tag(true)
            Text(offLabel).tag(false)
        }
        .help(
            isAgent
                ? L("After approval holds each reply in the chat until you send it.")
                : stepReplies
                    ? L("The workflow's Reply steps post into the conversation. Posts the output also sends its result when no Reply step ran.")
                    : L("Posts the output sends the workflow's result back to the conversation."))
    }

    private func rowMenu(_ rule: ChannelAgentRoster.Rule) -> some View {
        SettingsOverflowMenu(help: "Instructions, aliases, filters and more", size: .compact) {
            Button(L("Edit…")) { editor = EventEditorRequest(existing: rule.event) }
            Button(L("Duplicate for another room…")) { duplicateFor = rule.id }
            Divider()
            Button(L("Delete"), role: .destructive) { pendingDelete = rule.event }
        }
        .popover(
            isPresented: Binding(get: { duplicateFor == rule.id }, set: { if !$0 { duplicateFor = nil } }),
            arrowEdge: .bottom
        ) {
            ChannelRoomPickerPopover(
                title: L("Same rule, other rooms"),
                confirmTitle: L("Duplicate"),
                rooms: rooms,
                initial: [],
                onDone: { picked in
                    duplicate(rule, roomIds: picked)
                    duplicateFor = nil
                },
                onCancel: { duplicateFor = nil })
        }
    }

    // MARK: Summary

    private var summary: some View {
        let lines = roster.routingLines()
        let warnings = roster.routingWarnings(readableRoomIds: rooms.readable)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Where messages go", bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(lineKey(line.kind))
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.primary)
                    Image(systemName: "arrow.right")
                        .glyphSize(8, weight: .bold)
                        .foregroundColor(theme.text.tertiary)
                    Text(
                        line.targets.isEmpty
                            ? L("No one (waits in the inbox)")
                            : ChannelRoutingNames.list(line.targets)
                                + (line.mentionOnly ? " " + L("(when mentioned)") : "")
                    )
                    .textStyle(.footnote)
                    .foregroundColor(line.targets.isEmpty ? theme.text.tertiary : theme.text.secondary)
                }
            }
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Label(warningText(warning), systemImage: "exclamationmark.triangle.fill")
                    .textStyle(.footnote)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
        .settingsLandingAnchor("agentChannels.routingSummary")
    }

    private func lineKey(_ kind: ChannelAgentRoster.RoutingLine.Kind) -> String {
        switch kind {
        case .alias(let alias): L("Starts with “\(alias)”")
        case .room(let room): L("In \(rooms.label(room))")
        case .everywhereElse:
            roster.rules.contains { $0.isEnabled && $0.scope != .anyRoom } ? L("Everywhere else") : L("Every room")
        }
    }

    private func warningText(_ warning: ChannelAgentRoster.RoutingWarning) -> String {
        switch warning {
        case .nobodyAnswers:
            return L("No rule is on, so messages wait in this channel's inbox.")
        case .uncoveredRooms(let ids):
            return L(
                "Messages in \(ids.map(rooms.label).joined(separator: ", ")) reach no one. Add a rule for those rooms or an Any room rule."
            )
        case .severalAnswer(let kind, let targets):
            let names = ChannelRoutingNames.list(targets)
            switch kind {
            case .alias(let alias): return L("\(names) all answer messages that start with “\(alias)”.")
            case .room(let room): return L("\(names) all answer every message in \(rooms.label(room)).")
            case .everywhereElse: return L("\(names) all answer the same messages.")
            }
        case .missingTarget:
            return L("A rule has no agent. Edit it to choose one.")
        }
    }

    // MARK: Data and writes

    private func reload() {
        rooms = ChannelRoomChoices.live(connectionId: connectionId)
        roster = ChannelAgentRoster.build(
            events: manager.events(kind: kind, connectionId: connectionId),
            bindings: AgentChannelAutoDestinationResolver.effectiveConfiguration().bindings,
            connectionId: connectionId,
            writableRoomIds: rooms.writable
        )
    }

    private func addRule(target: ChannelAgentRoster.Target, roomIds: [String]) {
        var definition: WorkflowDefinition?
        if case .workflow(let id) = target { definition = InstalledWorkflowStore.shared.workflow(id: id)?.definition }
        let event = ChannelAgentRoster.newRule(
            kind: kind, connectionId: connectionId, connectionName: connectionName,
            target: target, targetName: ChannelRoutingNames.target(target),
            roomIds: roomIds, roomName: rooms.label, existingNames: manager.events.map(\.name),
            workflowDefinition: definition)
        _ = manager.create(event)
        reload()
    }

    private func duplicate(_ rule: ChannelAgentRoster.Rule, roomIds: [String]) {
        guard
            let copy = ChannelAgentRoster.duplicate(
                rule.event, roomIds: roomIds, roomName: rooms.label, connectionName: connectionName,
                targetName: rule.target.map(ChannelRoutingNames.target) ?? rule.event.name,
                existingNames: manager.events.map(\.name))
        else { return }
        _ = manager.create(copy)
        reload()
    }

    private func setReplies(_ on: Bool, rule: ChannelAgentRoster.Rule) {
        var event = rule.event
        switch event.action.kind {
        case .agent: event.reply.autoReply = on
        case .workflow: event.reply.replyWithWorkflowOutput = on
        case .prompt: return
        }
        manager.update(event)
        reload()
    }
}

// MARK: - Room picker

/// "Any room" or a set of rooms: the bot's readable rooms (with names when
/// known) plus any id typed in.
struct ChannelRoomSelection: View {
    @Environment(\.theme) private var theme

    let rooms: ChannelRoomChoices
    @Binding var anyRoom: Bool
    @Binding var selection: [String]
    @State private var typed = ""

    private var listed: [String] {
        AgentChannelConnection.normalizedIds(rooms.readable + selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $anyRoom) {
                Text("Any room", bundle: .module).tag(true)
                Text("Only these rooms", bundle: .module).tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if !anyRoom {
                if listed.isEmpty {
                    Text(
                        "This channel reads no rooms yet. Type a room ID below, or choose rooms under Receiving.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(listed, id: \.self) { room in
                                Toggle(
                                    isOn: Binding(
                                        get: { selection.contains(room) },
                                        set: { on in
                                            if on {
                                                if !selection.contains(room) { selection.append(room) }
                                            } else {
                                                selection.removeAll { $0 == room }
                                            }
                                        })
                                ) {
                                    HStack(spacing: 6) {
                                        Text(rooms.label(room))
                                            .font(SettingsFont.caption)
                                            .foregroundColor(theme.text.primary)
                                        if rooms.label(room) != room {
                                            Text(room)
                                                .font(SettingsFont.monoSmall)
                                                .foregroundColor(theme.text.tertiary)
                                        }
                                    }
                                }
                                .settingsCheckbox()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // A fixed height: in a popover a max-height scroll view
                    // collapses to nothing.
                    .frame(height: min(CGFloat(listed.count) * 22 + 4, 180))
                }
                HStack(spacing: 6) {
                    SettingsTextField(placeholder: L("Room ID"), text: $typed, onSubmit: addTyped)
                    Button(L("Add"), action: addTyped)
                        .assignedSettingsButtonStyle(.secondary, size: .compact)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addTyped() {
        let id = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if !selection.contains(id) { selection.append(id) }
        typed = ""
    }
}

struct ChannelRoomPickerPopover: View {
    @Environment(\.theme) private var theme

    let title: String
    let confirmTitle: String
    let rooms: ChannelRoomChoices
    let onDone: ([String]) -> Void
    let onCancel: () -> Void

    @State private var anyRoom: Bool
    @State private var selection: [String]

    init(
        title: String, confirmTitle: String, rooms: ChannelRoomChoices, initial: [String],
        onDone: @escaping ([String]) -> Void, onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.rooms = rooms
        self.onDone = onDone
        self.onCancel = onCancel
        _anyRoom = State(initialValue: initial.isEmpty)
        _selection = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)
            ChannelRoomSelection(rooms: rooms, anyRoom: $anyRoom, selection: $selection)
            HStack {
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { onDone(anyRoom ? [] : selection) }
                    .assignedSettingsButtonStyle(.primary, size: .compact)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!anyRoom && selection.isEmpty)
            }
        }
        .padding(theme.space.s16)
        .frame(width: 320)
    }
}

// MARK: - Add rule

struct ChannelAddRulePopover: View {
    @Environment(\.theme) private var theme

    let rooms: ChannelRoomChoices
    let onAdd: (ChannelAgentRoster.Target, [String]) -> Void
    let onCancel: () -> Void

    @State private var targetId = ""
    @State private var anyRoom = true
    @State private var selection: [String] = []

    private var agents: [Agent] { AgentManager.shared.agents.filter { !$0.isBuiltIn } }
    private var workflows: [InstalledWorkflow] { InstalledWorkflowStore.shared.workflows }

    private var selectedWorkflow: InstalledWorkflow? {
        workflows.first { "workflow.\($0.id.uuidString)" == targetId }
    }

    private var target: ChannelAgentRoster.Target? {
        if let agent = agents.first(where: { "agent.\($0.id.uuidString)" == targetId }) {
            return .agent(.local(agent.id))
        }
        if let workflow = workflows.first(where: { "workflow.\($0.id.uuidString)" == targetId }) {
            return .workflow(workflow.id)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a routing rule", bundle: .module)
                .font(SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Who answers", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                Picker("", selection: $targetId) {
                    Text("Choose…", bundle: .module).tag("")
                    if !agents.isEmpty {
                        Section(L("Agents")) {
                            ForEach(agents, id: \.id) { agent in
                                Text(agent.name).tag("agent.\(agent.id.uuidString)")
                            }
                        }
                    }
                    if !workflows.isEmpty {
                        Section(L("Workflows")) {
                            ForEach(workflows) { workflow in
                                Text(workflow.name).tag("workflow.\(workflow.id.uuidString)")
                            }
                        }
                    }
                }
                .assignedPickerPopupPresentation()
                .labelsHidden()
                if agents.isEmpty && workflows.isEmpty {
                    Text("Create an agent or install a workflow first.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
                if let workflow = selectedWorkflow {
                    let unbound = ChannelAgentRoster.unboundRequiredInputs(workflow.definition)
                    if !unbound.isEmpty {
                        Label(
                            L("\(unbound.map(\.label).joined(separator: ", ")) still need a value. After adding, use … → Edit… to bind them."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.status.warning.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if workflow.definition.hasReplyStep {
                        Text("This workflow replies from its own steps.", bundle: .module)
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Where", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                ChannelRoomSelection(rooms: rooms, anyRoom: $anyRoom, selection: $selection)
            }

            Text(
                "Agents reply on their own; workflows post their output, or reply from their own steps. Change it in the table, or use … → Edit for instructions, aliases and filters.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .keyboardShortcut(.cancelAction)
                Button(L("Add Rule")) {
                    if let target { onAdd(target, anyRoom ? [] : selection) }
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil || (!anyRoom && selection.isEmpty))
            }
        }
        .padding(theme.space.s16)
        .frame(width: 340)
    }
}

// MARK: - Posting

/// Agents that may start a message on this channel on their own.
struct ChannelPostingSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var roomDirectory = AgentChannelRoomDirectory.shared
    private var manager = EventManager.shared

    let kind: AgentChannelKind
    let connectionId: String
    let connectionName: String

    @State private var roster = ChannelAgentRoster(rules: [], posting: [])
    @State private var rooms = ChannelRoomChoices(connectionId: "", readable: [], writable: [], label: { $0 })
    @State private var pendingAutonomous: UUID?
    @State private var defaultAgentSheet = false

    init(kind: AgentChannelKind, connectionId: String, connectionName: String? = nil) {
        self.kind = kind
        self.connectionId = connectionId
        self.connectionName = connectionName ?? kind.displayName
    }

    private var canPost: Bool { !rooms.writable.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agents that post on their own", bundle: .module)
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    Text(
                        canPost
                            ? L(
                                "They may start a message in \(rooms.writable.map(rooms.label).joined(separator: ", ")). Replies to incoming messages are set in Routing."
                            )
                            : L("Turn on sending and choose rooms the bot may write to first.")
                    )
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                addMenu
            }

            if !roster.posting.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(roster.posting.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().opacity(0.5) }
                        postingRow(entry)
                    }
                }
                .background(theme.surface.raised)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
            }
        }
        .settingsLandingAnchor("agentChannels.posting")
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .eventsChanged).receive(on: DispatchQueue.main)) { _ in
            reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentChannelConfigurationChanged).receive(on: DispatchQueue.main)
        ) { _ in reload() }
        .onChange(of: roomDirectory.version) { _, _ in reload() }
        .sheet(isPresented: $defaultAgentSheet, onDismiss: reload) {
            AgentChannelDefaultAgentPostingSheet().themedAlertSheetHost()
        }
        .themedAlert(
            L("Let the agent post without asking?"),
            isPresented: Binding(get: { pendingAutonomous != nil }, set: { if !$0 { pendingAutonomous = nil } }),
            message: L(
                "The agent will send messages to \(connectionName) on its own, without a confirmation from you. Room allowlists, rate limits, and the global Sending switch still apply."
            ),
            primaryButton: .primary(L("Allow Auto-send")) {
                if let agentId = pendingAutonomous { setPosting(.autonomous, agentId: agentId) }
                pendingAutonomous = nil
            },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .window
        )
    }

    private func postingRow(_ entry: ChannelAgentRoster.AgentPosting) -> some View {
        let agent = AgentManager.shared.agent(for: entry.agentId)
        return HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .glyphSize(12)
                .foregroundColor(theme.text.secondary)
            Text(agent?.name ?? L("Missing agent"))
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if agent?.isBuiltIn == true {
                Button(L("Edit places…")) { defaultAgentSheet = true }
                    .buttonStyle(.plain)
                    .textStyle(.footnote, weight: 500)
                    .foregroundColor(theme.text.link)
            }
            if entry.posting == .withoutAsking {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(SettingsFont.glyphSmall)
                    .foregroundColor(theme.status.warning.foreground)
            }
            SettingsMenuPicker(
                selection: Binding(
                    get: { entry.posting },
                    set: { choose($0, agentId: entry.agentId, current: entry.posting) }
                )
            ) {
                ForEach(ChannelAgentRoster.Posting.choices, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .disabled(!canPost)
            .help(L("Asks first shows you each message before it is sent."))
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    private var addMenu: some View {
        SettingsMenuButton(.tertiary, "Add Agent", icon: "plus", size: .compact) {
            let present = Set(roster.posting.map(\.agentId))
            let agents = AgentManager.shared.agents.filter { !present.contains($0.id) }
            if agents.isEmpty {
                Text("Every agent is already listed", bundle: .module)
            }
            ForEach(agents, id: \.id) { agent in
                Button(agent.name) { setPosting(.confirm, agentId: agent.id) }
            }
        }
        .disabled(!canPost)
        .settingsLandingAnchor("agentChannels.addPostingAgent")
    }

    private func reload() {
        rooms = ChannelRoomChoices.live(connectionId: connectionId)
        roster = ChannelAgentRoster.build(
            events: manager.events(kind: kind, connectionId: connectionId),
            bindings: AgentChannelAutoDestinationResolver.effectiveConfiguration().bindings,
            connectionId: connectionId,
            writableRoomIds: rooms.writable
        )
    }

    private func choose(_ choice: ChannelAgentRoster.Posting, agentId: UUID, current: ChannelAgentRoster.Posting) {
        guard choice != current else { return }
        if choice == .withoutAsking {
            pendingAutonomous = agentId
        } else if let mode = choice.outboundMode {
            setPosting(mode, agentId: agentId)
        }
    }

    private func setPosting(_ mode: AgentChannelBindingOutboundMode, agentId: UUID) {
        let connectionManager = AgentChannelConnectionManager.shared
        let stored = connectionManager.loadConfiguration().bindings
        let plan = ChannelAgentRoster.postingBindings(
            mode: mode, agentId: agentId, connectionId: connectionId, connectionName: connectionName,
            writableRoomIds: rooms.writable, stored: stored)
        do {
            for binding in plan {
                let original = stored.first { $0.id == binding.id }?.id
                try connectionManager.upsertBinding(binding, replacingOriginalId: original)
            }
        } catch {
            _ = ToastManager.shared.error(L("Couldn't update this place"), message: error.localizedDescription)
        }
        reload()
    }
}
