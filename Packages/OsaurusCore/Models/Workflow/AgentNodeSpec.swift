//
//  AgentNodeSpec.swift
//  osaurus
//
//  Agent steps: hand one task to another agent and take its answer. The
//  agent is one of this Mac's, or a teammate's agent shared into a
//  workspace, which runs on the teammate's Mac (and bills to it). Only the
//  rendered task text travels; the agent works with its own model, tools,
//  and permissions, and the step sees its final answer.
//

import Foundation

public struct AgentNodeSpec: Codable, Equatable, Sendable {
    /// The agent's name as the author saw it: a local agent's name, or a
    /// shared agent's display name.
    public var agent: String
    /// Set for a teammate's shared agent: the workspace it is shared into
    /// and its address. Nil for an agent on the running Mac.
    public var workspace: WorkspaceAgentRef?
    /// What to ask the agent. A template string is rendered first.
    public var task: String

    public init(agent: String, workspace: WorkspaceAgentRef? = nil, task: String = "") {
        self.agent = agent
        self.workspace = workspace
        self.task = task
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        workspace = try c.decodeIfPresent(WorkspaceAgentRef.self, forKey: .workspace)
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agent, forKey: .agent)
        try c.encodeIfPresent(workspace, forKey: .workspace)
        try c.encode(task, forKey: .task)
    }

    enum CodingKeys: String, CodingKey { case agent, workspace, task }

    public var requirement: AgentRequirement { AgentRequirement(name: agent, workspace: workspace) }

    public static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object(["type": .string("string")]),
            "agent": .object(["type": .string("string")]),
            "session_id": .object(["type": .string("string")]),
            "needs_input": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("text"), .string("agent")]),
    ])
}

/// An agent a workflow's agent steps hand work to. Bound per Mac: an
/// installer may point it at another of their agents
/// (`InstallBindings.agents`).
public struct AgentRequirement: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var workspace: WorkspaceAgentRef?

    public init(name: String, workspace: WorkspaceAgentRef? = nil) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspace = workspace
    }

    /// The binding key: a shared agent by its workspace and address, a
    /// local agent by name.
    public var id: String {
        if let workspace { return "workspace:\(workspace.key.lowercased())" }
        return "local:\(name.lowercased())"
    }

    public var isShared: Bool { workspace != nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            workspace: try c.decodeIfPresent(WorkspaceAgentRef.self, forKey: .workspace))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(workspace, forKey: .workspace)
    }

    enum CodingKeys: String, CodingKey { case name, workspace }
}
