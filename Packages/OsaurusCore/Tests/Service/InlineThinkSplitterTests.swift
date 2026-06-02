//
//  InlineThinkSplitterTests.swift
//  osaurusTests
//
//  Verifies the streaming <think> splitter separates reasoning from visible
//  content, including tags split across delta boundaries.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("InlineThinkSplitter")
struct InlineThinkSplitterTests {

    /// Feed each delta through the splitter and flush at the end, returning the
    /// full ordered segment list.
    private func run(_ deltas: [String]) -> [InlineThinkSplitter.Segment] {
        var splitter = InlineThinkSplitter()
        var segments: [InlineThinkSplitter.Segment] = []
        for delta in deltas {
            segments.append(contentsOf: splitter.process(delta))
        }
        segments.append(contentsOf: splitter.flush())
        return segments
    }

    @Test func singleBlock_splitsReasoningAndContent() {
        let out = run(["<think>reasoning</think>answer"])
        #expect(out == [.reasoning("reasoning"), .content("answer")])
    }

    @Test func textBeforeThink_isContent() {
        let out = run(["hello <think>r</think>"])
        #expect(out == [.content("hello "), .reasoning("r")])
    }

    @Test func multipleBlocks_alternateChannels() {
        let out = run(["<think>a</think>x<think>b</think>y"])
        #expect(out == [.reasoning("a"), .content("x"), .reasoning("b"), .content("y")])
    }

    @Test func openTagSplitAcrossDeltas_doesNotLeak() {
        // The opening tag is split as "<thi" + "nk>"; no visible "<thi" leaks.
        let out = run(["<thi", "nk>r</thi", "nk>a"])
        #expect(out == [.reasoning("r"), .content("a")])
    }

    @Test func closeTagSplitAcrossDeltas_doesNotLeak() {
        let out = run(["<think>reason", "ing</thi", "nk>visible"])
        #expect(out == [.reasoning("reason"), .reasoning("ing"), .content("visible")])
    }

    @Test func unclosedThink_flushesAsReasoning() {
        let out = run(["<think>still thinking"])
        #expect(out == [.reasoning("still thinking")])
    }

    @Test func plainContent_noTags_passesThrough() {
        let out = run(["just an answer"])
        #expect(out == [.content("just an answer")])
    }

    @Test func danglingPartialTagThatIsNotATag_flushesAsContent() {
        // "a<" looks like it might start a tag, but the stream ends — the held
        // back "<" must be emitted as content, not dropped.
        let out = run(["answer<"])
        #expect(out == [.content("answer"), .content("<")])
    }

    @Test func customTokens_areRespected() {
        var splitter = InlineThinkSplitter(openToken: "[R]", closeToken: "[/R]")
        var segments = splitter.process("pre[R]mid[/R]post")
        segments.append(contentsOf: splitter.flush())
        #expect(segments == [.content("pre"), .reasoning("mid"), .content("post")])
    }
}
