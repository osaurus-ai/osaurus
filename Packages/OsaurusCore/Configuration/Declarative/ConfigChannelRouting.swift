//
//  ConfigChannelRouting.swift
//  osaurus
//
//  `channels.<platform>.routing` and `channels.<platform>.posting`: the
//  same two lists a channel's sheet shows under Routing and Sending.
//
//  A routing rule IS a channel automation. Each one compiles to an
//  `EventEntry` and goes through `ConfigEvents.build` / `plan` / `apply`,
//  scoped to its channel (`ConfigEventScope`), so validation is identical
//  to the editor's and `prune` only touches the declared channel.
//
//  Posting rows are the agent's stored destination bindings on the
//  connection, written with `ChannelAgentRoster.postingBindings` like the
//  Sending section. `without_asking` is a flagged risk.
//

import Foundation

// MARK: - Document entries

/// One routing rule: who answers which messages on a channel.
public struct ChannelRoutingRuleEntry: Codable, Equatable, Sendable {
    /// Match key (case-insensitive), unique across every automation.
    public var name: String
    public var enabled: Bool?
    public var agent: String?
    public var workflow: String?
    /// Room / channel / chat ids. Empty = any room the bot reads.
    public var rooms: [String]?
    public var aliases: [String]?
    public var requireMention: Bool?
    public var continueThreads: Bool?
    /// Agents: automatic | approval. Workflows: automatic | none.
    public var replies: String?
    public var instructions: String?
    public var workingFolder: String?
    public var freshSession: Bool?
    public var input: [String: String]?
    public var filter: EventFilterEntry?
    public var delivery: EventDeliveryEntry?
    /// `reply:` carried over from a translated `channel_message` automation.
    var legacyReply: EventReplyEntry?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, enabled, agent, workflow, rooms, aliases
        case requireMention = "require_mention"
        case continueThreads = "continue_threads"
        case replies, instructions
        case workingFolder = "working_folder"
        case freshSession = "fresh_session"
        case input, filter, delivery
    }

    /// The automation this rule describes on `kind` / `connection`.
    func eventEntry(kind: AgentChannelKind, connection: String?) -> EventEntry {
        var entry = EventEntry(name: name)
        entry.enabled = enabled
        var source = EventSourceEntry(kind: EventSourceKind.channelMessage.rawValue)
        source.platform = kind.rawValue
        source.connection = connection
        source.rooms = rooms
        source.aliases = aliases
        source.requireMention = requireMention
        source.continueThreads = continueThreads
        entry.source = source
        entry.agent = agent
        entry.workflow = workflow
        entry.instructions = instructions
        entry.workingFolder = workingFolder
        entry.freshSession = freshSession
        entry.input = input
        entry.filter = filter
        entry.delivery = delivery
        entry.reply = legacyReply
        entry.replies = replies
        return entry
    }

    /// A rule from a legacy `channel_message` automation entry.
    init(legacy entry: EventEntry) {
        name = entry.name
        enabled = entry.enabled
        agent = entry.agent
        workflow = entry.workflow
        rooms = entry.source?.rooms
        aliases = entry.source?.aliases
        requireMention = entry.source?.requireMention
        continueThreads = entry.source?.continueThreads
        instructions = entry.instructions
        workingFolder = entry.workingFolder
        freshSession = entry.freshSession
        input = entry.input
        filter = entry.filter
        delivery = entry.delivery
        legacyReply = entry.reply
    }
}

/// Whether one agent may post on a channel on its own.
public struct ChannelPostingEntry: Codable, Equatable, Sendable {
    /// Custom agent name, or `default` for the Default agent.
    public var agent: String
    /// off | ask_first | without_asking (HIGH RISK).
    public var mode: String?
    /// Writable room ids this row sets. Omitted = every writable room.
    public var rooms: [String]?

    public init(agent: String, mode: String? = nil, rooms: [String]? = nil) {
        self.agent = agent
        self.mode = mode
        self.rooms = rooms
    }
}

// MARK: - Scope

