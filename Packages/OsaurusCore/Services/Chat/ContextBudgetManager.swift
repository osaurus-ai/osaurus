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
        case "platform": return .indigo
        case "persona": return .purple
        case "codeStyle", "riskAware": return .gray
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
            ctx.append(Entry(id: "memory", label: L("Memory"), tokens: memoryTokens, tint: tint(for: "memory")))
        }
        if toolTokens > 0 {
            ctx.append(Entry(id: "tools", label: L("Tools"), tokens: toolTokens, tint: .orange))
        }

        var msgs: [Entry] = []
        if conversationTokens > 0 {
            msgs.append(Entry(id: "conversation", label: L("Conversation"), tokens: conversationTokens, tint: .gray))
        }
        if inputTokens > 0 { msgs.append(Entry(id: "input", label: L("Input"), tokens: inputTokens, tint: .cyan)) }
        if outputTokens > 0 { msgs.append(Entry(id: "output", label: L("Output"), tokens: outputTokens, tint: .green)) }

        return ContextBreakdown(context: ctx, messages: msgs, disable: nil)
    }

    private static func estimateTokens(for text: String) -> Int {
        TokenEstimator.estimate(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
        reservations[category] = max(1, characters / TokenEstimator.charsPerToken)
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
        TokenEstimator.estimate(text)
    }

    /// Estimate token count for a set of chat turns (conversation history).
    static func estimateTokens(for turns: [ChatTurn]) -> Int {
        turns.reduce(0) { total, turn in
            var t = 0
            if !turn.contentIsEmpty {
                t += max(1, turn.contentLength / TokenEstimator.charsPerToken)
            }
            if let calls = turn.toolCalls {
                for call in calls {
                    t += TokenEstimator.toolCallTokens(
                        name: call.function.name,
                        arguments: call.function.arguments
                    )
                }
            }
            for (_, result) in turn.toolResults {
                t += max(1, result.count / TokenEstimator.charsPerToken)
            }
            if turn.hasThinking {
                t += max(1, turn.thinkingLength / TokenEstimator.charsPerToken)
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
            tokens += max(1, turn.contentLength / TokenEstimator.charsPerToken)
        }
        if turn.hasThinking {
            tokens += max(1, turn.thinkingLength / TokenEstimator.charsPerToken)
        }
        if let calls = turn.toolCalls {
            for call in calls {
                tokens += TokenEstimator.toolCallTokens(
                    name: call.function.name,
                    arguments: call.function.arguments
                )
            }
        }
        return tokens
    }

    /// Estimate total output tokens across all assistant turns.
    static func estimateOutputTokens(for turns: [ChatTurn]) -> Int {
        turns.filter { $0.role == .assistant }.reduce(0) { $0 + estimateOutputTokens(for: $1) }
    }

    /// Estimate tokens for ONE message — the unit the array estimate sums,
    /// and the unit the incremental drop loop subtracts.
    static func estimateTokens(forMessage msg: ChatMessage) -> Int {
        var msgTokens = TokenEstimator.estimate(msg.content)
        if let toolCalls = msg.tool_calls {
            for tc in toolCalls {
                msgTokens += TokenEstimator.estimate(tc.function.arguments)
                msgTokens += TokenEstimator.toolCallTokens(
                    name: tc.function.name,
                    arguments: "",
                    id: tc.id
                )
            }
        }
        msgTokens += TokenEstimator.messageOverheadTokens
        return msgTokens
    }

    /// Estimate total tokens for a message array
    static func estimateTokens(for messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens(forMessage: $1) }
    }

    /// Whether the given messages fit within the history budget without trimming.
    func fitsInBudget(_ messages: [ChatMessage]) -> Bool {
        Self.estimateTokens(for: messages) <= historyBudget
    }

    // MARK: - Message Trimming

    /// Sticky trim: like `trimMessages(_:recentPairsToKeep:)` but compaction
    /// decisions persist in `watermark` so the trimmed transcript is
    /// MONOTONIC across successive calls — once a message is summarized its
    /// summary is replayed byte-identically, and once a message is dropped
    /// it stays dropped. The stateless variant recomputes from scratch each
    /// call, which can rewrite the middle of the message array between
    /// iterations and bust paged-KV prefix reuse.
    ///
    /// The watermark is keyed by index into the caller's UNTRIMMED history,
    /// which must be append-only between calls (chat turns / HTTP / plugin
    /// message arrays all are). If a recorded message's identity no longer
    /// matches (e.g. regeneration rewrote history), the watermark resets and
    /// decisions are recomputed fresh.
    func trimMessages(
        _ messages: [ChatMessage],
        recentPairsToKeep: Int = 3,
        watermark: CompactionWatermark
    ) -> [ChatMessage] {
        trimMessagesReportingOverflow(
            messages,
            recentPairsToKeep: recentPairsToKeep,
            watermark: watermark
        ).messages
    }

    /// The byte-stable context note inserted once messages have been
    /// dropped. Deliberately COUNT-FREE: a live count would rewrite the
    /// note's bytes on every additional drop, busting the KV prefix the
    /// watermark exists to protect.
    public static let trimmedHistoryNote =
        "[Note: Earlier messages were trimmed to fit the context window. The original task and recent actions are preserved.]"

    /// Sticky trim variant that also reports whether the transcript STILL
    /// exceeds the history budget after every compaction lever (summaries,
    /// drops) is exhausted — i.e. the protected first message + tail alone
    /// are over budget. Callers can surface that instead of silently
    /// sending an over-budget request.
    func trimMessagesReportingOverflow(
        _ messages: [ChatMessage],
        recentPairsToKeep: Int = 3,
        watermark: CompactionWatermark
    ) -> (messages: [ChatMessage], overBudget: Bool) {
        watermark.validate(against: messages)

        // Assemble the visible transcript: replay frozen summaries, skip
        // dropped indices. Original indices ride along so new decisions key
        // back to the caller's array.
        var visible: [(origIndex: Int, message: ChatMessage)] = []
        visible.reserveCapacity(messages.count)
        for (i, msg) in messages.enumerated() {
            switch watermark.decision(at: i) {
            case .dropped:
                continue
            case .summarized(let summary):
                visible.append(
                    (
                        i,
                        ChatMessage(
                            role: "tool",
                            content: summary,
                            tool_calls: nil,
                            tool_call_id: msg.tool_call_id
                        )
                    )
                )
            case .verbatim, .none:
                visible.append((i, msg))
            }
        }

        func render() -> [ChatMessage] {
            var result = visible.map { $0.message }
            if watermark.droppedCount > 0, !result.isEmpty {
                // Count-free so the note's bytes never change once emitted.
                result.insert(ChatMessage(role: "user", content: Self.trimmedHistoryNote), at: 1)
            }
            return result
        }

        // Everything in the returned transcript is about to be sent to the
        // model verbatim (frozen summaries excepted — they carry their own
        // decision). Record that so later trims DROP these messages when
        // space is needed instead of newly summarizing them — a summary of
        // a previously-sent message is a mid-transcript rewrite the KV
        // cache can't reuse past.
        func markVisibleAsSent() {
            for (origIndex, _) in visible where watermark.decision(at: origIndex) == nil {
                watermark.recordVerbatim(at: origIndex, original: messages[origIndex])
            }
        }

        let budget = historyBudget
        if Self.estimateTokens(for: render()) <= budget {
            markVisibleAsSent()
            return (render(), false)
        }

        // Identify protected regions on the VISIBLE transcript: first
        // message (original task) + recent pairs.
        let visibleMessages = visible.map { $0.message }
        let recentCount = countRecentMessages(in: visibleMessages, pairs: recentPairsToKeep)
        let protectedTailStart = visible.count - recentCount
        guard protectedTailStart > 1 else {
            // Protected regions cover everything — nothing left to trim.
            markVisibleAsSent()
            return (render(), Self.estimateTokens(for: render()) > budget)
        }

        // Phase 1: freeze summaries for middle tool results that were never
        // sent verbatim. Messages already sent verbatim are skipped — once
        // their bytes were part of the token stream, rewriting them as
        // summaries would invalidate the KV prefix at that point; phase 2
        // drops them instead (a pure truncation).
        for slot in 1 ..< protectedTailStart {
            let (origIndex, msg) = visible[slot]
            guard msg.role == "tool", let content = msg.content,
                watermark.decision(at: origIndex) == nil
            else { continue }
            let summary = Self.summarizeToolResult(content, toolCallId: msg.tool_call_id)
            watermark.recordSummary(summary, at: origIndex, original: messages[origIndex])
            visible[slot] = (
                origIndex,
                ChatMessage(role: "tool", content: summary, tool_calls: nil, tool_call_id: msg.tool_call_id)
            )
        }
        if Self.estimateTokens(for: render()) <= budget {
            markVisibleAsSent()
            return (render(), false)
        }

        // Phase 2: drop oldest middle messages (never the first message,
        // never the protected tail) until the transcript fits. Drops are
        // recorded so they persist on every later call. The oldest middle
        // message always sits at visible[1] (visible[0] is the protected
        // first message); the protected tail boundary shrinks with each
        // removal.
        //
        // Incremental accounting: estimate the rendered transcript ONCE,
        // then subtract each dropped message's own estimate — re-rendering
        // and re-estimating the whole array per drop was O(n²) on long
        // tool-heavy histories. The first drop ever also inserts the
        // count-free trimmed-history note, whose cost is added once.
        var tailStart = protectedTailStart
        var runningTokens = Self.estimateTokens(for: render())
        var noteAccounted = watermark.droppedCount > 0
        while tailStart > 1, runningTokens > budget {
            let dropped = visible[1]
            watermark.recordDrop(at: dropped.origIndex, original: messages[dropped.origIndex])
            visible.remove(at: 1)
            tailStart -= 1
            runningTokens -= Self.estimateTokens(forMessage: dropped.message)
            if !noteAccounted {
                runningTokens += Self.estimateTokens(
                    forMessage: ChatMessage(role: "user", content: Self.trimmedHistoryNote)
                )
                noteAccounted = true
            }
        }

        markVisibleAsSent()
        return (render(), runningTokens > budget)
    }

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

        // Structured directory listing envelope: collapse to a count so an
        // old listing doesn't retain its full entry array, but keep enough
        // that the model knows a listing happened and where. A truncated
        // listing keeps its find-by-name steer so the "incomplete, use
        // file_search" signal survives into later turns.
        if ToolEnvelope.isSuccess(content),
            let payload = ToolEnvelope.successPayload(content) as? [String: Any],
            payload["kind"] as? String == "listing"
        {
            let count = payload["entry_count"] as? Int ?? (payload["entries"] as? [Any])?.count ?? 0
            let path = payload["path"] as? String ?? "."
            let truncatedNote =
                payload["truncated"] as? Bool == true ? " (truncated; use file_search target:files)" : ""
            return "[Compressed: directory listing, \(count) entries in \(path)\(truncatedNote)]"
        }

        // Structured filename-search envelope: collapse to a match count and
        // the query, mirroring the listing collapse.
        if ToolEnvelope.isSuccess(content),
            let payload = ToolEnvelope.successPayload(content) as? [String: Any],
            payload["kind"] as? String == "search"
        {
            let count = payload["match_count"] as? Int ?? (payload["entries"] as? [Any])?.count ?? 0
            let query = payload["query"] as? String ?? ""
            return "[Compressed: \(count) file match(es) for '\(query)']"
        }

        // Compressed summaries carry ZERO semantic content; without an
        // explicit warning the model recalls "specifics" from thin air
        // (observed live: invented filenames and error codes in a summary
        // written after the underlying tool output was trimmed). The steer
        // makes the trim observable so the model re-fetches instead.
        let refetchSteer = "details no longer visible; re-fetch them, do not recall from memory"

        // Structured file-content envelope: keep the real path so the model
        // knows exactly which file to re-read.
        if ToolEnvelope.isSuccess(content),
            let payload = ToolEnvelope.successPayload(content) as? [String: Any],
            payload["kind"] as? String == "file"
        {
            let path = payload["path"] as? String ?? "unknown"
            let totalLines = payload["total_lines"] as? Int ?? lineCount
            return
                "[Compressed: file content of '\(path)', \(totalLines) lines — no longer in context; re-read the file if you need specifics]"
        }

        // Try to detect the tool type from content patterns
        if content.hasPrefix("Lines ") || content.contains("| ") {
            // file_read result
            let firstLine = content.components(separatedBy: .newlines).first ?? ""
            return
                "[Compressed: file content, \(lineCount) lines, \(charCount) chars — \(firstLine); \(refetchSteer)]"
        } else if content.hasPrefix("Found ") && content.contains("match") {
            // file_search result
            let firstLine = content.components(separatedBy: .newlines).first ?? ""
            return "[Compressed: \(firstLine); \(refetchSteer)]"
        } else if content.hasPrefix("Exit code:") {
            // shell_run result
            let exitLine = content.components(separatedBy: .newlines).first ?? "Exit code: unknown"
            return "[Compressed: command output, \(lineCount) lines — \(exitLine); \(refetchSteer)]"
        } else if content.hasPrefix("diff ") || content.hasPrefix("--- ") {
            // git_diff result
            return "[Compressed: git diff, \(lineCount) lines, \(charCount) chars; \(refetchSteer)]"
        } else if charCount > 200 {
            // Generic large result
            let preview = String(content.prefix(150)).replacingOccurrences(of: "\n", with: " ")
            return "[Compressed: \(charCount) chars — \(preview)...; \(refetchSteer)]"
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
        breakdown?.setTokens(for: "conversation", in: \.messages, tokens: tokens, label: L("Conversation"), tint: .gray)
    }

    /// Surface history compaction in the context popover: `savedTokens` is
    /// the estimate trimmed away from the conversation this iteration.
    func updateCompaction(savedTokens: Int) {
        guard savedTokens > 0 else { return }
        breakdown?.setTokens(
            for: "compacted",
            in: \.messages,
            tokens: savedTokens,
            label: L("Compacted (saved)"),
            tint: .teal
        )
    }

    /// Returns the snapshot with live output tokens, or nil if no snapshot is active.
    func activeBreakdown(isActive: Bool, outputTurn: ChatTurn?) -> ContextBreakdown? {
        guard var bd = breakdown, isActive else { return nil }
        var currentTurnOutput = 0
        if let turn = outputTurn, turn.role == .assistant {
            currentTurnOutput = ContextBudgetManager.estimateOutputTokens(for: turn)
        }
        let totalOutput = cumulativeOutputTokens + currentTurnOutput
        bd.setTokens(for: "output", in: \.messages, tokens: totalOutput, label: L("Output"), tint: .green)
        return bd
    }

    func clear() {
        breakdown = nil
        cumulativeOutputTokens = 0
    }

    var hasActiveSnapshot: Bool { breakdown != nil }
}
