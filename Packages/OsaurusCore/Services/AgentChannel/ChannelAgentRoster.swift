//
//  ChannelAgentRoster.swift
//  osaurus
//
//  The routing picture of one connection: every channel automation as a
//  rule (where, who, how it replies) and, per agent, whether it may post
//  on its own (its posting bindings). Pure: built from events and
//  bindings, so every shape (many agents across many rooms, aliases,
//  post-only agents, mixed posting) is testable without provider
//  services. Writes go through the existing stores.
//

import Foundation

struct ChannelAgentRoster: Equatable, Sendable {
    /// Who a row is about.
    enum Target: Hashable, Sendable {
        case agent(AgentDispatchTarget)
        case workflow(UUID)

        var localAgentId: UUID? {
            if case .agent(let target) = self { return target.localId }
            return nil
        }

        var isAgent: Bool {
            if case .agent = self { return true }
            return false
        }

        var id: String {
            switch self {
            case .agent(.local(let id)): "agent.\(id.uuidString)"
            case .agent(.workspace(let ref)): "agent.ws.\(ref.workspaceId).\(ref.agentAddress)"
            case .workflow(let id): "workflow.\(id.uuidString)"
            }
        }
    }

    /// Whether an agent may post on its own on this connection, summarized
    /// over its effective bindings for the connection's rooms.
    enum Posting: Equatable, Sendable {
        /// Workflows, workspace agents, and connections with no room the
        /// bot may write to.
        case unavailable
        case off
        case askFirst
        case withoutAsking
        /// Rooms disagree (some ask first, some do not).
        case mixed

        var label: String {
            switch self {
            case .unavailable, .off: L("Off")
            case .askFirst: L("Asks first")
            case .withoutAsking: L("Without asking")
            case .mixed: L("Mixed")
            }
        }

        /// The outbound mode "Set posting" writes for this choice; nil for
        /// states that are not choices.
        var outboundMode: AgentChannelBindingOutboundMode? {
            switch self {
            case .off: .off
            case .askFirst: .confirm
            case .withoutAsking: .autonomous
            case .unavailable, .mixed: nil
            }
        }

        static let choices: [Posting] = [.off, .askFirst, .withoutAsking]
    }

    /// Where a rule sits in routing precedence. Mirrors
    /// `EventMatcher.rankChannelEvents`: a message that starts with an
    /// alias goes to the alias rules; otherwise room rules beat any-room
    /// rules.
    enum Scope: Int, Comparable, Sendable {
        case alias
        case room
        case anyRoom

        static func < (lhs: Scope, rhs: Scope) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One channel automation: one row of the Routing table. Every channel
    /// automation is a rule; there is no separate "custom" list.
    struct Rule: Identifiable, Equatable, Sendable {
        var event: OsaurusEvent
        var source: ChannelMessageSourceConfig

        var id: UUID { event.id }
        var target: Target? { ChannelAgentRoster.target(of: event) }
        var roomIds: [String] { source.roomIds }
        var aliases: [String] { source.aliases }
        var requireMention: Bool { source.requireMention }
        var hasFilter: Bool { !event.filter.isEmpty }
        var isEnabled: Bool { event.isEnabled }
        var repliesAutomatically: Bool { event.reply.replies(for: event.action.kind) }
        var scope: Scope {
            if !source.aliases.isEmpty { return .alias }
            return source.roomIds.isEmpty ? .anyRoom : .room
        }
    }

    /// Whether one agent may post on its own on this connection.
    struct AgentPosting: Identifiable, Equatable, Sendable {
        let agentId: UUID
        var posting: Posting
        /// Effective bindings (stored + automatic) for this agent on this
        /// connection.
        var bindings: [AgentChannelBinding]

        var id: UUID { agentId }
    }

    /// Every channel automation on the connection, in routing order
    /// (alias rules, then room rules, then any-room rules).
    var rules: [Rule]
    /// One entry per local agent that answers here or has posting
    /// bindings here.
    var posting: [AgentPosting]

    // MARK: - Build