/// The stored events one list in the document owns: `automations`
/// (schedules, folders, webhooks) or one channel's `routing`.
@MainActor
struct ConfigEventScope {
    /// Plan / apply section.
    let section: String
    /// Document path used in issues, e.g. `channels.slack.routing`.
    let path: String
    let noun: String
    /// Prefix for plan / apply targets ("slack routing").
    let targetPrefix: String?
    let owns: @MainActor (OsaurusEvent) -> Bool
    /// The event flattened in this list's vocabulary, for plan diffs.
    let row: @MainActor (OsaurusEvent) -> [String: String]
    /// One line for a create: what it is and what it runs.
    let createSummary: @MainActor (OsaurusEvent, _ agentShown: String?) -> String

    func target(_ name: String) -> String {
        targetPrefix.map { "\($0): \(name)" } ?? name
    }

    static let automations = ConfigEventScope(
        section: ConfigEvents.section, path: "automations", noun: "automation", targetPrefix: nil,
        // Retired email automations are left alone: never exported, never pruned.
        owns: { $0.sourceKind != .channelMessage && $0.sourceKind != .email },
        row: { ConfigEvents.flatten(ConfigEvents.export($0)) },
        createSummary: { event, agent in
            let entry = ConfigEvents.export(event)
            return "create \(event.sourceKind.rawValue) automation running "
                + (entry.workflow.map { "workflow `\($0)`" } ?? "agent `\(agent ?? entry.agent ?? "?")`")
        })

    static func routing(kind: AgentChannelKind, connectionId: String, path: String, label: String)
        -> ConfigEventScope
    {
        let normalized = AgentChannelConnection.normalizedId(connectionId)
        return ConfigEventScope(
            section: "channels", path: path, noun: "routing rule", targetPrefix: "\(label) routing",
            owns: { event in
                guard let source = event.source.channelMessage else { return false }
                return source.kind == kind && AgentChannelConnection.normalizedId(source.connectionId) == normalized
            },
            row: { ConfigEvents.flatten(ConfigChannelRouting.exportRule($0)) },
            createSummary: { event, agent in
                ConfigChannelRouting.summary(of: ConfigChannelRouting.exportRule(event), agentShown: agent)
            })
    }

    /// "automation `Daily`" / "Slack routing rule `Triage`", for messages.
    static func describe(_ event: OsaurusEvent) -> String {
        if let source = event.source.channelMessage {
            return "\(source.kind.displayName) routing rule `\(event.name)`"
        }
        return "\(event.sourceKind.rawValue) automation `\(event.name)`"
    }
}

// MARK: - Routing

@MainActor
enum ConfigChannelRouting {
    /// One declared `routing` list, compiled. `scope` is nil (with `issue`)
    /// when the connection it names does not exist.
    struct Scoped {
        var scope: ConfigEventScope?
        var entries: [EventEntry]
        var issue: String?
    }

    /// Every `routing` list the document declares, platforms first.
    static func scopes(in document: OsaurusConfigDocument) -> [Scoped] {
        guard let channels = document.channels else { return [] }
        var out: [Scoped] = []
        for target in ConfigChannelPlatform.targets(in: channels) {
            guard let rules = target.section.routing else { continue }
            let kind = target.platform.kind
            let path = "\(target.path).routing"
            guard target.isPrimary || ChannelAccounts.account(connectionId: target.connectionId)?.kind == kind else {
                out.append(Scoped(scope: nil, entries: [], issue: ConfigChannelAccounts.unknownAccountIssue(target)))
                continue
            }
            out.append(
                Scoped(
                    scope: .routing(kind: kind, connectionId: target.connectionId, path: path, label: target.label),
                    entries: rules.map { $0.eventEntry(kind: kind, connection: target.connectionId) }))
        }
        let known = AgentChannelConfigurationStore.load().connections
        for entry in channels.connections ?? [] {
            guard let rules = entry.routing else { continue }
            let key = entry.connection.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = "channels.connections[\(entry.connection)].routing"
            guard
                let connection = known.first(where: {
                    $0.id == key || $0.name.caseInsensitiveCompare(key) == .orderedSame
                })
            else {
                out.append(
                    Scoped(
                        scope: nil, entries: [],
                        issue: "channels.connections[\(entry.connection)]: no n8n or custom HTTP connection with "
                            + "this name or id. Connections are created in Settings → Channels."))
                continue
            }
            out.append(
                Scoped(
                    scope: .routing(
                        kind: connection.kind, connectionId: connection.id, path: path,
                        label: connection.name.isEmpty ? connection.id : connection.name),
                    entries: rules.map { $0.eventEntry(kind: connection.kind, connection: connection.id) }))
        }
        return out
    }

