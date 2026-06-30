//
//  AppleScriptTool.swift
//  OsaurusCore — AppleScript Computer Use
//
//  The single model-facing entry point for the AppleScript subagent. The
//  parent agent calls `applescript(task:)` once; this thin tool parses the
//  arguments and hands an `AppleScriptKind` to the shared `SubagentSession`
//  host, which resolves the on-device AppleScript model, runs the
//  generate → gate → execute loop, and returns a single summary. The inner
//  steps never leak into the parent transcript — they surface only through the
//  shared `SubagentFeed` rendered in the chat row.
//
//  Gating: registered as a built-in so the runtime can execute it and ChatView
//  can intercept its feed, but the system prompt composer strips it
//  authoritatively (delegation family) unless the agent has AppleScript enabled
//  AND a model installed. Unlike `computer_use`, no OS permission is preflighted
//  here: AppleScript's Automation/Apple Events consent is triggered by the OS at
//  script-send time and attributed to Osaurus.
//

import Foundation

/// `applescript` — accomplish a macOS task by generating and running AppleScript.
final class AppleScriptTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "applescript"

    let name = AppleScriptTool.toolName

    static let toolDescription =
        "Accomplish a task on the user's Mac by generating and running AppleScript. Describe the WHOLE "
        + "task in `task` as one instruction — this runs a self-contained subagent that writes an "
        + "AppleScript, runs it, reads the result, and iterates until done, then returns a summary. Use "
        + "it for AppleScript-style automation (controlling Mac apps like Finder, Safari, Mail, Notes, "
        + "System Events; reading or setting app state; system actions). Depending on the user's setting, "
        + "each script is shown for approval or auto-run with a warning. Do NOT use it for shell, files, "
        + "or web requests — those have dedicated tools."

    let description = AppleScriptTool.toolDescription

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "task": .object([
                "type": .string("string"),
                "description": .string(
                    "The complete task to accomplish with AppleScript, in plain language, naming the app "
                        + "when it matters. Example: \"Get the URL of the front Safari tab.\""
                ),
            ]),
            "max_steps": .object([
                "type": .string("integer"),
                "description": .string(
                    "Optional safety cap on the number of script attempts (default 12). Raise only for "
                        + "genuinely multi-step tasks."
                ),
            ]),
        ]),
        "required": .array([.string("task")]),
    ])

    // The loop drives a model over many turns and runs scripts that may launch
    // apps; like `computer_use` it has no usable wall-clock budget, so it opts
    // out of the registry's 120s race and relies on its own `RunLimits` + the
    // user's stop control instead.
    var bypassRegistryTimeout: Bool { true }

    init() {}

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let taskReq = requireString(
            args,
            "task",
            expected: "the complete task to accomplish, in plain language",
            tool: name
        )
        guard case .value(let rawTask) = taskReq else { return taskReq.failureEnvelope ?? "" }
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`task` must be a non-empty instruction.",
                field: "task",
                expected: "non-empty task description",
                tool: name
            )
        }

        // Default to a tighter step cap than Computer Use — an AppleScript task
        // typically converges in a couple of script attempts. Honour an explicit
        // `max_steps`, clamped to a sane range.
        var limits = RunLimits(maxSteps: 12)
        if let raw = args["max_steps"], !(raw is NSNull) {
            if let n = coerceInt(raw) {
                limits = RunLimits(maxSteps: min(max(n, 1), 50))
            } else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`max_steps` must be an integer.",
                    field: "max_steps",
                    expected: "integer step cap",
                    tool: name
                )
            }
        }

        return await SubagentSession.run(
            AppleScriptKind(task: task, limits: limits),
            tool: name
        )
    }
}
