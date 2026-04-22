//
//  TextSimilarity.swift
//  osaurus
//
//  Shared text utilities used by the memory subsystem: tokenization,
//  Jaccard similarity over both word and shingle sets, and a deterministic
//  UUID derived from a stable composite key (used to pin VecturaKit
//  document IDs to SQLite rows without a reverse-map at startup).
//

import CryptoKit
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

    /// Jaccard similarity using pre-tokenized sets. Use when comparing one
    /// candidate against many existing entries to avoid repeated tokenization.
    public static func jaccardTokenized<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }

    /// Cheap word-shingle set: each alphanumeric run becomes one entry,
    /// truncated to 8 chars. Used by MMR dedup and the consolidator's
    /// near-duplicate episode merge — both want a coarse "do these texts
    /// overlap?" signal that's faster than tokenizing into a `Set<String>`
    /// of every word.
    public static func shingleSet(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.insert(current.count >= 4 ? String(current.prefix(8)) : current)
                current = ""
            }
        }
        if !current.isEmpty {
            out.insert(current.count >= 4 ? String(current.prefix(8)) : current)
        }
        return out
    }

    /// Deterministic UUID v5-ish: SHA-256 of the input, with the version
    /// and variant bits set so VecturaKit accepts it as a real UUID. Used
    /// to map composite keys (`"episode:42"`, `"transcript:conv-1:7"`,
    /// etc.) to stable VecturaKit document IDs without a reverse-map.
    public static func deterministicUUID(from string: String) -> UUID {
        let hash = SHA256.hash(data: Data(string.utf8))
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}
