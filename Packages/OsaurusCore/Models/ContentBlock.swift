//
//  ContentBlock.swift
//  osaurus
//
//  Unified content block model for flattened chat rendering.
//  Each block is a top-level item in LazyVStack for efficient recycling.
//

import Foundation

/// Position of a block within its turn (for styling purposes)
enum BlockPosition {
    case only  // Single block in turn - round all corners
    case first  // First block - round top corners
    case middle  // Middle block - no rounding
    case last  // Last block - round bottom corners
}

/// A single tool call with its result for grouped rendering
struct ToolCallItem: Equatable {
    let call: ToolCall
    let result: String?

    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.call.id == rhs.call.id && lhs.result == rhs.result
    }
}

/// A single content block in the flattened chat view.
enum ContentBlock: Identifiable {
    case header(turnId: UUID, role: MessageRole, personaName: String, isFirstInGroup: Bool, position: BlockPosition)
    case paragraph(
        turnId: UUID,
        index: Int,
        text: String,
        isStreaming: Bool,
        role: MessageRole,
        position: BlockPosition
    )
    case toolCall(turnId: UUID, call: ToolCall, result: String?, position: BlockPosition)
    case toolCallGroup(turnId: UUID, calls: [ToolCallItem], position: BlockPosition)
    case thinking(turnId: UUID, index: Int, text: String, isStreaming: Bool, position: BlockPosition)
    case image(turnId: UUID, index: Int, imageData: Data, position: BlockPosition)
    case typingIndicator(turnId: UUID, position: BlockPosition)
    case groupSpacer(afterTurnId: UUID)

    var id: String {
        switch self {
        case let .header(turnId, _, _, _, _): return "header-\(turnId.uuidString)"
        case let .paragraph(turnId, index, _, _, _, _): return "para-\(turnId.uuidString)-\(index)"
        case let .toolCall(turnId, call, _, _): return "tool-\(turnId.uuidString)-\(call.id)"
        case let .toolCallGroup(turnId, calls, _):
            let callIds = calls.map(\.call.id).joined(separator: "-")
            return "toolgroup-\(turnId.uuidString)-\(callIds)"
        case let .thinking(turnId, index, _, _, _): return "think-\(turnId.uuidString)-\(index)"
        case let .image(turnId, index, _, _): return "img-\(turnId.uuidString)-\(index)"
        case let .typingIndicator(turnId, _): return "typing-\(turnId.uuidString)"
        case let .groupSpacer(afterTurnId): return "spacer-\(afterTurnId.uuidString)"
        }
    }

    var turnId: UUID {
        switch self {
        case let .header(turnId, _, _, _, _),
            let .paragraph(turnId, _, _, _, _, _),
            let .toolCall(turnId, _, _, _),
            let .toolCallGroup(turnId, _, _),
            let .thinking(turnId, _, _, _, _),
            let .image(turnId, _, _, _),
            let .typingIndicator(turnId, _),
            let .groupSpacer(turnId):
            return turnId
        }
    }

    var role: MessageRole {
        switch self {
        case let .header(_, role, _, _, _): return role
        case let .paragraph(_, _, _, _, role, _): return role
        case .toolCall, .toolCallGroup, .thinking, .typingIndicator: return .assistant
        case .image: return .user
        case .groupSpacer: return .assistant
        }
    }

    var position: BlockPosition {
        switch self {
        case let .header(_, _, _, _, position),
            let .paragraph(_, _, _, _, _, position),
            let .toolCall(_, _, _, position),
            let .toolCallGroup(_, _, position),
            let .thinking(_, _, _, _, position),
            let .image(_, _, _, position),
            let .typingIndicator(_, position):
            return position
        case .groupSpacer:
            return .only
        }
    }

    /// Returns a copy of this block with the specified position
    func withPosition(_ newPosition: BlockPosition) -> ContentBlock {
        switch self {
        case let .header(turnId, role, personaName, isFirstInGroup, _):
            return .header(
                turnId: turnId,
                role: role,
                personaName: personaName,
                isFirstInGroup: isFirstInGroup,
                position: newPosition
            )
        case let .paragraph(turnId, index, text, isStreaming, role, _):
            return .paragraph(
                turnId: turnId,
                index: index,
                text: text,
                isStreaming: isStreaming,
                role: role,
                position: newPosition
            )
        case let .toolCall(turnId, call, result, _):
            return .toolCall(turnId: turnId, call: call, result: result, position: newPosition)
        case let .toolCallGroup(turnId, calls, _):
            return .toolCallGroup(turnId: turnId, calls: calls, position: newPosition)
        case let .thinking(turnId, index, text, isStreaming, _):
            return .thinking(turnId: turnId, index: index, text: text, isStreaming: isStreaming, position: newPosition)
        case let .image(turnId, index, imageData, _):
            return .image(turnId: turnId, index: index, imageData: imageData, position: newPosition)
        case let .typingIndicator(turnId, _):
            return .typingIndicator(turnId: turnId, position: newPosition)
        case .groupSpacer:
            return self
        }
    }
}

// MARK: - Block Generation

extension ContentBlock {
    private static let maxParagraphSize = 600

    /// Check if a turn is "tool-only" (has tool calls but no text content)
    private static func isToolOnlyTurn(_ turn: ChatTurn) -> Bool {
        turn.contentIsEmpty && !turn.hasThinking && (turn.toolCalls?.isEmpty == false)
    }

