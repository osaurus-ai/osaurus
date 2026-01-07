//
//  ContentBlock.swift
//  osaurus
//
//  Unified content block model for flattened chat rendering.
//  Each block is a top-level item in LazyVStack for efficient recycling.
//

import Foundation

/// A single content block in the flattened chat view.
enum ContentBlock: Identifiable {
    case header(turnId: UUID, role: MessageRole, personaName: String, isFirstInGroup: Bool)
    case paragraph(turnId: UUID, index: Int, text: String, isStreaming: Bool, role: MessageRole)
    case toolCall(turnId: UUID, call: ToolCall, result: String?)
    case thinking(turnId: UUID, index: Int, text: String, isStreaming: Bool)
    case image(turnId: UUID, index: Int, imageData: Data)
    case typingIndicator(turnId: UUID)
    case groupSpacer(afterTurnId: UUID)

    var id: String {
        switch self {
        case let .header(turnId, _, _, _): return "header-\(turnId.uuidString)"
        case let .paragraph(turnId, index, _, _, _): return "para-\(turnId.uuidString)-\(index)"
        case let .toolCall(turnId, call, _): return "tool-\(turnId.uuidString)-\(call.id)"
        case let .thinking(turnId, index, _, _): return "think-\(turnId.uuidString)-\(index)"
        case let .image(turnId, index, _): return "img-\(turnId.uuidString)-\(index)"
        case let .typingIndicator(turnId): return "typing-\(turnId.uuidString)"
        case let .groupSpacer(afterTurnId): return "spacer-\(afterTurnId.uuidString)"
        }
    }

    var turnId: UUID {
        switch self {
        case let .header(turnId, _, _, _),
            let .paragraph(turnId, _, _, _, _),
            let .toolCall(turnId, _, _),
            let .thinking(turnId, _, _, _),
            let .image(turnId, _, _),
            let .typingIndicator(turnId),
            let .groupSpacer(turnId):
            return turnId
        }
    }

    var role: MessageRole {
        switch self {
        case let .header(_, role, _, _): return role
        case let .paragraph(_, _, _, _, role): return role
        case .toolCall, .thinking, .typingIndicator: return .assistant
        case .image: return .user
        case .groupSpacer: return .assistant
        }
    }
}

// MARK: - Block Generation

extension ContentBlock {
    private static let maxParagraphSize = 600

    static func generateBlocks(
        from turns: [ChatTurn],
        streamingTurnId: UUID?,
        personaName: String
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var previousRole: MessageRole?
        var previousTurnId: UUID?

        for turn in turns where turn.role != .tool {
            let isStreaming = turn.id == streamingTurnId
            let isFirstInGroup = turn.role != previousRole

            // Spacer between role groups
            if isFirstInGroup, let prevId = previousTurnId {
                blocks.append(.groupSpacer(afterTurnId: prevId))
            }

            // Header for first message in group
            if isFirstInGroup {
                blocks.append(
                    .header(
                        turnId: turn.id,
                        role: turn.role,
                        personaName: turn.role == .assistant ? personaName : "You",
                        isFirstInGroup: true
                    )
                )
            }

            // Images
            for (index, imageData) in turn.attachedImages.enumerated() {
                blocks.append(.image(turnId: turn.id, index: index, imageData: imageData))
            }

            // Thinking blocks
            if turn.role == .assistant && turn.hasThinking {
                let paragraphs = splitIntoParagraphs(turn.thinking)
                for (index, text) in paragraphs.enumerated() {
                    let isLast = index == paragraphs.count - 1
                    blocks.append(
                        .thinking(
                            turnId: turn.id,
                            index: index,
                            text: text,
                            isStreaming: isStreaming && isLast && turn.contentIsEmpty
                        )
                    )
                }
            }

            // Content paragraphs or typing indicator
            if !turn.contentIsEmpty {
                let paragraphs = splitIntoParagraphs(turn.content)
                for (index, text) in paragraphs.enumerated() {
                    let isLast = index == paragraphs.count - 1
                    blocks.append(
                        .paragraph(
                            turnId: turn.id,
                            index: index,
                            text: text,
                            isStreaming: isStreaming && isLast,
                            role: turn.role
                        )
                    )
                }
            } else if isStreaming && turn.role == .assistant && !turn.hasThinking {
                let hasToolCalls = !(turn.toolCalls ?? []).isEmpty
                if !hasToolCalls {
                    blocks.append(.typingIndicator(turnId: turn.id))
                }
            }

            // Tool calls
            if let toolCalls = turn.toolCalls {
                for call in toolCalls {
                    blocks.append(.toolCall(turnId: turn.id, call: call, result: turn.toolResults[call.id]))
                }
            }

            previousRole = turn.role
            previousTurnId = turn.id
        }

        return blocks
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
