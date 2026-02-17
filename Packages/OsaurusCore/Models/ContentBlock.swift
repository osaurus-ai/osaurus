//
//  ContentBlock.swift
//  osaurus
//
//  Unified content block model for flattened chat rendering.
//  Uses stored `id` for efficient diffing in NSDiffableDataSource.
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
enum ContentBlockKind: Equatable {
    case header(role: MessageRole, agentName: String, isFirstInGroup: Bool)
    case paragraph(index: Int, text: String, isStreaming: Bool, role: MessageRole)
    case toolCallGroup(calls: [ToolCallItem])
    case thinking(index: Int, text: String, isStreaming: Bool)
    case clarification(request: ClarificationRequest)
    case userMessage(text: String, images: [Data])
    case typingIndicator
    case groupSpacer

    /// Custom Equatable optimized for performance during streaming.
    /// Uses text length comparison as a cheap proxy for content change detection.
    static func == (lhs: ContentBlockKind, rhs: ContentBlockKind) -> Bool {
        switch (lhs, rhs) {
        case let (.header(lRole, lName, lFirst), .header(rRole, rName, rFirst)):
            return lRole == rRole && lName == rName && lFirst == rFirst

        case let (.paragraph(lIdx, lText, lStream, lRole), .paragraph(rIdx, rText, rStream, rRole)):
            // Compare text length first (O(1)) - if lengths differ, content changed
            // Only do full comparison if lengths are equal (rare during streaming)
            guard lIdx == rIdx && lStream == rStream && lRole == rRole else { return false }
            guard lText.count == rText.count else { return false }
            return lText == rText

        case let (.toolCallGroup(lCalls), .toolCallGroup(rCalls)):
            return lCalls == rCalls

        case let (.thinking(lIdx, lText, lStream), .thinking(rIdx, rText, rStream)):
            // Same optimization as paragraph
            guard lIdx == rIdx && lStream == rStream else { return false }
            guard lText.count == rText.count else { return false }
            return lText == rText

        case let (.clarification(lRequest), .clarification(rRequest)):
            return lRequest == rRequest

        case let (.userMessage(lText, lImages), .userMessage(rText, rImages)):
            guard lText.count == rText.count else { return false }
            guard lImages.count == rImages.count else { return false }
            return lText == rText && lImages == rImages

        case (.typingIndicator, .typingIndicator):
            return true

        case (.groupSpacer, .groupSpacer):
            return true

        default:
            return false
        }
    }
}

// MARK: - ContentBlock

/// A single content block in the flattened chat view.
struct ContentBlock: Identifiable, Equatable, Hashable {
    let id: String
    let turnId: UUID
    let kind: ContentBlockKind
    var position: BlockPosition

    var role: MessageRole {
        switch kind {
        case let .header(role, _, _): return role
        case let .paragraph(_, _, _, role): return role
        case .toolCallGroup, .thinking, .clarification, .typingIndicator, .groupSpacer:
            return .assistant
        case .userMessage: return .user
        }
    }

    static func == (lhs: ContentBlock, rhs: ContentBlock) -> Bool {
        // Check id first (cheapest), then position, then kind (most expensive)
        lhs.id == rhs.id && lhs.position == rhs.position && lhs.kind == rhs.kind
    }

    /// Hash on `id` only — used by NSDiffableDataSource for item identity.
    /// Content equality is handled separately by the Equatable conformance.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func withPosition(_ newPosition: BlockPosition) -> ContentBlock {
        ContentBlock(id: id, turnId: turnId, kind: kind, position: newPosition)
    }

    // MARK: - Factory Methods

    static func header(
        turnId: UUID,
        role: MessageRole,
        agentName: String,
        isFirstInGroup: Bool,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "header-\(turnId.uuidString)",
            turnId: turnId,
            kind: .header(role: role, agentName: agentName, isFirstInGroup: isFirstInGroup),
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

    static func clarification(turnId: UUID, request: ClarificationRequest, position: BlockPosition)
        -> ContentBlock
    {
        ContentBlock(
            id: "clarification-\(turnId.uuidString)",
            turnId: turnId,
            kind: .clarification(request: request),
            position: position
        )
    }

    static func userMessage(turnId: UUID, text: String, images: [Data], position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "usermsg-\(turnId.uuidString)",
            turnId: turnId,
            kind: .userMessage(text: text, images: images),
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
    static func generateBlocks(
        from turns: [ChatTurn],
        streamingTurnId: UUID?,
        agentName: String,
        previousTurn: ChatTurn? = nil
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var previousRole: MessageRole? = previousTurn?.role
        var previousTurnId: UUID? = previousTurn?.id

        let filteredTurns = turns.filter { $0.role != .tool }

        for turn in filteredTurns {
            let isStreaming = turn.id == streamingTurnId
            // User messages always start a new group (each is distinct input).
            // Assistant messages group consecutive turns (continuing responses).
            let isFirstInGroup = turn.role != previousRole || turn.role == .user

            if isFirstInGroup, let prevId = previousTurnId {
                // Use the previous turn ID for the stable block ID (referencing the gap)
                // BUT associate it with the current turn ID so it gets regenerated/included with the current turn during incremental updates
                blocks.append(.groupSpacer(afterTurnId: prevId, associatedWithTurnId: turn.id))
            }

            // User messages are emitted as a single unified block
            if turn.role == .user {
                blocks.append(
                    .userMessage(
                        turnId: turn.id,
                        text: turn.content,
                        images: turn.attachedImages,
                        position: .only
                    )
                )
                previousRole = turn.role
                previousTurnId = turn.id
                continue
            }

            var turnBlocks: [ContentBlock] = []

            if isFirstInGroup {
                turnBlocks.append(
                    .header(
                        turnId: turn.id,
                        role: turn.role,
                        agentName: agentName,
                        isFirstInGroup: true,
                        position: .first
                    )
                )
            }

            // Add clarification block if pending (work mode)
            if let clarification = turn.pendingClarification {
                turnBlocks.append(
                    .clarification(
                        turnId: turn.id,
                        request: clarification,
                        position: .middle
                    )
                )
            }

            if turn.hasThinking {
                turnBlocks.append(
                    .thinking(
                        turnId: turn.id,
                        index: 0,
                        text: turn.thinking,
                        isStreaming: isStreaming && turn.contentIsEmpty,
                        position: .middle
                    )
                )
            }

            if !turn.contentIsEmpty {
                turnBlocks.append(
                    .paragraph(
                        turnId: turn.id,
                        index: 0,
                        text: turn.content,
                        isStreaming: isStreaming,
                        role: turn.role,
                        position: .middle
                    )
                )
            } else if isStreaming && !turn.hasThinking && (turn.toolCalls ?? []).isEmpty {
                turnBlocks.append(.typingIndicator(turnId: turn.id, position: .middle))
            }

            // Emit tool calls inline per turn to preserve chronological order.
            // Multiple tool calls within a single turn (parallel calls) are still
            // grouped together, but tool calls from different turns are not merged.
            if let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                let items = toolCalls.map { ToolCallItem(call: $0, result: turn.toolResults[$0.id]) }
                turnBlocks.append(.toolCallGroup(turnId: turn.id, calls: items, position: .middle))
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

}