    /// - Parameters:
    ///   - events: every channel automation on this connection (enabled or not).
    ///   - bindings: the effective posting bindings (stored + automatic) for
    ///     every agent; filtered to `connectionId` here.
    ///   - writableRoomIds: rooms the bot may post in on this connection.
    static func build(
        events: [OsaurusEvent],
        bindings: [AgentChannelBinding],
        connectionId: String,
        writableRoomIds: [String]
    ) -> ChannelAgentRoster {
        let normalizedConnection = AgentChannelConnection.normalizedId(connectionId)
        let rules = events.enumerated()
            .compactMap { offset, event -> (Int, Rule)? in
                guard let source = event.source.channelMessage else { return nil }
                return (offset, Rule(event: event, source: source))
            }
            .sorted { lhs, rhs in
                lhs.1.scope == rhs.1.scope ? lhs.0 < rhs.0 : lhs.1.scope < rhs.1.scope
            }
            .map(\.1)

        let mine = bindings.filter { AgentChannelConnection.normalizedId($0.connectionId) == normalizedConnection }
        var bindingsByAgent: [UUID: [AgentChannelBinding]] = [:]
        for binding in mine { bindingsByAgent[binding.agentId, default: []].append(binding) }

        var order: [UUID] = []
        for rule in rules {
            if let id = rule.target?.localAgentId, !order.contains(id) { order.append(id) }
        }
        for agentId in bindingsByAgent.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !order.contains(agentId) {
            order.append(agentId)
        }

        let canPost = !writableRoomIds.isEmpty
        let posting = order.map { agentId -> AgentPosting in
            let agentBindings = (bindingsByAgent[agentId] ?? []).sorted { $0.roomId < $1.roomId }
            return AgentPosting(
                agentId: agentId,
                posting: canPost || !agentBindings.isEmpty ? postingSummary(agentBindings) : .unavailable,
                bindings: agentBindings)
        }
        return ChannelAgentRoster(rules: rules, posting: posting)
    }

    func posting(for agentId: UUID) -> AgentPosting? {
        posting.first { $0.agentId == agentId }
    }

    static func target(of event: OsaurusEvent) -> Target? {
        switch event.action {
        case .agent(let action):
            guard let target = action.target else { return nil }
            return .agent(target)
        case .workflow(let action):
            return .workflow(action.workflowID)
        case .prompt:
            return nil
        }
    }

    /// Off when nothing usable, Asks first / Without asking when every
    /// usable room agrees, Mixed otherwise.
    static func postingSummary(_ bindings: [AgentChannelBinding]) -> Posting {
        let usable = bindings.filter(\.isUsable)
        guard !usable.isEmpty else { return .off }
        let modes = Set(usable.map(\.outboundMode))
        if modes == [.confirm] || modes == [.draft] { return .askFirst }
        if modes == [.autonomous] { return .withoutAsking }
        return .mixed
    }

    // MARK: - Writes (plans; the caller persists)

    /// A new routing rule: `target` answers messages in `roomIds` (every
    /// room the bot reads when empty) and, for agents, replies on its own.
    /// A workflow's inputs start from the message (`{{text}}`, sender,
    /// room) the way the automation editor prefills them, and its output
    /// is posted unless the workflow replies from its own steps. The name
    /// is unique among `existingNames` because `osaurus_config` matches
    /// automations by name.
    static func newRule(
        kind: AgentChannelKind,
        connectionId: String,
        connectionName: String,
        target: Target,
        targetName: String,
        roomIds: [String] = [],
        roomName: (String) -> String = { $0 },
        existingNames: [String] = [],
        workflowDefinition: WorkflowDefinition? = nil
    ) -> OsaurusEvent {
        let action: EventAction
        var repliesWithOutput = !target.isAgent
        switch target {
        case .agent(let dispatch):
            action = .agent(
                AgentEventAction(
                    target: dispatch, instructions: "",
                    freshSessionPerFire: AgentEventAction.defaultFreshSession(for: .channelMessage)))
        case .workflow(let id):
            let mapping =
                workflowDefinition.map {
                    WorkflowInputBinding.prefill(schema: $0.inputSchema, sourceKind: .channelMessage)
                } ?? [:]
            action = .workflow(WorkflowEventAction(workflowID: id, inputMapping: mapping))
            if workflowDefinition?.hasReplyStep == true { repliesWithOutput = false }
        }
        let rooms = AgentChannelConnection.normalizedIds(roomIds)
        let base =
            rooms.isEmpty
            ? L("\(targetName) on \(connectionName)")
            : L("\(targetName) in \(rooms.map(roomName).joined(separator: ", ")) on \(connectionName)")
        return OsaurusEvent(
            name: uniqueName(base, among: existingNames),
            source: .channelMessage(ChannelMessageSourceConfig(kind: kind, connectionId: connectionId, roomIds: rooms)),
            action: action,
            reply: EventReplyPolicy(autoReply: target.isAgent, replyWithWorkflowOutput: repliesWithOutput)
        )
    }

