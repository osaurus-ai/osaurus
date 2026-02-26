//
//  ContextBudgetManager.swift
//  osaurus
//
//  Manages context window budget for LLM requests.
//  Prevents exceeding model context limits by trimming older messages
//  while preserving the original task and recent conversation history.
//

import Foundation

/// Per-category token breakdown for the context window, displayed in the
/// context budget hover popover.
public struct ContextTokenBreakdown: Equatable, Sendable {
    public var systemPrompt: Int = 0
    public var memory: Int = 0
    public var tools: Int = 0
    public var skills: Int = 0
    public var conversation: Int = 0
    public var input: Int = 0

    public var total: Int {
        systemPrompt + memory + tools + skills + conversation + input
    }

    public static let zero = ContextTokenBreakdown()

    /// Non-zero categories with their display metadata.
    public var categories: [Category] {
        Category.all(from: self).filter { $0.tokens > 0 }
    }

    public struct Category: Identifiable {
        public let label: String
        public let tokens: Int
        public let tint: Tint
        public var id: String { label }

        public enum Tint: String {
            case purple, blue, orange, green, gray, cyan
        }

        static func all(from b: ContextTokenBreakdown) -> [Category] {
            [
                Category(label: "System Prompt", tokens: b.systemPrompt, tint: .purple),
                Category(label: "Memory", tokens: b.memory, tint: .blue),
                Category(label: "Tools", tokens: b.tools, tint: .orange),
                Category(label: "Skills", tokens: b.skills, tint: .green),
                Category(label: "Conversation", tokens: b.conversation, tint: .gray),
                Category(label: "Input", tokens: b.input, tint: .cyan),
            ]
        }
    }
}

/// Budget categories for context window allocation
public enum ContextBudgetCategory: String, CaseIterable, Sendable {
    case systemPrompt
    case tools
    case memory
    case response
    case history
}

/// Manages context window token budget across categories.
/// Ensures LLM requests stay within the model's context limit by
/// reserving tokens for fixed components and trimming conversation
/// history when necessary.
public struct ContextBudgetManager: Sendable {

    /// Safety margin applied to total context window (0.85 = use 85% of window).
    /// Accounts for imprecision in the 4-chars/token heuristic.
    public static let safetyMargin: Double = 0.85

    /// Approximate characters per token (consistent with codebase heuristic)
    static let charsPerToken: Int = 4

    /// The effective token budget (context length * safety margin)
    public let effectiveBudget: Int

    /// Reserved tokens per category
    private var reservations: [ContextBudgetCategory: Int]

    /// Creates a budget manager for a given model context length.
    /// - Parameter contextLength: The model's context window size in tokens
    public init(contextLength: Int) {
        self.effectiveBudget = Int(Double(contextLength) * Self.safetyMargin)
        self.reservations = [:]
        for category in ContextBudgetCategory.allCases {
            self.reservations[category] = 0
        }
    }

    /// Reserve tokens for a budget category.
    /// - Parameters:
    ///   - category: The budget category
    ///   - tokens: Number of tokens to reserve
    public mutating func reserve(_ category: ContextBudgetCategory, tokens: Int) {
        reservations[category] = max(0, tokens)
    }

    /// Reserve tokens for a category based on character count.
    /// Converts characters to tokens using the standard heuristic.
    /// - Parameters:
    ///   - category: The budget category
    ///   - characters: Number of characters to convert and reserve
    public mutating func reserveByCharCount(_ category: ContextBudgetCategory, characters: Int) {
        reservations[category] = max(1, characters / Self.charsPerToken)
    }

    /// Total tokens reserved across all non-history categories
    public var totalReserved: Int {
        reservations.filter { $0.key != .history }.values.reduce(0, +)
    }

    /// Remaining token budget available for conversation history
    public var historyBudget: Int {
        max(0, effectiveBudget - totalReserved)
    }

    /// Estimate token count for a string
    public static func estimateTokens(for text: String?) -> Int {
        guard let text = text, !text.isEmpty else { return 0 }
        return max(1, text.count / charsPerToken)
    }

    /// Estimate total tokens for a message array
    static func estimateTokens(for messages: [ChatMessage]) -> Int {
        return messages.reduce(0) { total, msg in
            var msgTokens = estimateTokens(for: msg.content)
            // Account for tool call arguments in assistant messages
            if let toolCalls = msg.tool_calls {
                for tc in toolCalls {
                    msgTokens += estimateTokens(for: tc.function.arguments)
                    msgTokens += max(1, (tc.function.name.count + tc.id.count + 20) / charsPerToken)
                }
            }
            // Per-message overhead (role, delimiters, etc.) ~4 tokens
            msgTokens += 4
            return total + msgTokens
        }
    }

    // MARK: - Message Trimming