    // MARK: Export

    /// Rules on one connection, in routing order (aliases, rooms, any room).
    static func exportRules(
        kind: AgentChannelKind, connectionId: String, events: [OsaurusEvent] = EventManager.shared.events
    ) -> [ChannelRoutingRuleEntry] {
        let scope = ConfigEventScope.routing(kind: kind, connectionId: connectionId, path: "", label: "")
        func rank(_ event: OsaurusEvent) -> Int {
            guard let source = event.source.channelMessage else { return 3 }
            if !source.aliases.isEmpty { return 0 }
            return source.roomIds.isEmpty ? 2 : 1
        }
        return events.filter(scope.owns)
            .sorted { lhs, rhs in
                rank(lhs) == rank(rhs) ? lhs.name.lowercased() < rhs.name.lowercased() : rank(lhs) < rank(rhs)
            }
            .map(exportRule)
    }

    static func exportRule(_ event: OsaurusEvent) -> ChannelRoutingRuleEntry {
        let full = ConfigEvents.export(event)
        var rule = ChannelRoutingRuleEntry(name: event.name)
        rule.enabled = event.isEnabled
        rule.agent = full.agent
        rule.workflow = full.workflow
        rule.input = full.input
        rule.filter = full.filter
        if let source = event.source.channelMessage {
            rule.rooms = source.roomIds.isEmpty ? nil : source.roomIds
            rule.aliases = source.aliases.isEmpty ? nil : source.aliases
            if ChannelMessageSourceConfig.supportsMentions(source.kind) { rule.requireMention = source.requireMention }
            if !source.continueThreads { rule.continueThreads = false }
        }
        switch event.action {
        case .agent(let action):
            rule.replies = event.reply.autoReply ? "automatic" : "approval"
            rule.instructions = action.instructions.isEmpty ? nil : action.instructions
            rule.workingFolder = action.folderPath
            if action.freshSessionPerFire != AgentEventAction.defaultFreshSession(for: .channelMessage) {
                rule.freshSession = action.freshSessionPerFire
            }
        case .workflow:
            rule.replies = event.reply.replyWithWorkflowOutput ? "automatic" : "none"
        case .prompt:
            break
        }
        if event.delivery != EventDeliveryPolicy.defaults(for: .channelMessage) { rule.delivery = full.delivery }
        return rule
    }

    /// "create routing rule: agent `Triage` answers in C1, C2 (replies after approval)".
    static func summary(of rule: ChannelRoutingRuleEntry, agentShown: String?) -> String {
        let who = rule.workflow.map { "workflow `\($0)`" } ?? "agent `\(agentShown ?? rule.agent ?? "?")`"
        var whereText = (rule.rooms ?? []).isEmpty ? "in any room" : "in \((rule.rooms ?? []).joined(separator: ", "))"
        if let aliases = rule.aliases, !aliases.isEmpty {
            whereText += " for messages starting with \(aliases.map { "“\($0)”" }.joined(separator: " or "))"
        }
        let replies: String
        switch rule.replies {
        case "automatic": replies = rule.workflow == nil ? "replies automatically" : "posts the output"
        case "none": replies = "doesn't reply"
        default: replies = "replies after approval"
        }
        return "create routing rule: \(who) answers \(whereText) (\(replies))"
    }

    // MARK: Automatic replies need writable rooms

