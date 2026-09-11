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
        + "subagent transcript is not returned. The worker runs as a chat session of the target "
        + "agent with that agent's own enabled tools; when the agent has a configured working "
        + "folder it can read and write files there. Tools this agent has but the target lacks remain "
        + "parent-owned. The target agent must be in this agent's spawnable list. Use `spawn_model` "
        + "instead to hand a task to a bare model with no agent attached. One call = one worker; to "
        + "run several independent workers at once, emit all the spawn calls together in one "
        + "message — they run as one batch with one approval and shared limits."

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
                    "The target spawnable agent: its exact display name OR its UUID "
                        + "(local agent) OR its `0x…` address (a teammate's shared workspace "
                        + "agent), as shown in the configured target list."
                ),
            ]),
            "background": .object([
                "type": .string("boolean"),
                "description": .string(SpawnInputContract.backgroundParameterDescription),
            ]),
        ]),
        "required": .array([.string("input"), .string("agent")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    public init() {}

    /// Narrow the request-local schema to the launching agent's currently
    /// runnable agent pool. Execution still enforces the durable allow-list;
    /// this enum is exact identity guidance and provider-side validation.
    ///
    /// The enum carries BOTH each allow-listed agent's UUID and its display name
    /// so a strict, enum-enforcing provider accepts either form — small models
    /// emit the name, not the UUID (issue #2408). `execute` resolves a name back
    /// to its UUID. Names are appended after the UUIDs and de-duplicated so the
    /// enum stays byte-stable for the frozen-prefix cache.
    static func constrainedSpec(
        _ tool: Tool,
        allowedAgentIDs: [UUID],
        allowedAgentNames: [String] = [],
        allowedWorkspaceAddresses: [String] = []
    ) -> Tool {
        let uuids = SpawnableAgentIdentity.normalizedIDs(allowedAgentIDs)
            .map(\.uuidString)
        // Workspace agents join the enum by lowercased address — durable
        // identity, independent of presence — after the local UUIDs.
        var seenAddresses = Set<String>()
        let addresses = allowedWorkspaceAddresses.compactMap { raw -> String? in
            let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard WorkspaceAgentRef.looksLikeAddress(lowered),
                seenAddresses.insert(lowered).inserted
            else { return nil }
            return lowered
        }
        let identitySet = Set(uuids + addresses)
        var seenNames = Set<String>()
        let names = allowedAgentNames.filter { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !identitySet.contains(trimmed) else { return false }
            return seenNames.insert(trimmed).inserted
        }
        guard !uuids.isEmpty || !addresses.isEmpty,
            case .object(var root)? = tool.function.parameters,
            case .object(var properties)? = root["properties"],
            case .object(var agent)? = properties["agent"]
        else { return tool }

        agent["enum"] = .array((uuids + addresses + names).map(JSONValue.string))
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
        // Sibling spawn calls in one model message rendezvous for a single
        // approval card. Whatever path this call takes out — validation
        // failure, denial, completion — it must stop counting as pending.
        defer { SpawnWaveGate.settleCurrentCall() }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let inputReq = requireString(args, "input", expected: "the task for the subagent", tool: name)
        guard case .value(let input) = inputReq else { return inputReq.failureEnvelope ?? "" }
        if let failure = SpawnInputContract.validationFailure(input: input, tool: name) {
            return failure
        }
        let agentReq = requireString(
            args, "agent", expected: "a spawnable agent name or UUID", tool: name)
        guard case .value(let rawAgentID) = agentReq else {
            return agentReq.failureEnvelope ?? ""
        }
        let target: AgentDispatchTarget
        if let parsed = UUID(uuidString: rawAgentID) {
            target = .local(parsed)
        } else {
            // Small local models reliably echo a spawnable agent's display name
            // but not its opaque UUID (issue #2408), so `agent` accepts either —
            // and a teammate's shared workspace agent by name or `0x…` address.
            // Resolve against the launching agent's own allow-lists (local +
            // workspace); authorization stays identity-exact in the spawn kind.
            let resolution = await SubagentToolVisibility.resolveSpawnableAgentTarget(
                rawAgentID,
                scope: SubagentScope.current()
            )
            guard let resolved = resolution.target else {
                let names = resolution.allowedNames
                let hint: String
                if resolution.isAmbiguous {
                    hint =
                        "That name matches more than one spawnable agent; pass the UUID "
                        + "(local agent) or the `0x…` address (workspace agent) instead."
                } else if names.isEmpty {
                    hint = "This agent has no spawnable agents configured."
                } else {
                    hint =
                        "Pass one of these exact agent names (or its UUID / address): "
                        + names.map { "\"\($0)\"" }.joined(separator: ", ") + "."
                }
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`agent` did not match a spawnable agent. " + hint,
                    field: "agent",
                    expected: "a spawnable agent name, UUID, or workspace agent address",
                    tool: name,
                    retryable: true
                )
            }
            target = resolved
        }

        // The shared host owns the recursion guard, live feed, permission
        // verdict, residency handoff, compact-result normalization, and
        // telemetry; the kind owns model resolution + the bounded text loop.
        // The name lookup here only seeds the human-readable feed title;
        // `resolveModel` re-resolves the agent authoritatively.
        let kind: TextSubagentKind
        switch target {
        case .local(let agentID):
            let agentName = await MainActor.run {
                AgentManager.shared.agent(for: agentID)?.name
            }
            kind = TextSubagentKind(agentID: agentID, agentName: agentName, input: input)
        case .workspace(let ref):
            let agentName = await MainActor.run { AgentTargetResolver.displayName(for: ref) }
            kind = TextSubagentKind(workspaceAgent: ref, agentName: agentName, input: input)
        }
        if ArgumentCoercion.bool(args["background"]) == true {
            return await SubagentSession.dispatchInBackground(kind, tool: name)
        }
        return await SubagentSession.runWithVisiblePreparation(kind, tool: name)
    }
}
