//
//  TemplateDiff.swift
//  osaurus
//
//  What changed between two versions of a template: identity, the payload
//  (workflow nodes, edges, and schemas through `WorkflowDiff`; agent entry
//  fields by key), and requirements. Version History shows it; the update
//  flow uses `newRequirements` to ask only about what is new.
//

import Foundation

public enum TemplateDiff {
    public static func changes(from old: Template, to new: Template) -> [WorkflowDiff.Change] {
        var out: [WorkflowDiff.Change] = []
        if old.name != new.name {
            out.append(.init(kind: .changed, subject: "name", fields: [], before: old.name, after: new.name))
        }
        if (old.summary ?? "") != (new.summary ?? "") {
            out.append(.init(kind: .changed, subject: "summary", fields: [], before: old.summary, after: new.summary))
        }
        switch (old.workflow, new.workflow) {
        case (let a?, let b?):
            out += WorkflowDiff.changes(from: a, to: b)
        case (nil, nil):
            out += agentChanges(from: old, to: new)
        default:
            out.append(.init(kind: .changed, subject: "kind", fields: [], before: old.kind.rawValue, after: new.kind.rawValue))
        }
        out += requirementChanges(from: old.requirements, to: new.requirements)
        return out
    }

    /// Agent entries compared field by field on their JSON form.
    static func agentChanges(from old: Template, to new: Template) -> [WorkflowDiff.Change] {
        guard case .object(let a) = encoded(old.agent), case .object(let b) = encoded(new.agent) else { return [] }
        let keys = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
        guard !keys.isEmpty else { return [] }
        return [
            .init(
                kind: .changed, subject: "agent", fields: keys,
                before: WorkflowDiff.pretty(old.agent), after: WorkflowDiff.pretty(new.agent))
        ]
    }

    public static func requirementChanges(from old: TemplateRequirements, to new: TemplateRequirements)
        -> [WorkflowDiff.Change]
    {
        var out: [WorkflowDiff.Change] = []
        func lists(_ label: String, _ a: [String], _ b: [String]) {
            for item in b where !a.contains(item) {
                out.append(.init(kind: .added, subject: "\(label) \(item)", fields: []))
            }
            for item in a where !b.contains(item) {
                out.append(.init(kind: .removed, subject: "\(label) \(item)", fields: []))
            }
        }
        let oldSlots = Dictionary(old.models.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        let newSlots = Dictionary(new.models.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        for slot in new.models {
            if let before = oldSlots[slot.slot] {
                if before != slot {
                    out.append(
                        .init(
                            kind: .changed, subject: "model slot \(slot.slot)", fields: slotFields(before, slot),
                            before: WorkflowDiff.pretty(before), after: WorkflowDiff.pretty(slot)))
                }
            } else {
                out.append(.init(kind: .added, subject: "model slot \(slot.slot)", fields: []))
            }
        }
        for slot in old.models where newSlots[slot.slot] == nil {
            out.append(.init(kind: .removed, subject: "model slot \(slot.slot)", fields: []))
        }
        lists("secret", old.secrets.map(\.key), new.secrets.map(\.key))
        lists("MCP server", old.mcpServers, new.mcpServers)
        lists("plugin", old.plugins, new.plugins)
        lists("permission", old.permissions, new.permissions)
        lists("network host", old.network, new.network)
        lists("knowledge", old.knowledge, new.knowledge)
        if old.workingFolder != new.workingFolder {
            out.append(
                .init(
                    kind: .changed, subject: "working folder", fields: [], before: old.workingFolder?.path,
                    after: new.workingFolder?.path))
        }
        return out
    }

    private static func slotFields(_ a: ModelRequirement, _ b: ModelRequirement) -> [String] {
        var fields: [String] = []
        if a.preferred != b.preferred { fields.append("preferred") }
        if a.strictness != b.strictness { fields.append("strictness") }
        if a.locality != b.locality { fields.append("locality") }
        if a.needsToolUse != b.needsToolUse { fields.append("needs_tool_use") }
        if a.minContext != b.minContext { fields.append("min_context") }
        return fields
    }

    /// Requirements an update must ask about: slots that are new or whose
    /// constraints changed, and secrets, servers, plugins, and permissions
    /// the old version did not need. Everything else keeps its binding.
    public struct NewRequirements: Equatable, Sendable {
        public var slots: Set<String> = []
        public var secrets: Set<String> = []
        public var mcpServers: Set<String> = []
        public var plugins: Set<String> = []
        public var permissions: Set<String> = []
        public var network: [String] = []
        /// Built-in tools the old version did not call.
        public var tools: Set<String> = []
        /// Package managers with new or changed packages (`WorkflowDependency.id`).
        public var dependencies: Set<String> = []
        /// Declared folder keys the old version did not have.
        public var folders: Set<String> = []
        /// Agents (`AgentRequirement.id`) the old version did not ask.
        public var agents: Set<String> = []

        public var isEmpty: Bool {
            slots.isEmpty && secrets.isEmpty && mcpServers.isEmpty && plugins.isEmpty && permissions.isEmpty
                && network.isEmpty && tools.isEmpty && dependencies.isEmpty && folders.isEmpty && agents.isEmpty
        }

        /// The new version reaches further than the pinned one: new hosts,
        /// tools, servers, plugins, or system permissions. Secrets the old
        /// version held are asked for again so the person confirms they may
        /// travel there.
        public var widensAccess: Bool {
            !network.isEmpty || !tools.isEmpty || !mcpServers.isEmpty || !plugins.isEmpty || !permissions.isEmpty
        }

        public func contains(_ item: SetupItem) -> Bool {
            switch item.kind {
            case .model: return slots.contains(item.value)
            case .secret: return secrets.contains(item.value)
            case .mcpServer: return mcpServers.contains(item.value)
            case .plugin: return plugins.contains(item.value)
            case .systemPermission: return permissions.contains(item.value)
            case .dependency: return dependencies.contains(item.value)
            case .folder: return folders.contains(item.value)
            case .agent: return agents.contains(item.value)
            default: return true
            }
        }
    }

    public static func newRequirements(from old: TemplateRequirements, to new: TemplateRequirements)
        -> NewRequirements
    {
        let oldSlots = Dictionary(old.models.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        var out = NewRequirements()
        for slot in new.models {
            guard let before = oldSlots[slot.slot] else {
                out.slots.insert(slot.slot)
                continue
            }
            if before.strictness != slot.strictness || before.locality != slot.locality
                || before.needsToolUse != slot.needsToolUse || before.minContext != slot.minContext
                || before.preferred != slot.preferred
            {
                out.slots.insert(slot.slot)
            }
        }
        out.secrets = Set(new.secrets.map(\.key)).subtracting(old.secrets.map(\.key))
        out.mcpServers = Set(new.mcpServers).subtracting(old.mcpServers)
        out.plugins = Set(new.plugins).subtracting(old.plugins)
        out.permissions = Set(new.permissions).subtracting(old.permissions)
        out.network = new.network.filter { !old.network.contains($0) }
        out.tools = Set(new.tools).subtracting(old.tools)
        for dependency in new.dependencies {
            let before = old.dependencies.first { $0.manager == dependency.manager }
            if before == nil || !Set(dependency.packages).isSubset(of: Set(before?.packages ?? [])) {
                out.dependencies.insert(dependency.id)
            }
        }
        out.folders = Set(new.folders.map(\.key)).subtracting(old.folders.map(\.key))
        out.agents = Set(new.agents.map(\.id)).subtracting(old.agents.map(\.id))
        return out
    }

    private static func encoded<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .null }
        return json
    }
}
