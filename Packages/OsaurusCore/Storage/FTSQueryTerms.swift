//
//  FTSQueryTerms.swift
//  osaurus
//
//  Shared term selection for the FTS5 recall queries in MemoryDatabase and
//  KnowledgeDatabase. Both OR-join prefix terms, so a function word like
//  "the" or "to" matches nearly every row: any question then "recalls"
//  something, and an unrelated stored instruction can ride along on words
//  it merely shares with the query.
//

import Foundation

enum FTSQueryTerms {
    /// English function words that carry no topic. Content words (including
    /// short ones such as names) are never listed here.
    static let stopwords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "be", "been", "before", "being", "but", "by", "can", "could", "did", "do", "does", "for",
        "from", "had", "has", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in",
        "into", "is", "it", "its", "just", "me", "my", "no", "not", "of", "on", "only", "or",
        "our", "please", "she", "should", "so", "some", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "those", "to", "too", "us", "very", "was", "we",
        "were", "what", "when", "where", "which", "who", "whom", "why", "will", "with", "would",
        "you", "your",
    ]

    /// Drop function words. A query made only of function words (a user
    /// literally searching "to be or not") keeps its full term list so it
    /// still matches.
    static func droppingStopwords(_ words: [String]) -> [String] {
        let kept = words.filter { !stopwords.contains($0.lowercased()) }
        return kept.isEmpty ? words : kept
    }
}
