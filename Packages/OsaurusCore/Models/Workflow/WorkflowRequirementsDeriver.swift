//
//  WorkflowRequirementsDeriver.swift
//  osaurus
//
//  Requirements follow the graph. A node that uses a model slot, a secret,
//  an MCP or plugin tool, network access, or an image/video model adds the
//  matching requirement;
//  removing the node removes it. Declarations on the definition (slot
//  preferences, secret labels, notes) only annotate what the graph needs.
//

import Foundation

public enum WorkflowRequirementsDeriver {

    public static func derive(_ def: WorkflowDefinition) -> TemplateRequirements {
        var slotOrder: [String] = []
        var agenticSlots = Set<String>()
        var secretKeys: [String] = []
        var servers: [String] = []
        var plugins: [String] = []
        var hosts: [String] = []
        var tools: [String] = []
        var mediaModels: [MediaModelRequirement] = []
        var agents: [AgentRequirement] = []

        func appendUnique(_ value: String, to list: inout [String]) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { return }
            list.append(trimmed)
        }

        func addTool(_ tool: ToolRef) {
            if let s = tool.server { appendUnique(s, to: &servers) }
            if let p = tool.plugin { appendUnique(p, to: &plugins) }
            if tool.server == nil && tool.plugin == nil { appendUnique(tool.name, to: &tools) }
        }

        func visit(_ node: WorkflowNode) {
            switch node.kind {
            case .inference(let spec):
                appendUnique(spec.modelSlot, to: &slotOrder)
                if case .agentic(let refs, _) = spec.mode {
                    agenticSlots.insert(spec.modelSlot)
                    refs.forEach(addTool)
                }
            case .code(let spec):
                for key in spec.secrets { appendUnique(key, to: &secretKeys) }
                for host in spec.network { appendUnique(host.lowercased(), to: &hosts) }
                // Python runs through the shell tool in the sandbox.
                if spec.language == .python { appendUnique("shell_run", to: &tools) }
            case .tool(let spec):
                addTool(spec.tool)
            case .http(let spec):
                for key in spec.secretKeys { appendUnique(key, to: &secretKeys) }
                for host in spec.hosts { appendUnique(host, to: &hosts) }
            case .map(let spec):
                visit(spec.body(parentID: node.id))
            case .media(let spec):
                let req = MediaModelRequirement(action: spec.action, model: spec.model)
                if !mediaModels.contains(where: { $0.id == req.id }) { mediaModels.append(req) }
            case .agent(let spec):
                let req = spec.requirement
                if !req.name.isEmpty, !agents.contains(where: { $0.id == req.id }) { agents.append(req) }
            case .dialog, .wait, .workflow, .state, .reply, nil:
                break
            }
        }
        def.nodes.forEach(visit)

        let models = slotOrder.map { slot -> ModelRequirement in
            var req = def.modelSlots.first { $0.slot == slot } ?? ModelRequirement(slot: slot)
            if agenticSlots.contains(slot) { req.needsToolUse = true }
            return req
        }
        let secrets = secretKeys.map { key in
            def.secrets.first { $0.key == key } ?? SecretRequirement(key: key)
        }
        return TemplateRequirements(
            models: models,
            secrets: secrets,
            mcpServers: servers,
            plugins: plugins,
            permissions: [],
            network: hosts,
            tools: tools,
            dependencies: def.dependencies,
            folders: def.folders,
            mediaModels: mediaModels,
            agents: agents,
            notes: def.requirementNotes
        )
    }

    // MARK: - Sub-workflows

    /// What runs when this workflow runs, including the installed workflows
    /// its `workflow` steps call, followed to the same depth and with the
    /// same cycle rule as the executor. Resolved on this Mac, so it is not
    /// part of the sealed template or its hash: `derive(_:)` stays what the
    /// template carries; this is what the setup wizard and import review
    /// show.
    ///
    /// Children's hosts, MCP servers, plugins, and tools are merged into
    /// `requirements`: the parent reaches them transitively. Children's
    /// models and secrets are not: a sub-workflow runs with its own install
    /// bindings, so listing them on the parent would ask the person to bind
    /// values the child never reads. They are listed per child instead.
    public struct Reach: Equatable, Sendable {
        public var requirements: TemplateRequirements
        public var subworkflows: [Subworkflow]
    }

    public struct Subworkflow: Equatable, Sendable, Identifiable {
        /// As written on the step.
        public var name: String
        /// The step that calls it, or (deeper down) the sub-workflow that
        /// does.
        public var calledFrom: String
        /// The child's own requirements, or nil when nothing installed here
        /// answers to the name.
        public var requirements: TemplateRequirements?
        public var id: String { name.lowercased() }
    }

    public static func reach(_ def: WorkflowDefinition, resolve: (String) -> WorkflowDefinition?) -> Reach {
        var merged = derive(def)
        var children: [Subworkflow] = []
        var seen = Set<String>()

        func appendUnique(_ value: String, to list: inout [String]) {
            guard !list.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
            list.append(value)
        }

        // Breadth-first, so a child shared by several steps is attributed
        // to the nearest one.
        var level: [(def: WorkflowDefinition, via: String?)] = [(def, nil)]
        var depth = 0
        while !level.isEmpty, depth < SubworkflowSpec.maximumDepth {
            var next: [(def: WorkflowDefinition, via: String?)] = []
            for (def, via) in level {
                for (name, step) in def.subworkflowCalls {
                    // Cycles and shared children, once.
                    guard seen.insert(name.lowercased()).inserted else { continue }
                    let calledFrom = via ?? step
                    guard let child = resolve(name) else {
                        children.append(Subworkflow(name: name, calledFrom: calledFrom, requirements: nil))
                        continue
                    }
                    let own = derive(child)
                    children.append(Subworkflow(name: name, calledFrom: calledFrom, requirements: own))
                    own.network.forEach { appendUnique($0, to: &merged.network) }
                    own.mcpServers.forEach { appendUnique($0, to: &merged.mcpServers) }
                    own.plugins.forEach { appendUnique($0, to: &merged.plugins) }
                    own.tools.forEach { appendUnique($0, to: &merged.tools) }
                    own.permissions.forEach { appendUnique($0, to: &merged.permissions) }
                    for media in own.mediaModels where !merged.mediaModels.contains(where: { $0.id == media.id }) {
                        merged.mediaModels.append(media)
                    }
                    next.append((child, name))
                }
            }
            level = next
            depth += 1
        }
        return Reach(requirements: merged, subworkflows: children)
    }
}
