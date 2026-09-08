//
//  GroundedKnowledgeClaimCheck.swift
//  osaurus
//
//  Deterministic grounding for answers ABOUT a knowledge collection.
//  Observed live (0.24.7, Discord): an agent with one granted collection,
//  "Obsidian Vault", called `list_knowledge {"collection":"knowledge"}`,
//  received `invalid_args` ("Unknown collection knowledge. Granted
//  collections: Obsidian Vault."), and answered "The Obsidian Vault
//  contains 20 documents — all dated 2025. The last entry is 20250318."
//  Nothing had been read; every number was invented from the `limit`
//  argument it had itself sent. Neither existing grounding check covers it:
//  `GroundedConfigClaimCheck` is about config changes and
//  `GroundedFileSideEffectCheck` about file writes.
//
//  Same contract as both: pure predicates over what actually executed and
//  over the visible text. Model output is never edited, stripped, or
//  synthesized. On a trip the loop stages a factual `[System Notice]` on the
//  transient channel and lets the model write its own corrected answer,
//  bounded by `AgentToolLoop.maxGroundedClaimRetries` — an ADVISORY nudge,
//  never a stop, never a refusal.
//

import Foundation

enum GroundedKnowledgeClaimCheck {

    /// The read-only knowledge tools. A SUCCESSFUL call to any of them this
    /// run grounds later statements about the collection's contents; a
    /// FAILED call with no later success is what this check is about.
    static let knowledgeReadToolNames: Set<String> = [
        "search_knowledge", "read_knowledge", "list_knowledge",
    ]

    /// True when this outcome is a successful knowledge read. After one of
    /// these, the model has real material and its counts are its own
    /// business — the check stays silent.
    static func isGroundedKnowledgeOutcome(toolName: String, result: String) -> Bool {
        guard knowledgeReadToolNames.contains(toolName) else { return false }
        return ToolEnvelope.isSuccess(result)
    }

    /// True when this outcome is a knowledge read that returned an error
    /// envelope of any kind (`invalid_args`, `rejected`, `unavailable`, …):
    /// nothing was read, so nothing it could have said is grounded.
    static func isFailedKnowledgeOutcome(toolName: String, result: String) -> Bool {
        guard knowledgeReadToolNames.contains(toolName) else { return false }
        return ToolEnvelope.isError(result)
    }

