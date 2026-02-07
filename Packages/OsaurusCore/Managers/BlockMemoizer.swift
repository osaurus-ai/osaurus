//
//  BlockMemoizer.swift
//  osaurus
//
//  Memoizes content block generation with incremental updates during streaming.
//  Only regenerates the last turn's blocks during streaming (O(1) vs O(n)).
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