    static func generateBlocks(
        from turns: [ChatTurn],
        streamingTurnId: UUID?,
        personaName: String
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var previousRole: MessageRole?
        var previousTurnId: UUID?

        // Accumulator for consecutive tool-only turns
        var pendingToolCalls: [ToolCallItem] = []
        var pendingToolTurnId: UUID?

        /// Flush accumulated tool calls into a single group block
        func flushPendingToolCalls(into turnBlocks: inout [ContentBlock]) {
            guard !pendingToolCalls.isEmpty, let turnId = pendingToolTurnId else { return }
            turnBlocks.append(.toolCallGroup(turnId: turnId, calls: pendingToolCalls, position: .middle))
            pendingToolCalls = []
            pendingToolTurnId = nil
        }

        let filteredTurns = turns.filter { $0.role != .tool }

        for (index, turn) in filteredTurns.enumerated() {
            let isStreaming = turn.id == streamingTurnId
            let isFirstInGroup = turn.role != previousRole
            let isToolOnly = isToolOnlyTurn(turn)

            // Check if next turn is also a tool-only assistant turn (for grouping)
            let nextTurn = index + 1 < filteredTurns.count ? filteredTurns[index + 1] : nil
            let nextIsToolOnly = nextTurn.map { isToolOnlyTurn($0) && $0.role == .assistant } ?? false

            // Spacer between role groups
            if isFirstInGroup, let prevId = previousTurnId {
                blocks.append(.groupSpacer(afterTurnId: prevId))
            }

            // Collect blocks for this turn first (to determine positions)
            var turnBlocks: [ContentBlock] = []

            // Header for first message in group
            if isFirstInGroup {
                turnBlocks.append(
                    .header(
                        turnId: turn.id,
                        role: turn.role,
                        personaName: turn.role == .assistant ? personaName : "You",
                        isFirstInGroup: true,
                        position: .first  // Temporary, will be updated
                    )
                )
            }

            // Images
            for (idx, imageData) in turn.attachedImages.enumerated() {
                turnBlocks.append(.image(turnId: turn.id, index: idx, imageData: imageData, position: .middle))
            }

            // Thinking blocks
            if turn.role == .assistant && turn.hasThinking {
                let paragraphs = splitIntoParagraphs(turn.thinking)
                for (idx, text) in paragraphs.enumerated() {
                    let isLast = idx == paragraphs.count - 1
                    turnBlocks.append(
                        .thinking(
                            turnId: turn.id,
                            index: idx,
                            text: text,
                            isStreaming: isStreaming && isLast && turn.contentIsEmpty,
                            position: .middle
                        )
                    )
                }
            }

            // Content paragraphs or typing indicator
            if !turn.contentIsEmpty {
                // Flush any pending tool calls before content
                flushPendingToolCalls(into: &turnBlocks)

                let paragraphs = splitIntoParagraphs(turn.content)
                for (idx, text) in paragraphs.enumerated() {
                    let isLast = idx == paragraphs.count - 1
                    turnBlocks.append(
                        .paragraph(
                            turnId: turn.id,
                            index: idx,
                            text: text,
                            isStreaming: isStreaming && isLast,
                            role: turn.role,
                            position: .middle
                        )
                    )
                }
            } else if isStreaming && turn.role == .assistant && !turn.hasThinking {
                let hasToolCalls = !(turn.toolCalls ?? []).isEmpty
                if !hasToolCalls {
                    turnBlocks.append(.typingIndicator(turnId: turn.id, position: .middle))
                }
            }

            // Tool calls - accumulate consecutive tool-only turns
            if let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                let items = toolCalls.map { call in
                    ToolCallItem(call: call, result: turn.toolResults[call.id])
                }

                if pendingToolTurnId == nil {
                    pendingToolTurnId = turn.id
                }
                pendingToolCalls.append(contentsOf: items)

                // Flush if this is the last tool-only turn in sequence or turn has content after
                if !nextIsToolOnly || !isToolOnly {
                    flushPendingToolCalls(into: &turnBlocks)
                }
            }

            // Update positions based on count
            let updatedBlocks = assignPositions(to: turnBlocks)
            blocks.append(contentsOf: updatedBlocks)

            previousRole = turn.role
            previousTurnId = turn.id
        }

        return blocks
    }

    /// Assigns proper positions (first/middle/last/only) to blocks within a turn
    private static func assignPositions(to blocks: [ContentBlock]) -> [ContentBlock] {
        guard !blocks.isEmpty else { return blocks }

        return blocks.enumerated().map { index, block in
            let position: BlockPosition
            if blocks.count == 1 {
                position = .only
            } else if index == 0 {
                position = .first
            } else if index == blocks.count - 1 {
                position = .last
            } else {
                position = .middle
            }

            return block.withPosition(position)
        }
    }

    /// Splits text into paragraphs while preserving code blocks
    private static func splitIntoParagraphs(_ text: String) -> [String] {
        guard text.count > maxParagraphSize else { return [text] }

        var result: [String] = []
        var chunk = ""
        var inCodeBlock = false

        let lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
            }

            if !chunk.isEmpty { chunk += "\n" }
            chunk += line

            let isLastLine = index == lines.count - 1
            let isBlankLine = trimmed.isEmpty
            let nextIsBlank = index + 1 < lines.count && lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty

            let shouldSplit =
                !inCodeBlock && !isLastLine
                && ((chunk.count >= maxParagraphSize && (isBlankLine || nextIsBlank))
                    || chunk.count >= maxParagraphSize * 2)

            if shouldSplit {
                result.append(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                chunk = ""
            }
        }

        let remaining = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            result.append(remaining)
        }

        return result.isEmpty ? [text] : result
    }
}
