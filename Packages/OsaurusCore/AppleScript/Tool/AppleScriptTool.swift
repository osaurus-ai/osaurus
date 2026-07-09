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
//  AND a model installed. Unlike `computer_use`, no blanket OS permission is
//  preflighted at the tool boundary: AppleScript's Automation/Apple Events
//  consent is triggered by the OS at script-send time and attributed to
//  Osaurus, and the loop preflights the Accessibility grant PER SCRIPT — only
//  when a proposed script actually uses System Events UI scripting (see
//  `AppleScriptAccessibility`), since most AppleScript needs no such grant.
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
        + "System Events; reading or setting app state; system actions). If the task must insert EXACT "
        + "text (a verbatim transcription, quotes, code, or a long note body), pass that text in "
        + "`content` and keep `task` as the instruction — it is then reproduced character-for-character "
        + "instead of being re-typed. When the task needs several exact blocks (a subject AND a body, "
        + "say), pass them in `contents` as a {name: text} map instead. Depending on the user's setting, "
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
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional. EXACT verbatim text the task must insert (a transcription, quote block, "
                        + "code, or long note body). Pass it here instead of inside `task` so it is "
                        + "reproduced character-for-character: the subagent inserts it via a `{{content}}` "
                        + "placeholder and never re-types it. Keep `task` as the instruction, e.g. \"Set "
                        + "the body of the note 'Quotes' to the provided content.\" For more than one "
                        + "exact block, use `contents` instead."
                ),
            ]),
            "contents": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")]),
                "description": .string(
                    "Optional. Several EXACT verbatim values as a { name: text } map, for a task that "
                        + "must insert more than one exact block (e.g. a subject AND a body) or must "
                        + "match an existing thing by its precise name (a note title, file path, "
                        + "mailbox, or URL). Each value is inserted character-for-character via its own "
                        + "`{{name}}` placeholder — never re-typed, so a long or unusual name can't be "
                        + "mistyped. Use short, semantic names. Example: {\"target\": \"Q3 Planning\", "
                        + "\"body\": \"…\"}. For a single block use `content`."
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

    // Default to a tighter step cap than Computer Use — an automation task
    // typically converges in a couple of script attempts.
    func execute(argumentsJSON: String) async throws -> String {
        await AppleScriptToolDispatch.run(
            tool: self,
            argumentsJSON: argumentsJSON,
            field: "task",
            expected: "the complete task to accomplish, in plain language",
            emptyMessage: "`task` must be a non-empty instruction.",
            defaultMaxSteps: 12,
            mode: .automate
        )
    }
}
