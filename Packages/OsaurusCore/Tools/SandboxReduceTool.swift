//
//  SandboxReduceTool.swift
//  osaurus
//
//  `sandbox_reduce` — the reduction subagent from docs/REDUCTION_SUBAGENT.md,
//  built on the shared `AgentToolLoop` primitive. "Read a lot, return a
//  little": the tool spawns a nested, context-isolated tool loop with a
//  read/search/exec-only allowlist and hands ONLY the child's final digest
//  back to the parent turn. Raw tool output never crosses into the parent
//  context, which is the whole point on small-window local models.
//
//  Guardrails:
//  - Allowlist: `sandbox_read_file`, `sandbox_search_files`, `sandbox_exec`.
//    Everything else — loop tools, `dispatch`, plugins/MCP, and
//    `sandbox_reduce` itself (no recursion) — is invisible to the child and
//    refused at execution time as defense in depth.
//  - Caps: own iteration budget (default 8, hard cap 12), wall-clock
//    deadline, and `sandbox_exec` calls count against the SAME
//    `SandboxExecLimiter` budget as the parent (same agent name), so a
//    child can't escape the per-turn command ceiling.
//  - Cancellation: the child loop probes `Task.isCancelled`, so a parent
//    [Stop]/[Terminate] that cancels the tool task stops the child at the
//    next boundary.
//  - Context isolation: fresh minimal seed (system + task) and an ephemeral
//    child session id — never the parent transcript.
//

import Foundation

// MARK: - sandbox_reduce

struct SandboxReduceTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_reduce"
    let description =
        "Delegate a read-heavy investigation to a context-isolated subagent and get back ONLY a "
        + "short digest. Use when the raw bytes would flood your context: scanning logs for the "
        + "few relevant errors, walking a directory tree to summarize structure, extracting one "
        + "fact from many files. The subagent can read files, search, and run shell commands in "
        + "the sandbox, then distills what it found; raw file contents never enter your context. "
        + "NOT for writes/edits — it is read-only by design. Example: `{\"task\": \"Scan logs/*.log "
        + "for ERROR lines from the last run and summarize the distinct failure causes\"}`."

    let agentId: String
    let agentName: String
    let home: String

    /// The nested loop runs multiple model + tool steps; the registry's
    /// per-tool wall clock would cut healthy reductions short. The tool
    /// enforces its own deadline instead (`wallClockSeconds`).
    var bypassRegistryTimeout: Bool { true }

    /// Child toolset: read/search/exec only. No loop tools, no dispatch,
    /// no plugins/MCP, no recursion.
    static let childToolAllowlist: [String] = [
        "sandbox_read_file", "sandbox_search_files", "sandbox_exec",
    ]

    /// Default and hard-cap iteration budgets for the child loop.
    static let defaultIterations = 8
    static let maxIterations = 12

    /// Wall-clock deadline for the whole reduction (checked at loop
    /// boundaries; individual `sandbox_exec` calls keep their own limits).
    static let wallClockSeconds: TimeInterval = 240

    /// Cap on the digest handed back to the parent.
    static let digestMaxChars = 8_000

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "task": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Natural-language reduction goal. Be specific about what to find and what "
                            + "the digest should contain."
                    ),
                ]),
                "paths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Optional file/directory paths (relative to agent home or absolute in the "
                            + "sandbox) scoping where the subagent should look."
                    ),
                ]),
                "max_iterations": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Optional child loop budget (model steps), default \(Self.defaultIterations), "
                            + "max \(Self.maxIterations)."
                    ),
                ]),
            ]),
            "required": .array([.string("task")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let taskReq = requireString(
            args,
            "task",
            expected: "a natural-language reduction goal, e.g. \"summarize the errors in logs/\"",
            tool: name
        )
        guard case .value(let task) = taskReq else { return taskReq.failureEnvelope ?? "" }
        let paths = coerceStringArray(args["paths"]) ?? []
        let iterations = min(
            max(coerceInt(args["max_iterations"]) ?? Self.defaultIterations, 1),
            Self.maxIterations
        )

        // The shared host owns the recursion guard, live feed, compact-result
        // normalization, and telemetry; the kind owns model/toolset resolution
        // and the bounded reduction loop (same model => no residency handoff).
        return await SubagentSession.run(
            SandboxReduceKind(agentId: agentId, task: task, paths: paths, iterations: iterations),
            tool: name
        )
    }
}
