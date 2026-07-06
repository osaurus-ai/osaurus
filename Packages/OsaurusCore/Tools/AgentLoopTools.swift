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
        "Write or replace the OPTIONAL task checklist. Use it for multi-step work (3+ steps): "
        + "create the list BEFORE starting, then re-send it with the new box checked IMMEDIATELY "
        + "after finishing each item — do not batch updates for the end. Every item is a line "
        + "starting with `- [ ]` (pending) or `- [x]` (done); each call replaces the entire "
        + "list. Skip it for a direct question or single-step work — just answer."

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

        // Zero parseable checkboxes is a CONTRACT failure, not a soft
        // warning. The old success-with-warning path let a `- item` list
        // (no `[ ]`) through silently: the store then held 0 items, the
        // todo-staleness nudge could never arm (pending == 0), the UI block
        // showed nothing, and mark-as-you-go discipline was structurally
        // impossible for the rest of the run (observed live: a model did
        // every step of a multi-file refactor correctly but its checkbox-less
        // list meant no progress could ever be recorded). Reject with the
        // exact syntax so the immediate retry lands.
        let parsed = AgentTodo.parse(trimmed)
        if parsed.totalCount == 0 {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "No checklist items found. Every item must be a line starting "
                    + "with `- [ ]` (pending) or `- [x]` (done) — e.g. "
                    + "\"- [x] Read config\\n- [ ] Add field\\n- [ ] Test\". "
                    + "Re-send the full list in that format.",
                field: "markdown",
                expected: "markdown checklist with `- [ ]` / `- [x]` items",
                tool: name
            )
        }
        let stored = await AgentTodoStore.shared.setTodo(markdown: trimmed, for: sessionId)
        return ToolEnvelope.success(
            tool: name,
            text:
                "Todo updated: \(stored.doneCount)/\(stored.totalCount) complete. "
                + "Continue with the next pending item; when everything is done, write your "
                + "answer to the user (you may then call `complete(summary)` to close the task)."
        )
    }
}

// MARK: - complete

