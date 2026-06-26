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
    /// How long the call took to finish (seconds), shown as "· 1.2s". Nil until
    /// measured / for calls whose duration wasn't recorded.
    var duration: TimeInterval? = nil

    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.call.id == rhs.call.id && lhs.result == rhs.result && lhs.duration == rhs.duration
    }
}

/// The kind/type of a content block
enum ContentBlockKind: Equatable {
    case header(role: MessageRole, agentName: String, isFirstInGroup: Bool)
    case paragraph(index: Int, text: String, isStreaming: Bool, role: MessageRole)
    case toolCallGroup(calls: [ToolCallItem])
    case thinking(index: Int, text: String, isStreaming: Bool, duration: TimeInterval?)
    case userMessage(text: String, attachments: [Attachment])
    case sharedArtifact(artifact: SharedArtifact)
    case pendingToolCall(toolName: String, argPreview: String?, argSize: Int)
    /// Generation benchmarks footer for a completed assistant turn.
    /// `unclosedReasoning` is true when vmlx's `GenerateCompletionInfo.unclosedReasoning`
    /// fires — model ended the stream still inside a `<think>` block (trapped
    /// thinking). Cell renderer surfaces a one-line "thinking didn't close"
    /// warning beside the tok/s chip when set.
    case generationStats(
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        unclosedReasoning: Bool
    )
    case typingIndicator
    case groupSpacer
    case chart(spec: ChartSpec)
    /// GitHub-style diff card rendered in place of the generic tool-call row
    /// for `file_write` / `file_edit` edits inside the selected folder.
    case fileDiff(diff: FileDiff)
    /// Footer row appended to every completed assistant turn.
    /// Replaces the hover-revealed copy/regenerate buttons that used to live in the header,
    /// so moving the mouse over the assistant transcript no longer triggers per-row reconfigures.
    /// `imageOnly` marks an image-generation result (content is just the rendered
    /// image), so Read-aloud and the overflow "…" Inspect — which have nothing to
    /// act on — are hidden. `timestamp` backs the overflow menu's "arrived at" header.
    case assistantActions(turnId: UUID, imageOnly: Bool, timestamp: Date)
    /// Shown when the Osaurus Router billed a turn that produced no visible
    /// text (and no reasoning/tools). Surfaces the charge honestly with a Retry
    /// affordance instead of silently dropping the turn. `costMicro` is the raw
    /// micro-USD string; `status` is the router's terminal status.
    case emptyResponseNotice(turnId: UUID, outputTokens: Int, costMicro: String, status: String)

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

        case let (.thinking(lIdx, lText, lStream, lDur), .thinking(rIdx, rText, rStream, rDur)):
            // Same optimization as paragraph
            guard lIdx == rIdx && lStream == rStream && lDur == rDur else { return false }
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

        case let (
            .generationStats(lTtft, lTps, lCount, lUnclosed),
            .generationStats(rTtft, rTps, rCount, rUnclosed)
        ):
            return lTtft == rTtft && lTps == rTps && lCount == rCount
                && lUnclosed == rUnclosed

        case (.typingIndicator, .typingIndicator):
            return true

        case (.groupSpacer, .groupSpacer):
            return true

        case let (.chart(lSpec), .chart(rSpec)):
            return lSpec == rSpec

        case let (.fileDiff(lDiff), .fileDiff(rDiff)):
            return lDiff == rDiff

        case let (
            .assistantActions(lId, lImageOnly, lTime),
            .assistantActions(rId, rImageOnly, rTime)
        ):
            return lId == rId && lImageOnly == rImageOnly && lTime == rTime

        case let (
            .emptyResponseNotice(lId, lTokens, lCost, lStatus),
            .emptyResponseNotice(rId, rTokens, rCost, rStatus)
        ):
            return lId == rId && lTokens == rTokens && lCost == rCost && lStatus == rStatus

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
        case .toolCallGroup, .thinking, .sharedArtifact, .pendingToolCall,
            .generationStats, .typingIndicator, .groupSpacer, .chart, .assistantActions,
            .emptyResponseNotice, .fileDiff:
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

