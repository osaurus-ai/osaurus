//
//  AgentWrapperCatalog.swift
//  osaurus
//
//  Every agent the Orchestrator may hand work to is a one-node workflow: a custom agent on its Allowed subagents list, and
//  each built-in worker. A wrapper takes one `task` string and runs one
//  `agent` step, so `run_workflow` and the run feed treat agents and
//  workflows alike.
//
//  Wrappers are derived on every read from the agents and the pool, so an
//  agent added, renamed, or removed (or dropped from the pool) changes them
//  at once; the id is stable per agent. They are never stored: the
//  Workflows UI, `osaurus_config`, `osaurus_inspect`, the Architect,
//  pickers, automations, and HTTP/MCP listings read `InstalledWorkflowStore`
//  and never see one. `RoutableWorkflowCatalog` and `run_workflow` are the
//  only readers.
//

import CryptoKit
import Foundation

struct AgentWrapper: Sendable, Equatable {
    /// Stable per agent (`AgentWrapperCatalog.id(forAgent:)`).
    let id: UUID
    let agentID: UUID
    let name: String
    let summary: String

    var worker: BuiltInWorker? { BuiltInWorker.worker(for: agentID) }

    var doc: RoutableWorkflowDoc {
        RoutableWorkflowDoc(
            id: id.uuidString, name: name, summary: summary,
            inputs: [.init(name: AgentWrapperCatalog.taskInput, type: "string", required: true)], kind: .wrapper)
    }

    /// The wrapper as an in-memory install, the shape `WorkflowRunService`
    /// starts. A custom agent's step is bound to the agent by id, so a
    /// rename or a second agent with the same name can't redirect it.
    var installed: InstalledWorkflow {
        let spec = AgentNodeSpec(agent: name, task: "{{input.\(AgentWrapperCatalog.taskInput)}}")
        let definition = WorkflowDefinition(
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    AgentWrapperCatalog.taskInput: .object([
                        "type": .string("string"),
                        "description": .string("What to ask \(name), in the user's words."),
                    ])
                ]),
                "required": .array([.string(AgentWrapperCatalog.taskInput)]),
            ]),
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string")]),
                    "needs_input": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("text")]),
            ]),
            nodes: [WorkflowNode(id: AgentWrapperCatalog.nodeID, name: name, kind: .agent(spec))],
            output: .object([
                "text": "{{nodes.\(AgentWrapperCatalog.nodeID).output.text}}",
                "needs_input": "{{nodes.\(AgentWrapperCatalog.nodeID).output.needs_input}}",
            ]))
        let template = Template(id: id, name: name, summary: summary, payload: .workflow(definition))
        let bindings =
            worker == nil
            ? InstallBindings(agents: [spec.requirement.id: agentID.uuidString])
            : InstallBindings()
        return InstalledWorkflow(id: id, template: template, bindings: bindings, orchestratorVisible: true)
    }
}

enum AgentWrapperCatalog {
    static let taskInput = "task"
    static let nodeID = "agent"

    private static let namespace = UUID(uuidString: "6f1c2a8e-3d4b-5e6f-8a9b-0c1d2e3f4a5b")!

