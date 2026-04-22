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
        "additionalProperties": .bool(false),
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
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "No active session — `todo` is only valid inside a chat conversation.",
                tool: name,
                retryable: false
            )
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let mdReq = requireString(
            args,
            "markdown",
            expected: "markdown checklist; each item starts with `- [ ]` or `- [x]`",
            tool: name
        )
        guard case .value(let raw) = mdReq else { return mdReq.failureEnvelope ?? "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`markdown` must be a non-empty checklist.",
                field: "markdown",
                expected: "non-empty markdown checklist",
                tool: name
            )
        }

        let stored = await AgentTodoStore.shared.setTodo(markdown: trimmed, for: sessionId)
        if stored.totalCount == 0 {
            return ToolEnvelope.success(
                tool: name,
                text:
                    "Todo updated, but no `- [ ]` / `- [x]` lines were found. "
                    + "Make sure each item starts with a checkbox.",
                warnings: ["no checklist items detected"]
            )
        }
        return ToolEnvelope.success(
            tool: name,
            text:
                "Todo updated: \(stored.doneCount)/\(stored.totalCount) complete. "
                + "Continue with the next pending item, or call `complete(summary)` when all done."
        )
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
        "additionalProperties": .bool(false),
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
        // even if the chat layer's post-execute intercept didn't fire
        // (e.g. when called from a bare HTTP API request).
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let summaryReq = requireString(
            args,
            "summary",
            expected: "≥30 chars describing what you did and how you verified it",
            tool: name
        )
        guard case .value(let summary) = summaryReq else { return summaryReq.failureEnvelope ?? "" }

        if let validation = Self.validate(summary: summary) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: validation,
                field: "summary",
                expected: "≥30 chars of meaningful prose; not a placeholder",
                tool: name
            )
        }
        return ToolEnvelope.success(tool: name, text: "Task completed.")
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

/// Structured payload for a `clarify` call. Built from the JSON
/// arguments via `ClarifyTool.parse`. The chat engine uses this to
/// drive the inline prompt UI: free-form questions render with an
/// embedded text field; questions with `options` render as clickable
/// chips so the user can answer with one tap.
public struct ClarifyPayload: Sendable {
    public let question: String
    public let options: [String]
    public let allowMultiple: Bool

    public init(question: String, options: [String] = [], allowMultiple: Bool = false) {
        self.question = question
        self.options = options
        self.allowMultiple = allowMultiple
    }
}

/// Maximum number of options accepted on a single clarify call. Kept
/// small so the chip strip never overflows the card horizontally; if
/// the model needs more than this it should ask follow-up questions
/// instead of offering a wall of choices.
private let kMaxClarifyOptions = 6

/// Per-option character cap. Long labels collapse the chip layout and
/// usually mean the model is dumping prose into the option slot.
private let kMaxClarifyOptionLength = 80

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
        + "sensible default and proceed instead of pausing. When the answer is one of a finite "
        + "set (≤6 short choices), pass them as `options` so the user can pick with a tap "
        + "instead of typing — e.g. `options: [\"Postgres\", \"SQLite\"]`. Set `allowMultiple` "
        + "to true only when the user genuinely needs to pick more than one (e.g. \"which "
        + "platforms?\")."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "question": .object([
                "type": .string("string"),
                "description": .string(
                    "Specific, concrete question. Avoid open-ended `what would you like?` style; ask the actual decision (\"Use Postgres or SQLite?\")."
                ),
            ]),
            "options": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "Optional list of short answer choices (≤6, ≤80 chars each). When present, the UI shows them as one-tap buttons; omit for free-form answers."
                ),
            ]),
            "allowMultiple": .object([
                "type": .string("boolean"),
                "description": .string(
                    "When true and `options` is set, the user can pick more than one. Defaults to false."
                ),
            ]),
        ]),
        "required": .array([.string("question")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let qReq = requireString(
            args,
            "question",
            expected: "single concrete question (e.g. `Use Postgres or SQLite?`)",
            tool: name
        )
        guard case .value(let raw) = qReq else { return qReq.failureEnvelope ?? "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`question` must be a non-empty string.",
                field: "question",
                expected: "non-empty question string",
                tool: name
            )
        }

        // `options` is optional. When present we validate count, length,
        // and dedupe so a sloppy model doesn't blow up the chip layout
        // or surface "Yes" twice with different cases. The validation
        // gate runs in the tool — not just the UI — so HTTP-API callers
        // see the same error envelope local UI users would.
        if let raw = args["options"], !(raw is NSNull) {
            guard let arr = ArgumentCoercion.stringArray(raw) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`options` must be an array of strings, got \(type(of: raw)). "
                        + "Pass e.g. `[\"Yes\", \"No\"]`.",
                    field: "options",
                    expected: "array of short string choices",
                    tool: name
                )
            }
            let cleaned = Self.normalizeOptions(arr)
            if cleaned.count > kMaxClarifyOptions {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`options` is capped at \(kMaxClarifyOptions) entries (got \(cleaned.count)). "
                        + "Drop low-value choices or break the question into a follow-up.",
                    field: "options",
                    expected: "≤\(kMaxClarifyOptions) short string choices",
                    tool: name
                )
            }
            for opt in cleaned where opt.count > kMaxClarifyOptionLength {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Option `\(opt.prefix(40))…` is \(opt.count) chars (>\(kMaxClarifyOptionLength)). "
                        + "Use short labels — put longer detail in `question`.",
                    field: "options",
                    expected: "each option ≤\(kMaxClarifyOptionLength) chars",
                    tool: name
                )
            }
        }

        return ToolEnvelope.success(tool: name, text: "Awaiting user response.")
    }

    /// Trim, drop empties, dedupe (case-insensitive, keeping first
    /// occurrence's casing). Pure helper — exposed so the chat
    /// intercept can reuse the exact same normalization without
    /// re-running validation.
    public static func normalizeOptions(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for opt in raw {
            let trimmed = opt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    /// Parse a `clarify` call's JSON arguments into a structured
    /// payload. Returns nil when the question is missing or empty;
    /// callers fall back to skipping the inline UI in that case (the
    /// tool's own validation already returned an error envelope to the
    /// model).
    public static func parse(argumentsJSON: String) -> ClarifyPayload? {
        guard let data = argumentsJSON.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let questionRaw = dict["question"] as? String else { return nil }
        let question = questionRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return nil }

        let options: [String]
        if let raw = dict["options"], !(raw is NSNull),
            let arr = ArgumentCoercion.stringArray(raw)
        {
            // Cap defensively even if the tool already validated — the
            // intercept sees pre-validated args, but tests and other
            // call sites might not.
            let cleaned = Self.normalizeOptions(arr)
            options = Array(cleaned.prefix(kMaxClarifyOptions))
        } else {
            options = []
        }

        let allowMultiple = ArgumentCoercion.bool(dict["allowMultiple"]) ?? false
        return ClarifyPayload(
            question: question,
            options: options,
            // `allowMultiple` only makes sense when there are options to
            // multi-select; collapse it to false otherwise so callers
            // don't have to guard.
            allowMultiple: options.isEmpty ? false : allowMultiple
        )
    }
}