    /// Required workflow inputs a new rule's prefill leaves unbound: each
    /// fails every run until bound under Edit….
    static func unboundRequiredInputs(_ definition: WorkflowDefinition) -> [DialogField] {
        let mapping = WorkflowInputBinding.prefill(schema: definition.inputSchema, sourceKind: .channelMessage)
        return WorkflowInputBinding.missingRequired(
            fields: WorkflowFormFields.fields(fromInputSchema: definition.inputSchema), mapping: mapping)
    }

    /// A copy of `event` scoped to other rooms: "Duplicate for another room".
    static func duplicate(
        _ event: OsaurusEvent, roomIds: [String], roomName: (String) -> String = { $0 },
        connectionName: String, targetName: String, existingNames: [String]
    ) -> OsaurusEvent? {
        guard var source = event.source.channelMessage else { return nil }
        source.roomIds = AgentChannelConnection.normalizedIds(roomIds)
        let base =
            source.roomIds.isEmpty
            ? L("\(targetName) on \(connectionName)")
            : L("\(targetName) in \(source.roomIds.map(roomName).joined(separator: ", ")) on \(connectionName)")
        return OsaurusEvent(
            name: uniqueName(base, among: existingNames),
            isEnabled: event.isEnabled,
            source: .channelMessage(source),
            filter: event.filter,
            action: event.action,
            delivery: event.delivery,
            reply: event.reply,
            parameters: event.parameters)
    }

    /// `event` answering in `roomIds` instead (empty = any room).
    static func withRooms(_ event: OsaurusEvent, roomIds: [String]) -> OsaurusEvent {
        guard var source = event.source.channelMessage else { return event }
        source.roomIds = AgentChannelConnection.normalizedIds(roomIds)
        var updated = event
        updated.source = .channelMessage(source)
        return updated
    }

