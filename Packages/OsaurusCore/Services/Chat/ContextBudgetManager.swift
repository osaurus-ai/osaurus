//
//  ContextBudgetManager.swift
//  osaurus
//
//  Manages context window budget for LLM requests.
//  Prevents exceeding model context limits by trimming older messages
//  while preserving the original task and recent conversation history.
//

import Foundation

/// Dynamic token breakdown for the context window, displayed in the
/// context budget hover popover. Entries are derived from the composer's
/// manifest sections rather than hardcoded fields.
public struct ContextBreakdown: Equatable, Sendable {

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public var tokens: Int
        public let tint: Tint
    }

    public enum Tint: String, Sendable {
        case purple, blue, orange, green, gray, cyan, teal, indigo
    }

    /// Prompt sections + tools
    public var context: [Entry]
    /// Conversation + input + output
    public var messages: [Entry]
    /// When non-nil, the popover renders an italic notice explaining
    /// which knobs the size-class auto-disable turned off and why.
    /// Threaded from `ComposedContext.contextDisable`.
    public var disable: ContextDisableInfo?

    public var total: Int {
        context.reduce(0) { $0 + $1.tokens } + messages.reduce(0) { $0 + $1.tokens }
    }

    public var allEntries: [Entry] { context + messages }

    public static let zero = ContextBreakdown(context: [], messages: [], disable: nil)

    /// Tint for a given prompt section ID.
    static func tint(for sectionId: String) -> Tint {
        switch sectionId {
        case "base": return .purple
        case "sandbox": return .teal
        case "memory": return .blue
        case "preflight": return .cyan
        case "skills": return .orange
        default: return .gray
        }
    }

    /// Build a breakdown from a `ComposedContext` with optional message token counts.
    /// Memory lives on `composed.memorySection` (it's prepended to the user
    /// message, not to the system prompt), so it's pulled out separately
    /// here and surfaced as its own entry.
    static func from(
        context composed: ComposedContext,
        conversationTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) -> ContextBreakdown {
        let memoryTokens = composed.memorySection.map { estimateTokens(for: $0) } ?? 0
        var breakdown = ContextBreakdown.from(
            manifest: composed.manifest,
            toolTokens: composed.toolTokens,
            memoryTokens: memoryTokens,
            conversationTokens: conversationTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        breakdown.disable = composed.contextDisable
        return breakdown
    }

    /// Build a breakdown from a manifest + tool tokens. `memoryTokens` is
    /// the cost of the per-turn memory snippet that the composer prepends
    /// to the latest user message. Surfaced as a dedicated entry so the
    /// budget popover shows it even though it doesn't live in `manifest.sections`.
    public static func from(
        manifest: PromptManifest,
        toolTokens: Int = 0,
        memoryTokens: Int = 0,
        conversationTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) -> ContextBreakdown {
        var ctx: [Entry] = manifest.sections
            .filter { $0.estimatedTokens > 0 }
            .map { Entry(id: $0.id, label: $0.label, tokens: $0.estimatedTokens, tint: tint(for: $0.id)) }
        if memoryTokens > 0 {
            ctx.append(Entry(id: "memory", label: "Memory", tokens: memoryTokens, tint: tint(for: "memory")))
        }
        if toolTokens > 0 {
            ctx.append(Entry(id: "tools", label: "Tools", tokens: toolTokens, tint: .orange))
        }

        var msgs: [Entry] = []
        if conversationTokens > 0 {
            msgs.append(Entry(id: "conversation", label: "Conversation", tokens: conversationTokens, tint: .gray))
        }
        if inputTokens > 0 { msgs.append(Entry(id: "input", label: "Input", tokens: inputTokens, tint: .cyan)) }
        if outputTokens > 0 { msgs.append(Entry(id: "output", label: "Output", tokens: outputTokens, tint: .green)) }

        return ContextBreakdown(context: ctx, messages: msgs, disable: nil)
    }

    private static func estimateTokens(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, trimmed.count / ContextBudgetManager.charsPerToken)
    }

    /// Update the token count for an entry by ID, or append it if not present.
    public mutating func setTokens(
        for id: String,
        in group: WritableKeyPath<ContextBreakdown, [Entry]>,
        tokens: Int,
        label: String = "",
        tint: Tint = .gray
    ) {
        if let idx = self[keyPath: group].firstIndex(where: { $0.id == id }) {
            let existing = self[keyPath: group][idx]
            self[keyPath: group][idx] = Entry(id: id, label: existing.label, tokens: tokens, tint: existing.tint)
        } else if tokens > 0 {
            self[keyPath: group].append(Entry(id: id, label: label, tokens: tokens, tint: tint))
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

    /// Estimate token count for a set of chat turns (conversation history).
    static func estimateTokens(for turns: [ChatTurn]) -> Int {
        turns.reduce(0) { total, turn in
            var t = 0
            if !turn.contentIsEmpty { t += max(1, turn.contentLength / charsPerToken) }
            if let calls = turn.toolCalls {
                for call in calls {
                    t += max(1, (call.function.name.count + call.function.arguments.count) / charsPerToken)
                }
            }
            for (_, result) in turn.toolResults {
                t += max(1, result.count / charsPerToken)
            }
            if turn.hasThinking {
                t += max(1, turn.thinkingLength / charsPerToken)
            }
            for attachment in turn.attachments {
                t += attachment.estimatedTokens
            }
            return total + t
        }
    }

    /// Estimate output tokens for a single assistant turn (text + thinking + tool calls).
    static func estimateOutputTokens(for turn: ChatTurn) -> Int {
        var tokens = 0
        if !turn.contentIsEmpty {
            tokens += max(1, turn.contentLength / charsPerToken)
        }
        if turn.hasThinking {
            tokens += max(1, turn.thinkingLength / charsPerToken)
        }
        if let calls = turn.toolCalls {
            for call in calls {
                tokens += max(1, (call.function.name.count + call.function.arguments.count) / charsPerToken)
            }
        }
        return tokens
    }

    /// Estimate total output tokens across all assistant turns.
    static func estimateOutputTokens(for turns: [ChatTurn]) -> Int {
        turns.filter { $0.role == .assistant }.reduce(0) { $0 + estimateOutputTokens(for: $1) }
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

    /// Whether the given messages fit within the history budget without trimming.
    func fitsInBudget(_ messages: [ChatMessage]) -> Bool {
        Self.estimateTokens(for: messages) <= historyBudget
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

    /// Counts how many trailing messages constitute the requested number of
    /// assistant→tool pairs. A "pair" is an assistant turn followed by one
    /// or more tool-result turns (each tool_call → tool_result is one round).
    /// Walking backwards, we count one pair every time we cross an assistant
    /// turn that itself follows tool-result turn(s) — that delimits a
    /// completed agent-loop iteration.
    ///
    /// Previously this counted every assistant turn as a pair, which
    /// over-protected long pure-assistant tails on tool-light conversations
    /// and under-protected tool-heavy ones (the comment said "tool followed
    /// by assistant" but the code only checked assistant). Realigning the
    /// implementation with the documented intent.
    private func countRecentMessages(in messages: [ChatMessage], pairs: Int) -> Int {
        var pairCount = 0
        var msgCount = 0
        var sawToolSinceLastAssistant = false

        for msg in messages.reversed() {
            msgCount += 1
            switch msg.role {
            case "tool":
                sawToolSinceLastAssistant = true
            case "assistant":
                if sawToolSinceLastAssistant {
                    pairCount += 1
                    sawToolSinceLastAssistant = false
                    if pairCount >= pairs { return msgCount }
                } else {
                    // Plain assistant turn (no tool result behind it). Treat
                    // it as a soft pair too — we still want some text-only
                    // history protected — but at half weight.
                    pairCount += 1
                    if pairCount >= pairs { return msgCount }
                }
            default:
                break
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

// MARK: - Context Budget Tracker

/// Tracks the active request's token breakdown during streaming/execution.
///
/// `ChatSession` owns an instance. The lifecycle is:
/// 1. `snapshot()` — captures context from ComposedContext or manifest
/// 2. `updateConversation()` — at each agent-loop iteration, updates conversation + output tokens
/// 3. `activeBreakdown()` — O(1) read returning the snapshot with live message tokens
/// 4. `clear()` — on completion/error/cancellation
@MainActor
final class ContextBudgetTracker {
    private var breakdown: ContextBreakdown?
    private var cumulativeOutputTokens: Int = 0

    /// Snapshot from a ComposedContext (chat path).
    func snapshot(context: ComposedContext) {
        breakdown = .from(context: context)
    }

    /// Snapshot from a manifest + tool tokens (work path where ComposedContext isn't available).
    func snapshot(manifest: PromptManifest, toolTokens: Int) {
        breakdown = .from(manifest: manifest, toolTokens: toolTokens)
    }

    /// Update conversation tokens at each agent-loop iteration start.
    func updateConversation(tokens: Int, finishedOutputTurn: ChatTurn? = nil) {
        if let turn = finishedOutputTurn, turn.role == .assistant {
            cumulativeOutputTokens += ContextBudgetManager.estimateOutputTokens(for: turn)
        }
        breakdown?.setTokens(for: "conversation", in: \.messages, tokens: tokens, label: "Conversation", tint: .gray)
    }

    /// Returns the snapshot with live output tokens, or nil if no snapshot is active.
    func activeBreakdown(isActive: Bool, outputTurn: ChatTurn?) -> ContextBreakdown? {
        guard var bd = breakdown, isActive else { return nil }
        var currentTurnOutput = 0
        if let turn = outputTurn, turn.role == .assistant {
            currentTurnOutput = ContextBudgetManager.estimateOutputTokens(for: turn)
        }
        let totalOutput = cumulativeOutputTokens + currentTurnOutput
        bd.setTokens(for: "output", in: \.messages, tokens: totalOutput, label: "Output", tint: .green)
        return bd
    }

    func clear() {
        breakdown = nil
        cumulativeOutputTokens = 0
    }

    var hasActiveSnapshot: Bool { breakdown != nil }
}