    /// The channel sheet's save check, for documents: every room a rule
    /// replies in automatically must be writable once the document applies.
    /// Runs only for platforms the document touches, so an unrelated edit
    /// is never blocked by the current state.
    static func autoReplyIssues(
        in document: OsaurusConfigDocument, prune: Bool, events: [OsaurusEvent] = EventManager.shared.events
    ) -> [String] {
        var issues: [String] = []
        for target in ConfigChannelPlatform.targets(in: document.channels) {
            let section = target.section
            let platform = target.platform
            guard section.routing != nil || section.hasPolicyKeys else { continue }
            let scope = ConfigEventScope.routing(
                kind: platform.kind, connectionId: target.connectionId, path: "", label: "")
            let live = events.filter(scope.owns)
            let declared = section.routing ?? []
            let declaredNames = Set(declared.map { $0.name.lowercased() })
            var rules: [ChannelAgentRoster.ReplyingRule] = []
            if !(prune && section.routing != nil) {
                rules += ChannelAgentRoster.replyingRules(live.filter { !declaredNames.contains($0.name.lowercased()) })
            }
            for rule in declared {
                let existing = live.first { $0.name.caseInsensitiveCompare(rule.name) == .orderedSame }
                rules.append(replyingRule(rule, existing: existing))
            }
            let readable = AgentChannelConnection.normalizedIds(
                section.readAllowlist ?? platform.snapshot(connectionId: target.connectionId).readAllowlist)
            let missing = ChannelAgentRoster.autoReplyRoomsNotWritable(
                rules, readable: readable,
                writable: ConfigChannelPosting.writableRooms(target, desired: section))
            guard !missing.isEmpty else { continue }
            guard platform.hasWriteAllowlist else {
                issues.append(
                    "\(target.path).routing: automatic replies need `write_enabled: true` — turn it on, "
                        + "or set the rules to `replies: approval`.")
                continue
            }
            issues.append(
                "\(target.path).routing: automatic replies need "
                    + "\(missing.joined(separator: ", ")) in write_allowlist (with write_enabled: true) — add them, "
                    + "or set the rules that answer there to `replies: approval`.")
        }
        return issues
    }

    private static func replyingRule(
        _ rule: ChannelRoutingRuleEntry, existing: OsaurusEvent?
    ) -> ChannelAgentRoster.ReplyingRule {
        let isWorkflow = rule.workflow != nil || (rule.agent == nil && existing?.action.kind == .workflow)
        let replies: Bool
        if let value = rule.replies?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            replies = value == "automatic"
        } else if let legacy = rule.legacyReply {
            replies = (isWorkflow ? legacy.workflowOutput : legacy.autoReply) ?? false
        } else if let existing {
            replies = isWorkflow ? existing.reply.replyWithWorkflowOutput : existing.reply.autoReply
        } else {
            replies = false
        }
        return ChannelAgentRoster.ReplyingRule(
            roomIds: rule.rooms ?? existing?.source.channelMessage?.roomIds ?? [],
            isEnabled: rule.enabled ?? existing?.isEnabled ?? true,
            replies: replies)
    }
}

// MARK: - Posting

@MainActor
enum ConfigChannelPosting {
    static let modes = ["off", "ask_first", "without_asking"]

    static func mode(_ raw: String) -> AgentChannelBindingOutboundMode? {
        switch raw.lowercased() {
        case "off": .off
        case "ask_first": .confirm
        case "without_asking": .autonomous
        default: nil
        }
    }

    static func name(of binding: AgentChannelBinding) -> String {
        guard binding.enabled else { return "off" }
        switch binding.outboundMode {
        case .off: return "off"
        case .draft, .confirm: return "ask_first"
        case .autonomous: return "without_asking"
        }
    }

    /// Rooms the bot may post in on `platform`, with the document's own
    /// `write_enabled` / `write_allowlist` taking effect first.
    static func writableRooms(_ target: ConfigChannelTarget, desired: ChannelPlatformSection?) -> [String] {
        writableRooms(target.platform, connectionId: target.connectionId, desired: desired)
    }

    static func writableRooms(
        _ platform: ConfigChannelPlatform, connectionId: String? = nil, desired: ChannelPlatformSection?
    ) -> [String] {
        let snapshot = platform.snapshot(connectionId: connectionId)
        let enabled = desired?.writeEnabled ?? snapshot.writeEnabled
        guard enabled else { return [] }
        guard platform.hasWriteAllowlist else {
            return AgentChannelConnection.normalizedIds(desired?.readAllowlist ?? snapshot.readAllowlist)
        }
        return AgentChannelConnection.normalizedIds(desired?.writeAllowlist ?? snapshot.writeAllowlist)
    }

    static func storedBindings(connectionId: String) -> [AgentChannelBinding] {
        let normalized = AgentChannelConnection.normalizedId(connectionId)
        return AgentChannelConnectionManager.shared.loadConfiguration().bindings
            .filter { AgentChannelConnection.normalizedId($0.connectionId) == normalized }
    }

    static func agentName(_ id: UUID) -> String? {
        if id == Agent.defaultId { return "default" }
        return AgentManager.shared.agents.first { $0.id == id && !$0.isBuiltIn }?.name
    }

