//
//  BlockMemoizer.swift
//  osaurus
//
//  Memoizes content block generation with incremental updates during streaming.
//  Supports three cache paths to minimize NSTableView re-layout:
//    1. Fast path   – nothing changed, return cached blocks
//    2. Incremental – only last turn's content changed (streaming)
//    3. Append      – one or more turns added at the end
//  Falls back to full rebuild when none of the above apply.
//

import Foundation

final class BlockMemoizer {
    private var cached: [ContentBlock] = []
    private var cachedGroupHeaderMap: [UUID: UUID] = [:]
    private var lastCount = 0
    private var lastTurnId: UUID?
    private var lastContentLen = 0
    private var lastThinkingLen = 0
    private var lastPendingToolName: String?
    private var lastPendingToolArgSize = 0
    /// Remote-agent (Mode 2) tool-activity counter of the streaming turn. A
    /// trace can change the persistent remote tool chips without touching
    /// content/thinking length or `pendingToolName`, so without this the fast
    /// path would keep returning the stale cached blocks and the chips would
    /// never appear/transition during a remote run.
    private var lastRemoteToolTick = 0
    private var lastVersion = -1
    /// The agent name baked into cached header blocks. A change (e.g. switching
    /// from a local agent to a remote one) must force a full rebuild so stale
    /// "Osaurus" headers aren't kept by the fast / incremental paths.
    private var lastAgentName: String?
    /// Must match `streamingTurnId` for the fast path — `generateBlocks` depends on it for typing / prefill UI.
    private var lastStreamingTurnId: UUID?
    private let streamingMaxBlocks = 80
    private let nonStreamingMaxBlocks = 400

    /// Maps each block's turnId to its visual group's header turnId.
    /// Updated alongside blocks in `blocks(from:...)`.
    var groupHeaderMap: [UUID: UUID] { cachedGroupHeaderMap }

    func blocks(
        from turns: [ChatTurn],
        streamingTurnId: UUID?,
        agentName: String,
        version: Int = 0,
        thinkingEnabled: Bool = false
    ) -> [ContentBlock] {
        let count = turns.count
        let lastId = turns.last?.id
        let contentLen = turns.last?.contentLength ?? 0
        let thinkingLen = turns.last?.thinkingLength ?? 0
        let pendingToolName = turns.last?.pendingToolName
        let pendingToolArgSize = turns.last?.pendingToolArgSize ?? 0
        let remoteToolTick = turns.last?.remoteToolActivityTick ?? 0
        // The header name is baked into cached blocks; a change must invalidate
        // the fast / incremental / append paths so headers re-render with it.
        let agentNameChanged = agentName != lastAgentName

        // Fast path: nothing changed (including which turn is streaming — drives typing indicator / placeholders).
        if !agentNameChanged
            && count == lastCount && lastId == lastTurnId
            && contentLen == lastContentLen && thinkingLen == lastThinkingLen
            && pendingToolName == lastPendingToolName
            && pendingToolArgSize == lastPendingToolArgSize
            && remoteToolTick == lastRemoteToolTick
            && version == lastVersion && !cached.isEmpty
            && streamingTurnId == lastStreamingTurnId
        {
            return limited(streaming: streamingTurnId != nil)
        }

        // Incremental: only last turn's content changed during streaming
        let canIncrement =
            !agentNameChanged
            && streamingTurnId != nil
            && count == lastCount && lastId == lastTurnId
            && lastId != nil && !cached.isEmpty

        // Append: one or more turns added at the end; previous last turn still matches
        let canAppend =
            !agentNameChanged
            && !canIncrement
            && count > lastCount && !cached.isEmpty
            && lastCount >= 1 && turns[lastCount - 1].id == lastTurnId

        let blocks: [ContentBlock]

        let wasIncremental: Bool
        if canIncrement {
            // Last turn's content changed during streaming.
            blocks = regenerateFromTurn(
                at: count - 1,
                in: turns,
                streamingTurnId: streamingTurnId,
                agentName: agentName,
                thinkingEnabled: thinkingEnabled
            )
            wasIncremental = true
        } else if canAppend {
            // Regenerate from the previous last turn onwards — it may have been
            // modified (e.g. tool calls added) before the new turns were appended.
            blocks = regenerateFromTurn(
                at: lastCount - 1,
                in: turns,
                streamingTurnId: streamingTurnId,
                agentName: agentName,
                thinkingEnabled: thinkingEnabled
            )
            wasIncremental = false
        } else {
            // Full rebuild (first load, reset, or structural change)
            blocks = ContentBlock.generateBlocks(
                from: turns,
                streamingTurnId: streamingTurnId,
                agentName: agentName,
                thinkingEnabled: thinkingEnabled
            )
            wasIncremental = false
        }

        // Update cache state
        cached = blocks
        lastCount = count
        lastTurnId = lastId
        lastContentLen = contentLen
        lastThinkingLen = thinkingLen
        lastPendingToolName = pendingToolName
        lastPendingToolArgSize = pendingToolArgSize
        lastRemoteToolTick = remoteToolTick
        lastVersion = version
        lastStreamingTurnId = streamingTurnId
        lastAgentName = agentName

        // incremental path: only rebuild the suffix portion of the map; preserve stable prefix
        if wasIncremental, let prefixEnd = blocks.firstIndex(where: { $0.turnId == turns[count - 1].id }) {
            let suffixBlocks = Array(blocks.suffix(from: prefixEnd))
            let suffixMap = Self.buildGroupHeaderMap(from: suffixBlocks)
            cachedGroupHeaderMap.merge(suffixMap) { _, new in new }
        } else {
            cachedGroupHeaderMap = Self.buildGroupHeaderMap(from: cached)
        }

        return limited(streaming: streamingTurnId != nil)
    }

