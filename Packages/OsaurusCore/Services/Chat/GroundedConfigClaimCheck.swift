//
//  GroundedConfigClaimCheck.swift
//  osaurus
//
//  Deterministic grounded-claim invariant for the configuration agent's
//  final responses. Three observed fabrication classes motivate it:
//
//  1. The model prints a raw tool-result envelope (sometimes with invented
//     data such as a fake API key) as its ANSWER after a tool error.
//  2. The model claims a configuration change happened ("I've rotated your
//     key", "your model has been set") in a turn where no `osaurus_config`
//     apply landed a single change.
//  3. The model prints a tool CALL as answer text (a fenced
//     `{"tool":"osaurus_config", …}` object) instead of invoking the tool —
//     the call never executes, so anything it implies is fabricated.
//
//  Both checks are pure text/state predicates over what actually executed —
//  no model output is ever edited, stripped, or synthesized. On a trip the
//  loop stages a factual `[System Notice]` (the same transient channel every
//  other typed recovery uses) and lets the model write its own corrected
//  answer, bounded by `AgentToolLoop.maxGroundedClaimRetries`.
//

import Foundation

enum GroundedConfigClaimCheck {

    /// The declarative write tool whose apply results ground change claims.
    static let configToolName = "osaurus_config"

    // MARK: - Apply-outcome grounding

    /// True when this tool outcome is an `osaurus_config` apply whose
    /// envelope reports that at least one change actually landed (a
    /// `done`/`started` row, or an aggregate applied status when rows are
    /// absent). Dry-run plans, denials, all-failed/cancelled applies, and
    /// every other tool return false.
    static func isGroundedApplyOutcome(
        toolName: String,
        argumentsJSON: String,
        result: String
    ) -> Bool {
        guard toolName == configToolName else { return false }
        guard let argsData = argumentsJSON.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
            let action = (args["action"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            action == "apply"
        else { return false }
        guard let resultData = result.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
            envelope["ok"] as? Bool == true,
            let payload = envelope["result"] as? [String: Any]
        else { return false }
        // Row-level truth beats the aggregate: a "partial" aggregate can
        // cover an all-failed apply, and a claim grounded on that would be
        // exactly the fabrication this check exists to catch.
        if let rows = payload["results"] as? [[String: Any]] {
            return rows.contains { row in
                let status = (row["status"] as? String) ?? ""
                return status == "done" || status == "started"
            }
        }
        let status = (payload["status"] as? String) ?? ""
        return status == "applied" || status == "applied_downloads_running"
    }

    // MARK: - Final-text checks

    /// Corrective notice when the final text is ungrounded, or nil when the
    /// answer passes. `hasGroundedApply` is whether any apply landed a
    /// change THIS run (one logical user turn).
    static func notice(finalText: String, hasGroundedApply: Bool) -> String? {
        if isFabricatedEnvelopeAnswer(finalText) {
            return fabricatedEnvelopeNotice
        }
        if containsFabricatedToolCall(finalText) {
            return fabricatedToolCallNotice
        }
        if !hasGroundedApply, containsUngroundedChangeClaim(finalText) {
            return ungroundedChangeClaimNotice
        }
        return nil
    }

    static let fabricatedEnvelopeNotice =
        "[System Notice] Your previous reply was a raw tool-result envelope, which is never a "
        + "valid answer — tool results only exist as real tool outputs, and inventing one is a "
        + "serious error. Answer the user in plain language grounded in the actual tool results "
        + "in this conversation (call the tool first if you have not)."

    static let ungroundedChangeClaimNotice =
        "[System Notice] Your previous reply claims a configuration change was made, but no "
        + "`osaurus_config` apply reported a completed change this turn — nothing has actually "
        + "changed. Either call osaurus_config {action: 'apply', yaml: ...} now to make the "
        + "change, or rewrite your answer to state accurately that no change was made."

    static let fabricatedToolCallNotice =
        "[System Notice] Your previous reply printed a tool call as text — a printed tool call "
        + "never executes, so nothing happened. To run the tool, invoke it through the normal "
        + "tool-calling channel now, then answer the user in plain language with the real result."

    /// A final answer that IS a tool-result envelope: after stripping an
    /// optional code fence, the text is a JSON object carrying the envelope's
    /// `ok` discriminator (parsed when well-formed; prefix-matched when the
    /// fabrication was cut off mid-generation).
    static func isFabricatedEnvelopeAnswer(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst()
                .joined(separator: "\n")
            if let fenceEnd = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<fenceEnd.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard trimmed.hasPrefix("{") else { return false }
        if let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return object["ok"] != nil
        }
        // Truncated fabrication: unparseable, but unmistakably envelope-shaped.
        let compactPrefix = String(trimmed.prefix(24)).replacingOccurrences(of: " ", with: "")
        return compactPrefix.hasPrefix("{\"ok\"")
    }

    /// A final answer that prints a tool CALL as text (observed live: prose
    /// followed by a fenced `{"tool":"osaurus_config","action":"apply",…}`
    /// block). A printed call never executes, so it is never a valid answer.
    /// Scoped tightly to JSON objects whose `tool` key names an `osaurus_*`
    /// tool — YAML samples, config exports, and ordinary code examples in an
    /// answer never match.
    static func containsFabricatedToolCall(_ text: String) -> Bool {
        var candidates: [String] = []
        let trimmedWhole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWhole.hasPrefix("{") {
            candidates.append(trimmedWhole)
        }
        // Fenced blocks: segments at odd indices after splitting on ```.
        let segments = text.components(separatedBy: "```")
        if segments.count >= 3 {
            for index in stride(from: 1, to: segments.count, by: 2) {
                var block = segments[index]
                // Drop a leading language tag line (e.g. "json").
                if let newline = block.firstIndex(of: "\n") {
                    let firstLine = block[..<newline].trimmingCharacters(in: .whitespaces)
                    if !firstLine.isEmpty, !firstLine.hasPrefix("{") {
                        block = String(block[block.index(after: newline)...])
                    }
                }
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") { candidates.append(trimmed) }
            }
        }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let toolName = object["tool"] as? String,
                toolName.hasPrefix("osaurus_")
            {
                return true
            }
            // Truncated mid-generation: unparseable but unmistakably a call.
            let compactPrefix = String(candidate.prefix(32)).replacingOccurrences(of: " ", with: "")
            if compactPrefix.hasPrefix("{\"tool\":\"osaurus_") { return true }
        }
        return false
    }

