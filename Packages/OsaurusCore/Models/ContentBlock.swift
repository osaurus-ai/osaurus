//
//  ContentBlock.swift
//  osaurus
//
//  Unified content block model for flattened chat rendering.
//  Uses stored `id` for efficient SwiftUI diffing in LazyVStack.
//

import Foundation

// MARK: - Supporting Types

/// Position of a block within its turn (for styling)
enum BlockPosition: Equatable {
    case only, first, middle, last
}

/// A tool call with its result for grouped rendering
struct ToolCallItem: Equatable {
    let call: ToolCall
    let result: String?

    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.call.id == rhs.call.id && lhs.result == rhs.result
    }
}

/// The kind/type of a content block
enum ContentBlockKind {
    case header(role: MessageRole, personaName: String, isFirstInGroup: Bool)
    case paragraph(index: Int, text: String, isStreaming: Bool, role: MessageRole)
    case toolCall(call: ToolCall, result: String?)
    case toolCallGroup(calls: [ToolCallItem])
    case thinking(index: Int, text: String, isStreaming: Bool)
    case image(index: Int, imageData: Data)
    case typingIndicator
    case groupSpacer
}

// MARK: - ContentBlock

/// A single content block in the flattened chat view.
struct ContentBlock: Identifiable, Equatable {
    let id: String
    let turnId: UUID
    let kind: ContentBlockKind
    var position: BlockPosition

    var role: MessageRole {
        switch kind {
        case let .header(role, _, _): return role
        case let .paragraph(_, _, _, role): return role
        case .toolCall, .toolCallGroup, .thinking, .typingIndicator, .groupSpacer: return .assistant
        case .image: return .user
        }
    }

    static func == (lhs: ContentBlock, rhs: ContentBlock) -> Bool {
        lhs.id == rhs.id && lhs.position == rhs.position
    }

    func withPosition(_ newPosition: BlockPosition) -> ContentBlock {
        ContentBlock(id: id, turnId: turnId, kind: kind, position: newPosition)
    }

    // MARK: - Factory Methods

    static func header(
        turnId: UUID,
        role: MessageRole,
        personaName: String,
        isFirstInGroup: Bool,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "header-\(turnId.uuidString)",
            turnId: turnId,
            kind: .header(role: role, personaName: personaName, isFirstInGroup: isFirstInGroup),
            position: position
        )
    }

    static func paragraph(
        turnId: UUID,
        index: Int,
        text: String,
        isStreaming: Bool,
        role: MessageRole,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "para-\(turnId.uuidString)-\(index)",
            turnId: turnId,
            kind: .paragraph(index: index, text: text, isStreaming: isStreaming, role: role),
            position: position
        )
    }

    static func toolCall(turnId: UUID, call: ToolCall, result: String?, position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "tool-\(turnId.uuidString)-\(call.id)",
            turnId: turnId,
            kind: .toolCall(call: call, result: result),
            position: position
        )
    }

    static func toolCallGroup(turnId: UUID, calls: [ToolCallItem], position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "toolgroup-\(turnId.uuidString)-\(calls.map(\.call.id).joined(separator: "-"))",
            turnId: turnId,
            kind: .toolCallGroup(calls: calls),
            position: position
        )
    }

    static func thinking(turnId: UUID, index: Int, text: String, isStreaming: Bool, position: BlockPosition)
        -> ContentBlock
    {
        ContentBlock(
            id: "think-\(turnId.uuidString)-\(index)",
            turnId: turnId,
            kind: .thinking(index: index, text: text, isStreaming: isStreaming),
            position: position
        )
    }

    static func image(turnId: UUID, index: Int, imageData: Data, position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "img-\(turnId.uuidString)-\(index)",
            turnId: turnId,
            kind: .image(index: index, imageData: imageData),
            position: position
        )
    }

    static func typingIndicator(turnId: UUID, position: BlockPosition) -> ContentBlock {
        ContentBlock(id: "typing-\(turnId.uuidString)", turnId: turnId, kind: .typingIndicator, position: position)
    }

    static func groupSpacer(afterTurnId: UUID, associatedWithTurnId: UUID? = nil) -> ContentBlock {
        let turnId = associatedWithTurnId ?? afterTurnId
        return ContentBlock(id: "spacer-\(afterTurnId.uuidString)", turnId: turnId, kind: .groupSpacer, position: .only)
    }
}

