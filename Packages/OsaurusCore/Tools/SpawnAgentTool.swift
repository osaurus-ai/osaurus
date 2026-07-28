//
//  SpawnAgentTool.swift
//  osaurus
//
//  `spawn_agent(input, agent)` — delegate a task to a user-configured agent
//  (its system prompt + model). Runs a bounded text subagent on the agent's
//  model (with the local-orchestrator residency handoff when needed)
//  and returns only a compact digest. Sibling of `spawn_model`, which delegates
//  to a bare model with no agent. Default OFF; each agent opts in from its
//  Subagents tab (`spawnableAgentIDs`). See docs/SUBAGENT_PORTABLE_DESIGN.md.
//

import Foundation

public final class SpawnAgentTool: OsaurusTool, @unchecked Sendable {
    public let name = SubagentCapabilityRegistry.spawnAgentToolName
    public let description =
        "Delegate a bounded subtask to a user-configured agent (runs on the target agent's own "
        + "system prompt + model, local or remote) and get back only a compact result digest — the "
        + "subagent transcript is not returned. The worker receives only the target agent's enabled "
        + "tools whose concrete implementations are cancellation-audited for spawned execution; "
        + "other direct-chat tools remain parent-owned. The target agent must be in this agent's "
        + "spawnable list. Use `spawn_model` instead to hand a task to a bare model with no agent "
        + "attached."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "input": .object([
                "type": .string("string"),
                "description": .string(SpawnInputContract.schemaDescription),
            ]),
            "agent": .object([
                "type": .string("string"),
                "description": .string(
                    "UUID of a spawnable agent. Copy the exact UUID from the configured target list."
                ),
            ]),
        ]),
        "required": .array([.string("input"), .string("agent")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    public init() {}

    /// Narrow the request-local schema to the launching agent's currently
    /// runnable agent pool. Execution still enforces the durable allow-list;
    /// this enum is exact identity guidance and provider-side validation.
    static func constrainedSpec(_ tool: Tool, allowedAgentIDs: [UUID]) -> Tool {
        let normalized = SpawnableAgentIdentity.normalizedIDs(allowedAgentIDs)
            .map(\.uuidString)
        guard !normalized.isEmpty,
            case .object(var root)? = tool.function.parameters,
            case .object(var properties)? = root["properties"],
            case .object(var agent)? = properties["agent"]
        else { return tool }

        agent["enum"] = .array(normalized.map(JSONValue.string))
        properties["agent"] = .object(agent)
        root["properties"] = .object(properties)
        return Tool(
            type: tool.type,
            function: ToolFunction(
                name: tool.function.name,
                description: tool.function.description,
                parameters: .object(root)
            )
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let inputReq = requireString(args, "input", expected: "the task for the subagent", tool: name)
        guard case .value(let input) = inputReq else { return inputReq.failureEnvelope ?? "" }
        if let failure = SpawnInputContract.validationFailure(input: input, tool: name) {
            return failure
        }
        let agentReq = requireString(args, "agent", expected: "a spawnable agent UUID", tool: name)
        guard case .value(let rawAgentID) = agentReq else {
            return agentReq.failureEnvelope ?? ""
        }
        guard let agentID = UUID(uuidString: rawAgentID) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`agent` must be an exact UUID from the configured spawnable-agent list.",
                field: "agent",
                expected: "UUID",
                tool: name,
                retryable: true
            )
        }

        // The shared host owns the recursion guard, live feed, permission
        // verdict, residency handoff, compact-result normalization, and
        // telemetry; the kind owns model resolution + the bounded text loop.
        return await SubagentSession.runWithVisiblePreparation(
            TextSubagentKind(agentID: agentID, input: input),
            tool: name
        )
    }
}
