//
//  DegenerationDetector.swift
//  osaurus
//
//  Pure repetition detector for the gauntlet's degeneration canary
//  (`osaurus bench --gauntlet`). Long greedy generations are where broken
//  bundles betray themselves — the two failure modes seen in the wild are a
//  single character repeated forever (`!!!!!…`) and a short phrase looping
//  (`idea idea idea…`) — so the detector targets exactly those shapes:
//
//    - any single character repeated `minCharacterRun` (64) or more times
//      consecutively, and
//    - any n-gram of `minNGram`...`maxNGram` (2–12) whitespace-separated
//      tokens occurring `minConsecutiveRepeats` (8) or more times
//      back-to-back.
//
//  "Token" here means a whitespace-separated word, not a model token: the
//  detector runs client-side over streamed text and must not depend on any
//  tokenizer. A pure single-word loop (`idea idea …`) is caught by the
//  3-gram rule once it spans 24 words; a pure character loop is caught by
//  the run rule regardless of whitespace. Pure function, no I/O — kept that
//  way so it stays unit-testable.
//

import Foundation

public enum DegenerationDetector {
    /// Smallest and largest repeating unit considered, in whitespace tokens.
    public static let minNGram = 2
    public static let maxNGram = 12
    /// An n-gram must occur this many times back-to-back to count as a loop.
    public static let minConsecutiveRepeats = 8
    /// A single character repeated this many times consecutively is a loop.
    public static let minCharacterRun = 64

    /// Returns human-readable evidence (containing the repeating fragment)
    /// when `text` degenerates per the thresholds above, or nil when clean.
    /// Scan the FULL generation — reasoning and content — because loops
    /// routinely start inside the thinking channel.
    public static func detect(in text: String) -> String? {
        if let (character, length) = firstCharacterRun(atLeast: minCharacterRun, in: text) {
            return "character \"\(character)\" repeated \(length)x consecutively"
        }

        let tokens = text.split(whereSeparator: \.isWhitespace)
        for n in minNGram...maxNGram {
            // A loop of period n needs at least n × repeats tokens; larger
            // n needs strictly more, so once one n is impossible all are.
            guard tokens.count >= n * minConsecutiveRepeats else { break }
            var start = 0
            while start + n * minConsecutiveRepeats <= tokens.count {
                var occurrences = 1
                var next = start + n
                while next + n <= tokens.count,
                    blocksEqual(tokens, start, next, length: n) {
                    occurrences += 1
                    next += n
                }
                if occurrences >= minConsecutiveRepeats {
                    let fragment = tokens[start..<(start + n)].joined(separator: " ")
                    return "\(n)-token n-gram \"\(truncated(fragment))\" repeated \(occurrences)x consecutively"
                }
                start += 1
            }
        }
        return nil
    }

    /// First run of a single repeated character reaching `threshold`,
    /// returned with its full length for evidence.
    private static func firstCharacterRun(
        atLeast threshold: Int, in text: String
    ) -> (Character, Int)? {
        var runCharacter: Character?
        var runLength = 0
        for character in text {
            if character == runCharacter {
                runLength += 1
            } else {
                if runLength >= threshold, let runCharacter {
                    return (runCharacter, runLength)
                }
                runCharacter = character
                runLength = 1
            }
        }
        if runLength >= threshold, let runCharacter {
            return (runCharacter, runLength)
        }
        return nil
    }

    private static func blocksEqual(
        _ tokens: [Substring], _ a: Int, _ b: Int, length: Int
    ) -> Bool {
        for offset in 0..<length where tokens[a + offset] != tokens[b + offset] {
            return false
        }
        return true
    }

    private static func truncated(_ fragment: String, limit: Int = 80) -> String {
        fragment.count <= limit ? fragment : String(fragment.prefix(limit)) + "…"
    }
}