    /// Past/perfect change verbs that read unambiguously as "this already
    /// happened" after a first-person subject or in passive voice.
    private static let changeVerbs =
        "updated|changed|rotated|installed|uninstalled|created|added|removed|deleted|applied"
        + "|configured|enabled|disabled|switched|renamed|retired|activated|deactivated|saved"
        + "|stored|downloaded|imported|registered|connected|disconnected|paused|resumed|spun up"

    /// Claim patterns. "set" is present/past ambiguous ("Should I set…?"),
    /// so it only counts in perfect/passive/"is now" forms where the tense
    /// is explicit.
    private static let claimPatterns: [NSRegularExpression] = {
        let verbs = changeVerbs
        let verbsWithSet = verbs + "|set"
        let sources = [
            // "I've rotated…", "I have now set…", "I just installed…"
            "\\bi(?:'|’)?ve\\s+(?:now\\s+|just\\s+|also\\s+|already\\s+|successfully\\s+)?(?:\(verbsWithSet))\\b",
            "\\bi\\s+have\\s+(?:now\\s+|just\\s+|also\\s+|already\\s+|successfully\\s+)?(?:\(verbsWithSet))\\b",
            // "I updated…" (unambiguous past forms only — never bare "I set")
            "\\bi\\s+(?:just\\s+|also\\s+|successfully\\s+)?(?:\(verbs))\\b",
            // "I set your budgets…" — bare "I set" IS a past claim when it
            // takes a direct object and is not conditional/interrogative
            // (questions are already vetoed at the sentence level). Observed
            // live: "Done! I set your delegated subagent budgets".
            "(?<!\\bif\\s)(?<!\\bwhen\\s)(?<!\\bunless\\s)(?<!\\bonce\\s)(?<!\\bbefore\\s)"
                + "(?<!\\bshould\\s)(?<!\\bcould\\s)(?<!\\bcan\\s)(?<!\\bshall\\s)(?<!\\bmay\\s)"
                + "(?<!\\bmight\\s)(?<!\\bwould\\s)(?<!\\bdo\\s)(?<!\\bdid\\s)"
                + "\\bi\\s+set\\s+(?:up\\s+)?(?:your|the|this|that|these|those|it|them|both|all|a|an|new)\\b",
            // "…has been set", "…was rotated", "…were removed", and passive
            // participle chains — "was exported, planned, and applied"
            // (observed live) — where the change verb closes the chain.
            "\\b(?:has|have)\\s+been\\s+(?:successfully\\s+)?(?:\(verbsWithSet))\\b",
            "\\b(?:was|were)\\s+(?:successfully\\s+)?(?:[a-z]+ed[,\\s]+(?:and\\s+)?){0,3}(?:\(verbsWithSet))\\b",
            // "…is now set", "…are now active", "your old key is now retired",
            // "your subagents are now capped at 2" (observed live)
            "\\b(?:is|are)\\s+now\\s+(?:\(verbsWithSet)|active|live|in\\s+place|in\\s+effect|gone|capped|limited|enforced)\\b",
            // "Successfully installed the plugin"
            "\\bsuccessfully\\s+(?:\(verbsWithSet))\\b",
        ]
        return sources.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// The claim must be ABOUT the configuration surface: a config-domain
    /// noun in the same sentence keeps ordinary prose ("I've explained the
    /// steps") from tripping.
    private static let configNounPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            "\\b(?:key|token|credential|secret|provider|model|plugin|agent|subagent|schedule"
            + "|watcher|channel|command|mcp|server|memory|memories|knowledge|collection|tool"
            + "|setting|configuration|config|download|delegation|budget|limit|policy|policies"
            + "|personality|prompt)s?\\b",
        options: [.caseInsensitive]
    )