    /// The wrapper id for an agent: a name-based (v5) UUID, the same on
    /// every launch and every Mac.
    static func id(forAgent agentID: UUID) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes += Array("wrapper:\(agentID.uuidString.lowercased())".utf8)
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
            ))
    }

    /// A wrapper left out because something else already answers to its
    /// name: a custom agent named like a worker, or an installed workflow
    /// or hosted link named like a wrapper.
    struct Shadowed: Sendable, Equatable {
        enum By: String, Sendable { case agent, workflow }
        /// The name both sides use.
        let name: String
        let by: By
        /// The worker left out, when it is one (a custom agent's wrapper
        /// can only be shadowed by a workflow).
        let worker: BuiltInWorker?

        var row: [String: Any] {
            var row: [String: Any] = ["name": name, "shadowed_by": by.rawValue]
            if let worker { row["worker"] = worker.displayName }
            return row
        }

        var logLine: String {
            let lost = worker.map { "the built-in \($0.displayName) worker" } ?? "the agent wrapper"
            let kept = by == .agent ? "custom agent" : "workflow"
            return "[AgentWrapperCatalog] \(kept) \"\(name)\" shadows \(lost); `run_workflow` \"\(name)\" runs the \(kept)"
        }
    }

    struct Listing: Sendable {
        var wrappers: [AgentWrapper]
        var shadowed: [Shadowed]
    }

    /// Wrappers for `agents` that the Orchestrator's pool allows, then the
    /// built-in workers. A custom agent whose name a worker uses keeps it;
    /// that worker is left out. So is a worker whose teammate is wrapped
    /// (Scout for Research, Builder for Code): the teammate takes its asks,
    /// and the worker returns once the teammate is gone, or, for Research,
    /// once Scout cannot search.
    static func wrappers(agents: [Agent], config: SubagentConfiguration) -> [AgentWrapper] {
        listing(agents: agents, config: config).wrappers
    }

    /// `wrappers(agents:config:)` plus the workers a custom agent shadows.
    static func listing(agents: [Agent], config: SubagentConfiguration) -> Listing {
        var superseded = Set<BuiltInWorker>()
        var team = Set<Teammate>()
        var out: [AgentWrapper] = agents.compactMap { agent in
            guard !agent.isBuiltIn, !Agent.isHiddenBuiltIn(agent.id),
                AgentNodeExecutor.isAllowed(
                    .local(agent.id, name: agent.name), isDefault: true, config: config, settings: nil)
            else { return nil }
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            if let teammate = agent.teammate { team.insert(teammate) }
            if let worker = agent.supersededWorker { superseded.insert(worker) }
            return AgentWrapper(
                id: id(forAgent: agent.id), agentID: agent.id, name: name, summary: agent.description)
        }
        let taken = Dictionary(out.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        var shadowed: [Shadowed] = []
        for worker in BuiltInWorker.allCases {
            if let name = taken[worker.displayName.lowercased()] {
                shadowed.append(Shadowed(name: name, by: .agent, worker: worker))
                continue
            }
            if superseded.contains(worker) { continue }
            out.append(
                AgentWrapper(
                    id: id(forAgent: worker.agentId), agentID: worker.agentId, name: worker.displayName,
                    summary: worker.summary(beside: team)))
        }
        return Listing(wrappers: out, shadowed: shadowed)
    }

    /// The live wrappers.
    @MainActor
    static func live() -> [AgentWrapper] { liveListing().wrappers }

    @MainActor
    static func liveListing() -> Listing {
        listing(agents: AgentManager.shared.agents, config: SubagentConfigurationStore.snapshot())
    }

    /// Logs each shadowing once per process, when it first appears.
    @MainActor private static var loggedShadows: Set<String> = []

    @MainActor
    static func logNewShadows(_ shadowed: [Shadowed]) {
        for entry in shadowed where loggedShadows.insert("\(entry.by.rawValue):\(entry.name.lowercased())").inserted {
            print(entry.logLine)
        }
    }

    /// The wrapper `run_workflow` names: exact name first, then a
    /// case-insensitive match.
    @MainActor
    static func wrapper(named key: String) -> AgentWrapper? {
        let all = live()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.name == trimmed }
            ?? all.first { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    /// Whether `id` names a wrapper (current or past: the id is derived
    /// from an agent id, so this checks every agent this Mac knows and
    /// every worker).
    @MainActor
    static func isWrapperID(_ id: UUID) -> Bool {
        BuiltInWorker.allCases.contains { Self.id(forAgent: $0.agentId) == id }
            || AgentManager.shared.agents.contains { Self.id(forAgent: $0.id) == id }
    }

    /// Why a config document's workflow reference (an agent's `workflows`, an
    /// automation's `workflow`) cannot be `raw`; nil when `raw` names no
    /// wrapper. Checked only once `raw` matched no installed workflow.
    @MainActor
    static func configRefusal(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isWrapper = UUID(uuidString: trimmed).map(isWrapperID) ?? (wrapper(named: trimmed) != nil)
        guard isWrapper else { return nil }
        return "`\(trimmed)` is an agent Osaurus hands work to, not an installed workflow; "
            + "only installed workflows can be used here."
    }
}
