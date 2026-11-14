//
//  ChatShellLayoutTests.swift
//  osaurusTests
//
//  The chat shell's column model across a width matrix: the breakpoint,
//  whether each side pane docks or floats, that docked columns add up to
//  the window, that the content column never drops below its floor, and
//  that the thread, composer card and prompt cards share one width.
//

import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

struct ChatShellLayoutTests {
    private static let widths: [CGFloat] = [560, 640, 760, 1024, 1199, 1200, 1600, 2400]
    private static let rail = ChatShellLayout.railWidth

    private func layout(
        _ width: CGFloat, sidebar: Bool = true, sidebarWidth: CGFloat = 260, context: Bool = false,
        contextWidth: CGFloat = ChatShellLayout.defaultContextWidth
    ) -> ChatShellLayout {
        ChatShellLayout(
            windowWidth: width, sidebarRequested: sidebar, preferredSidebarWidth: sidebarWidth,
            contextRequested: context, preferredContextWidth: contextWidth)
    }

    @Test("breakpoints are measured on the room beside the rail")
    func breakpoints() {
        #expect(layout(560).breakpoint == .compact)
        #expect(layout(640).breakpoint == .compact)
        #expect(layout(760).breakpoint == .compact, "760 window leaves 716 beside the rail")
        #expect(layout(760 + Self.rail).breakpoint == .regular)
        #expect(layout(1024).breakpoint == .regular)
        #expect(layout(1199 + Self.rail).breakpoint == .regular)
        #expect(layout(1200 + Self.rail).breakpoint == .wide)
        #expect(layout(1600).breakpoint == .wide)
        #expect(layout(2400).breakpoint == .wide)
    }

    @Test("compact: side panes float over the content, which keeps the full width")
    func compactPanesOverlay() {
        for width: CGFloat in [560, 640, 760] {
            let both = layout(width, context: true)
            #expect(both.sidebarMode == .overlay)
            #expect(both.contextMode == .overlay)
            #expect(both.contentWidth == width - Self.rail)
            #expect(both.sidebarWidth <= width - Self.rail - ChatShellLayout.overlayEdgeClearance)
            #expect(both.contextWidth <= width - Self.rail - ChatShellLayout.overlayEdgeClearance)
            #expect(both.sidebarStepsAside == false)

            let closed = layout(width, sidebar: false)
            #expect(closed.sidebarMode == .hidden)
            #expect(closed.sidebarWidth == 0)
            #expect(closed.contextMode == .hidden)
        }
    }

    @Test("docked columns always add up to the window")
    func dockedWidthsSum() {
        for width in Self.widths {
            for sidebar in [false, true] {
                for context in [false, true] {
                    let l = layout(width, sidebar: sidebar, sidebarWidth: 460, context: context, contextWidth: 520)
                    let docked =
                        (l.sidebarMode == .docked ? l.sidebarWidth : 0)
                        + (l.contextMode == .docked ? l.contextWidth : 0)
                    #expect(Self.rail + docked + l.contentWidth == width, "width \(width) sidebar \(sidebar) context \(context)")
                }
            }
        }
    }

    @Test("the content column never docks below its floor")
    func contentFloor() {
        for width in Self.widths where width - Self.rail >= ChatShellLayout.compactUpperBound {
            let sidebarOnly = layout(width, sidebarWidth: 460)
            #expect(sidebarOnly.contentWidth >= ChatShellLayout.minimumContentWidth)
            let withContext = layout(width, sidebarWidth: 460, context: true, contextWidth: 520)
            #expect(withContext.contentWidth >= ChatShellLayout.minimumContentWidthWithPanel)
        }
    }

