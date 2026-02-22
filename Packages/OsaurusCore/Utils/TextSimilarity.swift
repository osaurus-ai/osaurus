//
//  TextSimilarity.swift
//  osaurus
//
//  Shared text similarity utilities used by MemoryService and MemorySearchService.
//

import Foundation

public enum TextSimilarity {
    /// Jaccard similarity between two strings based on word-level token overlap.
    /// Returns a value in [0, 1] where 1 means identical word sets.
    public static func jaccard(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(separator: " ").map(String.init))
        let wordsB = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }
}