// MARK: - Block Generation

extension ContentBlock {
    private static let maxParagraphSize = 600

    private static func isToolOnlyTurn(_ turn: ChatTurn) -> Bool {
        turn.contentIsEmpty && !turn.hasThinking && (turn.toolCalls?.isEmpty == false)
    }

    static func generateBlocks(
        from turns: [ChatTurn],
        streamingTurnId: UUID?,
        personaName: String,
        previousTurn: ChatTurn? = nil
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var previousRole: MessageRole? = previousTurn?.role
        var previousTurnId: UUID? = previousTurn?.id
        var pendingToolCalls: [ToolCallItem] = []
        var pendingToolTurnId: UUID?

        // If we have a previous turn, we assume any pending tool calls were already flushed or irrelevant for this batch.
        // However, if we were splitting processing in the middle of tool accumulation, this would be complex.
        // Given we split at turn boundaries, previous turn's tools should be handled.

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
            let nextTurn = index + 1 < filteredTurns.count ? filteredTurns[index + 1] : nil
            let nextIsToolOnly = nextTurn.map { isToolOnlyTurn($0) && $0.role == .assistant } ?? false

            if isFirstInGroup, let prevId = previousTurnId {
                // Use the previous turn ID for the stable block ID (referencing the gap)
                // BUT associate it with the current turn ID so it gets regenerated/included with the current turn during incremental updates
                blocks.append(.groupSpacer(afterTurnId: prevId, associatedWithTurnId: turn.id))
            }

            var turnBlocks: [ContentBlock] = []

            if isFirstInGroup {
                turnBlocks.append(
                    .header(
                        turnId: turn.id,
                        role: turn.role,
                        personaName: turn.role == .assistant ? personaName : "You",
                        isFirstInGroup: true,
                        position: .first
                    )
                )
            }

            for (idx, imageData) in turn.attachedImages.enumerated() {
                turnBlocks.append(.image(turnId: turn.id, index: idx, imageData: imageData, position: .middle))
            }

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

            if !turn.contentIsEmpty {
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
            } else if isStreaming && turn.role == .assistant && !turn.hasThinking && (turn.toolCalls ?? []).isEmpty {
                turnBlocks.append(.typingIndicator(turnId: turn.id, position: .middle))
            }

            if let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                let items = toolCalls.map { ToolCallItem(call: $0, result: turn.toolResults[$0.id]) }
                if pendingToolTurnId == nil { pendingToolTurnId = turn.id }
                pendingToolCalls.append(contentsOf: items)
                if !nextIsToolOnly || !isToolOnly {
                    flushPendingToolCalls(into: &turnBlocks)
                }
            }

            blocks.append(contentsOf: assignPositions(to: turnBlocks))
            previousRole = turn.role
            previousTurnId = turn.id
        }

        return blocks
    }

    private static func assignPositions(to blocks: [ContentBlock]) -> [ContentBlock] {
        guard !blocks.isEmpty else { return blocks }
        return blocks.enumerated().map { index, block in
            let position: BlockPosition =
                blocks.count == 1 ? .only : (index == 0 ? .first : (index == blocks.count - 1 ? .last : .middle))
            return block.withPosition(position)
        }
    }

    private static func splitIntoParagraphs(_ text: String) -> [String] {
        guard text.count > maxParagraphSize else { return [text] }

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
                && ((chunk.count >= maxParagraphSize && (isBlankLine || nextIsBlank))
                    || chunk.count >= maxParagraphSize * 2)

            if shouldSplit {
                result.append(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                chunk = ""
            }
        }

        let remaining = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty { result.append(remaining) }
        return result.isEmpty ? [text] : result
    }
}
