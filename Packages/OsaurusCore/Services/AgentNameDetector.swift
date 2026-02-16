//
//  AgentNameDetector.swift
//  osaurus
//
//  Detects agent names in transcribed text for VAD activation.
//  Supports fuzzy matching and custom wake phrases.
//

import Foundation

/// Detects agent names in transcribed speech
@MainActor
public final class AgentNameDetector {
    /// IDs of agents enabled for VAD detection
    private let enabledAgentIds: [UUID]

    /// Custom wake phrase (e.g., "Hey Osaurus")
    private let customWakePhrase: String

    /// Cached agent names for matching
    private let agentNames: [(id: UUID, name: String, normalizedName: String)]

    /// Common wake phrase variations
    private static let wakeVariations = [
        "hey",
        "hi",
        "hello",
        "ok",
        "okay",
        "yo",
    ]

    public init(enabledAgentIds: [UUID], customWakePhrase: String = "") {
        self.enabledAgentIds = enabledAgentIds
        self.customWakePhrase = customWakePhrase

        // Load agent names synchronously from AgentManager
        let manager = AgentManager.shared
        self.agentNames = enabledAgentIds.compactMap { id in
            guard let agent = manager.agent(for: id) else { return nil }
            return (id: id, name: agent.name, normalizedName: Self.normalizeText(agent.name))
        }
    }

    /// Static helper for normalization (used in init)
    private static func normalizeText(_ text: String) -> String {
        text
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Detect an agent name in the given transcription
    public func detect(in transcription: String) -> VADDetectionResult? {
        let normalized = Self.normalizeText(transcription)

        // First check custom wake phrase
        if !customWakePhrase.isEmpty {
            if checkWakePhrase(in: normalized) {
                // Custom wake phrase detected, but no specific agent
                // Return the first enabled agent or a default
                if let first = agentNames.first {
                    return VADDetectionResult(
                        agentId: first.id,
                        agentName: first.name,
                        confidence: 0.9,
                        transcription: transcription
                    )
                }
            }
        }

        // Check for agent names
        for agent in agentNames {
            if let match = findMatch(for: agent.normalizedName, in: normalized) {
                return VADDetectionResult(
                    agentId: agent.id,
                    agentName: agent.name,
                    confidence: match.confidence,
                    transcription: transcription
                )
            }
        }

        // Check for variations like "Hey [Agent]"
        for agent in agentNames {
            for wake in Self.wakeVariations {
                let pattern = "\(wake) \(agent.normalizedName)"
                if let match = findMatch(for: pattern, in: normalized) {
                    return VADDetectionResult(
                        agentId: agent.id,
                        agentName: agent.name,
                        confidence: match.confidence * 1.1,  // Boost for explicit wake word
                        transcription: transcription
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Private Methods

    /// Check if the custom wake phrase is in the text
    private func checkWakePhrase(in normalizedText: String) -> Bool {
        let normalizedPhrase = Self.normalizeText(customWakePhrase)
        return normalizedText.contains(normalizedPhrase)
    }

    /// Find a match for the pattern in the text
    private func findMatch(for pattern: String, in text: String) -> (confidence: Float, range: Range<String.Index>)? {
        // Exact match
        if let range = text.range(of: pattern) {
            return (confidence: 1.0, range: range)
        }

        // Fuzzy match - check if words are contained
        let patternWords = pattern.split(separator: " ")
        let textWords = text.split(separator: " ")

        guard !patternWords.isEmpty else { return nil }

        var matchedWords = 0
        for patternWord in patternWords {
            for textWord in textWords {
                if fuzzyMatch(String(patternWord), String(textWord)) {
                    matchedWords += 1
                    break
                }
            }
        }

        let matchRatio = Float(matchedWords) / Float(patternWords.count)

        // Require at least 70% of words to match
        if matchRatio >= 0.7 {
            return (confidence: matchRatio, range: text.startIndex ..< text.endIndex)
        }

        return nil
    }

    /// Fuzzy match two words using Levenshtein distance
    private func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }

        // Allow for small differences (1-2 characters for short words)
        let maxDistance = max(1, min(a.count, b.count) / 4)
        let distance = levenshteinDistance(a, b)

        return distance <= maxDistance
    }

    /// Calculate Levenshtein distance between two strings
    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 0 ... m { matrix[i][0] = i }
        for j in 0 ... n { matrix[0][j] = j }

        for i in 1 ... m {
            for j in 1 ... n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,  // deletion
                    matrix[i][j - 1] + 1,  // insertion
                    matrix[i - 1][j - 1] + cost  // substitution
                )
            }
        }

        return matrix[m][n]
    }
}
