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
    private var lastCount = 0
    private var lastTurnId: UUID?
    private var lastContentLen = 0
    private var lastThinkingLen = 0
    private var lastVersion = -1
    private let maxBlocks = 80

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

        return limited(streaming: streamingTurnId != nil)
    }

    private func limited(streaming: Bool) -> [ContentBlock] {
        streaming && cached.count > maxBlocks ? Array(cached.suffix(maxBlocks)) : cached
    }

    func clear() {
        cached = []
        lastCount = 0
        lastTurnId = nil
        lastContentLen = 0
        lastThinkingLen = 0
        lastVersion = -1
    }
}
