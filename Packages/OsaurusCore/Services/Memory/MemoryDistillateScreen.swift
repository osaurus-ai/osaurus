//
//  MemoryDistillateScreen.swift
//  osaurus
//
//  One choke point between the core model's distill JSON and every durable
//  memory sink (agent pinned facts, the project mirror, always-on identity).
//  Screening once, before the fan-out, keeps the three sinks from drifting:
//  a candidate rejected for the agent namespace can't reappear through the
//  project mirror.
//

import Foundation

enum MemoryDistillateScreen {
    /// Filter a parsed distillate against the session it was distilled from.
    /// Only the two shapes below are removed; everything else passes through
    /// unchanged, including low-salience candidates, so recall quality still
    /// rests on the distiller and the existing dedupe.
    static func screen(
        _ result: MemoryService.DistillResult,
        userMessages: [String]
    ) -> MemoryService.DistillResult {
        var screened = result
        let typed = Set(userMessages.map(normalized).filter { !$0.isEmpty })
        screened.pinnedCandidates = result.pinnedCandidates.filter { candidate in
            let echo = typed.contains(normalized(candidate.content))
                && isRequestEcho(candidate.content)
            if echo {
                MemoryLogger.service.debug("pinned: skip verbatim user turn '\(candidate.content.prefix(60))'")
            }
            return !echo
        }
        screened.identityFacts = result.identityFacts.filter { fact in
            let placeholder = isAbsenceStatement(fact)
            if placeholder {
                MemoryLogger.service.debug("identity: skip absence statement '\(fact.prefix(60))'")
            }
            return !placeholder
        }
        return screened
    }

    /// Reject only the bounded imperative shapes evidenced in task echoes.
    /// Equality alone is insufficient: a durable fact or preference can be
    /// quoted verbatim and remains a valid memory. This is not a classifier
    /// for arbitrary paraphrased requests or transient tool results.
    static func isRequestEcho(_ text: String) -> Bool {
        normalized(text).range(
            of: #"^(?:please\s+)?(?:use\s+[\p{L}\p{N}_-]+\s+to\s+(?:read|write|run|execute|open|return)\b|(?:read|write|run|execute|open)\s+|return\s+(?:exactly|only)\s+)"#,
            options: .regularExpression
        ) != nil
    }

    /// The bb10 native replay pinned "Use file_read to read probe.json in the working
    /// folder. Return its current value without modifying any file." at 0.8
    /// salience; recall later handed it back to the model and it re-ran the
    /// finished task. Normalization only compares candidate and source text.
    static func normalized(_ text: String) -> String {
        let collapsed = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .!?;:,\"'`"))
    }

    /// Identity facts are injected into every request as things to always
    /// remember. Small core models fill the prompt's "User's name is X" slot
    /// even when nothing was said, producing "User's name is not specified"
    /// and "No identity facts found" (both present in the bb10 replay DB).
    /// Those are statements that a fact is absent, so they carry nothing.
    static func isAbsenceStatement(_ fact: String) -> Bool {
        let text = normalized(fact)
        guard !text.isEmpty else { return true }
        if ["none", "n/a", "na", "null", "nil", "unknown", "not specified", "unspecified",
            "not mentioned", "not provided", "not stated", "not disclosed", "no", "nothing"].contains(text)
        {
            return true
        }
        // Match a complete absence report, never a substring inside an
        // actual preference (e.g. salary not disclosed to coworkers).
        let absence = #"(?:not specified|unspecified|not mentioned|not provided|not stated|not disclosed|unknown)"#
        let slot = #"(?:(?:the )?user(?:'s)? (?:name|location|age|job|occupation|employer|workplace|identity) (?:is|are)|(?:the )?user works at)"#
        let emptyReport = #"(?:no (?:(?:identity(?:-relevant)?|identifying) )?(?:facts|information)(?: (?:were )?(?:found|identified|mentioned|provided))?|none (?:found|identified|mentioned)|nothing identity(?:-relevant)?)"#
        return text.range(
            of: "^(?:\(slot) \(absence)|\(emptyReport))$",
            options: .regularExpression
        ) != nil
    }
}
