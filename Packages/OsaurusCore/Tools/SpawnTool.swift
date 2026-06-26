//
//  SpawnTool.swift
//  osaurus
//
//  `spawn(agent, input)` — the portable subagent primitive. Resolves a
//  user-configured, spawnable Agent persona, runs a bounded text subagent on its
//  model (with the local-orchestrator residency handoff when needed), and returns
//  only a compact digest. Default OFF; each agent opts in from its Sub-agents tab
//  (`spawnableAgentNames`). See docs/SUBAGENT_PORTABLE_DESIGN.md.
//

import Foundation

public final class SpawnTool: OsaurusTool, @unchecked Sendable {
    public let name = "spawn"
    public let description =
        "Spawn a bounded subagent: hand a task to a user-configured agent persona by name and get back "
        + "only a compact result. Use to offload bounded text/coding/analysis subtasks to a local or "
        + "remote model the user has marked spawnable. The subagent transcript is not returned."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "agent": .object([
                "type": .string("string"),
                "description": .string("Name of a spawnable agent persona (e.g. \"sparky\")."),
            ]),
            "input": .object([
                "type": .string("string"),
                "description": .string("The task/query for the subagent."),
            ]),
        ]),
        "required": .array([.string("agent"), .string("input")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = requireString(args, "agent", expected: "a spawnable agent name", tool: name)
        guard case .value(let agentName) = agentReq else { return agentReq.failureEnvelope ?? "" }
        let inputReq = requireString(args, "input", expected: "the task for the subagent", tool: name)
        guard case .value(let input) = inputReq else { return inputReq.failureEnvelope ?? "" }

        // The shared host owns the recursion guard, live feed, permission
        // verdict, residency handoff, compact-result normalization, and
        // telemetry; the kind owns model resolution + the bounded text loop.
        return await SubagentSession.run(
            TextSubagentKind(agentName: agentName, input: input),
            tool: name
        )
    }
}