    /// `base`, or `base 2`, `base 3`, … when taken (case-insensitive).
    static func uniqueName(_ base: String, among names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// The stored bindings that set `agentId`'s posting on every writable
    /// room to `mode`. A room that already has a stored binding keeps its
    /// id, label, guidance and rate policy; new rooms get a fresh binding.
    /// Written through `AgentChannelConnectionManager.upsertBinding`, these
    /// suppress the automatic ask-first bindings for the same rooms.
    static func postingBindings(
        mode: AgentChannelBindingOutboundMode,
        agentId: UUID,
        connectionId: String,
        connectionName: String,
        writableRoomIds: [String],
        stored: [AgentChannelBinding]
    ) -> [AgentChannelBinding] {
        let normalizedConnection = AgentChannelConnection.normalizedId(connectionId)
        let rooms = AgentChannelConnection.normalizedIds(writableRoomIds)
        return rooms.map { roomId in
            if var existing = stored.first(where: {
                $0.agentId == agentId && $0.connectionId == normalizedConnection && $0.roomId == roomId
            }) {
                existing.outboundMode = mode
                existing.enabled = true
                return existing
            }
            return AgentChannelBinding(
                id: placeBindingId(connectionId: normalizedConnection, roomId: roomId, agentId: agentId),
                agentId: agentId,
                connectionId: normalizedConnection,
                roomId: roomId,
                label: "\(connectionName) · \(roomId)",
                allowedSources: AgentChannelBindingRunSource.allCases,
                outboundMode: mode,
                enabled: true
            )
        }
    }

    /// Stable id for a binding the channel sheet materializes. Distinct
    /// from the `auto-` prefix so it is never badged "Automatic".
    static func placeBindingId(connectionId: String, roomId: String, agentId: UUID) -> String {
        let agentSuffix = agentId.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return AgentChannelBinding.normalizedBindingId("place-\(connectionId)-\(roomId)-\(agentSuffix)")
    }
}

// MARK: - Per-agent presence (Agents → agent → Channels)

extension ChannelAgentRoster {
    /// One read-only line for an agent's Channels tab: how it takes part
    /// on this connection, or nil when it does not. Mirrors the row the
    /// channel sheet shows, in words: "answers, replies automatically,
    /// posts after asking first".
    func presenceDetail(for agentId: UUID, roomName: (String) -> String = { $0 }) -> String? {
        let mine = rules.filter { $0.target?.localAgentId == agentId }
        let enabled = mine.filter(\.isEnabled)
        let agentPosting = posting(for: agentId)
        var parts: [String] = []

        if !enabled.isEmpty {
            if enabled.contains(where: { $0.scope == .anyRoom }) {
                parts.append(L("answers"))
            } else {
                let rooms = AgentChannelConnection.normalizedIds(enabled.flatMap(\.roomIds))
                let aliases = Array(Set(enabled.flatMap(\.aliases).map { $0.lowercased() })).sorted()
                if !rooms.isEmpty {
                    parts.append(L("answers in \(rooms.map(roomName).joined(separator: ", "))"))
                } else {
                    parts.append(L("answers to \(aliases.map { "“\($0)”" }.joined(separator: ", "))"))
                }
            }
            let auto = enabled.filter(\.repliesAutomatically).count
            if auto == enabled.count {
                parts.append(L("replies automatically"))
            } else if auto == 0 {
                parts.append(L("replies after your approval"))
            } else {
                parts.append(L("replies depend on the rule"))
            }
        } else if !mine.isEmpty {
            parts.append(L("answering is off"))
        }
        switch agentPosting?.posting {
        case .askFirst: parts.append(L("posts after asking first"))
        case .withoutAsking: parts.append(L("posts without asking"))
        case .mixed: parts.append(L("posts (settings differ by room)"))
        case .off, .unavailable, .none: break
        }

        guard !parts.isEmpty else { return mine.isEmpty && agentPosting == nil ? nil : L("Not active here") }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

// MARK: - By agent (Channels overview)

extension ChannelAgentRoster {
    /// One agent or workflow across every channel: where it answers and
    /// where it may post on its own.
    struct AgentOverviewRow: Identifiable, Equatable, Sendable {
        struct Answers: Equatable, Sendable {
            let connectionId: String
            /// Empty = any room.
            let roomIds: [String]
            let aliases: [String]
            let isEnabled: Bool
        }

        struct Posts: Equatable, Sendable {
            let connectionId: String
            let posting: Posting
        }

        let target: Target
        var answers: [Answers]
        var posts: [Posts]

        var id: String { target.id }
    }

    /// Every target on any of `rosters`, in first-seen order.
    static func agentOverview(_ rosters: [(connectionId: String, roster: ChannelAgentRoster)]) -> [AgentOverviewRow] {
        var rows: [Target: AgentOverviewRow] = [:]
        var order: [Target] = []
        func row(_ target: Target) -> AgentOverviewRow {
            if let existing = rows[target] { return existing }
            order.append(target)
            return AgentOverviewRow(target: target, answers: [], posts: [])
        }
        for (connectionId, roster) in rosters {
            for rule in roster.rules {
                guard let target = rule.target else { continue }
                var entry = row(target)
                entry.answers.append(
                    .init(
                        connectionId: connectionId, roomIds: rule.roomIds, aliases: rule.aliases,
                        isEnabled: rule.isEnabled))
                rows[target] = entry
            }
            for posting in roster.posting where posting.posting != .unavailable && posting.posting != .off {
                let target = Target.agent(.local(posting.agentId))
                var entry = row(target)
                entry.posts.append(.init(connectionId: connectionId, posting: posting.posting))
                rows[target] = entry
            }
        }
        return order.compactMap { rows[$0] }
    }
}

// MARK: - Routing explanation

extension ChannelAgentRoster {
    /// One line of the plain-language routing summary under the table.
    struct RoutingLine: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Messages that start with this alias.
            case alias(String)
            /// Messages in this room.
            case room(String)
            /// Every other room the bot reads.
            case everywhereElse
        }

        var kind: Kind
        /// Who answers, in table order; empty means nobody.
        var targets: [Target]
        /// Some of the rules only answer when the bot is mentioned.
        var mentionOnly: Bool
    }

    /// Something in the routing a person would want to know before a
    /// message gets lost or answered twice.
    enum RoutingWarning: Equatable, Sendable {
        /// No enabled rule: messages wait in the inbox.
        case nobodyAnswers
        /// No any-room rule, and these readable rooms have no room rule.
        case uncoveredRooms([String])
        /// Several targets answer the same message.
        case severalAnswer(RoutingLine.Kind, [Target])
        /// A rule's agent or workflow is missing.
        case missingTarget(UUID)
    }

