//
//  ChannelsOverviewTable.swift
//  osaurus
//
//  The whole picture on one screen: every connected channel with what it
//  receives, where each message goes, and what agents may send — or the
//  same facts grouped by agent. A row opens that channel's setup.
//

import SwiftUI

struct ChannelOverviewEntry: Identifiable {
    let connectionId: String
    let kind: AgentChannelKind
    let name: String
    let badge: AgentChannelStatusPresentation?
    /// Shown under the name, e.g. pending n8n approvals.
    var note: String?
    /// Stored connections (n8n) switch on and off right in the row.
    var enabledToggle: AgentChannelCardEnabledToggle?
    let open: () -> Void

    var id: String { connectionId }
}

enum ChannelsOverviewGrouping: String, CaseIterable, AnimatedTabItem {
    case byChannel
    case byAgent

    var title: String {
        switch self {
        case .byChannel: L("By channel")
        case .byAgent: L("By agent")
        }
    }
}

struct ChannelsOverviewTable: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var roomDirectory = AgentChannelRoomDirectory.shared
    @ObservedObject private var agentManager = AgentManager.shared

    let entries: [ChannelOverviewEntry]
    let writesEnabled: Bool
    /// The add button on a channel that can hold several accounts.
    var onAddAccount: ((AgentChannelKind) -> Void)?

    @Binding var grouping: ChannelsOverviewGrouping
    @State private var facts: [String: Facts] = [:]

    /// What one connection receives, routes and sends, read from live stores.
    struct Facts {
        var readableRooms: [String]
        var senders: Int
        var writableRooms: [String]
        var writeEnabled: Bool
        var roster: ChannelAgentRoster
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsSectionHeader(title: "Connected")

            Group {
                switch grouping {
                case .byChannel: channelTable
                case .byAgent: agentTable
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
            .settingsChrome(.surface)
        }
        .onAppear(perform: reload)
        .onChange(of: entries.map(\.id)) { _, _ in reload() }
        .onChange(of: roomDirectory.version) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .eventsChanged).receive(on: DispatchQueue.main)) { _ in
            reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentChannelConfigurationChanged).receive(on: DispatchQueue.main)
        ) { _ in reload() }
    }

    // MARK: By channel

    /// One channel's rows: its accounts, or its stored connections.
    struct KindGroup: Identifiable {
        let kind: AgentChannelKind
        let entries: [ChannelOverviewEntry]
        var id: String { kind.rawValue }
    }

    private var groups: [KindGroup] {
        var order: [AgentChannelKind] = []
        var byKind: [AgentChannelKind: [ChannelOverviewEntry]] = [:]
        for entry in entries {
            if byKind[entry.kind] == nil { order.append(entry.kind) }
            byKind[entry.kind, default: []].append(entry)
        }
        return order.map { KindGroup(kind: $0, entries: byKind[$0] ?? []) }
    }

    private func canAdd(_ kind: AgentChannelKind) -> Bool {
        onAddAccount != nil && ChannelAccounts.multiAccountKinds.contains(kind)
    }

    /// Channels that can hold several accounts get a heading with their
    /// add button; a lone iMessage or WhatsApp row needs none.
    private func showsHeading(_ group: KindGroup) -> Bool {
        canAdd(group.kind) || group.entries.count > 1
    }

    private var channelTable: some View {
        VStack(spacing: 0) {
            header([L("Channel"), L("Receives from"), L("Routes to"), L("Sends")])
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { SettingsGroupDivider() }
                if showsHeading(group) {
                    groupHeading(group)
                }
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { rowIndex, entry in
                    if rowIndex > 0 || showsHeading(group) { SettingsGroupDivider() }
                    ChannelOverviewRow(
                        entry: entry, facts: facts[entry.connectionId], writesEnabled: writesEnabled,
                        anchorId: showsHeading(group) ? nil : ChannelOverviewRow.anchorId(entry))
                }
            }
        }
    }

    private func groupHeading(_ group: KindGroup) -> some View {
        HStack(spacing: theme.space.s8) {
            SettingsIconTile(icon: group.kind.icon, size: 18, gradient: group.kind.brandGradient)
            Text(verbatim: group.kind.displayName)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            if group.entries.count > 1 {
                Text(verbatim: "\(group.entries.count)")
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.tertiary)
            }
            Spacer(minLength: theme.space.s8)
            if canAdd(group.kind), let onAddAccount {
                SettingsButton(.tertiary, ChannelAccounts.addTitle(group.kind), icon: "plus", size: .compact) {
                    onAddAccount(group.kind)
                }
                .help(ChannelAccounts.addHelp(group.kind))
                .settingsLandingAnchor(ChannelAccounts.addAnchorId(group.kind))
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s6)
        .background(theme.surface.subtle)
        .settingsLandingAnchor(ChannelOverviewRow.groupAnchorId(group.kind))
    }

    private func header(_ titles: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Text(title.uppercased())
                    .font(SettingsFont.chip)
                    .tracking(0.4)
                    .foregroundColor(theme.text.tertiary)
                    .frame(
                        minWidth: index == 0 ? 150 : 0, maxWidth: index == 0 ? 190 : .infinity, alignment: .leading)
                    // The name column takes its full width first, so status
                    // badges don't truncate; rows use the same priority.
                    .layoutPriority(index == 0 ? 1 : 0)
            }
            Color.clear.frame(width: 10, height: 1)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .background(theme.surface.hover)
    }

    // MARK: By agent

    private var agentTable: some View {
        let rows = ChannelAgentRoster.agentOverview(
            entries.compactMap { entry in facts[entry.connectionId].map { (entry.connectionId, $0.roster) } })
        return VStack(spacing: 0) {
            header([L("Agent"), L("Answers on"), L("Posts on its own")])
            if rows.isEmpty {
                Text(
                    "No agent answers or posts on a channel yet. Open a channel and add a routing rule.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { SettingsGroupDivider() }
                agentRow(row)
            }
        }
    }

    private func agentRow(_ row: ChannelAgentRoster.AgentOverviewRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: row.target.isAgent ? "person.crop.circle" : "point.3.connected.trianglepath.dotted")
                    .glyphSize(12)
                    .foregroundColor(theme.text.secondary)
                Text(ChannelRoutingNames.target(row.target))
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
            }
            .frame(minWidth: 150, maxWidth: 190, alignment: .leading)
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 3) {
                if row.answers.isEmpty {
                    muted(L("—"))
                }
                ForEach(Array(row.answers.enumerated()), id: \.offset) { _, answer in
                    cell(answerText(answer), dimmed: !answer.isEnabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if row.posts.isEmpty {
                    muted(L("—"))
                }
                ForEach(Array(row.posts.enumerated()), id: \.offset) { _, post in
                    cell("\(channelName(post.connectionId)): \(post.posting.label)", dimmed: !writesEnabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: 10, height: 1)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    private func answerText(_ answer: ChannelAgentRoster.AgentOverviewRow.Answers) -> String {
        let label = ChannelRoomChoices.labeler(connectionId: answer.connectionId)
        var text = "\(channelName(answer.connectionId)): \(ChannelRoutingNames.rooms(answer.roomIds, label: label))"
        if !answer.aliases.isEmpty {
            text += " · " + answer.aliases.map { "“\($0)”" }.joined(separator: ", ")
        }
        if !answer.isEnabled { text += " · " + L("off") }
        return text
    }

    private func channelName(_ connectionId: String) -> String {
        ChannelAccounts.displayName(connectionId: connectionId)
            ?? entries.first { $0.connectionId == connectionId }?.name ?? connectionId
    }

    private func cell(_ text: String, dimmed: Bool = false) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.rowDescription)
            .foregroundColor(dimmed ? theme.text.tertiary : theme.text.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func muted(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
    }

    // MARK: Data

    private func reload() {
        var next: [String: Facts] = [:]
        let bindings = AgentChannelAutoDestinationResolver.effectiveConfiguration().bindings
        for entry in entries {
            let view = try? AgentChannelConnectionService.shared.resolvedConnectionView(id: entry.connectionId)
            let writable = ChannelAgentRoster.liveWritableRoomIds(connectionId: entry.connectionId)
            next[entry.connectionId] = Facts(
                readableRooms: view?.readRoomAllowlist ?? [],
                senders: view?.inboundAuthorization.senderAllowlist.count ?? 0,
                writableRooms: view?.writeRoomAllowlist ?? [],
                writeEnabled: view?.writeEnabled ?? false,
                roster: ChannelAgentRoster.build(
                    events: EventManager.shared.events(kind: entry.kind, connectionId: entry.connectionId),
                    bindings: bindings, connectionId: entry.connectionId, writableRoomIds: writable))
        }
        roomDirectory.prepare(connectionIds: entries.map(\.connectionId))
        facts = next
    }
}

/// One channel: name and status, then Receives from / Routes to / Sends.
/// A table row (column-aligned with the header), not a `LibraryRow`.
private struct ChannelOverviewRow: View {
    @Environment(\.theme) private var theme

    let entry: ChannelOverviewEntry
    let facts: ChannelsOverviewTable.Facts?
    let writesEnabled: Bool
    let anchorId: String?

    @State private var isHovering = false

    /// The row's one status: a broken listener first, then the first thing
    /// setup still needs, then the listener's state.
    private var status: AgentChannelStatusPresentation? {
        guard entry.kind != .n8n, entry.kind != .customHTTP, let facts else { return entry.badge }
        if let badge = entry.badge, badge.tone == .error { return badge }
        if facts.readableRooms.isEmpty { return .init(label: L("Needs rooms"), tone: .warning) }
        if facts.senders == 0 { return .init(label: L("Needs people"), tone: .warning) }
        if !facts.roster.rules.contains(where: \.isEnabled) {
            return .init(label: L("No one answers"), tone: .warning)
        }
        return entry.badge
    }

    var body: some View {
        Button(action: entry.open) {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    SettingsIconTile(icon: entry.kind.icon, size: 30, gradient: entry.kind.brandGradient)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: entry.name)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                        if let status {
                            AgentChannelStatusBadge(presentation: status)
                        }
                        if let note = entry.note {
                            Text(verbatim: note)
                                .font(SettingsFont.footnote)
                                .foregroundColor(theme.status.warning.foreground)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(minWidth: 150, maxWidth: 190, alignment: .leading)
                .layoutPriority(1)

                column(receives)
                column(routes)
                column(sends)

                if let toggle = entry.enabledToggle {
                    Toggle("", isOn: Binding(get: { toggle.isOn }, set: { toggle.onChange($0) }))
                        .settingsSwitch()
                        .help(
                            toggle.isOn
                                ? L("Channel enabled — turn off to refuse every request with 403")
                                : L("Channel disabled — turn on to accept requests again"))
                        .settingsLandingAnchor(toggle.anchorId)
                }

                SettingsChevron()
                    .frame(width: 10)
                    .padding(.top, theme.space.s8)
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s12)
            .background(isHovering ? theme.surface.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .settingsLandingAnchor(anchorId)
        .help(L("Open \(entry.name) settings"))
    }

    static func anchorId(_ entry: ChannelOverviewEntry) -> String? {
        switch entry.kind {
        case .n8n: return "agentChannels.n8n"
        case .customHTTP: return nil
        default:
            guard entry.connectionId == entry.kind.rawValue else { return nil }
            return "agentChannels.\(entry.kind.rawValue)"
        }
    }

    static func groupAnchorId(_ kind: AgentChannelKind) -> String? {
        kind == .customHTTP ? nil : "agentChannels.\(kind.rawValue)"
    }

    private func column(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if line.warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .glyphSize(9)
                            .foregroundColor(theme.status.warning.foreground)
                    }
                    Text(verbatim: line.text)
                        .textStyle(.footnote, weight: line.strong ? 500 : 400)
                        .foregroundColor(
                            line.warning
                                ? theme.status.warning.foreground
                                : line.strong ? theme.text.primary : theme.text.secondary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(line.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Line {
        var text: String
        var strong = false
        var warning = false
    }

    private var label: (String) -> String { ChannelRoomChoices.labeler(connectionId: entry.connectionId) }

    private var receives: [Line] {
        guard let facts else { return [] }
        if entry.kind == .n8n {
            return [Line(text: facts.senders == 1 ? L("1 approved workflow") : L("\(facts.senders) approved workflows"))]
        }
        if facts.readableRooms.isEmpty {
            return [Line(text: L("—"))]
        }
        var lines = [Line(text: Self.list(facts.readableRooms.map(label)), strong: true)]
        if facts.senders > 0 {
            lines.append(Line(text: facts.senders == 1 ? L("1 person") : L("\(facts.senders) people")))
        }
        return lines
    }

    private var routes: [Line] {
        guard let facts else { return [] }
        let lines = facts.roster.routingLines()
        let hasScoped = facts.roster.rules.contains { $0.isEnabled && $0.scope != .anyRoom }
        var out: [Line] = []
        for line in lines {
            let who = line.targets.isEmpty ? L("no one") : ChannelRoutingNames.list(line.targets)
            switch line.kind {
            case .alias(let alias): out.append(Line(text: "“\(alias)” → \(who)"))
            case .room(let room): out.append(Line(text: "\(label(room)) → \(who)"))
            case .everywhereElse:
                if line.targets.isEmpty && hasScoped { continue }
                out.append(
                    Line(
                        text: line.targets.isEmpty
                            ? L("—")
                            : (hasScoped ? L("Elsewhere → \(who)") : L("All rooms → \(who)")),
                        strong: !line.targets.isEmpty))
            }
        }
        return Array(out.prefix(4)) + (out.count > 4 ? [Line(text: L("+\(out.count - 4) more"))] : [])
    }

    private var sends: [Line] {
        guard let facts else { return [] }
        if entry.kind == .n8n { return [Line(text: L("Replies to the workflow"))] }
        guard facts.writeEnabled, !facts.writableRooms.isEmpty else { return [Line(text: L("Off"))] }
        var lines = [Line(text: Self.list(facts.writableRooms.map(label)), strong: writesEnabled)]
        if !writesEnabled { lines.append(Line(text: L("Paused (Sending is off)"))) }
        let posting = facts.roster.posting.filter { $0.posting != .off && $0.posting != .unavailable }
        if !posting.isEmpty {
            let names = posting.map { AgentManager.shared.agent(for: $0.agentId)?.name ?? L("Missing agent") }
            lines.append(Line(text: L("Posts: \(names.joined(separator: ", "))")))
        }
        return lines
    }

    static func list(_ items: [String]) -> String {
        items.count <= 3 ? items.joined(separator: ", ") : items.prefix(2).joined(separator: ", ") + " +\(items.count - 2)"
    }
}
