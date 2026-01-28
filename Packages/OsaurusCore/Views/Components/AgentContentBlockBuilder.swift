//
//  AgentContentBlockBuilder.swift
//  osaurus
//
//  Converts agent execution data (IssueEvents, streaming content) into ContentBlocks
//  for rendering in MessageThreadView.
//

import Foundation

// MARK: - Agent Content Block Builder

/// Builds ContentBlock arrays from agent execution data for MessageThreadView rendering.
/// Supports both live execution (streaming) and historical event viewing.
@MainActor
final class AgentContentBlockBuilder {
    /// Unique turn ID for this execution session
    private var turnId: UUID

    /// Current blocks being built
    private(set) var blocks: [ContentBlock] = []

    /// Issue being displayed
    private var issue: Issue?

    /// Persona name for headers
    private var personaName: String

    /// Current paragraph index (for streaming text)
    private var currentParagraphIndex: Int = 0

    /// Current text content being streamed
    private var currentContent: String = ""

    /// Whether streaming is active
    private var isStreaming: Bool = false

    /// Tool calls accumulated during execution
    private var toolCalls: [ToolCallItem] = []

    init(personaName: String = "Agent") {
        self.turnId = UUID()
        self.personaName = personaName
    }

    // MARK: - Live Execution Support

    /// Starts a new execution session for an issue
    func startExecution(for issue: Issue) {
        self.issue = issue
        self.turnId = UUID()
        self.blocks = []
        self.currentParagraphIndex = 0
        self.currentContent = ""
        self.isStreaming = true
        self.toolCalls = []

        // Add header for the execution
        blocks.append(
            .header(
                turnId: turnId,
                role: .assistant,
                personaName: personaName,
                isFirstInGroup: true,
                position: .first
            )
        )

        // Add issue context as thinking block
        let contextText = "Working on: **\(issue.title)**"
        blocks.append(
            .thinking(
                turnId: turnId,
                index: 0,
                text: contextText,
                isStreaming: false,
                position: .middle
            )
        )
    }

    /// Appends streaming delta content
    func appendDelta(_ delta: String) {
        currentContent += delta
        isStreaming = true
        rebuildCurrentParagraph()
    }

    /// Handles a plan creation event
    func handlePlanCreated(_ plan: ExecutionPlan) {
        // Add plan as thinking block
        let planSummary = plan.steps.enumerated().map { idx, step in
            "\(idx + 1). \(step.description)"
        }.joined(separator: "\n")

        let thinkingText = "**Plan:**\n\(planSummary)"
        blocks.append(
            .thinking(
                turnId: turnId,
                index: blocks.count,
                text: thinkingText,
                isStreaming: false,
                position: .middle
            )
        )
    }

    /// Handles a tool call execution
    func handleToolCall(name: String, arguments: String, result: String?) {
        // Create a ToolCall for display
        let toolCall = ToolCall(
            id: UUID().uuidString,
            type: "function",
            function: ToolCallFunction(name: name, arguments: arguments)
        )

        let item = ToolCallItem(call: toolCall, result: result)
        toolCalls.append(item)

        // If we have multiple tool calls, group them
        if toolCalls.count > 1 {
            // Remove any existing tool call blocks and add grouped
            blocks.removeAll { block in
                if case .toolCall = block.kind { return true }
                if case .toolCallGroup = block.kind { return true }
                return false
            }
            blocks.append(
                .toolCallGroup(turnId: turnId, calls: toolCalls, position: .middle)
            )
        } else {
            // Single tool call
            blocks.append(
                .toolCall(turnId: turnId, call: toolCall, result: result, position: .middle)
            )
        }
    }

    /// Handles step completion
    func handleStepCompleted(stepIndex: Int, content: String?) {
        if let content = content, !content.isEmpty {
            // If there's content, append it
            if !currentContent.isEmpty {
                currentContent += "\n\n"
            }
            currentContent += content
            rebuildCurrentParagraph()
        }
    }

    /// Handles verification result
    func handleVerification(summary: String, success: Bool) {
        let emoji = success ? "✅" : "❌"
        let verificationText = "\n\n---\n\(emoji) **Result:** \(summary)"
        currentContent += verificationText
        isStreaming = false
        rebuildCurrentParagraph()
    }

    /// Marks execution as complete
    func completeExecution(success: Bool, message: String?) {
        isStreaming = false

        if let message = message, !message.isEmpty {
            if !currentContent.isEmpty && !currentContent.hasSuffix("\n") {
                currentContent += "\n\n"
            }
            currentContent += message
        }

        rebuildCurrentParagraph()
        updatePositions()
    }

    // MARK: - Historical Event Loading

    /// Builds blocks from historical IssueEvent records
    func buildFromHistory(events: [IssueEvent], issue: Issue) -> [ContentBlock] {
        self.issue = issue
        self.turnId = UUID()
        self.blocks = []
        self.currentContent = ""
        self.toolCalls = []

        // Add header
        blocks.append(
            .header(
                turnId: turnId,
                role: .assistant,
                personaName: personaName,
                isFirstInGroup: true,
                position: .first
            )
        )

        // Add issue context
        blocks.append(
            .thinking(
                turnId: turnId,
                index: 0,
                text: "**\(issue.title)**\n\(issue.description ?? "")",
                isStreaming: false,
                position: .middle
            )
        )

        // Process events
        for event in events {
            processHistoricalEvent(event)
        }

        // Add result if issue is closed
        if issue.status == .closed, let result = issue.result {
            blocks.append(
                .paragraph(
                    turnId: turnId,
                    index: blocks.count,
                    text: "---\n✅ **Completed:** \(result)",
                    isStreaming: false,
                    role: .assistant,
                    position: .middle
                )
            )
        }

        updatePositions()
        return blocks
    }