    /// The granted collection names the failure envelope itself lists
    /// ("… Granted collections: Obsidian Vault, Runbooks."), so the notice
    /// can repeat the exact names the retry needs. Empty when the envelope
    /// carries none (e.g. "no agent context").
    static func grantedCollectionNames(inFailure envelope: String) -> [String] {
        let message = ToolEnvelope.failureMessage(envelope)
        guard let range = message.range(of: "Granted collections:", options: .caseInsensitive) else {
            return []
        }
        var tail = String(message[range.upperBound...])
        if let newline = tail.firstIndex(of: "\n") { tail = String(tail[..<newline]) }
        // The envelope's sentence ends with ". " or end-of-text; a name may
        // itself contain a period, so only cut at a period followed by space.
        if let end = tail.range(of: ". ") { tail = String(tail[..<end.lowerBound]) }
        while tail.hasSuffix(".") { tail.removeLast() }
        return tail.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Corrective notice. `grantedNames` are the names the failed envelope
    /// listed (may be empty); `tool` is the knowledge tool that failed.
    static func ungroundedKnowledgeClaimNotice(tool: String, grantedNames: [String]) -> String {
        var notice =
            "[System Notice] Your previous answer states counts, dates, or contents of a knowledge "
            + "collection, but every knowledge tool call this turn FAILED (`\(tool)` returned an "
            + "error) and no knowledge tool succeeded — nothing was read, so those details are not "
            + "grounded and must not be presented as fact. "
        if grantedNames.isEmpty {
            notice +=
                "Call `list_knowledge` or `search_knowledge` again with the `collection` argument "
                + "omitted (all granted collections), "
        } else {
            let names = grantedNames.map { "`\($0)`" }.joined(separator: ", ")
            notice +=
                "The granted collection name\(grantedNames.count == 1 ? " is" : "s are") \(names). "
                + "Call `\(tool)` again with `collection` set to that exact name (or omit `collection` "
                + "to use all granted collections), "
        }
        notice +=
            "then answer from the real result. If you cannot read the collection, tell the user "
            + "plainly that the knowledge tool failed and what it said — do not estimate."
        return notice
    }

    // MARK: - Claim detection

    /// A count or listing about a corpus: "contains 20 documents", "there
    /// are 312 notes", "20 of them, all dated 2025", "the vault has 5
    /// folders", "the last entry is 20250318", "files: a.md, b.md".
    private static let claimPatterns: [NSRegularExpression] = {
        let unit =
            "(?:documents?|docs?|files?|notes?|entries|entry|items?|pages?|folders?|"
            + "directories|directory|records?|articles?|markdown\\s+files?|md\\s+files?)"
        let corpus =
            "(?:collection|vault|knowledge(?:\\s+base)?|library|folder|corpus|"
            + "index|repository|repo|wiki|notebook|archive)"
        let sources = [
            // "contains 20 documents", "has 312 notes", "holds 5 folders",
            // "lists 20 entries", "returned 50 files", "includes 3 pages".
            "\\b(?:contains?|has|have|holds?|includes?|lists?|returned|shows?|comprises?|"
                + "consists?\\s+of|made\\s+up\\s+of)\\s+(?:a\\s+total\\s+of\\s+|about\\s+|"
                + "around\\s+|roughly\\s+|approximately\\s+|exactly\\s+|only\\s+|just\\s+|"
                + "some\\s+)?\\d[\\d,]*\\s+(?:\\w+\\s+){0,2}" + unit + "\\b",
            // "there are 20 documents", "20 documents in the vault",
            // "a total of 312 notes".
            "\\b(?:there\\s+(?:are|is)|total\\s+of|totals?|totalling|totaling)\\s+"
                + "(?:about\\s+|around\\s+|roughly\\s+)?\\d[\\d,]*\\s+(?:\\w+\\s+){0,2}" + unit + "\\b",
            "\\b\\d[\\d,]*\\s+(?:\\w+\\s+){0,2}" + unit + "\\s+(?:in|inside|within|across|under)\\s+"
                + "(?:the\\s+|this\\s+|your\\s+|that\\s+)?" + corpus + "\\b",
            // "20 of them, all dated 2025" / "all of them dated 2025".
            "\\b\\d[\\d,]*\\s+of\\s+them\\b",
            // "the last entry is 20250318", "the newest note is …",
            // "the oldest file dates from …".
            "\\b(?:last|latest|newest|most\\s+recent|first|oldest|earliest)\\s+" + unit
                + "\\s+(?:is|was|dates?|dated|being)\\b",
            // "the collection/vault contains …" / "the vault has …" with a
            // specific structural claim.
            "\\b" + corpus + "\\s+(?:contains?|has|holds?|includes?|is\\s+organi[sz]ed|"
                + "is\\s+structured|consists?\\s+of|comprises?)\\b",
        ]
        return sources.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// Honest failure narration vetoes the sentence: "I could not read the
    /// collection", "the listing failed", "no documents were returned",
    /// "unable to access the vault".
    private static let negationPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            "\\b(?:cannot|can't|couldn't|could\\s+not|unable|failed|failing|failure|error|"
            + "not\\s+(?:able|available|accessible|found|granted|permitted|possible)|"
            + "no\\s+access|wasn't|weren't|didn't|did\\s+not|isn't|aren't|won't|"
            + "unavailable|inaccessible|rejected|denied|nothing\\s+was\\s+(?:read|returned|"
            + "listed|found))\\b",
        options: [.caseInsensitive]
    )

    /// Stated intent is not a claim: "I'll list the 20 most recent notes",
    /// "let me check how many documents the vault has".
    private static let intentPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            "\\b(?:i(?:'|’)?ll|i\\s+will|will|would|i(?:'|’)?d|let\\s+me|let's|going\\s+to"
            + "|about\\s+to|plan(?:ning)?\\s+to|need\\s+to|want(?:s)?\\s+(?:me\\s+)?to|shall"
            + "|should|could|can|may|might|try(?:ing)?\\s+to|ready\\s+to|able\\s+to|if)\\b",
        options: [.caseInsensitive]
    )

    /// True when any declarative sentence asserts a count, date, or
    /// structure of the collection's contents. Sentence-scoped so an honest
    /// negation or a plan elsewhere in the message can neither mask nor cause
    /// a match.
    static func containsCollectionContentClaim(_ text: String) -> Bool {
        for sentence in sentences(in: text) {
            guard !sentence.isQuestion else { continue }
            let range = NSRange(sentence.text.startIndex..., in: sentence.text)
            if let negation = negationPattern,
                negation.firstMatch(in: sentence.text, options: [], range: range) != nil
            {
                continue
            }
            if let intent = intentPattern,
                intent.firstMatch(in: sentence.text, options: [], range: range) != nil
            {
                continue
            }
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
    /// unit ended interrogatively. Mirrors `GroundedFileSideEffectCheck`.
    /// An em-dash clause ("20 documents — 20 of them, all dated 2025") stays
    /// in its sentence: it is the same assertion.
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
