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
    private var lastVersion = -1
    private let maxBlocks = 80

    /// Maps each block's turnId to its visual group's header turnId.
    /// Updated alongside blocks in `blocks(from:...)`.
    var groupHeaderMap: [UUID: UUID] { cachedGroupHeaderMap }

    func blocks(
        from turns: [ChatTurn],
        streamingTurnId: UUID?,
        agentName: String,
        version: Int = 0
    ) -> [ContentBlock] {
        let count = turns.count
        let lastId = turns.last?.id
        let contentLen = turns.last?.contentLength ?? 0
        let thinkingLen = turns.last?.thinkingLength ?? 0

        // Fast path: nothing changed
        if count == lastCount && lastId == lastTurnId
            && contentLen == lastContentLen && thinkingLen == lastThinkingLen
            && version == lastVersion && !cached.isEmpty
        {
            return limited(streaming: streamingTurnId != nil)
        }

        // Incremental: only last turn's content changed during streaming
        let canIncrement =
            streamingTurnId != nil
            && count == lastCount && lastId == lastTurnId
            && lastId != nil && !cached.isEmpty

        // Append: one or more turns added at the end; previous last turn still matches
        let canAppend =
            !canIncrement
            && count > lastCount && !cached.isEmpty
            && lastCount >= 1 && turns[lastCount - 1].id == lastTurnId

        let blocks: [ContentBlock]

        if canIncrement {
            // Last turn's content changed during streaming.
            blocks = regenerateFromTurn(
                at: count - 1,
                in: turns,
                streamingTurnId: streamingTurnId,
                agentName: agentName
            )
        } else if canAppend {
            // Regenerate from the previous last turn onwards — it may have been
            // modified (e.g. tool calls added) before the new turns were appended.
            blocks = regenerateFromTurn(
                at: lastCount - 1,
                in: turns,
                streamingTurnId: streamingTurnId,
                agentName: agentName
            )
        } else {
            // Full rebuild (first load, reset, or structural change)
            blocks = ContentBlock.generateBlocks(
                from: turns,
                streamingTurnId: streamingTurnId,
                agentName: agentName
            )
        }

        // Update cache state
        cached = blocks
        lastCount = count
        lastTurnId = lastId
        lastContentLen = contentLen
        lastThinkingLen = thinkingLen
        lastVersion = version
        cachedGroupHeaderMap = Self.buildGroupHeaderMap(from: cached)

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
        agentName: String
    ) -> [ContentBlock] {
        let turnId = turns[turnIndex].id

        // Guard: if the turn ID is not in the cache, the cache is stale.
        // Fall back to full rebuild rather than mixing stale and fresh blocks.
        guard let prefixEnd = cached.firstIndex(where: { $0.turnId == turnId }) else {
            return ContentBlock.generateBlocks(
                from: turns,
                streamingTurnId: streamingTurnId,
                agentName: agentName
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
            previousTurn: previousTurn
        )

        return stablePrefix + freshBlocks
    }

    private func limited(streaming: Bool) -> [ContentBlock] {
        // Tight cap during streaming to prevent layout thrash on every delta.
        // Generous cap otherwise so users can still scroll back through history
        // while bounding pathological layout cost in very long conversations.
        let limit = streaming ? maxBlocks : maxBlocks * 5
        return cached.count > limit ? Array(cached.suffix(limit)) : cached
    }

    func clear() {
        cached = []
        cachedGroupHeaderMap = [:]
        lastCount = 0
        lastTurnId = nil
        lastContentLen = 0
        lastThinkingLen = 0
        lastVersion = -1
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
