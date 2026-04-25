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
    case userMessage(text: String, attachments: [Attachment])
    case sharedArtifact(artifact: SharedArtifact)
    case pendingToolCall(toolName: String, argPreview: String?, argSize: Int)
    case preflightCapabilities(items: [PreflightCapabilityItem])
    case generationStats(ttft: TimeInterval?, tokensPerSecond: Double?, tokenCount: Int?)
    case typingIndicator
    case groupSpacer
    case chart(spec: ChartSpec)
    /// Footer row appended to every completed assistant turn.
    /// Replaces the hover-revealed copy/regenerate buttons that used to live in the header,
    /// so moving the mouse over the assistant transcript no longer triggers per-row reconfigures.
    case assistantActions(turnId: UUID)

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

        case let (.userMessage(lText, lAttach), .userMessage(rText, rAttach)):
            guard lText.count == rText.count else { return false }
            guard lAttach.count == rAttach.count else { return false }
            return lText == rText && lAttach == rAttach

        case let (.sharedArtifact(lArt), .sharedArtifact(rArt)):
            return lArt == rArt

        case let (.pendingToolCall(lName, _, lSize), .pendingToolCall(rName, _, rSize)):
            return lName == rName && lSize == rSize

        case let (.preflightCapabilities(lItems), .preflightCapabilities(rItems)):
            return lItems == rItems

        case let (.generationStats(lTtft, lTps, lCount), .generationStats(rTtft, rTps, rCount)):
            return lTtft == rTtft && lTps == rTps && lCount == rCount

        case (.typingIndicator, .typingIndicator):
            return true

        case (.groupSpacer, .groupSpacer):
            return true

        case let (.chart(lSpec), .chart(rSpec)):
            return lSpec == rSpec

        case let (.assistantActions(lId), .assistantActions(rId)):
            return lId == rId

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
        case .toolCallGroup, .thinking, .sharedArtifact, .pendingToolCall, .preflightCapabilities,
            .generationStats, .typingIndicator, .groupSpacer, .chart, .assistantActions:
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
            id: "toolgroup-\(turnId.uuidString)",
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

    static func userMessage(turnId: UUID, text: String, attachments: [Attachment], position: BlockPosition)
        -> ContentBlock
    {
        ContentBlock(
            id: "usermsg-\(turnId.uuidString)",
            turnId: turnId,
            kind: .userMessage(text: text, attachments: attachments),
            position: position
        )
    }

    static func pendingToolCall(
        turnId: UUID,
        toolName: String,
        argPreview: String?,
        argSize: Int,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "pending-tool-\(turnId.uuidString)",
            turnId: turnId,
            kind: .pendingToolCall(toolName: toolName, argPreview: argPreview, argSize: argSize),
            position: position
        )
    }

    static func typingIndicator(turnId: UUID, position: BlockPosition) -> ContentBlock {
        ContentBlock(id: "typing-\(turnId.uuidString)", turnId: turnId, kind: .typingIndicator, position: position)
    }

    static func sharedArtifact(turnId: UUID, artifact: SharedArtifact, position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "artifact-\(turnId.uuidString)-\(artifact.id)",
            turnId: turnId,
            kind: .sharedArtifact(artifact: artifact),
            position: position
        )
    }

    static func preflightCapabilities(turnId: UUID, items: [PreflightCapabilityItem], position: BlockPosition)
        -> ContentBlock
    {
        ContentBlock(
            id: "preflight-\(turnId.uuidString)",
            turnId: turnId,
            kind: .preflightCapabilities(items: items),
            position: position
        )
    }

    static func generationStats(
        turnId: UUID,
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "stats-\(turnId.uuidString)",
            turnId: turnId,
            kind: .generationStats(ttft: ttft, tokensPerSecond: tokensPerSecond, tokenCount: tokenCount),
            position: position
        )
    }

    static func groupSpacer(afterTurnId: UUID, associatedWithTurnId: UUID? = nil) -> ContentBlock {
        let turnId = associatedWithTurnId ?? afterTurnId
        return ContentBlock(id: "spacer-\(afterTurnId.uuidString)", turnId: turnId, kind: .groupSpacer, position: .only)
    }

    static func assistantActions(turnId: UUID, position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "actions-\(turnId.uuidString)",
            turnId: turnId,
            kind: .assistantActions(turnId: turnId),
            position: position
        )
    }

    static func chart(turnId: UUID, spec: ChartSpec, position: BlockPosition) -> ContentBlock {
        ContentBlock(
            id: "chart-\(turnId.uuidString)",
            turnId: turnId,
            kind: .chart(spec: spec),
            position: position
        )
    }
}

// MARK: - Block Generation

extension ContentBlock {
    static func generateBlocks(
        from turns: [ChatTurn],
        streamingTurnId: UUID?,
        agentName: String,
        previousTurn: ChatTurn? = nil,
        thinkingEnabled: Bool = false
    ) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var previousRole: MessageRole? = previousTurn?.role
        var previousTurnId: UUID? = previousTurn?.id

        let filteredTurns = turns.filter { $0.role != .tool }

