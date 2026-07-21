//
//  AppleScriptToolDispatch.swift
//  OsaurusCore — AppleScript Computer Use
//
//  Shared argument parsing + dispatch for the two AppleScript subagent tools:
//  `applescript` (state-changing automation) and `mac_query` (read-only info).
//  They differ only in the argument name, the default step cap, and the run
//  mode; the parse → validate → clamp → hand-to-`SubagentSession` flow is
//  identical, so it lives here once instead of being copied into both tools.
//

import Foundation

enum AppleScriptToolDispatch {
    /// Hard ceiling on `max_steps` regardless of what the model requests.
    private static let maxStepCap = 50

    /// Remove exactly one known sibling-tool field when the selected tool's
    /// own required field is already present. The live Ornith row emitted a
    /// valid `applescript` payload plus the sibling `mac_query.question`
    /// property; rejecting that entire call caused a worse retry with an
    /// invented path and save. This repair happens before schema validation,
    /// does not advertise or consume the sibling value, and leaves malformed
    /// JSON, missing-required-field calls, and every unknown property strict.
    static func removingSiblingField(
        _ argumentsJSON: String,
        siblingField: String,
        requiredField: String
    ) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object[requiredField] != nil,
            object[siblingField] != nil
        else { return argumentsJSON }
        object.removeValue(forKey: siblingField)
        guard let cleaned = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ), let text = String(data: cleaned, encoding: .utf8)
        else { return argumentsJSON }
        debugLog(
            "[AppleScript] removed sibling field `\(siblingField)` before schema validation"
        )
        return text
    }

    /// Normalize the two concrete cross-schema shapes observed from the parent
    /// Ornith tool call while keeping the public schema strict:
    /// 1. remove a leaked `mac_query.question` when `task` exists;
    /// 2. recover `contents` encoded as `oldText:<old>,newText:<new>` only when
    ///    the task independently contains the same exact replacement pair.
    /// The second condition prevents an arbitrary colon/comma string from
    /// being reinterpreted as user data.
    static func normalizeAutomationArguments(_ argumentsJSON: String) -> String {
        let withoutSibling = removingSiblingField(
            argumentsJSON,
            siblingField: "question",
            requiredField: "task"
        )
        guard let data = withoutSibling.data(using: .utf8),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let task = object["task"] as? String,
            let encoded = object["contents"] as? String,
            let inferred = exactReplacementLiterals(from: task),
            let oldText = inferred.value(for: "oldText"),
            let newText = inferred.value(for: "newText"),
            encoded == "oldText:\(oldText),newText:\(newText)"
        else { return withoutSibling }
        object["contents"] = ["oldText": oldText, "newText": newText]
        guard let cleaned = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ), let text = String(data: cleaned, encoding: .utf8)
        else { return withoutSibling }
        debugLog("[AppleScript] recovered exact replacement contents object")
        return text
    }

    /// Parse the single natural-language argument (`field`) + optional
    /// `max_steps` + optional verbatim literals (`content` and/or `contents`),
    /// then run a configured `AppleScriptKind` on the subagent host. Returns the
    /// tool envelope (success payload or `invalid_args`).
    static func run(
        tool: OsaurusTool,
        argumentsJSON: String,
        field: String,
        expected: String,
        emptyMessage: String,
        defaultMaxSteps: Int,
        mode: AppleScriptRunMode
    ) async -> String {
        let argsReq = tool.requireArgumentsDictionary(argumentsJSON, tool: tool.name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let textReq = tool.requireString(args, field, expected: expected, tool: tool.name)
        guard case .value(let rawText) = textReq else { return textReq.failureEnvelope ?? "" }
        let request = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: emptyMessage,
                field: field,
                expected: expected,
                tool: tool.name
            )
        }

        let latestUserTask = latestUserTaskFromCurrentSession()
        if let conflict = readOnlyConflictMessage(
            latestUserTask: latestUserTask,
            mode: mode
        ) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: conflict,
                field: field,
                expected: "a read-only Mac/app-state question grounded in the current user request",
                tool: tool.name,
                retryable: true
            )
        }

        let suppliedLiterals = literals(from: args)
        // The parent model may paraphrase a direct replacement request before
        // calling this tool. The live 16B path proved that such a paraphrase
        // can add an unrequested save and lose working-document anaphora. When
        // (and only when) both texts encode the same exact two-value
        // replacement, keep the persisted user turn authoritative.
        let dispatchTask = authoritativeReplacementTask(
            parentTask: request,
            latestUserTask: latestUserTask
        )
        let parsedLiterals = literalsForDispatch(task: dispatchTask, literals: suppliedLiterals)
        if let violation = literalContractViolation(task: dispatchTask, literals: parsedLiterals) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: violation.message,
                field: violation.field,
                expected: "verbatim user-supplied text referenced by the plain-language task",
                tool: tool.name
            )
        }

        var limits = RunLimits(maxSteps: defaultMaxSteps)
        if let raw = args["max_steps"], !(raw is NSNull) {
            guard let n = tool.coerceInt(raw) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`max_steps` must be an integer.",
                    field: "max_steps",
                    expected: "integer step cap",
                    tool: tool.name
                )
            }
            limits = RunLimits(maxSteps: min(max(n, 1), maxStepCap))
        }

        // Keep exact user data out of the helper's natural-language task when
        // the parent already supplied it through `content` / `contents`.
        // The helper now has one authoritative data channel and cannot
        // silently re-type or mutate the bytes while generating AppleScript.
        let childRequest = taskForSubagent(dispatchTask, literals: parsedLiterals)

        return await SubagentSession.run(
            AppleScriptKind(
                task: childRequest,
                limits: limits,
                mode: mode,
                literals: parsedLiterals
            ),
            tool: tool.name
        )
    }

    struct LiteralContractViolation: Equatable {
        let field: String
        let message: String
    }

    /// Return the user's direct replacement wording when the parent tool task
    /// describes the same exact old/new values. This prevents a model rewrite
    /// from broadening side effects (for example, inventing `save`) while
    /// preserving parent-resolved context for every ambiguous, anaphoric, or
    /// non-replacement request. An explicit save in the user wording remains.
    static func authoritativeReplacementTask(
        parentTask: String,
        latestUserTask: String?
    ) -> String {
        guard let latestUserTask else { return parentTask }
        let userTask = latestUserTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userTask.isEmpty,
            let parentValues = exactReplacementLiterals(from: parentTask),
            let userValues = exactReplacementLiterals(from: userTask),
            replacementValues(parentValues) == replacementValues(userValues)
        else { return parentTask }
        debugLog("[AppleScript] kept matching latest user replacement task authoritative")
        return userTask
    }

    static func latestUserTaskFromCurrentSession() -> String? {
        guard let rawSessionId = ChatExecutionContext.currentSessionId,
            let sessionId = UUID(uuidString: rawSessionId),
            let session = ChatHistoryDatabase.shared.loadSession(id: sessionId)
        else { return nil }
        return session.turns.last(where: { $0.role == .user })?.content
    }

    /// Reject the confirmed parent-routing failure where a state-changing
    /// replacement request is rewritten into an unrelated `mac_query`. The
    /// read tool must never run a fabricated filesystem/state question merely
    /// because the parent selected the wrong sibling tool. Returning a
    /// retryable contract error lets the parent choose `applescript`; it does
    /// not execute, rewrite, or silently reroute the user's task.
    static func readOnlyConflictMessage(
        latestUserTask: String?,
        mode: AppleScriptRunMode
    ) -> String? {
        guard mode == .query,
            let latestUserTask,
            exactReplacementLiterals(from: latestUserTask) != nil
        else { return nil }
        return
            "`mac_query` is read-only, but the current user request is an exact text replacement. "
            + "Call `applescript` with the user's replacement task and exact old/new values. Do not "
            + "invent a filesystem query or a save step."
    }

    /// Reject a separate chat attachment when the persisted user request is
    /// specifically an exact replacement in the frontmost/current document.
    /// `share_artifact` cannot mutate that app state; allowing it to succeed
    /// would create an unrelated file and let the parent falsely report the
    /// requested edit as complete. Ordinary artifact creation and path-based
    /// file delivery remain unchanged.
    static func artifactConflictMessage(latestUserTask: String?) -> String? {
        guard let latestUserTask,
            exactReplacementLiterals(from: latestUserTask) != nil,
            AppleScriptAppKnowledge.mentionsWorkingApp(latestUserTask)
        else { return nil }
        return
            "`share_artifact` only presents a separate chat attachment; it cannot edit the current "
            + "open file/document. Call `applescript` with the user's replacement task and exact "
            + "old/new values. Do not create an output file or claim the existing document changed."
    }

    private static func replacementValues(_ literals: AppleScriptLiterals) -> Set<String> {
        Set(literals.names.compactMap { literals.value(for: $0) })
    }

    /// Recover the confirmed parent-model failure where a complete generated
    /// AppleScript program is placed in an otherwise unreferenced literal
    /// field while `task` already contains the whole requested outcome. The
    /// literal is neither user data nor part of the instruction, so it must not
    /// be executed, shown as a successful attempt, or bounced back to the
    /// parent for another model/tool round. Discard it and let the dedicated
    /// AppleScript helper implement the plain-language task.
    ///
    /// This deliberately does NOT repair mixed literal maps, referenced
    /// literals, or requests to insert AppleScript source as text. Those keep
    /// the strict validation path so real user data can never be silently
    /// removed.
    static func literalsForDispatch(
        task: String,
        literals: AppleScriptLiterals
    ) -> AppleScriptLiterals {
        if let inferred = exactReplacementLiterals(from: task) {
            if literals.isEmpty || suppliedLiteralsMatchReplacement(literals, inferred: inferred) {
                debugLog(
                    "[AppleScript] preserved exact replacement values as oldText,newText"
                )
                return inferred
            }

            // The live Ornith parent sometimes supplied a complete generated
            // script in `content` even though the authoritative task itself
            // carried an exact old/new replacement pair. That `content` is not
            // user data and must still be discarded, but doing so must not also
            // discard the exact values independently recovered from the user's
            // task. Preserve only the inferred pair when every conflicting
            // supplied value is generated source; mixed/user-data maps remain
            // strict below.
            let names = literals.names
            let allGeneratedSource = !names.isEmpty && names.allSatisfy { name in
                guard let value = literals.value(for: name) else { return false }
                return looksLikeAppleScriptSource(value)
            }
            if allGeneratedSource {
                debugLog(
                    "[AppleScript] discarded generated-script literals and preserved exact "
                        + "replacement values as oldText,newText"
                )
                return inferred
            }
        }

        if literals.isEmpty { return literals }

        let normalizedTask = task.lowercased()
        let explicitlyInsertingSource =
            normalizedTask.contains("applescript source")
            || normalizedTask.contains("applescript code")
            || normalizedTask.contains("script source")
            || normalizedTask.contains("script text")
            || normalizedTask.contains("code as text")
        guard !explicitlyInsertingSource else { return literals }

        let names = literals.names
        let allGeneratedSource = names.allSatisfy { name in
            guard let value = literals.value(for: name) else { return false }
            return looksLikeAppleScriptSource(value)
        }
        let referencesLiteralValue = names.contains { name in
            guard let value = literals.value(for: name), !value.isEmpty else { return false }
            return task.range(of: value, options: [.literal, .caseInsensitive]) != nil
        }
        let referencesLiteral =
            normalizedTask.contains("provided")
            || normalizedTask.contains("content")
            || normalizedTask.contains("literal")
            || normalizedTask.contains("{{")
            || names.contains(where: { normalizedTask.contains($0.lowercased()) })
            || referencesLiteralValue

        guard allGeneratedSource, !referencesLiteral else { return literals }
        debugLog(
            "[AppleScript] discarded unreferenced generated-script literal fields "
                + names.joined(separator: ",")
        )
        return AppleScriptLiterals()
    }

    /// Preserve the two exact user-visible values when a parent model puts a
    /// replacement pair in `task` but omits `contents`, or supplies only one of
    /// the values through the single `content` field. This recovers only the
    /// common `replace “old” with “new”`, `change … from “old” to “new”`, and
    /// the observed parent rewrite `file containing “old” and replace that
    /// text with “new”` forms: exactly two quoted values and a narrow
    /// replacement grammar are required.
    /// It extracts DATA only — it never guesses an app, document, or file.
    /// Ambiguous tasks (extra quoted values or no replacement grammar) remain
    /// unchanged.
    ///
    /// The recovered values still travel through the ordinary literal store
    /// and `taskForSubagent`, so the helper receives `{{oldText}}` and
    /// `{{newText}}` placeholders and never has to re-type the bytes.
    private static func exactReplacementLiterals(
        from task: String
    ) -> AppleScriptLiterals? {
        struct QuotedValue {
            let value: String
            let opening: String.Index
            let closing: String.Index
        }

        var quoted: [QuotedValue] = []
        var cursor = task.startIndex
        while cursor < task.endIndex {
            let character = task[cursor]
            let closingQuote: Character?
            switch character {
            case "\"": closingQuote = "\""
            case "“": closingQuote = "”"
            default: closingQuote = nil
            }
            guard let closingQuote else {
                cursor = task.index(after: cursor)
                continue
            }

            let valueStart = task.index(after: cursor)
            guard let close = task[valueStart...].firstIndex(of: closingQuote) else { return nil }
            quoted.append(
                QuotedValue(
                    value: String(task[valueStart..<close]),
                    opening: cursor,
                    closing: close
                )
            )
            cursor = task.index(after: close)
        }

        guard quoted.count == 2,
            !quoted[0].value.isEmpty,
            !quoted[1].value.isEmpty,
            !quoted[0].value.contains("{{"),
            !quoted[1].value.contains("{{")
        else { return nil }

        let beforeOld = task[..<quoted[0].opening].lowercased()
        let separatorStart = task.index(after: quoted[0].closing)
        let separator = task[separatorStart..<quoted[1].opening].lowercased()
        let trimmedBeforeOld = beforeOld.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSeparator = separator.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaceForm =
            trimmedSeparator == "with"
            && trimmedBeforeOld.range(of: #"\breplace\b"#, options: .regularExpression) != nil
        let changeForm =
            trimmedSeparator == "to"
            && trimmedBeforeOld.range(of: #"\bchange\b"#, options: .regularExpression) != nil
            && trimmedBeforeOld.range(of: #"\bfrom$"#, options: .regularExpression) != nil
        let changeOccurrenceForm =
            trimmedSeparator == "to"
            && trimmedBeforeOld.range(of: #"\bchange\b"#, options: .regularExpression) != nil
            && trimmedBeforeOld.range(
                of: #"\boccurrences?\s+of$"#,
                options: .regularExpression
            ) != nil
        let containingThenReplaceForm =
            trimmedBeforeOld.range(
                of: #"\b(?:file|document)\s+containing$"#,
                options: .regularExpression
            ) != nil
            && trimmedSeparator.range(
                of: #"^(?:and\s+)?replace\s+(?:that|the|this)\s+(?:text|content|string|value)\s+with$"#,
                options: .regularExpression
            ) != nil
        guard replaceForm || changeForm || changeOccurrenceForm || containingThenReplaceForm else {
            return nil
        }

        return AppleScriptLiterals([
            "oldText": quoted[0].value,
            "newText": quoted[1].value,
        ])
    }

    /// A partial literal map is safe to upgrade only when every supplied value
    /// exactly matches one of the two values visibly present in the task. A
    /// conflicting or extra value keeps the strict existing contract instead
    /// of being silently discarded.
    private static func suppliedLiteralsMatchReplacement(
        _ supplied: AppleScriptLiterals,
        inferred: AppleScriptLiterals
    ) -> Bool {
        let replacementValues = Set(
            inferred.names.compactMap { inferred.value(for: $0) }
        )
        guard !replacementValues.isEmpty else { return false }
        return supplied.names.allSatisfy { name in
            guard let value = supplied.value(for: name) else { return false }
            return replacementValues.contains(value)
        }
    }

    /// Literal fields are an out-of-band DATA channel, not a second instruction
    /// or script channel. An unreferenced literal can be silently ignored by the
    /// child model; worse, a parent model can accidentally put the AppleScript it
    /// invented into `content`, turning implementation text into user data. Fail
    /// closed at the tool boundary and give the parent one precise correction.
    ///
    /// Genuine user requests to insert AppleScript source as text remain valid
    /// when `task` explicitly identifies the supplied value as code/source.
    static func literalContractViolation(
        task: String,
        literals: AppleScriptLiterals
    ) -> LiteralContractViolation? {
        guard !literals.isEmpty else { return nil }

        let normalizedTask = task.lowercased()
        let names = literals.names
        let referencesLiteralValue = names.contains { name in
            guard let value = literals.value(for: name), !value.isEmpty else { return false }
            return task.range(of: value, options: [.literal, .caseInsensitive]) != nil
        }
        let referencesLiteral =
            normalizedTask.contains("provided")
            || normalizedTask.contains("content")
            || normalizedTask.contains("literal")
            || normalizedTask.contains("{{")
            || names.contains(where: { normalizedTask.contains($0.lowercased()) })
            || referencesLiteralValue

        if !referencesLiteral {
            let field = names == ["content"] ? "content" : "contents"
            return LiteralContractViolation(
                field: field,
                message:
                    "`\(field)` was supplied, but `task` does not tell the AppleScript subagent to use "
                    + "the provided literal value. Keep `task` as the desired outcome and put only exact "
                    + "user-supplied text in literal fields; do not place generated AppleScript there."
            )
        }

        let explicitlyInsertingSource =
            normalizedTask.contains("applescript source")
            || normalizedTask.contains("applescript code")
            || normalizedTask.contains("script source")
            || normalizedTask.contains("script text")
            || normalizedTask.contains("code as text")
        if !explicitlyInsertingSource,
            let scriptName = names.first(where: {
                guard let value = literals.value(for: $0) else { return false }
                return looksLikeAppleScriptSource(value)
            })
        {
            let field = scriptName == "content" ? "content" : "contents.\(scriptName)"
            return LiteralContractViolation(
                field: field,
                message:
                    "`\(field)` looks like generated AppleScript source, but literal fields may contain "
                    + "only exact user-supplied data. Describe the desired outcome in `task` and let the "
                    + "AppleScript subagent write the script. If the user really asked to insert source "
                    + "code as text, say that explicitly in `task`."
            )
        }

        return nil
    }

    /// Replace exact values repeated in the parent task with their named
    /// placeholder before handing the instruction to the helper. Longest
    /// values go first so overlapping short values cannot consume a prefix of
    /// a longer one. A task already phrased using `provided` values is left as
    /// written because it contains no literal bytes to redact.
    static func taskForSubagent(
        _ task: String,
        literals: AppleScriptLiterals
    ) -> String {
        guard !literals.isEmpty else { return task }
        var result = task
        let entries = literals.names.compactMap { name -> (String, String)? in
            guard let value = literals.value(for: name), !value.isEmpty else { return nil }
            return (name, value)
        }.sorted { lhs, rhs in
            if lhs.1.count != rhs.1.count { return lhs.1.count > rhs.1.count }
            return lhs.0 < rhs.0
        }
        for (name, value) in entries {
            result = result.replacingOccurrences(
                of: value,
                with: "{{\(name)}}",
                options: [.literal, .caseInsensitive]
            )
        }
        // In the narrow two-value replacement grammar, quotation marks in the
        // parent/user prose delimit the old/new values; they are not part of
        // those values. Once named placeholders occupy the slots, retaining
        // those marks is both redundant and hazardous: the live 16B path
        // copied typographic quotes from `“{{oldText}}”` / `“{{newText}}”`
        // into generated AppleScript source, which OSA rejects as an unknown
        // token. Strip only complete matching pairs around those two inferred
        // replacement placeholders. Generic content tasks may intentionally
        // ask for wrapper quotes, so their punctuation remains untouched.
        if exactReplacementLiterals(from: task) != nil {
            for name in ["oldText", "newText"] {
                let token = "{{\(name)}}"
                for (opening, closing) in [("\"", "\""), ("“", "”"), ("‘", "’")] {
                    result = result.replacingOccurrences(
                        of: opening + token + closing,
                        with: token,
                        options: .literal
                    )
                }
            }
        }
        return result
    }

    private static func looksLikeAppleScriptSource(_ value: String) -> Bool {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasBlock =
            (source.contains("tell application") && source.contains("end tell"))
            || (source.contains("tell process") && source.contains("end tell"))
            || (source.contains("on run") && source.contains("end run"))
        let hasAutomationCommand =
            source.contains("keystroke ")
            || source.contains("do shell script")
            || source.contains("using command down")
        return hasBlock || (source.contains("tell application") && hasAutomationCommand)
    }

    /// Build the literal store from the optional `content` string and/or the
    /// optional `contents` object map. Both are optional; when both define the
    /// reserved `content` key the `contents` entry wins (so a map author is
    /// never overridden by the single-block convenience). The exact bytes are
    /// preserved (NOT trimmed) so verbatim payloads survive; a whitespace-only
    /// value is skipped so it can't advertise an empty `{{name}}` placeholder.
    ///
    /// Values are read defensively: a literal that arrived as a non-`String`
    /// (e.g. an upstream normalization pass re-parsed a JSON-looking payload
    /// like `{"a":1}` into a dictionary) is recovered back to its string form
    /// rather than dropped, so verbatim JSON-looking content still reaches the
    /// script.
    static func literals(from args: [String: Any]) -> AppleScriptLiterals {
        var merged: [String: String] = [:]

        if let raw = args["contents"], !(raw is NSNull), let map = raw as? [String: Any] {
            for (name, value) in map {
                guard let text = stringLiteralValue(value),
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                merged[name] = text
            }
        }

        if merged["content"] == nil, let raw = args["content"], !(raw is NSNull),
            let text = stringLiteralValue(raw),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            merged["content"] = text
        }

        return AppleScriptLiterals(merged)
    }

    /// Recover the verbatim string for one literal value. A `String` passes
    /// through unchanged; a scalar (`Bool`/number) renders to its literal text;
    /// a collection an upstream JSON re-parse produced from a JSON-looking
    /// literal (`"{…}"` / `"[…]"`) is re-serialized so its content still
    /// reaches the script. `nil` when nothing textual can be recovered.
    private static func stringLiteralValue(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // Distinguish a bool-tagged NSNumber (JSON `true`/`false`) from a
            // numeric one via the CFBoolean type id — the NSNumber ⇄ Bool
            // bridging would otherwise coerce every non-zero number to `true`.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        return nil
    }
}
