//
//  CapabilityQueryIntent.swift
//  osaurus
//
//  Cheap, deterministic query-intent gate that runs BEFORE capability
//  search (BM25 + embed + RRF). Its only job is to recognize a query that
//  is purely conversational — a greeting, a thank-you, a closing
//  pleasantry — and short-circuit capability discovery to an empty result.
//
//  Why this exists: rank-based RRF with k=60 saturates near
//  `2/(60+1) ≈ 0.0328`, so an abstain-noise tool that merely *ranks* in the
//  embed top-K fuses into the same ~0.03 band as real recall. No single
//  fused-score or cosine floor separates "thanks, that's perfect" from a
//  real capability request without also dropping legitimate recall
//  (proven by the 2026-06 sweep in Config/capability-search-sweep.md). The
//  documented correct fix is a query-intent abstain gate, not a higher
//  threshold — this is it.
//
//  Design contract: PRECISION OVER RECALL. A false abstain (suppressing a
//  real capability request) is far worse than a missed abstain (a greeting
//  that slips through and gets caught by the cosine floors anyway), so the
//  gate fires ONLY when EVERY content token is a known pleasantry. A single
//  capability token — "weather", "browser", "summarize", "gist", "chart",
//  "pdf", "debug" … — keeps the query out of the abstain bucket. The gate
//  carries no model and no allocation beyond tokenization, so it is safe on
//  the hot `capabilities_discover` path.
//

import Foundation

enum CapabilityQueryIntent {

    /// True when `query` is purely conversational chit-chat with no
    /// capability/action intent, so capability search should abstain
    /// (return no methods/tools/skills) instead of fusing noise hits.
    ///
    /// Rule: tokenize, drop function-word stopwords, and abstain only when
    /// at least one token remains AND every remaining token is a known
    /// pleasantry. An empty residue (e.g. "do it") does NOT abstain — there
    /// is no pleasantry signal to act on, and the search lanes will return
    /// nothing relevant on their own.
    static func isConversationalAbstain(_ query: String) -> Bool {
        let tokens = contentTokens(query)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { pleasantries.contains($0) }
    }

    /// Lowercase alphanumeric tokens with stopwords removed. Apostrophes
    /// are stripped first so contractions normalize ("that's" → "thats",
    /// "what's" → "whats") and match the stopword list.
    private static func contentTokens(_ query: String) -> [String] {
        let folded =
            query
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")  // curly apostrophe
        let raw = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return raw.filter { !stopwords.contains($0) }
    }

    /// Function words that carry neither capability intent nor pleasantry
    /// signal. Removed before the decision so "thanks, that's perfect"
    /// reduces to {thanks, perfect} and "what's the weather" keeps
    /// {weather} (a capability token) and never abstains.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "this", "that", "thats", "these", "those",
        "it", "its", "is", "are", "was", "were", "be", "been",
        "to", "for", "of", "in", "on", "at", "with", "from", "by",
        "and", "or", "but", "if", "as",
        "me", "my", "mine", "you", "your", "yours", "youre", "i", "im",
        "we", "our", "us", "he", "she", "they", "them",
        "so", "very", "really", "much", "just", "now", "then",
        "here", "there", "all", "any", "some",
        "please", "pls", "plz",
        "would", "could", "can", "will", "shall", "should", "may",
        "do", "does", "did", "am", "what", "whats", "how",
    ]

    /// Pure conversational pleasantries: greetings, gratitude,
    /// acknowledgements, affirmations/negations, and farewells. Deliberately
    /// excludes action verbs (make, help, give, run, open, find, show,
    /// create, send, search …) and capability nouns so a real request is
    /// never classified as chit-chat.
    private static let pleasantries: Set<String> = [
        // Greetings
        "hi", "hello", "hey", "heya", "hiya", "yo", "sup", "howdy",
        "greetings", "hai", "hallo", "hullo",
        // Time-of-day greetings (compose with "good")
        "morning", "afternoon", "evening", "gm", "ge",
        // Gratitude
        "thanks", "thank", "thankyou", "thx", "thnx", "ty", "tysm",
        "cheers", "ta", "appreciated",
        // Acknowledgement / closing
        "ok", "okay", "okey", "k", "kk", "oki", "cool", "great", "perfect",
        "awesome", "nice", "sweet", "excellent", "wonderful", "amazing",
        "fantastic", "brilliant", "good", "fine", "alright", "allgood",
        "gotcha", "noted", "understood", "done", "neat", "lovely",
        "super", "splendid", "marvelous", "wicked",
        // Affirmation / negation standing alone
        "yes", "yeah", "yep", "yup", "ya", "no", "nope", "nah", "sure",
        // Farewells
        "bye", "goodbye", "cya", "ttyl", "later", "night", "goodnight",
        "farewell", "adios", "ciao",
        // Filler / interjections
        "lol", "haha", "hah", "hehe", "oh", "ah", "aha", "hmm", "hm",
        "welcome", "np", "yw", "word", "dope", "rad", "okthanks",
    ]
}