    /// Negation vocabulary that vetoes a sentence: "no key was set or
    /// rotated", "nothing has been changed", "the plan was created as a dry
    /// run — not applied".
    private static let negationPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            "\\b(?:no|not|never|nothing|none|cannot|can't|couldn't|didn't|wasn't|weren't"
            + "|hasn't|haven't|isn't|aren't|won't|unable|without|dry.run|unchanged)\\b",
        options: [.caseInsensitive]
    )

    /// True when any declarative sentence claims a config change was made.
    /// Sentence-scoped so an honest negation or an unrelated clause elsewhere
    /// in the reply can't mask or cause a match.
    static func containsUngroundedChangeClaim(_ text: String) -> Bool {
        for sentence in sentences(in: text) {
            guard !sentence.isQuestion else { continue }
            let range = NSRange(sentence.text.startIndex..., in: sentence.text)
            if let negation = negationPattern,
                negation.firstMatch(in: sentence.text, options: [], range: range) != nil
            {
                continue
            }
            guard let nouns = configNounPattern,
                nouns.firstMatch(in: sentence.text, options: [], range: range) != nil
            else { continue }
            for pattern in claimPatterns
            where pattern.firstMatch(in: sentence.text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private struct Sentence {
        let text: String
        let isQuestion: Bool
    }

    /// Split on sentence terminators and newlines, remembering whether each
    /// unit ended interrogatively ("Should I set your model to X?").
    private static func sentences(in text: String) -> [Sentence] {
        var result: [Sentence] = []
        var current = ""
        for character in text {
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(Sentence(text: trimmed, isQuestion: character == "?"))
                }
                current = ""
            } else {
                current.append(character)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(Sentence(text: trimmed, isQuestion: false))
        }
        return result
    }
}