    /// Display-only tool-call group for remote-agent (Mode 2) activity. Reuses
    /// the `.toolCallGroup` kind (same rendering / height / caching), but with a
    /// distinct id so it can never collide with a turn's real tool group in the
    /// table/diff (it never coexists in Mode 2 — the client runs no tools — but
    /// the id space stays unambiguous regardless).
    static func remoteToolActivityGroup(turnId: UUID, calls: [ToolCallItem], position: BlockPosition)
        -> ContentBlock
    {
        ContentBlock(
            id: "remote-toolgroup-\(turnId.uuidString)",
            turnId: turnId,
            kind: .toolCallGroup(calls: calls),
            position: position
        )
    }

    /// Stable id for a turn's thinking block. Shared by the factory and the
    /// reasoning-only auto-expand seeding so the two never drift apart.
    static func thinkingBlockId(turnId: UUID, index: Int = 0) -> String {
        "think-\(turnId.uuidString)-\(index)"
    }

    static func thinking(
        turnId: UUID,
        index: Int,
        text: String,
        isStreaming: Bool,
        duration: TimeInterval?,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: thinkingBlockId(turnId: turnId, index: index),
            turnId: turnId,
            kind: .thinking(index: index, text: text, isStreaming: isStreaming, duration: duration),
            position: position
        )
    }

    static func userMessage(
        turnId: UUID,
        text: String,
        attachments: [Attachment],
        position: BlockPosition
    ) -> ContentBlock {
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

    static func generationStats(
        turnId: UUID,
        ttft: TimeInterval?,
        tokensPerSecond: Double?,
        tokenCount: Int?,
        unclosedReasoning: Bool = false,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "stats-\(turnId.uuidString)",
            turnId: turnId,
            kind: .generationStats(
                ttft: ttft,
                tokensPerSecond: tokensPerSecond,
                tokenCount: tokenCount,
                unclosedReasoning: unclosedReasoning
            ),
            position: position
        )
    }

    static func groupSpacer(afterTurnId: UUID, associatedWithTurnId: UUID? = nil) -> ContentBlock {
        let turnId = associatedWithTurnId ?? afterTurnId
        return ContentBlock(id: "spacer-\(afterTurnId.uuidString)", turnId: turnId, kind: .groupSpacer, position: .only)
    }

    static func assistantActions(turnId: UUID, imageOnly: Bool, timestamp: Date, position: BlockPosition)
        -> ContentBlock
    {
        ContentBlock(
            id: "actions-\(turnId.uuidString)",
            turnId: turnId,
            kind: .assistantActions(turnId: turnId, imageOnly: imageOnly, timestamp: timestamp),
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

    static func fileDiff(
        turnId: UUID,
        callId: String,
        diff: FileDiff,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "filediff-\(callId)",
            turnId: turnId,
            kind: .fileDiff(diff: diff),
            position: position
        )
    }

    static func emptyResponseNotice(
        turnId: UUID,
        billing: RouterBillingSummary,
        position: BlockPosition
    ) -> ContentBlock {
        ContentBlock(
            id: "empty-notice-\(turnId.uuidString)",
            turnId: turnId,
            kind: .emptyResponseNotice(
                turnId: turnId,
                outputTokens: billing.outputTokens,
                costMicro: billing.costMicro,
                status: billing.status
            ),
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
            let nextRole: MessageRole? =
                index + 1 < filteredTurns.count
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

            let hasVisibleContent =
                !turn.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasRenderableThinking = turn.hasRenderableThinking
            let hasSharedArtifacts = !turn.sharedArtifacts.isEmpty

            if hasRenderableThinking {
                turnBlocks.append(
                    .thinking(
                        turnId: turn.id,
                        index: 0,
                        text: turn.thinking,
                        isStreaming: isStreaming && !hasVisibleContent,
                        duration: turn.thinkingDuration,
                        position: .middle
                    )
                )
            }

            // Mode 2 remote-agent tool activity, rendered above the answer so it
            // reads chronologically ("called these tools, then replied"). Each
            // row is reconstructed from sanitized traces: a missing result keeps
            // it shimmering ("running"), a failure envelope turns it red, any
            // other result marks it done. Agent-loop control tools (todo /
            // complete / clarify) are filtered to match local behavior.
            if turn.hasRemoteToolActivity {
                let remoteItems =
                    turn.remoteToolActivity
                    .filter { !Self.isAgentLoopToolName($0.function.name) }
                    .map { call in
                        ToolCallItem(
                            call: call,
                            result: turn.remoteToolResults[call.id],
                            duration: nil
                        )
                    }
                if !remoteItems.isEmpty {
                    turnBlocks.append(
                        .remoteToolActivityGroup(turnId: turn.id, calls: remoteItems, position: .middle)
                    )
                }
            }

            if hasVisibleContent {
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

            if hasSharedArtifacts {
                for artifact in turn.sharedArtifacts {
                    turnBlocks.append(.sharedArtifact(turnId: turn.id, artifact: artifact, position: .middle))
                }
            }

            if isStreaming && !hasVisibleContent && !hasRenderableThinking
                && !hasSharedArtifacts && (turn.toolCalls ?? []).isEmpty && turn.pendingToolName == nil
                && !turn.hasRemoteToolActivity
            {
                // During prefill (no content/thinking/tools yet), always show the typing
                // indicator so the interface doesn't appear frozen. Skipped once a
                // Mode 2 remote tool is running — the running tool chip already
                // signals progress, so a typing indicator on top would be noise.
                // Only add the thinking placeholder when thinking is actually enabled for
                // this model — non-thinking models don't need it.
                if thinkingEnabled {
                    turnBlocks.append(
                        .thinking(
                            turnId: turn.id,
                            index: 0,
                            text: "",
                            isStreaming: true,
                            duration: nil,
                            position: .middle
                        )
                    )
                }
                turnBlocks.append(.typingIndicator(turnId: turn.id, position: .middle))
            }

            if !isStreaming && !hasVisibleContent && !hasRenderableThinking
                && !hasSharedArtifacts && (turn.toolCalls ?? []).isEmpty && turn.pendingToolName == nil
                && !turn.hasRemoteToolActivity,
                let billing = turn.routerBilling
            {
                // The router billed this turn but it produced no visible text,
                // reasoning, or tools. Surface the charge with a Retry instead
                // of the generic "no text" line.
                turnBlocks.append(
                    .emptyResponseNotice(turnId: turn.id, billing: billing, position: .middle)
                )
            } else if !isStreaming && !hasVisibleContent && !hasRenderableThinking
                && !hasSharedArtifacts && (turn.toolCalls ?? []).isEmpty && turn.pendingToolName == nil
                && !turn.hasRemoteToolActivity
                && (turn.generationTokenCount != nil || turn.generationTokensPerSecond != nil)
            {
                turnBlocks.append(
                    .paragraph(
                        turnId: turn.id,
                        index: 0,
                        text: "No visible text was produced.",
                        isStreaming: false,
                        role: turn.role,
                        position: .middle
                    )
                )
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
                    if Self.isArtifactRenderingToolName(call.function.name),
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
                    } else if FileDiff.diffProducingToolNames.contains(call.function.name),
                        let result,
                        let diff = FileDiff.from(toolResult: result)
                    {
                        // Replace the generic tool-call row with a GitHub-style
                        // diff card so a folder-scoped edit reads as a reviewable
                        // change rather than an opaque tool invocation.
                        flushRegularItems()
                        turnBlocks.append(
                            .fileDiff(turnId: turn.id, callId: call.id, diff: diff, position: .middle)
                        )
                    } else {
                        regularItems.append(
                            ToolCallItem(call: call, result: result, duration: turn.toolCallDurations[call.id])
                        )
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

            // stats must be shown only on the final turn (intermediate tool calling turns should not display them)
            if !isStreaming && turn.role == .assistant && isLastInGroup,
                turn.timeToFirstToken != nil || turn.generationTokensPerSecond != nil
            {
                turnBlocks.append(
                    .generationStats(
                        turnId: turn.id,
                        ttft: turn.timeToFirstToken,
                        tokensPerSecond: turn.generationTokensPerSecond,
                        tokenCount: turn.generationTokenCount,
                        unclosedReasoning: turn.unclosedReasoning,
                        position: .middle
                    )
                )
            }

            // copy/regenerate bar pinned to the bottom of the final completed assistant
            // turn in a consecutive assistant group — intermediate tool-calling turns in
            // an agent loop don't get their own footer.
            if !isStreaming && turn.role == .assistant && isLastInGroup,
                hasVisibleContent || hasRenderableThinking || hasSharedArtifacts || !(turn.toolCalls ?? []).isEmpty
            {
                // An image-generation reply renders as just the produced image, so
                // Read-aloud (nothing to speak) and the overflow Inspect (no request
                // log) are hidden — only Copy and Regenerate stay.
                let imageOnly =
                    hasVisibleContent && !hasRenderableThinking
                    && (turn.toolCalls ?? []).isEmpty
                    && Self.isImageOnlyContent(turn.visibleContent)
                turnBlocks.append(
                    .assistantActions(
                        turnId: turn.id,
                        imageOnly: imageOnly,
                        timestamp: turn.createdAt,
                        position: .last
                    )
                )
            }

            blocks.append(contentsOf: assignPositions(to: turnBlocks))
            previousRole = turn.role
            previousTurnId = turn.id
        }

        // NOTE: coalescing of adjacent tool groups is applied at the display
        // chokepoint (`BlockMemoizer.limited`), not here, so the incremental
        // block cache keeps stable per-turn group ids while the view still sees
        // a single stitched timeline (including across the incremental seam).
        return blocks
    }

    /// Merge directly-adjacent `.toolCallGroup` blocks into one. The agent loop
    /// emits one tool call per assistant turn, so a run of tool calls becomes a
    /// run of single-call group blocks; coalescing them lets the UI render the
    /// whole run as a single connected timeline (rail + nodes) instead of N
    /// disconnected lone nodes. Anything else between two groups (thinking, a
    /// chart/artifact, the final answer) breaks the run, as intended. The merged
    /// block keeps the first group's id/turnId so diffing stays stable.
    ///
    /// Applied to the array handed to the view (not the cache) so that the
    /// memoizer's prefix/suffix incremental regeneration — which stores per-turn
    /// group blocks — still renders consecutive calls as one connected rail the
    /// moment the second call appears.
    static func coalesceToolGroups(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var result: [ContentBlock] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            if case let .toolCallGroup(calls) = block.kind,
                let prev = result.last,
                case let .toolCallGroup(prevCalls) = prev.kind
            {
                result[result.count - 1] = .toolCallGroup(
                    turnId: prev.turnId,
                    calls: prevCalls + calls,
                    position: prev.position
                )
            } else {
                result.append(block)
            }
        }
        return result
    }

    /// Reconstructs a SharedArtifact from an enriched share_artifact tool result.
    private static func parseSharedArtifactFromResult(_ result: String) -> SharedArtifact? {
        SharedArtifact.fromEnrichedToolResult(result)
    }

    private static func isArtifactRenderingToolName(_ name: String) -> Bool {
        name == "share_artifact" || NativeImageToolArtifactBridge.isNativeImageTool(name)
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

    /// True when the trimmed content is nothing but one or more standalone
    /// markdown images — the shape an image-generation reply takes. Used to
    /// drop the Insights / Read-aloud footer actions, which have nothing to
    /// act on for a pure-image turn.
    private static let standaloneImageLineRegex = try? NSRegularExpression(
        pattern: #"^!\[[^\]]*\]\([^)]+\)$"#
    )

    static func isImageOnlyContent(_ content: String) -> Bool {
        guard let regex = standaloneImageLineRegex else { return false }
        let lines =
            content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            let range = NSRange(line.startIndex ..< line.endIndex, in: line)
            return regex.firstMatch(in: line, range: range) != nil
        }
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