    /// Trims messages to fit within the history budget.
    ///
    /// Strategy:
    /// 1. If messages fit within budget, return as-is (no-op for large-context models).
    /// 2. Always preserve the first user message (original task).
    /// 3. Always preserve the last `recentPairsToKeep` message pairs in full.
    /// 4. Compress middle messages by replacing tool results with one-line summaries.
    /// 5. If still over budget after compression, drop oldest middle messages entirely.
    ///
    /// - Parameters:
    ///   - messages: The full conversation message array
    ///   - recentPairsToKeep: Number of recent assistant+tool message pairs to keep in full (default: 3)
    /// - Returns: Trimmed message array that fits within the history budget
    func trimMessages(
        _ messages: [ChatMessage],
        recentPairsToKeep: Int = 3
    ) -> [ChatMessage] {
        let budget = historyBudget
        let currentTokens = Self.estimateTokens(for: messages)

        // If within budget, return unchanged
        if currentTokens <= budget {
            return messages
        }

        // Identify protected regions
        // First message (original task) is always kept
        let firstMessageCount = 1

        // Count recent messages to protect (walk backwards to find pairs)
        let recentCount = countRecentMessages(in: messages, pairs: recentPairsToKeep)
        let protectedTailStart = messages.count - recentCount

        // If protected regions cover everything, we can't trim further
        if firstMessageCount >= protectedTailStart {
            return messages
        }

        // Phase 1: Compress middle tool results to summaries
        var trimmed = Array(messages)
        for i in firstMessageCount ..< protectedTailStart {
            if trimmed[i].role == "tool", let content = trimmed[i].content {
                let summary = Self.summarizeToolResult(content, toolCallId: trimmed[i].tool_call_id)
                trimmed[i] = ChatMessage(
                    role: "tool",
                    content: summary,
                    tool_calls: nil,
                    tool_call_id: trimmed[i].tool_call_id
                )
            }
        }

        // Check if compression was sufficient
        if Self.estimateTokens(for: trimmed) <= budget {
            return trimmed
        }

        // Phase 2: Drop oldest middle messages until within budget
        // Remove from just after the first message, preserving message ordering
        var result: [ChatMessage] = [trimmed[0]]  // Keep first message
        let tail = Array(trimmed[protectedTailStart...])

        // Add middle messages from newest to oldest until budget is reached
        let middle = Array(trimmed[firstMessageCount ..< protectedTailStart])
        var middleToKeep: [ChatMessage] = []
        var runningTokens = Self.estimateTokens(for: result) + Self.estimateTokens(for: tail)

        // Iterate from end of middle to start, keeping what fits
        for msg in middle.reversed() {
            let msgTokens = Self.estimateTokens(for: [msg])
            if runningTokens + msgTokens <= budget {
                middleToKeep.insert(msg, at: 0)
                runningTokens += msgTokens
            }
        }

        // If we dropped some middle messages, insert a context note
        if middleToKeep.count < middle.count {
            let droppedCount = middle.count - middleToKeep.count
            let contextNote = ChatMessage(
                role: "user",
                content:
                    "[Note: \(droppedCount) earlier messages were trimmed to fit context window. The original task and recent actions are preserved.]"
            )
            result.append(contextNote)
        }

        result.append(contentsOf: middleToKeep)
        result.append(contentsOf: tail)

        return result
    }

    // MARK: - Private Helpers

    /// Counts how many messages from the end constitute N assistant+tool pairs
    private func countRecentMessages(in messages: [ChatMessage], pairs: Int) -> Int {
        var pairCount = 0
        var msgCount = 0

        for msg in messages.reversed() {
            msgCount += 1
            // A tool message followed by an assistant message = one pair
            if msg.role == "assistant" {
                pairCount += 1
                if pairCount >= pairs {
                    break
                }
            }
        }

        return min(msgCount, messages.count)
    }

    /// Creates a short summary of a tool result for context compression
    static func summarizeToolResult(_ content: String, toolCallId: String?) -> String {
        let lineCount = content.components(separatedBy: .newlines).count
        let charCount = content.count

        // Try to detect the tool type from content patterns
        if content.hasPrefix("Lines ") || content.contains("| ") {
            // file_read result
            let firstLine = content.components(separatedBy: .newlines).first ?? ""
            return "[Compressed: file content, \(lineCount) lines, \(charCount) chars — \(firstLine)]"
        } else if content.hasPrefix("Found ") && content.contains("match") {
            // file_search result
            let firstLine = content.components(separatedBy: .newlines).first ?? ""
            return "[Compressed: \(firstLine)]"
        } else if content.hasPrefix("Exit code:") {
            // shell_run result
            let exitLine = content.components(separatedBy: .newlines).first ?? "Exit code: unknown"
            return "[Compressed: command output, \(lineCount) lines — \(exitLine)]"
        } else if content.hasPrefix("diff ") || content.hasPrefix("--- ") {
            // git_diff result
            return "[Compressed: git diff, \(lineCount) lines, \(charCount) chars]"
        } else if charCount > 200 {
            // Generic large result
            let preview = String(content.prefix(150)).replacingOccurrences(of: "\n", with: " ")
            return "[Compressed: \(charCount) chars — \(preview)...]"
        }

        // Small results are kept as-is
        return content
    }
}