/// End the current task with a single-summary contract. The chat engine
/// intercepts this call, ends the loop, and surfaces the summary to the UI.
public final class CompleteTool: OsaurusTool, @unchecked Sendable {
    public let name = "complete"
    public let description =
        "OPTIONAL closure for a multi-step task you tracked with a `todo` list. Write your "
        + "actual answer/result to the user as a normal message FIRST; this summary is a short "
        + "status of WHAT you did + HOW you verified it (the command you ran, the file you "
        + "checked, the URL you opened), NOT the answer itself. Call it in the same message as "
        + "that final answer and not alongside other tool calls; for a direct question, just "
        + "answer and do not call complete. Vague summaries (`done`, `looks good`, `complete`) "
        + "are rejected. If you couldn't finish, say so honestly in the summary instead of "
        + "pretending — that's fine; the user understands partial work."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "summary": .object([
                "type": .string("string"),
                "description": .string(
                    "What you did + how you verified, in one paragraph (≥30 chars of meaningful prose). Example: \"Added /health route in app.py; verified with `curl localhost:8080/health` returning 200.\""
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

        // Soft warning, never a rejection (rejecting here loops small
        // models): completing with unchecked todo boxes is allowed, but
        // the discrepancy is flagged in the envelope so it lands in the
        // transcript the user reads.
        if let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty,
            let todo = await AgentTodoStore.shared.todo(for: sessionId)
        {
            let pending = todo.totalCount - todo.doneCount
            if pending > 0 {
                return ToolEnvelope.success(
                    tool: name,
                    text: "Task completed.",
                    warnings: [
                        "todo list has \(pending) unchecked item\(pending == 1 ? "" : "s") — update it, or state honestly in the summary that they were not done"
                    ]
                )
            }
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

    /// Pull the trimmed `summary` out of a `complete(...)` call's JSON
    /// arguments. Returns nil when the JSON is malformed or the summary
    /// is empty; callers fall back to the raw tool result string. Shared
    /// by the chat-surface intercept and the eval harness so the parsed
    /// completion text is identical on every surface.
    public static func parseSummary(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let summary = dict["summary"] as? String
        else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - clarify

/// Structured payload for a `clarify` call. Built from the JSON
/// arguments via `ClarifyTool.parse`. The chat engine uses this to
/// drive the inline prompt UI: free-form questions render with an
/// embedded text field; questions with `options` render as clickable
/// chips so the user can answer with one tap.
public struct ClarifyPayload: Sendable, Equatable {
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
        "Ask the user a single critical question ONLY when the task is genuinely under-specified "
        + "— a required input is missing or contradictory and guessing wrong would change the "
        + "result. A fully specified task, even a large multi-step one, is NOT ambiguous: plan it "
        + "and start. The conversation pauses; the user's next "
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
                    "The concrete decision to ask (\"Use Postgres or SQLite?\") — not open-ended \"what would you like?\" style."
                ),
            ]),
            "options": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "≤6 short answer choices (≤80 chars each), shown as one-tap buttons; omit for free-form answers."
                ),
            ]),
            "allowMultiple": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Allow picking more than one option. Defaults to false."
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

// MARK: - speak

/// Speak text aloud via PocketTTS. Fire-and-forget: returns the moment
/// playback starts. The row spinner clears when audio drains.
public final class SpeakTool: OsaurusTool, @unchecked Sendable {
    public let name = "speak"
    public let description =
        "Read text aloud using the local text-to-speech engine. Use ONLY when the user explicitly "
        + "asks to hear the response (`read this aloud`, `dictate this`, `speak`). Pass the exact "
        + "prose to vocalize as plain text — no markdown, no code fences, no tool noise. Playback "
        + "runs in the background; the user sees a spinner on the call until audio finishes."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string(
                    "Plain prose to speak aloud. Strip markdown/code; keep it conversational."
                ),
            ])
        ]),
        "required": .array([.string("text")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let textReq = requireString(
            args,
            "text",
            expected: "non-empty plain prose to speak",
            tool: name
        )
        guard case .value(let raw) = textReq else { return textReq.failureEnvelope ?? "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`text` must be a non-empty string.",
                field: "text",
                expected: "non-empty plain prose",
                tool: name
            )
        }

        // Respect the user's master TTS toggle.
        let enabled = await MainActor.run { TTSConfigurationStore.load().enabled }
        guard enabled else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Text-to-speech is disabled in settings. Tell the user to enable it under "
                    + "Settings → Voice if they want spoken responses.",
                tool: name,
                retryable: false
            )
        }

        // Outside chat (HTTP API), fall back to fresh ids — playback
        // still works, just without the bubble/row UI binding.
        let messageId = ChatExecutionContext.currentAssistantTurnId ?? UUID()
        let callId = ChatExecutionContext.currentToolCallId ?? UUID().uuidString
        let agentId = ChatExecutionContext.currentAgentId

        do {
            try await MainActor.run {
                let agentVoice = agentId.flatMap { AgentManager.shared.agent(for: $0)?.ttsVoice }
                try TTSService.shared.startToolPlayback(
                    text: trimmed,
                    messageId: messageId,
                    callId: callId,
                    voiceOverride: agentVoice
                )
            }
        } catch TTSPlaybackError.modelNotReady {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "TTS model isn't loaded. User was prompted to download it — retry "
                    + "once ready, or fall back to a text response.",
                tool: name,
                retryable: true
            )
        } catch {
            return ToolEnvelope.fromError(error, tool: name)
        }

        // Past-tense label — the spinner conveys in-progress state.
        return ToolEnvelope.success(tool: name, text: "Read aloud.")
    }

    /// Extract the trimmed `text` field. Returns nil when missing or
    /// empty. Pure helper for tests.
    public static func parse(argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = dict["text"] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
