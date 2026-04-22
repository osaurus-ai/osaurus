//
//  MemoryRelevanceGate.swift
//  osaurus
//
//  Cheap pre-flight check on the user's query: should we inject memory at
//  all, and if so what kind? Returns a `MemorySection` verdict the planner
//  uses to decide which slice to fetch.
//
//  Heuristic mode is fully synchronous: pronouns referencing prior context,
//  entity-name hits, temporal markers, and identity-curious phrases. LLM
//  mode adds a single classifier call when the heuristic is ambiguous.
//

import Foundation

public enum MemoryRecallSection: String, Sendable {
    /// No memory needed (default for greetings, math, code questions, etc.).
    case none
    /// Pull only the identity block ("who am I" style queries).
    case identity
    /// Pull only the top pinned facts ("did I tell you...", explicit recall).
    case pinned
    /// Pull a small set of relevant episodes ("what did we discuss...", "last time").
    case episode
    /// Pull a couple of literal transcript excerpts ("you said exactly...").
    case transcript
}

public enum MemoryRelevanceGate {
    /// Decide which (if any) memory section to surface for this query.
    public static func decide(
        query: String,
        identity: Identity?,
        knownEntities: [String],
        mode: MemoryRelevanceGateMode
    ) -> MemoryRecallSection {
        guard mode != .off else { return .episode }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return .none }

        let lower = trimmed.lowercased()

        if isIdentityCurious(lower) {
            return .identity
        }

        if isLiteralRecall(lower) {
            return .transcript
        }

        if hasTemporalMarker(lower) || hasPriorContextPronoun(lower) {
            return .episode
        }

        if hasEntityHit(lower, entities: knownEntities) {
            return .pinned
        }

        if hasExplicitRecallVerb(lower) {
            return .pinned
        }

        // Heuristic-only: when no signal fired, skip memory.
        if mode == .heuristic {
            return .none
        }

        // LLM mode would fall back to a tiny classifier call. We keep this
        // synchronous for now and default to skipping; the classifier hook
        // can be wired in later without changing call sites.
        return .none
    }

    // MARK: - Heuristics

    private static let identityPhrases: Set<String> = [
        "what's my name", "what is my name", "who am i", "tell me about myself",
        "what do you know about me", "what do you remember about me",
        "what do i do", "where do i work", "where am i from", "what's my job",
        "how old am i", "what's my role",
    ]

    private static func isIdentityCurious(_ s: String) -> Bool {
        for phrase in identityPhrases where s.contains(phrase) { return true }
        return false
    }

    private static let literalRecallPhrases: Set<String> = [
        "exact words", "exactly", "verbatim", "word for word", "literally said",
        "what i typed", "what i wrote",
    ]

    private static func isLiteralRecall(_ s: String) -> Bool {
        for p in literalRecallPhrases where s.contains(p) { return true }
        return false
    }

    private static let temporalPattern = try? NSRegularExpression(
        pattern:
            #"\b(yesterday|last (?:week|month|year|time|session)|earlier|previously|before|ago|when did|on (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|in (?:january|february|march|april|may|june|july|august|september|october|november|december)|\d{4}-\d{2}-\d{2})\b"#,
        options: [.caseInsensitive]
    )

    private static func hasTemporalMarker(_ s: String) -> Bool {
        guard let re = temporalPattern else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, range: range) != nil
    }

    private static let priorContextPattern = try? NSRegularExpression(
        pattern:
            #"\b(we discussed|we talked|you said|you told me|you mentioned|remember (?:when|that|the)|recall (?:when|that|the)|as i (?:said|mentioned)|like i said|that thing (?:we|i))\b"#,
        options: [.caseInsensitive]
    )

    private static func hasPriorContextPronoun(_ s: String) -> Bool {
        guard let re = priorContextPattern else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, range: range) != nil
    }

    private static func hasEntityHit(_ s: String, entities: [String]) -> Bool {
        guard !entities.isEmpty else { return false }
        for entity in entities {
            let lowered = entity.lowercased()
            // Skip very short entity names — they false-match common words
            // ("a", "i", "me", etc.).
            guard lowered.count >= 4 else { continue }
            if s.contains(lowered) { return true }
        }
        return false
    }

    private static let recallVerbPattern = try? NSRegularExpression(
        pattern: #"\b(remember|recall|forget|did i say|did i tell|do you know about my)\b"#,
        options: [.caseInsensitive]
    )

    private static func hasExplicitRecallVerb(_ s: String) -> Bool {
        guard let re = recallVerbPattern else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, range: range) != nil
    }
}
