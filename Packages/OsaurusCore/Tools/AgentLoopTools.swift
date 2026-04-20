//
//  AgentLoopTools.swift
//  osaurus
//
//  The three tools that drive the unified Chat agent loop:
//
//    - `todo(markdown)`    — write/replace the session's task checklist
//    - `complete(summary)` — finish the task with a one-paragraph summary
//    - `clarify(question)` — pause and wait for the user
//
//  Each has a single required field — smallest schema small local models
//  can reliably call, while remaining expressive enough for frontier ones.
//
//  These are normal `OsaurusTool`s. They execute through `ToolRegistry`
//  like any other tool; the chat layer (`ChatView`'s post-execute branch)
//  then inspects the tool name and result to drive the inline UI: mirror
//  `todo` into `AgentTodoStore`, end the loop on `complete`, pause for
//  input on `clarify`. HTTP-API callers see the raw result strings (no
//  inline UI) — that divergence is intentional and documented.
//

import Foundation

// MARK: - todo

/// Replace the session's task checklist. Markdown body, full-list replace.
/// Each call rewrites the entire list (no merging) so the model can fix
/// mistakes and reorder freely.
public final class TodoTool: OsaurusTool, @unchecked Sendable {
    public let name = "todo"
    public let description =
        "Write or replace the current task checklist. Pass a markdown checklist where every item "
        + "is a line starting with `- [ ]` (pending) or `- [x]` (done). Calling again replaces "
        + "the entire list — to mark items done, send the full list with the new boxes checked. "
        + "Use this for tasks with more than 2 obvious steps; skip for trivial work."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "markdown": .object([
                "type": .string("string"),
                "description": .string(
                    "Markdown checklist. Example: \"- [x] Read existing config\\n- [ ] Add new field\\n- [ ] Test\"."
                ),
            ])
        ]),
        "required": .array([.string("markdown")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        guard let sessionId = ChatExecutionContext.currentSessionId,
            !sessionId.isEmpty
        else {
            return "Error: no active session — `todo` is only valid inside a chat conversation."
        }
        guard let args = parseArguments(argumentsJSON),
            let raw = args["markdown"] as? String
        else {
            return "Error: `markdown` (string) is required. Pass a checklist like `- [ ] step 1\\n- [x] step 2`."
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: `markdown` must be a non-empty checklist."
        }

        let stored = await AgentTodoStore.shared.setTodo(markdown: trimmed, for: sessionId)
        if stored.totalCount == 0 {
            return
                "Todo updated, but no `- [ ]` / `- [x]` lines were found. Make sure each item starts with a checkbox."
        }
        return
            "Todo updated: \(stored.doneCount)/\(stored.totalCount) complete. "
            + "Continue with the next pending item, or call `complete(summary)` when all done."
    }
}

// MARK: - complete

/// End the current task with a single-summary contract. The chat engine
/// intercepts this call, ends the loop, and surfaces the summary to the UI.
public final class CompleteTool: OsaurusTool, @unchecked Sendable {
    public let name = "complete"
    public let description =
        "End the current task with a one-paragraph summary. Include WHAT you did and HOW you "
        + "verified it (the command you ran, the file you checked, the URL you opened). "
        + "Vague summaries (`done`, `looks good`, `complete`) are rejected. If you couldn't "
        + "finish, say so honestly in the summary instead of pretending — that's fine; the "
        + "user understands partial work."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "summary": .object([
                "type": .string("string"),
                "description": .string(
                    "What you did + how you verified, in one paragraph. Example: \"Added /health route in app.py and verified with `curl localhost:8080/health` returning 200.\" Required minimum length: about 30 characters of meaningful prose."
                ),
            ])
        ]),
        "required": .array([.string("summary")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        // Validation runs here so the runtime rejection has a useful message
        // even if the chat engine's intercept didn't fire (e.g. when called
        // from a bare HTTP API request).
        guard let args = parseArguments(argumentsJSON),
            let summary = args["summary"] as? String
        else {
            return "Error: `summary` (string) is required."
        }
        if let validation = Self.validate(summary: summary) {
            return "Error: \(validation)"
        }
        return "Task completed."
    }

    /// Returns nil when the summary is acceptable, or a human-readable
    /// reason string otherwise. Exposed at module visibility so the chat
    /// engine intercept can run the same gate before ending the loop.
    public static func validate(summary: String) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 30 {
            return
                "`summary` is too short (\(trimmed.count) chars). Describe both what you did and how you verified it — about 30 characters of meaningful prose at minimum."
        }
        let normalised = trimmed.lowercased()
        let placeholders: Set<String> = [
            "done.", "done", "complete.", "complete", "completed.", "completed",
            "ok.", "ok", "okay.", "okay", "looks good.", "looks good",
            "all good.", "all good", "fine.", "fine", "finished.", "finished",
        ]
        if placeholders.contains(normalised) {
            return
                "`summary` looks like a placeholder. Describe the concrete work and the concrete verification step (a command, a file, a URL)."
        }
        return nil
    }
}

// MARK: - clarify

/// Pause the agent loop and ask the user a critical question. The chat
/// engine intercepts this, surfaces the question as an inline assistant
/// bubble, and the user's next input becomes the answer. The model
/// resumes from there.
public final class ClarifyTool: OsaurusTool, @unchecked Sendable {
    public let name = "clarify"
    public let description =
        "Ask the user a single critical question when the task is ambiguous in a way that would "
        + "lead to the wrong result if you guessed. The conversation pauses; the user's next "
        + "message becomes your answer. For minor preferences or recoverable choices, pick a "
        + "sensible default and proceed instead of pausing."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "question": .object([
                "type": .string("string"),
                "description": .string(
                    "Specific, concrete question. Avoid open-ended `what would you like?` style; ask the actual decision (\"Use Postgres or SQLite?\")."
                ),
            ])
        ]),
        "required": .array([.string("question")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let raw = args["question"] as? String
        else {
            return "Error: `question` (string) is required."
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: `question` must be a non-empty string."
        }
        return "Awaiting user response."
    }
}
