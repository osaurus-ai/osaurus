//
//  StreamingMarkdownParser.swift
//  osaurus
//
//  Parses a growing markdown message without re-parsing its finished blocks

import Foundation

/// Gives the same blocks as `parseBlocks(StreamingMarkdownBalancer.balance(text))`
/// for each successive streamed `text`, but parses only the part after the last
/// resume point it has seen, as long as the balanced text still matches the
/// bytes through the end of that resume line.
struct StreamingMarkdownParser {
    private struct Checkpoint {
        /// Balanced text through the end of the resume line.
        let verifiedPrefix: String
        /// UTF-8 offset of the resume line, where parsing restarts.
        let resumeUTF8Offset: Int
        /// Blocks before the resume line.
        let blocks: [MessageBlock]
    }

    private var checkpoint: Checkpoint?
    private var fenceScan = StreamingMarkdownBalancer.FenceScan()
    /// Blocks the last `parse` took from the checkpoint instead of parsing.
    private(set) var reusedBlockCount = 0

    mutating func reset() {
        checkpoint = nil
        fenceScan = StreamingMarkdownBalancer.FenceScan()
        reusedBlockCount = 0
    }

    mutating func parse(_ text: String) -> [MessageBlock] {
        let balanced = StreamingMarkdownBalancer.balance(text, scan: &fenceScan)
        let utf8 = balanced.utf8

        var reused: Checkpoint?
        var prefixBlocks: [MessageBlock] = []
        var start = 0
        var tail = balanced
        if let checkpoint, utf8HasPrefix(balanced, checkpoint.verifiedPrefix),
            let rest = String(utf8[utf8.index(utf8.startIndex, offsetBy: checkpoint.resumeUTF8Offset)...])
        {
            reused = checkpoint
            prefixBlocks = checkpoint.blocks
            start = checkpoint.resumeUTF8Offset
            tail = rest
        }
        reusedBlockCount = prefixBlocks.count

        let parsed = parseBlocksWithResumePoint(tail)

        var blocks = prefixBlocks
        blocks.reserveCapacity(prefixBlocks.count + parsed.blocks.count)
        let indexOffset = prefixBlocks.count
        for block in parsed.blocks {
            blocks.append(MessageBlock(index: block.index + indexOffset, kind: block.kind))
        }

        if let resume = parsed.resume,
            let verified = String(utf8[..<utf8.index(utf8.startIndex, offsetBy: start + resume.lineEndUTF8Offset)])
        {
            checkpoint = Checkpoint(
                verifiedPrefix: verified,
                resumeUTF8Offset: start + resume.utf8Offset,
                blocks: Array(blocks.prefix(indexOffset + resume.blockCount))
            )
        } else {
            checkpoint = reused
        }
        return blocks
    }
}
