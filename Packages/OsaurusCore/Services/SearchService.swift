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

    /// Main fuzzy search function. Returns true if query matches target via:
    /// 1. Token matching (each query word found in target)
    /// 2. Normalized substring (ignoring special characters)
    /// 3. Sequential character matching (fuzzy subsequence)
    static func matches(query: String, in target: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        // Try token-based matching first (handles multi-word queries)
        if tokenizedMatch(query: query, in: target) {
            return true
        }

        // Try normalized substring matching (handles queries like "glm47")
        let normalizedQuery = normalizeForSearch(query)
        let normalizedTarget = normalizeForSearch(target)
        if normalizedTarget.contains(normalizedQuery) {
            return true
        }

        // Fall back to fuzzy subsequence matching
        return fuzzyMatch(query: query, in: target)
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
        let query = query.lowercased()
        let target = target.lowercased()

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
    static func filterModels(_ models: [MLXModel], with searchText: String) -> [MLXModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }

        return models.filter { model in
            [model.name, model.id, model.description, model.downloadURL]
                .contains { matches(query: query, in: $0) }
        }
    }
}
