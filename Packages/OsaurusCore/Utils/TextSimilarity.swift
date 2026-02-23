//
//  TextSimilarity.swift
//  osaurus
//
//  Shared text similarity utilities used by MemoryService and MemorySearchService.
//

import Foundation

public enum TextSimilarity {
    /// Tokenize a string into a lowercase word set for reuse across multiple comparisons.
    public static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased().split(separator: " ").map(String.init))
    }

    /// Jaccard similarity between two strings based on word-level token overlap.
    /// Returns a value in [0, 1] where 1 means identical word sets.
    public static func jaccard(_ a: String, _ b: String) -> Double {
        jaccardTokenized(tokenize(a), tokenize(b))
    }

    /// Jaccard similarity using pre-tokenized word sets.
    /// Use when comparing one candidate against many existing entries to avoid repeated tokenization.
    public static func jaccardTokenized(_ wordsA: Set<String>, _ wordsB: Set<String>) -> Double {
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }
}
