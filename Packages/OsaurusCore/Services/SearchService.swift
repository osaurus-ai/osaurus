//
//  SearchService.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// Service for handling search functionality across the app
struct SearchService {

    // MARK: - Text Processing

    /// Normalizes text by removing special characters and converting to lowercase.
    static func normalizeForSearch(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Splits text into lowercase tokens on non-alphanumeric characters.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Search Matching

    /// Query-side work (trim, tokenize, normalize, lowercase) hoisted out of
    /// the per-target loop. Filtering many targets with the same query would
    /// otherwise redo all of it once per target — the dominant cost when the
    /// model catalog is large.
    struct PreparedQuery {
        let tokens: [String]
        let normalized: String
        let lowercased: String

        init(_ query: String) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            self.tokens = SearchService.tokenize(trimmed)
            self.normalized = SearchService.normalizeForSearch(trimmed)
            self.lowercased = trimmed.lowercased()
        }
    }

    /// Returns true if query matches target via token matching, normalized
    /// substring, or (when `allowFuzzy`) sequential character matching.
    ///
    /// `allowFuzzy` should only be enabled for short identifier-style
    /// fields (name, id). Subsequence matching against prose-length strings
    /// like a description produces false positives
    static func matches(query: String, in target: String, allowFuzzy: Bool = true) -> Bool {
        matches(PreparedQuery(query), in: target, allowFuzzy: allowFuzzy)
    }

    /// Prepared-query variant. A query with no alphanumeric tokens (empty or
    /// punctuation-only) matches everything, mirroring the original early-out
    /// in `matches`/`tokenizedMatch`.
    static func matches(_ query: PreparedQuery, in target: String, allowFuzzy: Bool = true) -> Bool {
        guard !query.tokens.isEmpty else { return true }

        let targetTokens = tokenize(target)
        let normalizedTarget = normalizeForSearch(target)

        let tokenized = query.tokens.allSatisfy { queryToken in
            targetTokens.contains { $0.contains(queryToken) } || normalizedTarget.contains(queryToken)
        }
        if tokenized { return true }

        if normalizedTarget.contains(query.normalized) {
            return true
        }

        guard allowFuzzy else { return false }
        return fuzzyMatch(lowercasedQuery: query.lowercased, inLowercased: target.lowercased())
    }

    /// Returns true if all query tokens are found in target (order independent).
    static func tokenizedMatch(query: String, in target: String) -> Bool {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return true }

        let targetTokens = tokenize(target)
        let normalizedTarget = normalizeForSearch(target)

        return queryTokens.allSatisfy { queryToken in
            targetTokens.contains { $0.contains(queryToken) } || normalizedTarget.contains(queryToken)
        }
    }

    /// Returns true if all query characters appear in target in order (subsequence match).
    static func fuzzyMatch(query: String, in target: String) -> Bool {
        fuzzyMatch(lowercasedQuery: query.lowercased(), inLowercased: target.lowercased())
    }

    /// Subsequence match with both sides already lowercased, so the query side
    /// can be lowercased once and reused across many targets.
    static func fuzzyMatch(lowercasedQuery query: String, inLowercased target: String) -> Bool {
        var queryIndex = query.startIndex
        var targetIndex = target.startIndex

        while queryIndex < query.endIndex, targetIndex < target.endIndex {
            if query[queryIndex] == target[targetIndex] {
                queryIndex = query.index(after: queryIndex)
            }
            targetIndex = target.index(after: targetIndex)
        }

        return queryIndex == query.endIndex
    }

    // MARK: - Model Filtering

    /// Filters models by matching query against name, id, description, and URL.
    /// Fuzzy subsequence matching is enabled only for the short identifier
    /// fields (name, id)
    static func filterModels(_ models: [MLXModel], with searchText: String) -> [MLXModel] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }

        // Prepare the query once, then reuse it for every model and field.
        let query = PreparedQuery(trimmed)
        return models.filter { model in
            matches(query, in: model.name)
                || matches(query, in: model.id)
                || matches(query, in: model.description, allowFuzzy: false)
                || matches(query, in: model.downloadURL, allowFuzzy: false)
        }
    }
}