    static func liveAgentId(_ value: String) -> UUID? {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default" { return Agent.defaultId }
        return AgentManager.shared.agents.first {
            !$0.isBuiltIn && $0.name.caseInsensitiveCompare(value) == .orderedSame
        }?.id
    }

    // MARK: Export

    /// Stored posting rows, one per agent and mode. `rooms` is omitted when
    /// a row covers every writable room.
    static func export(_ platform: ConfigChannelPlatform, connectionId: String? = nil) -> [ChannelPostingEntry] {
        let connectionId = connectionId ?? platform.primaryConnectionId
        let writable = Set(writableRooms(platform, connectionId: connectionId, desired: nil))
        var byAgent: [String: [String: [String]]] = [:]
        for binding in storedBindings(connectionId: connectionId) {
            guard let agent = agentName(binding.agentId) else { continue }
            byAgent[agent, default: [:]][name(of: binding), default: []].append(binding.roomId)
        }
        var out: [ChannelPostingEntry] = []
        for agent in byAgent.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            let modes = byAgent[agent] ?? [:]
            for mode in modes.keys.sorted() {
                let rooms = AgentChannelConnection.normalizedIds(modes[mode] ?? []).sorted()
                let coversAll = modes.count == 1 && !writable.isEmpty && Set(rooms) == writable
                out.append(ChannelPostingEntry(agent: agent, mode: mode, rooms: coversAll ? nil : rooms))
            }
        }
        return out
    }

    // MARK: Desired state

    /// (agent key, room) → mode for one platform's `posting`, or issues.
    struct Desired {
        var rows: [(agent: String, room: String, mode: AgentChannelBindingOutboundMode)] = []
        var issues: [String] = []
    }

    static func desired(
        _ entries: [ChannelPostingEntry], platform: ConfigChannelPlatform, path: String? = nil,
        writable: [String], agentExists: (String) -> Bool
    ) -> Desired {
        var out = Desired()
        var seen = Set<String>()
        let label = "\(path ?? "channels.\(platform.rawValue)").posting"
        for entry in entries {
            let item = "\(label)[\(entry.agent)]"
            guard agentExists(entry.agent) else {
                out.issues.append(
                    "\(item): no custom agent named `\(entry.agent)` exists or is created by this document "
                        + "(use `default` for the Default agent).")
                continue
            }
            guard let raw = entry.mode, let mode = mode(raw) else {
                out.issues.append("\(item).mode: must be one of: \(modes.joined(separator: ", ")).")
                continue
            }
            let rooms = entry.rooms.map(AgentChannelConnection.normalizedIds) ?? writable
            if mode != .off {
                if writable.isEmpty {
                    out.issues.append(
                        "\(item): \(platform.rawValue) cannot post yet — set `write_enabled: true` and list the rooms "
                            + "in `write_allowlist`.")
                    continue
                }
                let outside = rooms.filter { !writable.contains($0) }
                if !outside.isEmpty {
                    out.issues.append(
                        "\(item).rooms: \(outside.joined(separator: ", ")) not in `write_allowlist` — the bot may "
                            + "only post in writable rooms.")
                    continue
                }
            }
            for room in rooms {
                let key = "\(entry.agent.lowercased())|\(room)"
                if !seen.insert(key).inserted {
                    out.issues.append("\(item): room \(room) is set twice for this agent.")
                    continue
                }
                out.rows.append((entry.agent, room, mode))
            }
        }
        return out
    }

    // MARK: Plan

    static func validate(
        _ entries: [ChannelPostingEntry], target: ConfigChannelTarget,
        agentNames: Set<String>, into issues: inout [String]
    ) {
        let result = desired(
            entries, platform: target.platform, path: target.path,
            writable: writableRooms(target, desired: target.section),
            agentExists: { exists($0, agentNames: agentNames) })
        issues += result.issues
    }

    static func exists(_ agent: String, agentNames: Set<String>) -> Bool {
        agent.lowercased() == "default" || agentNames.contains(agent.lowercased())
    }

    static func plan(
        _ entries: [ChannelPostingEntry], target: ConfigChannelTarget,
        agentNames: Set<String>, prune: Bool, into actions: inout [ConfigPlanAction]
    ) {
        let platform = target.platform
        let result = desired(
            entries, platform: platform, path: target.path,
            writable: writableRooms(target, desired: target.section),
            agentExists: { exists($0, agentNames: agentNames) })
        guard result.issues.isEmpty else { return }
        let stored = storedBindings(connectionId: target.connectionId)
        func current(_ agent: String, _ room: String) -> AgentChannelBinding? {
            guard let id = liveAgentId(agent) else { return nil }
            return stored.first { $0.agentId == id && $0.roomId == room }
        }
        var linesByAgent: [String: [String]] = [:]
        var risky = Set<String>()
        for row in result.rows {
            let before = current(row.agent, row.room).map(name(of:)) ?? "(automatic)"
            let after = name(for: row.mode)
            guard before != after else { continue }
            linesByAgent[row.agent, default: []].append("\(row.room): \(before) -> \(after)")
            if row.mode == .autonomous { risky.insert(row.agent) }
        }
        if prune {
            let keep = Set(result.rows.compactMap { row in liveAgentId(row.agent).map { "\($0)|\(row.room)" } })
            for binding in stored where !keep.contains("\(binding.agentId)|\(binding.roomId)") {
                let agent = agentName(binding.agentId) ?? binding.agentId.uuidString
                linesByAgent[agent, default: []].append(
                    "\(binding.roomId): \(name(of: binding)) -> (automatic; stored setting removed)")
            }
        }
        for agent in linesByAgent.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            actions.append(
                ConfigPlanAction(
                    section: "channels", target: "\(target.label) posting: \(agent)", kind: .update,
                    changes: linesByAgent[agent] ?? [],
                    risks: risky.contains(agent) ? [ConfigRisk.channelAutonomousPosting(agent, platform.rawValue)] : []))
        }
    }

    static func name(for mode: AgentChannelBindingOutboundMode) -> String {
        switch mode {
        case .off: "off"
        case .draft, .confirm: "ask_first"
        case .autonomous: "without_asking"
        }
    }

    // MARK: Apply

    static func apply(
        _ entries: [ChannelPostingEntry], target: ConfigChannelTarget, prune: Bool
    ) -> [ConfigApplyResult] {
        let platform = target.platform
        let connectionId = target.connectionId
        let label = target.label
        let result = desired(
            entries, platform: platform, path: target.path,
            writable: writableRooms(target, desired: nil),
            agentExists: { liveAgentId($0) != nil })
        guard result.issues.isEmpty else {
            return [
                ConfigApplyResult(
                    section: "channels", target: "\(label) posting", status: .failed,
                    message: result.issues.joined(separator: " "))
            ]
        }
        let manager = AgentChannelConnectionManager.shared
        let displayName = ChannelAccounts.displayName(connectionId: connectionId) ?? platform.kind.displayName
        var results: [ConfigApplyResult] = []
        var keep = Set<String>()
        let grouped = Dictionary(grouping: result.rows) { "\($0.agent.lowercased())|\(name(for: $0.mode))" }
        for key in grouped.keys.sorted() {
            guard let rows = grouped[key], let first = rows.first, let agentId = liveAgentId(first.agent) else {
                continue
            }
            let stored = manager.loadConfiguration().bindings
            let plan = ChannelAgentRoster.postingBindings(
                mode: first.mode, agentId: agentId, connectionId: connectionId, connectionName: displayName,
                writableRoomIds: rows.map(\.room), stored: stored)
            do {
                for binding in plan {
                    try manager.upsertBinding(binding, replacingOriginalId: stored.first { $0.id == binding.id }?.id)
                    keep.insert("\(agentId)|\(binding.roomId)")
                }
                results.append(
                    ConfigApplyResult(section: "channels", target: "\(label) posting: \(first.agent)", status: .done))
            } catch {
                results.append(
                    ConfigApplyResult(
                        section: "channels", target: "\(label) posting: \(first.agent)", status: .failed,
                        message: error.localizedDescription))
            }
        }
        if prune {
            for binding in storedBindings(connectionId: connectionId)
            where !keep.contains("\(binding.agentId)|\(binding.roomId)") {
                do {
                    try manager.deleteBinding(id: binding.id)
                } catch {
                    results.append(
                        ConfigApplyResult(
                            section: "channels", target: "\(label) posting", status: .failed,
                            message: error.localizedDescription))
                }
            }
        }
        return results
    }
}
