//
//  TerminalLineTrackerTests.swift
//
//  Pin Tier-1 TUI behaviour for the line tracker that powers in-place
//  redraws in `LiveOutputView`. The dominant case is `pip install` /
//  `curl --progress-bar` / `apt-get` style single-line bars that emit
//  `frame\rframe\rfinal\n` — they MUST collapse to one committed line,
//  never stack row-by-row.
//
//  Cases:
//    - simple `\r` overwrite            → only the final frame survives
//    - mixed `\r` + `\n`                → committed lines preserved
//    - chunk boundary mid-CR            → state survives across feeds
//    - ANSI + CR (post-strip behaviour) → `\r` semantics still applied
//    - trailing live line               → unterminated tail is exposed
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct TerminalLineTrackerTests {

    @Test func pipStyleProgressCollapsesToFinalFrame() {
        var tracker = TerminalLineTracker()
        tracker.feed("frame1\rframe2\rfinal\n")
        let committed = tracker.drainNewlyCommittedLines()
        #expect(committed == ["final"])
        #expect(tracker.liveLine.isEmpty)
    }

    @Test func mixedNewlineAndCarriageReturnPreservesHistory() {
        var tracker = TerminalLineTracker()
        tracker.feed("line1\nprogress\rdone\nline3\n")
        let committed = tracker.drainNewlyCommittedLines()
        #expect(committed == ["line1", "done", "line3"])
        #expect(tracker.liveLine.isEmpty)
    }

    @Test func chunkBoundaryMidCarriageReturnPreservesOverwrite() {
        var tracker = TerminalLineTracker()
        // First chunk lays down a partial line, second chunk arrives
        // with a `\r` followed by the replacement → only the
        // replacement should survive.
        tracker.feed("abc")
        tracker.feed("\rxyz\n")
        let committed = tracker.drainNewlyCommittedLines()
        #expect(committed == ["xyz"])
    }

    @Test func ansiStrippedThenCarriageReturnStillCollapses() {
        // Real-world flow: ANSIStripper drops the `\x1B[K` clear-to-EOL
        // sequence, then the tracker sees `foo\rbar\n`. The tracker
        // doesn't know about ANSI — that's the stripper's job — but
        // the resulting stream MUST still end up as a single "bar".
        let raw = "\u{1B}[Kfoo\rbar\n"
        let stripped = ANSIStripper.strip(raw)
        var tracker = TerminalLineTracker()
        tracker.feed(stripped)
        let committed = tracker.drainNewlyCommittedLines()
        #expect(committed == ["bar"])
    }

    @Test func trailingLiveLineSurfacedSeparately() {
        var tracker = TerminalLineTracker()
        tracker.feed("done\nin-progress")
        let committed = tracker.drainNewlyCommittedLines()
        #expect(committed == ["done"])
        #expect(tracker.liveLine == "in-progress")
    }

    @Test func emptyFeedIsNoop() {
        var tracker = TerminalLineTracker()
        tracker.feed("")
        tracker.feed(Data())
        #expect(tracker.drainNewlyCommittedLines().isEmpty)
        #expect(tracker.liveLine.isEmpty)
    }

    @Test func resetClearsState() {
        var tracker = TerminalLineTracker()
        tracker.feed("partial\nleftover")
        _ = tracker.drainNewlyCommittedLines()
        #expect(tracker.liveLine == "leftover")
        tracker.reset()
        #expect(tracker.liveLine.isEmpty)
    }

    @Test func renderHelperRoundTripsForSnapshots() {
        // The same logic powers Phase B's completed-mode render (apply
        // the tracker once over the full buffer). Verify the rendered
        // snapshot equals what the streaming case would surface.
        let raw = "header\n0%\r50%\r100%\nfooter\n"
        let rendered = TerminalLineTracker.render(raw)
        #expect(rendered == "header\n100%\nfooter\n")
    }

    @Test func renderPreservesTrailingLiveLine() {
        let raw = "spinner\rstill running"
        #expect(TerminalLineTracker.render(raw) == "still running")
    }

    @Test func renderAcceptsData() {
        let raw = "step1\nstep2\rstep2-final\n"
        let data = Data(raw.utf8)
        #expect(TerminalLineTracker.render(data) == "step1\nstep2-final\n")
    }

    @Test func longProgressBurstStaysSingleCommit() {
        // 200 progress frames followed by a final newline → one
        // committed line. Verifies the tracker doesn't accumulate
        // intermediate frames in `pendingCommits`.
        var tracker = TerminalLineTracker()
        for i in 0 ..< 200 {
            tracker.feed("\r\(i)%")
        }
        tracker.feed("\rdone\n")
        let committed = tracker.drainNewlyCommittedLines()
        #expect(committed == ["done"])
    }
}