        for (index, turn) in filteredTurns.enumerated() {
            let isStreaming = turn.id == streamingTurnId
            let nextRole: MessageRole? = index + 1 < filteredTurns.count
                ? filteredTurns[index + 1].role : nil
            let isLastInGroup = nextRole != turn.role
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
                        attachments: turn.attachments,
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

            if let capabilities = turn.preflightCapabilities, !capabilities.isEmpty {
                turnBlocks.append(
                    .preflightCapabilities(turnId: turn.id, items: capabilities, position: .middle)
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
                // during streaming, skip the regex-based metadata strip (O(n) on every sync).
                // visibleContent is used for the final render once streaming ends.
                let text = isStreaming ? turn.content : turn.visibleContent
                let chartBlocks = Self.extractChartBlocks(
                    from: text,
                    turnId: turn.id,
                    isStreaming: isStreaming && turn.pendingToolName == nil,
                    role: turn.role
                )
                turnBlocks.append(contentsOf: chartBlocks)
            }

            if isStreaming && turn.contentIsEmpty && !turn.hasThinking
                && (turn.toolCalls ?? []).isEmpty && turn.pendingToolName == nil
            {
                // During prefill (no content/thinking/tools yet), always show the typing
                // indicator so the interface doesn't appear frozen.
                // Only add the thinking placeholder when thinking is actually enabled for
                // this model — non-thinking models don't need it.
                if thinkingEnabled {
                    turnBlocks.append(
                        .thinking(
                            turnId: turn.id,
                            index: 0,
                            text: "",
                            isStreaming: true,
                            position: .middle
                        )
                    )
                }
                turnBlocks.append(.typingIndicator(turnId: turn.id, position: .middle))
            }

            if let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                var regularItems: [ToolCallItem] = []

                // Flush queued chip items so the next specialised block
                // (artifact card, chart, clarify Q) lands in original
                // call order rather than after a trailing tool group.
                func flushRegularItems() {
                    guard !regularItems.isEmpty else { return }
                    turnBlocks.append(
                        .toolCallGroup(turnId: turn.id, calls: regularItems, position: .middle)
                    )
                    regularItems = []
                }

                for call in toolCalls {
                    // Agent-loop tools (`todo`, `complete`, `clarify`)
                    // already drive first-class inline UI — the todo
                    // checklist banner, the completion banner, and the
                    // bottom-pinned clarify overlay. Rendering them as
                    // generic tool chips on top of that would show the
                    // same call twice. `clarify` is the one exception:
                    // its overlay dismisses on submit, so without an
                    // inline trace the answered question vanishes from
                    // scroll-back. Emit a styled paragraph for it so
                    // the Q&A pair stays readable; the user's answer
                    // renders as the next user bubble below.
                    if Self.isAgentLoopToolName(call.function.name) {
                        if call.function.name == "clarify",
                            let block = Self.makeClarifyQuestionBlock(turnId: turn.id, call: call)
                        {
                            flushRegularItems()
                            turnBlocks.append(block)
                        }
                        continue
                    }

                    let result = turn.toolResults[call.id]
                    if call.function.name == "share_artifact",
                        let result,
                        let artifact = Self.parseSharedArtifactFromResult(result)
                    {
                        flushRegularItems()
                        turnBlocks.append(.sharedArtifact(turnId: turn.id, artifact: artifact, position: .middle))
                    } else if call.function.name == "render_chart",
                        let result,
                        let spec = Self.parseChartSpecFromResult(result)
                    {
                        flushRegularItems()
                        turnBlocks.append(.chart(turnId: turn.id, spec: spec.normalized, position: .middle))
                    } else {
                        regularItems.append(ToolCallItem(call: call, result: result))
                    }
                }
                flushRegularItems()
            }

            if isStreaming, let pendingName = turn.pendingToolName {
                turnBlocks.append(
                    .pendingToolCall(
                        turnId: turn.id,
                        toolName: pendingName,
                        argPreview: turn.pendingToolArgPreview,
                        argSize: turn.pendingToolArgSize,
                        position: .middle
                    )
                )
            }

            if !isStreaming && turn.role == .assistant,
                turn.timeToFirstToken != nil || turn.generationTokensPerSecond != nil
            {
                turnBlocks.append(
                    .generationStats(
                        turnId: turn.id,
                        ttft: turn.timeToFirstToken,
                        tokensPerSecond: turn.generationTokensPerSecond,
                        tokenCount: turn.generationTokenCount,
                        position: .middle
                    )
                )
            }

            // copy/regenerate bar pinned to the bottom of the final completed assistant
            // turn in a consecutive assistant group — intermediate tool-calling turns in
            // an agent loop don't get their own footer.
            if !isStreaming && turn.role == .assistant && isLastInGroup,
                !turn.contentIsEmpty || !(turn.toolCalls ?? []).isEmpty
            {
                turnBlocks.append(.assistantActions(turnId: turn.id, position: .last))
            }

            blocks.append(contentsOf: assignPositions(to: turnBlocks))
            previousRole = turn.role
            previousTurnId = turn.id
        }