    @Test("regular: the sidebar steps aside for the context panel only when all three cannot fit")
    func regularStepAside() {
        let tight = layout(760 + Self.rail, sidebarWidth: 260, context: true)
        #expect(tight.sidebarStepsAside)
        #expect(tight.sidebarMode == .hidden)
        #expect(tight.contextMode == .docked)

        let roomy = layout(1100, sidebarWidth: 240, context: true)
        #expect(roomy.sidebarStepsAside == false)
        #expect(roomy.sidebarMode == .docked)
        #expect(roomy.contextMode == .docked)

        let noContext = layout(800 + Self.rail, sidebarWidth: 460)
        #expect(noContext.sidebarMode == .docked)
        #expect(noContext.sidebarWidth == 800 - ChatShellLayout.minimumContentWidth, "clamped to keep the content floor")
    }

    @Test("wide: both panes dock at any stored width")
    func wideDocksEverything() {
        for width: CGFloat in [1200 + Self.rail, 1600, 2400] {
            let l = layout(width, sidebarWidth: 460, context: true, contextWidth: 520)
            #expect(l.sidebarMode == .docked)
            #expect(l.contextMode == .docked)
            #expect(l.sidebarStepsAside == false)
        }
    }

    @Test("thread, composer card and prompt cards share one readable width")
    func sharedReadableColumn() {
        for width in Self.widths {
            for sidebar in [false, true] {
                let l = layout(width, sidebar: sidebar)
                #expect(l.readableWidth <= ChatShellLayout.readableColumnWidth)
                #expect(l.readableWidth <= l.contentWidth)
                let composerCard = l.composerFrameWidth - 2 * ChatShellLayout.composerOuterInset
                #expect(composerCard == l.threadContentWidth)
                #expect(l.threadContentWidth == l.readableWidth - 2 * ChatShellLayout.columnInset)
            }
        }
        #expect(layout(2400).readableWidth == ChatShellLayout.readableColumnWidth)
    }

    @Test("stored widths outside the allowed ranges are clamped")
    func clamping() {
        #expect(ChatShellLayout.clampSidebarWidth(100) == 240)
        #expect(ChatShellLayout.clampSidebarWidth(900) == 460)
        #expect(ChatShellLayout.clampContextWidth(100) == 300)
        #expect(ChatShellLayout.clampContextWidth(900) == 520)
        #expect(layout(2400, sidebarWidth: 900).sidebarWidth == 460)
    }

    @Test("the composer collapses its chips only at the compact breakpoint")
    func compactComposer() {
        #expect(layout(640).usesCompactComposer)
        #expect(layout(1024).usesCompactComposer == false)
        #expect(layout(1600).usesCompactComposer == false)
    }

    @Test("workflow creation splits proportionally, and stacks when narrow")
    func workflowCreationSplit() {
        func chat(_ width: CGFloat, preferred: CGFloat? = nil) -> CGFloat? {
            ChatShellLayout.workflowCreationChatWidth(contentWidth: width, spacing: 24, preferred: preferred)
        }
        #expect(chat(700) == nil)
        #expect(chat(760) == 340)
        #expect(chat(1000) == 400)
        // The draft's column stops at 880; the chat takes what it can't use,
        // up to the thread's readable width.
        #expect(chat(1600) == 696)
        #expect(chat(2400) == 800)
    }

    @Test("a dragged workflow-creation chat keeps its width, inside what leaves the draft usable")
    func workflowCreationDraggedChat() {
        func chat(_ width: CGFloat, preferred: CGFloat) -> CGFloat? {
            ChatShellLayout.workflowCreationChatWidth(contentWidth: width, spacing: 24, preferred: preferred)
        }
        #expect(chat(1400, preferred: 500) == 500)
        #expect(chat(1400, preferred: 100) == 340)
        #expect(chat(1400, preferred: 1300) == 996, "the draft keeps its 380 floor")
        #expect(chat(700, preferred: 500) == nil, "still stacks when narrow")
        #expect(ChatShellLayout.workflowCreationChatRange(contentWidth: 1400, spacing: 24) == 340...996)
    }

