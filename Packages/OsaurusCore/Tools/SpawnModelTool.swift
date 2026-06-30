//
//  SpawnModelTool.swift
//  osaurus
//
//  `spawn_model(input, model)` — delegate a task directly to a model the user
//  has marked spawnable (local or remote), with NO agent/system prompt
//  attached. Runs a bounded text subagent on that model (with the
//  local-orchestrator residency handoff when the target is local and clashes
//  with the resident chat model) and returns only a compact digest. Sibling of
//  `spawn_agent`, which delegates to a configured agent. Default OFF; each
//  agent opts in from its Subagents tab (`spawnableModelNames`). See
//  docs/SUBAGENT_PORTABLE_DESIGN.md.
//

import Foundation

public final class SpawnModelTool: OsaurusTool, @unchecked Sendable {
    public let name = SubagentCapabilityRegistry.spawnModelToolName
    public let description =
        "Delegate a bounded subtask directly to a model the user has marked spawnable (local or remote), "
        + "with no agent or system prompt attached, and get back only a compact result digest — the "
        + "subagent transcript is not returned. The model id must be in this agent's spawnable model list. "
        + "Use `spawn_agent` instead to hand a task to a configured agent (its own prompt + model)."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "input": .object([
                "type": .string("string"),
                "description": .string("The task/query for the subagent."),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string(
                    "Id of a spawnable model (e.g. \"qwen3-4b-4bit\" or a remote \"provider/model\")."
                ),
            ]),
        ]),
        "required": .array([.string("input"), .string("model")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let inputReq = requireString(args, "input", expected: "the task for the subagent", tool: name)
        guard case .value(let input) = inputReq else { return inputReq.failureEnvelope ?? "" }
        let modelReq = requireString(args, "model", expected: "a spawnable model id", tool: name)
        guard case .value(let model) = modelReq else { return modelReq.failureEnvelope ?? "" }

        // The shared host owns the recursion guard, live feed, permission
        // verdict, residency handoff, compact-result normalization, and
        // telemetry; the kind owns model resolution + the bounded text loop.
        return await SubagentSession.run(
            TextSubagentKind(model: model, input: input),
            tool: name
        )
    }
}