        return blocks
    }

    /// Reconstructs a SharedArtifact from an enriched share_artifact tool result.
    private static func parseSharedArtifactFromResult(_ result: String) -> SharedArtifact? {
        SharedArtifact.fromEnrichedToolResult(result)
    }

    /// Parses a ChartSpec from a render_chart tool result marker.
    /// Accepts both the legacy raw marker block and the new envelope shape
    /// where the marker block lives inside `result.text`.
    private static func parseChartSpecFromResult(_ result: String) -> ChartSpec? {
        let source: String
        if let payload = ToolEnvelope.successPayload(result) as? [String: Any],
            let text = payload["text"] as? String
        {
            source = text
        } else {
            source = result
        }
        guard let start = source.range(of: "---CHART_START---\n"),
            let end = source.range(of: "\n---CHART_END---")
        else { return nil }
        let json = String(source[start.upperBound ..< end.lowerBound])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChartSpec.self, from: data)
    }

    /// Splits text into paragraph and chart blocks by detecting ```chart fenced blocks.
    /// During streaming, incomplete fences (no closing ```) are left as plain paragraphs
    /// and re-evaluated on the next sync once the closing fence arrives.
    private static func extractChartBlocks(
        from text: String,
        turnId: UUID,
        isStreaming: Bool,
        role: MessageRole
    ) -> [ContentBlock] {
        let fence = "```chart"
        guard text.contains(fence) else {
            return [
                .paragraph(
                    turnId: turnId,
                    index: 0,
                    text: text,
                    isStreaming: isStreaming,
                    role: role,
                    position: .middle
                )
            ]
        }

        var blocks: [ContentBlock] = []
        var remaining = text
        var paraIndex = 0

        while let fenceStart = remaining.range(of: fence) {
            let before = String(remaining[..<fenceStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty {
                blocks.append(
                    .paragraph(
                        turnId: turnId,
                        index: paraIndex,
                        text: before,
                        isStreaming: false,
                        role: role,
                        position: .middle
                    )
                )
                paraIndex += 1
            }

            let afterFence = remaining[fenceStart.upperBound...]
            if let closeRange = afterFence.range(of: "```") {
                let json = String(afterFence[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                remaining = String(afterFence[closeRange.upperBound...])

                if let data = json.data(using: .utf8),
                    let spec = try? JSONDecoder().decode(ChartSpec.self, from: data)
                {
                    blocks.append(.chart(turnId: turnId, spec: spec.normalized, position: .middle))
                } else {
                    // Malformed JSON — show as readable code block so user can see what was emitted
                    let errText = "⚠️ Could not render chart — invalid spec:\n```\n\(json)\n```"
                    blocks.append(
                        .paragraph(
                            turnId: turnId,
                            index: paraIndex,
                            text: errText,
                            isStreaming: false,
                            role: role,
                            position: .middle
                        )
                    )
                    paraIndex += 1
                }
            } else {
                // No closing fence yet — streaming in progress; leave as plain text for now
                let partialText = fence + String(afterFence)
                blocks.append(
                    .paragraph(
                        turnId: turnId,
                        index: paraIndex,
                        text: partialText,
                        isStreaming: isStreaming,
                        role: role,
                        position: .middle
                    )
                )
                paraIndex += 1
                remaining = ""
                break
            }
        }

        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            blocks.append(
                .paragraph(
                    turnId: turnId,
                    index: paraIndex,
                    text: tail,
                    isStreaming: isStreaming,
                    role: role,
                    position: .middle
                )
            )
        }

        return blocks.isEmpty
            ? [
                .paragraph(
                    turnId: turnId,
                    index: 0,
                    text: text,
                    isStreaming: isStreaming,
                    role: role,
                    position: .middle
                )
            ]
            : blocks
    }

    /// Build the inline "Asked: …" paragraph block for a `clarify`
    /// tool call. Returns nil when the arguments don't decode to a
    /// usable question (matches what the overlay would have skipped).
    /// Reuses the paragraph kind so the existing markdown renderer
    /// handles it without a dedicated block type — the blockquote +
    /// bold prefix gives the question its own visual weight inside
    /// the assistant turn.
    private static func makeClarifyQuestionBlock(turnId: UUID, call: ToolCall) -> ContentBlock? {
        guard let payload = ClarifyTool.parse(argumentsJSON: call.function.arguments) else {
            return nil
        }
        return ContentBlock(
            // Key on the call id so multiple clarifies in one turn
            // (rare, but legal) each get a distinct stable block id.
            id: "clarifyq-\(turnId.uuidString)-\(call.id)",
            turnId: turnId,
            kind: .paragraph(
                index: -1,
                text: "> **Asked:** \(payload.question)",
                isStreaming: false,
                role: .assistant
            ),
            position: .middle
        )
    }

    /// Tools whose results are surfaced through dedicated inline UI
    /// (todo banner, completion banner, clarify overlay) rather than
    /// the generic tool-call chip group. Centralized so the chip
    /// filter and any other render-time skip stay in lockstep.
    private static let agentLoopToolNames: Set<String> = ["todo", "complete", "clarify"]

    static func isAgentLoopToolName(_ name: String) -> Bool {
        agentLoopToolNames.contains(name)
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