    @Test("the New Agent chat leads, with the agent card a narrower column beside it")
    func agentCreationWidths() {
        #expect(ChatShellLayout.agentCreationChatWidth(contentWidth: 700, spacing: 24) == nil)
        #expect(ChatShellLayout.agentCreationChatWidth(contentWidth: 1000, spacing: 24) == 636)
        // Settings at its default size: stacked with its sidebar open, side
        // by side with it collapsed.
        #expect(ChatShellLayout.agentCreationChatWidth(contentWidth: 667, spacing: 24, embedded: true) == nil)
        #expect(ChatShellLayout.agentCreationChatWidth(contentWidth: 843, spacing: 24, embedded: true) == 519)
        #expect(ChatShellLayout.agentCreationChatWidth(contentWidth: 1200, spacing: 24, embedded: true) == 816)
    }

    @Test("a dragged New Agent chat keeps its width while the card stays between its floor and 640")
    func agentCreationDraggedChat() {
        func chat(_ width: CGFloat, preferred: CGFloat, embedded: Bool = false) -> CGFloat? {
            ChatShellLayout.agentCreationChatWidth(
                contentWidth: width, spacing: 24, embedded: embedded, preferred: preferred)
        }
        #expect(chat(1400, preferred: 900) == 900)
        #expect(chat(1400, preferred: 1300) == 1056, "the card keeps its 320 floor")
        #expect(chat(1400, preferred: 400) == 736, "the card stops at 640")
        #expect(chat(1000, preferred: 100) == 340, "the chat keeps its floor")
        #expect(chat(843, preferred: 800, embedded: true) == 519, "Settings' card keeps its 300 floor")
        #expect(chat(700, preferred: 500) == nil, "still stacks when narrow")
        #expect(ChatShellLayout.agentCreationChatRange(contentWidth: 1400, spacing: 24) == 736...1056)
    }

    @Test("the File Changes card keeps its width when it fits and never reaches the composer")
    func floatingContextCard() {
        let roomy = ChatShellLayout.floatingContextSize(contentWidth: 1200, height: 1000, headerHeight: 44)
        #expect(roomy.width == 360)
        #expect(roomy.height == 560, "capped at its maximum")

        let narrow = ChatShellLayout.floatingContextSize(contentWidth: 300, height: 1000, headerHeight: 44)
        #expect(narrow.width == 276, "the column less its insets")

        // 600 - 44 header - 12 inset - 140 composer clearance.
        let short = ChatShellLayout.floatingContextSize(contentWidth: 1200, height: 600, headerHeight: 44)
        #expect(short.height == 404)
        #expect(ChatShellLayout.floatingContextSize(contentWidth: 0, height: 100, headerHeight: 44) == .zero)
    }

    @Test("only a wide window sets a column aside for the File Changes card")
    func contextColumnOnlyWhenWide() {
        #expect(ChatShellLayout.contextReservesColumn(.wide))
        #expect(ChatShellLayout.contextReservesColumn(.regular) == false)
        #expect(ChatShellLayout.contextReservesColumn(.compact) == false)
        #expect(ChatShellLayout.reservedContextWidth == 384, "the card plus its two insets")

        // A wide window with the sidebar docked keeps a readable column
        // beside the reserved one.
        let wide = ChatShellLayout(
            windowWidth: 1500, sidebarRequested: true, preferredSidebarWidth: 260,
            contextRequested: true, preferredContextWidth: ChatShellLayout.reservedContextWidth)
        #expect(wide.contextMode == .docked)
        #expect(wide.contextWidth == 384)
        #expect(wide.sidebarStepsAside == false)
        #expect(wide.contentWidth == CGFloat(1500 - 44 - 260 - 384))
    }
}

struct CompactRelativeAgeTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let locale = Locale(identifier: "en_US")

    private func age(_ seconds: TimeInterval) -> String {
        compactRelativeAge(now.addingTimeInterval(-seconds), now: now, locale: locale)
    }

    @Test("sidebar ages use one abbreviated unit")
    func singleUnit() {
        #expect(age(5) == L("Now"))
        #expect(age(-30) == L("Now"), "a clock-skewed future date reads as now")
        #expect(age(5 * 60) == "5m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(3 * 86400) == "3d")
        #expect(age(12 * 86400) == "12d")
        #expect(age(80 * 86400) == "2mo")
    }
}
