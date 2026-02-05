//
//  DiscoveryDetector.swift
//  osaurus
//
//  Detects discoverable work from tool outputs and execution results.
//  Creates linked issues for bugs, TODOs, prerequisites, and follow-up work.
//
//  DEPRECATED: This class was part of the waterfall pipeline and is no longer used.
//  The reasoning loop architecture uses the `create_issue` tool for follow-up work.
//

import Foundation

/// Detects discoveries from tool outputs and execution results
/// - Note: DEPRECATED - Waterfall pipeline removed. Use create_issue tool instead.
@available(*, deprecated, message: "Waterfall pipeline removed. Use create_issue tool instead.")
public actor DiscoveryDetector {
    /// Patterns to detect in tool outputs
    private let patterns: [DiscoveryPattern]

    public init() {
        self.patterns = Self.defaultPatterns
    }

    // MARK: - Detection

    /// Analyzes tool output for discoveries
    public func analyze(toolOutput: String, toolName: String, context: DiscoveryContext) -> [Discovery] {
        let sourcePrefix = buildSourcePrefix(toolName: toolName, context: context)

        let discoveries = patterns.flatMap { pattern in
            pattern.detect(in: toolOutput).map { match in
                let source = match.source.map { "\(sourcePrefix): \($0)" } ?? sourcePrefix
                return Discovery(
                    type: match.type,
                    title: match.title,
                    description: match.description,
                    source: source,
                    suggestedPriority: match.suggestedPriority
                )
            }
        }

        return deduplicateDiscoveries(discoveries)
    }

    /// Analyzes LLM response for discoveries
    public func analyzeResponse(response: String, context: DiscoveryContext) -> [Discovery] {
        let sourcePrefix = buildSourcePrefix(toolName: "Agent response", context: context)
        var discoveries: [Discovery] = []

        let markerPattern = #"(?:DISCOVERY|FOUND|TODO|FIXME|BUG|NOTE|WARNING):\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: markerPattern, options: .caseInsensitive) else {
            return []
        }

        let range = NSRange(response.startIndex..., in: response)
        for match in regex.matches(in: response, options: [], range: range) {
            guard let descRange = Range(match.range(at: 1), in: response),
                let fullRange = Range(match.range, in: response)
            else { continue }

            let description = String(response[descRange]).trimmingCharacters(in: .whitespaces)
            let type = detectDiscoveryType(from: response[fullRange])

            discoveries.append(
                Discovery(
                    type: type,
                    title: truncateTitle(description),
                    description: description,
                    source: sourcePrefix,
                    suggestedPriority: type == .error ? .p1 : .p2
                )
            )
        }

        return deduplicateDiscoveries(discoveries)
    }

    /// Builds source prefix like "Step 3 - search" from context
    private func buildSourcePrefix(toolName: String, context: DiscoveryContext) -> String {
        let stepPart = context.currentStep.map { "Step \($0 + 1)" }
        return [stepPart, toolName.isEmpty ? nil : toolName]
            .compactMap { $0 }
            .joined(separator: " - ")
    }

    /// Detects the discovery type from the marker text
    private func detectDiscoveryType(from text: Substring) -> Discovery.DiscoveryType {
        let upper = text.uppercased()
        if upper.contains("BUG") || upper.contains("ERROR") {
            return .error
        } else if upper.contains("TODO") {
            return .todo
        } else if upper.contains("FIXME") {
            return .fixme
        } else if upper.contains("PREREQUISITE") || upper.contains("REQUIRES") {
            return .prerequisite
        } else {
            return .followUp
        }
    }

    /// Truncates a description to create a title
    private func truncateTitle(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 {
            return trimmed
        }
        return String(trimmed.prefix(57)) + "..."
    }

    /// Removes duplicate or very similar discoveries
    private func deduplicateDiscoveries(_ discoveries: [Discovery]) -> [Discovery] {
        var unique: [Discovery] = []

        for discovery in discoveries {
            let isDuplicate = unique.contains { existing in
                // Consider duplicates if titles are similar
                let similarity = stringSimilarity(existing.title, discovery.title)
                return similarity > 0.8
            }

            if !isDuplicate {
                unique.append(discovery)
            }
        }

        return unique
    }

    /// Simple string similarity check (Jaccard similarity of words)
    private func stringSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().components(separatedBy: .whitespaces))
        let wordsB = Set(b.lowercased().components(separatedBy: .whitespaces))

        let intersection = wordsA.intersection(wordsB)
        let union = wordsA.union(wordsB)

        guard !union.isEmpty else { return 0 }
        return Double(intersection.count) / Double(union.count)
    }

    // MARK: - Default Patterns

    private static var defaultPatterns: [DiscoveryPattern] {
        [
            // Error patterns
            ErrorDiscoveryPattern(),
            // TODO/FIXME patterns
            TodoDiscoveryPattern(),
            // Prerequisite patterns
            PrerequisiteDiscoveryPattern(),
            // Follow-up patterns
            FollowUpDiscoveryPattern(),
        ]
    }
}

// MARK: - Discovery Context

/// Context for discovery detection
/// - Note: DEPRECATED - Waterfall pipeline removed.
@available(*, deprecated, message: "Waterfall pipeline removed.")
public struct DiscoveryContext: Sendable {
    public let issueId: String
    public let taskId: String
    public let currentStep: Int?

    public init(issueId: String, taskId: String, currentStep: Int? = nil) {
        self.issueId = issueId
        self.taskId = taskId
        self.currentStep = currentStep
    }
}

// MARK: - Discovery Pattern Protocol

/// Protocol for discovery patterns
protocol DiscoveryPattern: Sendable {
    func detect(in text: String) -> [DiscoveryMatch]
}

