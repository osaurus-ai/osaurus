//
//  SidebarScrollOverflowTests.swift
//  osaurusTests
//
//  The sidebar fades an edge only while content runs past it: nothing
//  when the list fits, the bottom at the top of a long list, both in the
//  middle, the top at the end. Rubber-banding past an end is not overflow.
//

import CoreGraphics
import Testing

@testable import OsaurusCore

@Suite
struct SidebarScrollOverflowTests {

    private func overflow(offset: CGFloat, viewport: CGFloat = 400, content: CGFloat) -> SidebarScrollOverflow {
        SidebarScrollOverflow(
            visibleRect: CGRect(x: 0, y: offset, width: 240, height: viewport),
            contentHeight: content
        )
    }

    @Test("a list that fits fades neither edge")
    func fits() {
        #expect(overflow(offset: 0, content: 300) == SidebarScrollOverflow())
        #expect(overflow(offset: 0, content: 400) == SidebarScrollOverflow())
    }

    @Test("a long list at rest fades only the bottom")
    func atTop() {
        let edges = overflow(offset: 0, content: 900)
        #expect(!edges.above)
        #expect(edges.below)
    }

    @Test("mid-scroll fades both edges")
    func middle() {
        let edges = overflow(offset: 200, content: 900)
        #expect(edges.above)
        #expect(edges.below)
    }

    @Test("scrolled to the end fades only the top")
    func atBottom() {
        let edges = overflow(offset: 500, content: 900)
        #expect(edges.above)
        #expect(!edges.below)
    }

    @Test("rubber-banding past either end and sub-point rounding are not overflow")
    func bounceAndRounding() {
        #expect(!overflow(offset: -30, content: 900).above)
        #expect(!overflow(offset: 530, content: 900).below)
        #expect(!overflow(offset: 0.5, content: 900).above)
        #expect(!overflow(offset: 499.5, content: 900).below)
    }
}
