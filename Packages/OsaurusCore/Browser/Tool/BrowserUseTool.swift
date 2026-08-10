//
//  BrowserUseTool.swift
//  OsaurusCore — Native Browser Use
//
//  The single model-facing entry point for the native Browser Use feature
//  (the replacement for the `osaurus.browser` plugin's eighteen-tool parent
//  schema). The parent agent calls `browser_use(goal:)` once; this thin tool
//  parses the arguments and hands a `BrowserUseKind` to the shared
//  `SubagentSession` host, which runs the nested navigate→act→verify loop on
//  the private `browser_*` toolset and returns a single summary.
//
//  Gating: registered as a built-in so the runtime can execute it and
//  ChatView can intercept its feed, but the system prompt composer strips it
//  authoritatively unless the agent set `browserUseEnabled` (custom agents
//  only — the Default agent never gets browser access).
//

import Foundation

/// `browser_use` — drive a persistent per-agent browser session to accomplish
/// a natural-language goal.
final class BrowserUseTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "browser_use"

    let name = BrowserUseTool.toolName

    let description =
        "Browse the web on the user's behalf to accomplish a goal, using a persistent browser "
        + "session that belongs to this agent (cookies and sign-ins survive across chats). "
        + "Describe the WHOLE task in `goal` as one instruction — this runs a self-contained "
        + "subagent that navigates, reads pages, clicks, types, and verifies each step on its "
        + "own, then returns a summary. Reads and navigation happen automatically; typing and "
        + "anything consequential pause for the user to approve, and sign-ins happen through a "
        + "secure user-facing window (never ask for credentials in chat). Use this for "
        + "interacting with websites (dashboards, forms, content behind a login), NOT for simple "
        + "lookups — web_search is faster for those."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "goal": .object([
                "type": .string("string"),
                "description": .string(
                    "The complete task to accomplish, in plain language, naming the site when it "
                        + "matters. Example: \"On github.com, list my open pull requests and tell me "
                        + "which have failing checks.\""
                ),
            ]),
            "max_steps": .object([
                "type": .string("integer"),
                "description": .string(
                    "Optional safety cap on the number of model turns (default "
                        + "\(BrowserUseKind.defaultMaxSteps)). Each turn can batch many page actions. "
                        + "Raise only for genuinely long tasks."
                ),
            ]),
        ]),
        "required": .array([.string("goal")]),
    ])

    // `.auto`: the per-action gate (BrowserGate + the shared confirm overlay)
    // is the real consent surface, so we don't stack a per-call approval card
    // on top.
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto

    // The loop drives a real browser over many model turns (and may park on a
    // user sign-in window); like `computer_use` it opts out of the registry's
    // timeout and relies on its own wall-clock budget + the stop control.
    var bypassRegistryTimeout: Bool { true }

    init() {}

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let goalReq = requireString(
            args,
            "goal",
            expected: "the complete task to accomplish, in plain language",
            tool: name
        )
        guard case .value(let rawGoal) = goalReq else { return goalReq.failureEnvelope ?? "" }
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`goal` must be a non-empty instruction.",
                field: "goal",
                expected: "non-empty task description",
                tool: name
            )
        }

        var maxSteps = BrowserUseKind.defaultMaxSteps
        if let raw = args["max_steps"], !(raw is NSNull) {
            if let n = coerceInt(raw) {
                maxSteps = min(max(n, 1), 100)
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

        // Model resolution, the per-action gate + confirm overlay, the live
        // feed, the interrupt token, and the compact result all run through
        // the shared `SubagentSession` host via `BrowserUseKind`.
        return await SubagentSession.run(
            BrowserUseKind(goal: goal, maxSteps: maxSteps),
            tool: name
        )
    }
}
