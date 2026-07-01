//
//  MacQueryTool.swift
//  OsaurusCore — AppleScript Computer Use
//
//  The read-only sibling of `applescript`. The parent agent calls
//  `mac_query(question)` to READ information from the Mac and its apps (front
//  Safari URL, selected Finder items, current track, unread mail, system state,
//  …). It shares the AppleScript subagent + on-device model + loop, but runs in
//  `.query` mode: the loop auto-runs read-only scripts (no confirmation) and
//  BLOCKS any script that would mutate state, and the result is value-first.
//
//  Sharing the `applescript` capability means it is gated by the same per-agent
//  toggle + installed-model check (`SubagentToolVisibility`) — enabling
//  AppleScript for an agent exposes both `applescript` and `mac_query`.
//

import Foundation

/// `mac_query` — read information from the Mac via a read-only AppleScript.
final class MacQueryTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "mac_query"

    let name = MacQueryTool.toolName

    static let toolDescription =
        "Read information from the user's Mac or its apps by generating and running a READ-ONLY "
        + "AppleScript, and get the values back. Ask the WHOLE question in `question` — a self-contained "
        + "subagent writes a read-only script, runs it (no confirmation needed, since it changes "
        + "nothing), and returns the actual value(s) plus a per-step transcript. Use it to READ state: "
        + "the front Safari tab/URL, selected Finder items, the current Music track, unread Mail, "
        + "Calendar events, clipboard, window titles, or system state (volume, brightness, battery, "
        + "running apps). To CHANGE anything, use `applescript` instead. Not for shell, files, or web "
        + "requests — those have dedicated tools."

    let description = MacQueryTool.toolDescription

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "question": .object([
                "type": .string("string"),
                "description": .string(
                    "The information to read from the Mac, in plain language, naming the app when it "
                        + "matters. Example: \"What is the URL of the front Safari tab?\""
                ),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional. EXACT verbatim text the question needs to compare against (e.g. \"does "
                        + "the note 'X' body equal the provided content?\"). Passed through to a "
                        + "`{{content}}` placeholder so the read never has to re-type it. This tool "
                        + "stays read-only regardless. For more than one exact block, use `contents`."
                ),
            ]),
            "contents": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")]),
                "description": .string(
                    "Optional. Several EXACT verbatim values as a { name: text } map, for a question "
                        + "that must compare against more than one exact block or read a thing named "
                        + "precisely (a note title, file path, mailbox, or URL). Reference each by its "
                        + "own `{{name}}` placeholder; each is inserted verbatim, so an exact name is "
                        + "never mistyped. Use short, semantic names. For a single block use `content`. "
                        + "This tool stays read-only regardless."
                ),
            ]),
            "max_steps": .object([
                "type": .string("integer"),
                "description": .string(
                    "Optional safety cap on the number of script attempts (default 8). Raise only for "
                        + "genuinely multi-step reads."
                ),
            ]),
        ]),
        "required": .array([.string("question")]),
    ])

    // Like `applescript`, the loop drives a model over many turns, so it opts
    // out of the registry's 120s race and relies on its own `RunLimits`.
    var bypassRegistryTimeout: Bool { true }

    init() {}

    // A read converges faster than an automation task, so default to a tighter
    // cap. Runs in `.query` mode (reads auto-run, writes are blocked).
    func execute(argumentsJSON: String) async throws -> String {
        await AppleScriptToolDispatch.run(
            tool: self,
            argumentsJSON: argumentsJSON,
            field: "question",
            expected: "the information to read from the Mac, in plain language",
            emptyMessage: "`question` must be a non-empty request.",
            defaultMaxSteps: 8,
            mode: .query
        )
    }
}
