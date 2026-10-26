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

    /// A pinned candidate that is, word for word, something the user typed in
    /// this session is the request itself, not a distilled fact. The bb10
    /// native replay pinned "Use file_read to read probe.json in the working
    /// folder. Return its current value without modifying any file." at 0.8
    /// salience; recall later handed it back to the model as something to
    /// always remember, and the model re-ran the finished task. Facts the
    /// distiller restates ("User's name is Eric", "User prefers metric
    /// units") never equal the typed turn, so they are unaffected.
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
        if ["none", "n/a", "na", "null", "nil", "unknown", "not specified", "no", "nothing"].contains(text) {
            return true
        }
        // Phrases that only occur when the model reports an empty slot. Kept
        // narrow on purpose: "not available on weekends" or "no information
        // shared with third parties" are real facts and must survive.
        let phrases = [
            "not specified", "unspecified", "not mentioned", "not provided", "not stated",
            "not disclosed", "no identity", "no identifying", "no facts",
            "none found", "none identified", "none mentioned", "nothing identity",
        ]
        if phrases.contains(where: text.contains) { return true }
        return text.hasSuffix(" is unknown") || text.hasSuffix(" are unknown")
    }
}