    /// "Messages starting with “sales”: Sales. In #support: Triage, Ops.
    /// Everywhere else: Dinoki." Enabled rules only.
    func routingLines() -> [RoutingLine] {
        let enabled = rules.filter(\.isEnabled)
        var lines: [RoutingLine] = []

        var aliasOrder: [String] = []
        var aliasRules: [String: [Rule]] = [:]
        for rule in enabled where rule.scope == .alias {
            for alias in rule.aliases {
                let key = alias.lowercased()
                if aliasRules[key] == nil { aliasOrder.append(key) }
                aliasRules[key, default: []].append(rule)
            }
        }
        for alias in aliasOrder {
            let matched = aliasRules[alias] ?? []
            lines.append(line(.alias(alias), matched))
        }

        var roomOrder: [String] = []
        var roomRules: [String: [Rule]] = [:]
        for rule in enabled where rule.scope == .room {
            for room in rule.roomIds {
                if roomRules[room] == nil { roomOrder.append(room) }
                roomRules[room, default: []].append(rule)
            }
        }
        for room in roomOrder {
            lines.append(line(.room(room), roomRules[room] ?? []))
        }

        lines.append(line(.everywhereElse, enabled.filter { $0.scope == .anyRoom }))
        return lines
    }

    func routingWarnings(readableRoomIds: [String]) -> [RoutingWarning] {
        var warnings: [RoutingWarning] = []
        for rule in rules where rule.isEnabled && rule.target == nil {
            warnings.append(.missingTarget(rule.id))
        }
        let enabled = rules.filter { $0.isEnabled && $0.target != nil }
        guard !enabled.isEmpty else { return warnings + [.nobodyAnswers] }

        let lines = routingLines()
        // Mentions name the one bot, so a mention-only line still wakes every
        // agent on it.
        for line in lines where line.targets.count > 1 {
            warnings.append(.severalAnswer(line.kind, line.targets))
        }
        let everywhere = lines.first { $0.kind == .everywhereElse }
        if everywhere?.targets.isEmpty ?? true {
            let covered = Set(enabled.filter { $0.scope == .room }.flatMap(\.roomIds))
            let uncovered = AgentChannelConnection.normalizedIds(readableRoomIds).filter { !covered.contains($0) }
            if !uncovered.isEmpty { warnings.append(.uncoveredRooms(uncovered)) }
        }
        return warnings
    }

    private func line(_ kind: RoutingLine.Kind, _ matched: [Rule]) -> RoutingLine {
        var targets: [Target] = []
        for rule in matched {
            if let target = rule.target, !targets.contains(target) { targets.append(target) }
        }
        return RoutingLine(
            kind: kind, targets: targets,
            mentionOnly: !matched.isEmpty && matched.allSatisfy(\.requireMention))
    }
}

// MARK: - Live

extension ChannelAgentRoster {
    /// The roster for a connection from live stores. Main-actor because
    /// `EventManager.shared` is.
    @MainActor
    static func live(kind: AgentChannelKind, connectionId: String) -> ChannelAgentRoster {
        build(
            events: EventManager.shared.events(kind: kind, connectionId: connectionId),
            bindings: AgentChannelAutoDestinationResolver.effectiveConfiguration().bindings,
            connectionId: connectionId,
            writableRoomIds: liveWritableRoomIds(connectionId: connectionId)
        )
    }

    /// Rooms the bot may post in, from the same resolved view the publish
    /// path enforces. Empty for connections that cannot send (n8n, custom).
    static func liveWritableRoomIds(connectionId: String) -> [String] {
        guard let view = try? AgentChannelConnectionService.shared.resolvedConnectionView(id: connectionId),
            view.writeEnabled
        else { return [] }
        return view.writeRoomAllowlist
    }

    // MARK: Automatic replies need writable rooms

    /// One rule as far as replying goes: its rooms (empty = any room the bot
    /// reads), whether it is on, and whether its result goes back.
    struct ReplyingRule: Equatable, Sendable {
        var roomIds: [String]
        var isEnabled: Bool
        var replies: Bool
    }

    static func replyingRules(_ events: [OsaurusEvent]) -> [ReplyingRule] {
        events.map { event in
            let rooms: [String]
            if case .channelMessage(let source) = event.source { rooms = source.roomIds } else { rooms = [] }
            return ReplyingRule(
                roomIds: rooms, isEnabled: event.isEnabled, replies: event.reply.replies(for: event.action.kind))
        }
    }

    /// Rooms where an enabled rule replies automatically but the bot cannot
    /// post. A rule for any room needs every readable room. The channel
    /// sheets and `osaurus_config` both refuse such a setup.
    static func autoReplyRoomsNotWritable(
        _ rules: [ReplyingRule], readable: [String], writable: [String]
    ) -> [String] {
        let write = Set(AgentChannelConnection.normalizedIds(writable))
        var needed: [String] = []
        for rule in rules where rule.isEnabled && rule.replies {
            needed += rule.roomIds.isEmpty ? readable : rule.roomIds
        }
        return AgentChannelConnection.normalizedIds(needed).filter { !write.contains($0) }
    }
}