    private func processHistoricalEvent(_ event: IssueEvent) {
        switch event.eventType {
        case .executionStarted:
            blocks.append(
                .paragraph(
                    turnId: turnId,
                    index: blocks.count,
                    text: "Execution started...",
                    isStreaming: false,
                    role: .assistant,
                    position: .middle
                )
            )

        case .planCreated:
            if let payload = event.payload,
                let data = payload.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(StepCountPayload.self, from: data)
            {
                blocks.append(
                    .thinking(
                        turnId: turnId,
                        index: blocks.count,
                        text: "Created plan with \(decoded.stepCount) steps",
                        isStreaming: false,
                        position: .middle
                    )
                )
            }

        case .toolCallExecuted:
            if let payload = event.payload,
                let data = payload.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(ToolCallPayload.self, from: data)
            {
                // Create a minimal tool call display
                let toolCall = ToolCall(
                    id: event.id,
                    type: "function",
                    function: ToolCallFunction(name: decoded.tool, arguments: "{}")
                )
                blocks.append(
                    .toolCall(
                        turnId: turnId,
                        call: toolCall,
                        result: nil,
                        position: .middle
                    )
                )
            }

        case .executionCompleted:
            if let payload = event.payload,
                let data = payload.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(ExecutionCompletedPayload.self, from: data)
            {
                let status = decoded.success ? "✅ Completed" : "❌ Failed"
                var text = status
                if decoded.discoveries > 0 {
                    text += " (discovered \(decoded.discoveries) new issues)"
                }
                blocks.append(
                    .paragraph(
                        turnId: turnId,
                        index: blocks.count,
                        text: text,
                        isStreaming: false,
                        role: .assistant,
                        position: .middle
                    )
                )
            }

        case .decomposed:
            if let payload = event.payload,
                let data = payload.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(ChildCountPayload.self, from: data)
            {
                blocks.append(
                    .paragraph(
                        turnId: turnId,
                        index: blocks.count,
                        text: "🔀 Decomposed into \(decoded.childCount) sub-issues",
                        isStreaming: false,
                        role: .assistant,
                        position: .middle
                    )
                )
            }

        case .closed:
            // Already handled via issue.result
            break

        default:
            // Other events not displayed in thread
            break
        }
    }

    // MARK: - Private Helpers

    private func rebuildCurrentParagraph() {
        // Remove existing paragraph if any
        blocks.removeAll { block in
            if case .paragraph = block.kind {
                return true
            }
            return false
        }

        // Add current content as paragraph(s)
        if !currentContent.isEmpty {
            let paragraphs = splitIntoParagraphs(currentContent)
            for (idx, text) in paragraphs.enumerated() {
                let isLast = idx == paragraphs.count - 1
                blocks.append(
                    .paragraph(
                        turnId: turnId,
                        index: idx,
                        text: text,
                        isStreaming: isStreaming && isLast,
                        role: .assistant,
                        position: .middle
                    )
                )
            }
        }
    }

    private func splitIntoParagraphs(_ text: String) -> [String] {
        let maxSize = 600
        guard text.count > maxSize else { return [text] }

        var result: [String] = []
        var chunk = ""
        var inCodeBlock = false
        let lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
            if !chunk.isEmpty { chunk += "\n" }
            chunk += line

            let isLastLine = index == lines.count - 1
            let isBlankLine = trimmed.isEmpty
            let nextIsBlank = index + 1 < lines.count && lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty
            let shouldSplit =
                !inCodeBlock && !isLastLine
                && ((chunk.count >= maxSize && (isBlankLine || nextIsBlank))
                    || chunk.count >= maxSize * 2)

            if shouldSplit {
                result.append(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                chunk = ""
            }
        }

        let remaining = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty { result.append(remaining) }
        return result.isEmpty ? [text] : result
    }

    private func updatePositions() {
        guard !blocks.isEmpty else { return }
        for i in 0 ..< blocks.count {
            let position: BlockPosition
            if blocks.count == 1 {
                position = .only
            } else if i == 0 {
                position = .first
            } else if i == blocks.count - 1 {
                position = .last
            } else {
                position = .middle
            }
            blocks[i] = blocks[i].withPosition(position)
        }
    }

    /// Resets the builder for a new session
    func reset() {
        turnId = UUID()
        blocks = []
        issue = nil
        currentParagraphIndex = 0
        currentContent = ""
        isStreaming = false
        toolCalls = []
    }
}

// MARK: - Payload Decoding Types

private struct ToolCallPayload: Decodable {
    let tool: String
    let step: Int
}

private struct ExecutionCompletedPayload: Decodable {
    let success: Bool
    let discoveries: Int
}

private struct ChildCountPayload: Decodable {
    let childCount: Int
}

private struct StepCountPayload: Decodable {
    let stepCount: Int
}
