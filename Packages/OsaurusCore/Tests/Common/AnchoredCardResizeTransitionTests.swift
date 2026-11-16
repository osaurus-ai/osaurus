import Foundation
import Testing

@testable import OsaurusCore

@Suite("Anchored card resize transition")
struct AnchoredCardResizeTransitionTests {
    private let compact = CGRect(x: 200, y: 136, width: 532, height: 124)
    private let expanded = CGRect(x: -60, y: 136, width: 792, height: 440)

    @Test("width leads height while opening and closing", arguments: [true, false])
    func widthLeadsHeightWithOverlappingMotion(opening: Bool) {
        let from = opening ? compact : expanded
        let to = opening ? expanded : compact
        let transition = AnchoredCardResizeTransition(from: from, to: to, startTime: 10)

        let leadingFrame = transition.frame(at: 10.035)
        #expect(leadingFrame.width != from.width)
        #expect(leadingFrame.height == from.height)
        #expect(leadingFrame.origin.y == from.origin.y)

        let overlappingFrame = transition.frame(at: 10.135)
        let widthProgress = (overlappingFrame.width - from.width) / (to.width - from.width)
        let heightProgress = (overlappingFrame.height - from.height) / (to.height - from.height)
        #expect(widthProgress > heightProgress)
        #expect(widthProgress < 1)
        #expect(heightProgress > 0)

        let widthFinishedFrame = transition.frame(at: 10.27)
        #expect(widthFinishedFrame.width == to.width)
        #expect(widthFinishedFrame.height != to.height)
        #expect(!transition.isComplete(at: 10.27))
        #expect(abs(transition.duration - 0.33) < 0.000_001)
    }

    @Test("width-only motion starts immediately and uses cubic ease-out")
    func widthOnlyUsesCubicEaseOut() {
        let to = CGRect(x: -60, y: compact.minY, width: 792, height: compact.height)
        let transition = AnchoredCardResizeTransition(from: compact, to: to, startTime: 0)
        let midway = transition.frame(at: 0.13)

        // Half the time through cubic ease-out covers seven eighths of the distance.
        #expect(midway.width == compact.width + (to.width - compact.width) * 0.875)
        #expect(midway.origin.x == compact.origin.x + (to.origin.x - compact.origin.x) * 0.875)
        #expect(midway.height == compact.height)
        #expect(midway.origin.y == compact.origin.y)
        #expect(transition.frame(at: 0.035).width != compact.width)
        #expect(transition.duration == 0.26)
        #expect(transition.frame(at: 0.26) == to)
        #expect(transition.isComplete(at: 0.26))
    }

    @Test("height-only motion starts immediately and keeps the top edge fixed")
    func heightOnlyHasNoDelay() {
        let from = CGRect(x: 200, y: 500, width: 532, height: 124)
        let to = CGRect(x: 200, y: 184, width: 532, height: 440)
        let transition = AnchoredCardResizeTransition(from: from, to: to, startTime: 0)
        let early = transition.frame(at: 0.035)
        let midway = transition.frame(at: 0.13)

        #expect(early.height > from.height)
        #expect(midway.height == from.height + (to.height - from.height) * 0.875)
        #expect(midway.maxY == from.maxY)
        #expect(midway.width == from.width)
        #expect(midway.origin.x == from.origin.x)
        #expect(transition.duration == 0.26)
        #expect(transition.frame(at: 0.26) == to)
        #expect(transition.isComplete(at: 0.26))
    }

    @Test("the card retains its anchored vertical and horizontal edges", arguments: [true, false])
    func anchoredEdgesStayFixed(aboveAnchor: Bool) {
        let from = compact
        let to = CGRect(
            x: expanded.minX,
            y: aboveAnchor ? from.minY : from.maxY - expanded.height,
            width: expanded.width,
            height: expanded.height
        )

        for (initial, target) in [(from, to), (to, from)] {
            let transition = AnchoredCardResizeTransition(from: initial, to: target, startTime: 0)
            for step in 0 ... 33 {
                let frame = transition.frame(at: Double(step) / 100)
                let anchoredY = aboveAnchor ? frame.minY : frame.maxY
                let expectedY = aboveAnchor ? from.minY : from.maxY
                #expect(abs(anchoredY - expectedY) < 0.000_001)
                #expect(abs(frame.maxX - from.maxX) < 0.000_001)
            }
        }
    }

    @Test("frames clamp to exact endpoints and never overshoot", arguments: [true, false])
    func endpointsAndBounds(opening: Bool) {
        let short = CGRect(x: 200, y: 500, width: 532, height: 124)
        let tall = CGRect(x: -60, y: 184, width: 792, height: 440)
        let from = opening ? short : tall
        let to = opening ? tall : short
        let transition = AnchoredCardResizeTransition(from: from, to: to, startTime: 50)
        let completionTime = transition.startTime + transition.duration

        #expect(transition.frame(at: 49) == from)
        #expect(transition.frame(at: 50) == from)
        #expect(!transition.isComplete(at: 50))
        #expect(!transition.isComplete(at: completionTime - 0.001))
        #expect(transition.frame(at: completionTime) == to)
        #expect(transition.isComplete(at: completionTime))
        #expect(transition.frame(at: completionTime + 1) == to)

        for step in -20 ... 50 {
            let frame = transition.frame(at: 50 + Double(step) / 100)
            #expect((-60 ... CGFloat(200)).contains(frame.origin.x))
            #expect((184 ... CGFloat(500)).contains(frame.origin.y))
            #expect((532 ... CGFloat(792)).contains(frame.width))
            #expect((124 ... CGFloat(440)).contains(frame.height))
        }
    }

    @Test("identical frames stay finite and unchanged")
    func identicalFramesStayUnchanged() {
        let transition = AnchoredCardResizeTransition(from: compact, to: compact, startTime: 10)

        for time in [9.0, 10.0, 10.035, 10.13, 10.26, 11.0] {
            #expect(transition.frame(at: time) == compact)
        }
    }

    @Test("an interrupted transition resumes from the displayed frame without jumping")
    func interruptionStartsAtCurrentFrame() {
        let opening = AnchoredCardResizeTransition(from: compact, to: expanded, startTime: 10)
        let interruptionTime = 10.14
        let displayed = opening.frame(at: interruptionTime)
        let closing = AnchoredCardResizeTransition(from: displayed, to: compact, startTime: interruptionTime)

        #expect(displayed != compact)
        #expect(displayed != expanded)
        #expect(closing.frame(at: interruptionTime) == displayed)

        let shortlyAfter = closing.frame(at: interruptionTime + 0.035)
        #expect(shortlyAfter.width < displayed.width)
        #expect(shortlyAfter.width > compact.width)
        #expect(shortlyAfter.height == displayed.height)
        #expect(closing.frame(at: interruptionTime + closing.duration) == compact)
    }
}