/// A match from a discovery pattern
struct DiscoveryMatch: Sendable {
    let type: Discovery.DiscoveryType
    let title: String
    let description: String?
    let source: String?
    let suggestedPriority: IssuePriority
}

// MARK: - Error Discovery Pattern

/// Detects errors and exceptions in tool output
struct ErrorDiscoveryPattern: DiscoveryPattern {
    func detect(in text: String) -> [DiscoveryMatch] {
        var matches: [DiscoveryMatch] = []

        // Common error patterns
        let patterns = [
            #"(?:Error|Exception|Failed|Failure):\s*(.+)"#,
            #"(?:error\[E\d+\]):\s*(.+)"#,  // Rust errors
            #"(?:TypeError|SyntaxError|ReferenceError|RangeError):\s*(.+)"#,  // JS errors
            #"(?:fatal error|compilation error):\s*(.+)"#,
            #"(?:FAILED|FAIL):\s*(.+)"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                let regexMatches = regex.matches(in: text, options: [], range: range)

                for match in regexMatches {
                    if let descRange = Range(match.range(at: 1), in: text) {
                        let description = String(text[descRange]).trimmingCharacters(in: .whitespaces)
                        matches.append(
                            DiscoveryMatch(
                                type: .error,
                                title: "Fix: \(truncate(description, to: 50))",
                                description: description,
                                source: extractContext(text, around: match.range),
                                suggestedPriority: .p1
                            )
                        )
                    }
                }
            }
        }

        return matches
    }

    private func truncate(_ text: String, to length: Int) -> String {
        if text.count <= length { return text }
        return String(text.prefix(length - 3)) + "..."
    }

    private func extractContext(_ text: String, around range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        let lineStart =
            text[..<swiftRange.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) }
            ?? text.startIndex
        let lineEnd = text[swiftRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        return String(text[lineStart ..< lineEnd])
    }
}

// MARK: - TODO Discovery Pattern

/// Detects TODO and FIXME comments
struct TodoDiscoveryPattern: DiscoveryPattern {
    func detect(in text: String) -> [DiscoveryMatch] {
        var matches: [DiscoveryMatch] = []

        // TODO/FIXME patterns
        let patterns = [
            (#"TODO:\s*(.+)"#, Discovery.DiscoveryType.todo),
            (#"FIXME:\s*(.+)"#, Discovery.DiscoveryType.fixme),
            (#"XXX:\s*(.+)"#, Discovery.DiscoveryType.fixme),
            (#"HACK:\s*(.+)"#, Discovery.DiscoveryType.fixme),
        ]

        for (pattern, type) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                let regexMatches = regex.matches(in: text, options: [], range: range)

                for match in regexMatches {
                    if let descRange = Range(match.range(at: 1), in: text) {
                        let description = String(text[descRange]).trimmingCharacters(in: .whitespaces)
                        matches.append(
                            DiscoveryMatch(
                                type: type,
                                title: description.count <= 60 ? description : String(description.prefix(57)) + "...",
                                description: description,
                                source: nil,
                                suggestedPriority: type == .fixme ? .p1 : .p2
                            )
                        )
                    }
                }
            }
        }

        return matches
    }
}

// MARK: - Prerequisite Discovery Pattern

/// Detects prerequisites and requirements
struct PrerequisiteDiscoveryPattern: DiscoveryPattern {
    func detect(in text: String) -> [DiscoveryMatch] {
        var matches: [DiscoveryMatch] = []

        // Prerequisite patterns
        let patterns = [
            #"(?:requires|prerequisite|dependency|must first|need to first):\s*(.+)"#,
            #"(?:missing|not found|not installed):\s*(.+)"#,
            #"(?:please install|please configure|please set up)\s+(.+)"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                let regexMatches = regex.matches(in: text, options: [], range: range)

                for match in regexMatches {
                    if let descRange = Range(match.range(at: 1), in: text) {
                        let description = String(text[descRange]).trimmingCharacters(in: .whitespaces)
                        matches.append(
                            DiscoveryMatch(
                                type: .prerequisite,
                                title: "Prerequisite: \(truncate(description, to: 45))",
                                description: description,
                                source: nil,
                                suggestedPriority: .p0  // Prerequisites are urgent
                            )
                        )
                    }
                }
            }
        }

        return matches
    }

    private func truncate(_ text: String, to length: Int) -> String {
        if text.count <= length { return text }
        return String(text.prefix(length - 3)) + "..."
    }
}

// MARK: - Follow-up Discovery Pattern

/// Detects follow-up work and suggestions
struct FollowUpDiscoveryPattern: DiscoveryPattern {
    func detect(in text: String) -> [DiscoveryMatch] {
        var matches: [DiscoveryMatch] = []

        // Follow-up patterns
        let patterns = [
            #"(?:consider|should also|you might want to|recommended to|suggest):\s*(.+)"#,
            #"(?:follow-up|next step|additional work):\s*(.+)"#,
            #"(?:WARNING|WARN|NOTE):\s*(.+)"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                let regexMatches = regex.matches(in: text, options: [], range: range)

                for match in regexMatches {
                    if let descRange = Range(match.range(at: 1), in: text) {
                        let description = String(text[descRange]).trimmingCharacters(in: .whitespaces)
                        matches.append(
                            DiscoveryMatch(
                                type: .followUp,
                                title: truncate(description, to: 60),
                                description: description,
                                source: nil,
                                suggestedPriority: .p3  // Follow-ups are lower priority
                            )
                        )
                    }
                }
            }
        }

        return matches
    }

    private func truncate(_ text: String, to length: Int) -> String {
        if text.count <= length { return text }
        return String(text.prefix(length - 3)) + "..."
    }
}