    // MARK: - Private Helpers

    /// Preserves all cached blocks **before** the turn at `turnIndex`, then
    /// regenerates blocks from that turn through the end of `turns`.
    /// Falls back to a full rebuild if the turn ID is not found in the cache
    /// (e.g. after history reload with new ChatTurn objects).
    private func regenerateFromTurn(
        at turnIndex: Int,
        in turns: [ChatTurn],
        streamingTurnId: UUID?,
        agentName: String,
        thinkingEnabled: Bool = false
    ) -> [ContentBlock] {
        let turnId = turns[turnIndex].id

        // Guard: if the turn ID is not in the cache, the cache is stale.
        // Fall back to full rebuild rather than mixing stale and fresh blocks.
        guard let prefixEnd = cached.firstIndex(where: { $0.turnId == turnId }) else {
            return ContentBlock.generateBlocks(
                from: turns,
                streamingTurnId: streamingTurnId,
                agentName: agentName,
                thinkingEnabled: thinkingEnabled
            )
        }

        let stablePrefix = Array(cached.prefix(prefixEnd))

        let turnsToGenerate = Array(turns.suffix(from: turnIndex))
        let previousTurn: ChatTurn? =
            turnIndex >= 1
            ? turns.prefix(turnIndex).last { $0.role != .tool }
            : nil

        let freshBlocks = ContentBlock.generateBlocks(
            from: turnsToGenerate,
            streamingTurnId: streamingTurnId,
            agentName: agentName,
            previousTurn: previousTurn,
            thinkingEnabled: thinkingEnabled
        )

        return stablePrefix + freshBlocks
    }

    private func limited(streaming: Bool) -> [ContentBlock] {
        // synthetic stress thread for profiling — must not truncate (see MockChatData)
        if ProcessInfo.processInfo.environment["USE_MOCK_CHAT_DATA"] == "1" {
            return ContentBlock.coalesceToolGroups(cached)
        }
        // during streaming, cap tightly to prevent layout thrash on every delta.
        // use a smooth transition: once streaming ends the cap rises gradually so
        // the table doesn't get a sudden burst of new rows all at once.
        let target = streaming ? streamingMaxBlocks : nonStreamingMaxBlocks
        let windowed = cached.count > target ? Array(cached.suffix(target)) : cached
        // Coalesce adjacent tool groups for display. `cached` keeps the original
        // per-turn group blocks (stable ids for incremental regen); the view sees
        // a single connected timeline, stitched even across the regeneration seam.
        return ContentBlock.coalesceToolGroups(windowed)
    }

    func clear() {
        cached = []
        cachedGroupHeaderMap = [:]
        lastCount = 0
        lastTurnId = nil
        lastContentLen = 0
        lastThinkingLen = 0
        lastPendingToolName = nil
        lastPendingToolArgSize = 0
        lastVersion = -1
        lastStreamingTurnId = nil
        lastAgentName = nil
    }

    // MARK: - Group Header Map

    private static func buildGroupHeaderMap(from blocks: [ContentBlock]) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        map.reserveCapacity(blocks.count)
        var currentGroupHeaderId: UUID?

        for block in blocks {
            if case .groupSpacer = block.kind {
                currentGroupHeaderId = nil
                continue
            }

            if case .header = block.kind {
                currentGroupHeaderId = block.turnId
            }

            if let groupId = currentGroupHeaderId {
                map[block.turnId] = groupId
            } else {
                map[block.turnId] = block.turnId
            }
        }
        return map
    }
}
