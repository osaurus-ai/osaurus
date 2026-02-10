//
//  BlockMemoizer.swift
//  osaurus
//
//  Memoizes content block generation with incremental updates during streaming.
//  Supports four cache paths to minimize SwiftUI LazyVStack re-layout:
//    1. Fast path   – nothing changed, return cached blocks
//    2. Incremental – only last turn's content changed (streaming)
//    3. Append      – exactly one turn was added at the end
//    4. Truncate    – turns were removed from the end (regeneration/deletion)
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
        personaName: String,
        version: Int = 0
    ) -> [ContentBlock] {
        let count = turns.count
        let lastId = turns.last?.id
        let contentLen = turns.last?.contentLength ?? 0
        let thinkingLen = turns.last?.thinkingLength ?? 0

        // Fast path: cache valid
        if count == lastCount && lastId == lastTurnId
            && contentLen == lastContentLen && thinkingLen == lastThinkingLen
            && version == lastVersion && !cached.isEmpty
        {
            return limited(streaming: streamingTurnId != nil)
        }

        // Incremental path: only last turn changed during streaming
        let canIncrement =
            streamingTurnId != nil && count == lastCount
            && lastId == lastTurnId && lastId != nil && !cached.isEmpty

        // Append path: one or more turns were added at the end.
        // Preserves existing cached blocks and only generates blocks for new turns,
        // preventing LazyVStack from re-laying out all existing items.
        // Handles single turn additions (user sends message) and multi-turn additions
        // (tool call loop appends tool turn + new assistant turn together).
        let canAppend =
            !canIncrement
            && count > lastCount
            && !cached.isEmpty
            && lastCount >= 1
            && turns[lastCount - 1].id == lastTurnId

        // Truncate path: turns were removed from the end (regeneration / deletion).
        // Keeps cached blocks for remaining turns and regenerates the last turn's blocks
        // to handle potential content edits (e.g. editAndRegenerate).
        let canTruncate =
            !canIncrement && !canAppend
            && count > 0 && count < lastCount
            && !cached.isEmpty

        let blocks: [ContentBlock]
        if canIncrement {
            let turnId = lastId!
            let prefixEnd = cached.firstIndex { $0.turnId == turnId } ?? cached.count
            let lastTurnBlocks = ContentBlock.generateBlocks(
                from: [turns.last!],
                streamingTurnId: streamingTurnId,
                personaName: personaName,
                previousTurn: turns.dropLast().last { $0.role != .tool }
            )
            blocks = Array(cached.prefix(prefixEnd)) + lastTurnBlocks
        } else if canAppend {
            let newTurns = Array(turns.suffix(count - lastCount))
            let previousNonToolTurn = turns.prefix(lastCount).last { $0.role != .tool }
            let newTurnBlocks = ContentBlock.generateBlocks(
                from: newTurns,
                streamingTurnId: streamingTurnId,
                personaName: personaName,
                previousTurn: previousNonToolTurn
            )
            blocks = cached + newTurnBlocks
        } else if canTruncate {
            blocks = truncateBlocks(
                turns: turns,
                streamingTurnId: streamingTurnId,
                personaName: personaName
            )
        } else {
            blocks = ContentBlock.generateBlocks(
                from: turns,
                streamingTurnId: streamingTurnId,
                personaName: personaName
            )
        }

        cached = blocks
        lastCount = count
        lastTurnId = lastId
        lastContentLen = contentLen
        lastThinkingLen = thinkingLen
        lastVersion = version

        cachedGroupHeaderMap = Self.buildGroupHeaderMap(from: cached)

        return limited(streaming: streamingTurnId != nil)
    }

    // MARK: - Truncate Path

    /// Removes blocks belonging to turns that no longer exist, and regenerates
    /// the last remaining turn's blocks to handle potential content edits.
    private func truncateBlocks(
        turns: [ChatTurn],
        streamingTurnId: UUID?,
        personaName: String
    ) -> [ContentBlock] {
        let currentTurnIds = Set(turns.map(\.id))

        // Blocks are generated in turn order, so find the first block belonging
        // to a removed turn — everything before that point is a stable prefix.
        let cutoff = cached.firstIndex { !currentTurnIds.contains($0.turnId) } ?? cached.count

        guard let lastTurn = turns.last else { return [] }

        // Within the stable prefix, find where the last remaining turn's blocks
        // start.  We regenerate them so that editAndRegenerate (which modifies
        // the last turn's content before truncating) produces fresh blocks.
        let lastTurnStart = cached.prefix(cutoff).firstIndex { $0.turnId == lastTurn.id } ?? cutoff
        let stablePrefix = Array(cached.prefix(lastTurnStart))

        let previousNonToolTurn: ChatTurn? =
            turns.count >= 2
            ? turns.dropLast().last { $0.role != .tool }
            : nil

        let freshBlocks = ContentBlock.generateBlocks(
            from: [lastTurn],
            streamingTurnId: streamingTurnId,
            personaName: personaName,
            previousTurn: previousNonToolTurn
        )

        return stablePrefix + freshBlocks
    }

    private func limited(streaming: Bool) -> [ContentBlock] {
        streaming && cached.count > maxBlocks ? Array(cached.suffix(maxBlocks)) : cached
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

    private static func buildGroupHeaderMap(from blocks: [ContentBlock]) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        map.reserveCapacity(blocks.count)
        var currentGroupHeaderId: UUID? = nil

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
