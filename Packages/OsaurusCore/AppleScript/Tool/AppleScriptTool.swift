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
        + "instead of being re-typed. `content` is only for literal text supplied by the user; never put "
        + "AppleScript or instructions you generated into it. When the task needs several exact blocks, "
        + "pass them in `contents` as a {name: text} map. This is REQUIRED for text replacement even "
        + "when the strings are short: pass the old and replacement text as separate named values and "
        + "phrase `task` to use those provided values. For an existing open document, name the app "
        + "or exact path that the request or conversation identifies. A request that explicitly says "
        + "`the file` or `the document` is working-app anaphora: keep that phrase in `task` so the "
        + "subagent can resolve the tracked frontmost app, and do not ask for a path first. Never tell "
        + "the subagent to choose, create, or save a file to make up for a missing target. "
        + "Editing an open document does not imply saving it. Depending on the user's setting, "
        + "each script is shown for approval or auto-run with a warning. Use AppleScript for documents "
        + "open in Mac apps. Do NOT use it for shell commands, path-addressed files in a selected "
        + "folder/sandbox, or web requests — those have dedicated tools."

    let description = AppleScriptTool.toolDescription

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "task": .object([
                "type": .string("string"),
                "description": .string(
                    "The complete task to accomplish with AppleScript, in plain language, naming the app "
                        + "when it matters. Existing-document edits must identify the app or exact path "
                        + "from the request/conversation, except explicit `the file`/`the document` "
                        + "working-app anaphora, which must be passed through unchanged for tracked-"
                        + "frontmost resolution. Never invent a file picker or save step. "
                        + "Example: \"Get the URL of the front Safari tab.\""
                ),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional. EXACT verbatim text the task must insert (a transcription, quote block, "
                        + "code, or long note body). Pass it here instead of inside `task` so it is "
                        + "reproduced character-for-character: the subagent inserts it via a `{{content}}` "
                        + "placeholder and never re-types it. Copy only literal text supplied by the user; "
                        + "never place AppleScript or instructions you generated in this field. Keep "
                        + "`task` as the instruction, e.g. \"Set the body of the note 'Quotes' to the "
                        + "provided content.\" For more than one exact block, including old and "
                        + "replacement text, use `contents` instead; exact replacement values must not "
                        + "be left only inside `task`."
                ),
            ]),
            "contents": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")]),
                "description": .string(
                    "Optional. Several EXACT verbatim values as a { name: text } map, for a task that "
                        + "must insert more than one exact block (e.g. a subject AND a body) or must "
                        + "match an existing thing by its precise name (a note title, file path, "
                        + "mailbox, or URL). For replacement, use names such as `oldText` and `newText` "
                        + "and tell `task` to replace the provided old text with the provided new text. "
                        + "Each value is inserted character-for-character via its own "
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

    func normalizeArgumentsBeforeValidation(_ argumentsJSON: String) -> String {
        AppleScriptToolDispatch.normalizeAutomationArguments(argumentsJSON)
    }

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
