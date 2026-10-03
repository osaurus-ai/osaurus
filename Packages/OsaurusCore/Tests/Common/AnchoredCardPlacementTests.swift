import Foundation
import Testing

@testable import OsaurusCore

@Suite("Anchored card placement")
struct AnchoredCardPlacementTests {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let cardSize = CGSize(width: 532, height: 440)

    @Test func opensAboveTheAnchorWithAnEightPointGap() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 200, y: 100, width: 160, height: 28),
            size: cardSize,
            visibleFrame: display
        )
        #expect(result == CGRect(x: 200, y: 136, width: 532, height: 440))
    }

    @Test func opensBelowWhenTheTopEdgeHasInsufficientSpace() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 200, y: 850, width: 160, height: 28),
            size: cardSize,
            visibleFrame: display
        )
        #expect(result == CGRect(x: 200, y: 402, width: 532, height: 440))
    }

    @Test func thirdColumnExpansionStaysInsideTheRightDisplayEdge() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 1300, y: 100, width: 100, height: 28),
            size: CGSize(width: 792, height: 440),
            visibleFrame: display
        )
        #expect(result.maxX == 1428)
        #expect(result.width == 792)
    }

    @Test func narrowDisplayConstrainsBothWidthAndHeight() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 180, y: 40, width: 80, height: 30),
            size: cardSize,
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 500)
        )
        #expect(result.width == 296)
        #expect(result.minX == 12)
        #expect(result.minY == 78)
        #expect(result.maxY == 488)
    }

    @Test func rightToLeftAlignsTheLeadingEdgeWithTheAnchor() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 900, y: 100, width: 160, height: 28),
            size: cardSize,
            visibleFrame: display,
            rightToLeft: true
        )
        #expect(result.maxX == 1060)
    }

    @Test func trailingAlignedCardMatchesTheCreditsButtonRightEdge() {
        let anchor = CGRect(x: 750, y: 100, width: 120, height: 28)
        let result = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: CGSize(width: 272, height: 300),
            visibleFrame: display,
            trailingAligned: true,
            containerFrame: CGRect(x: 200, y: 50, width: 700, height: 650)
        )
        #expect(result == CGRect(x: 598, y: 136, width: 272, height: 300))
        #expect(result.maxX == anchor.maxX)
    }

    @Test func trailingAlignmentMirrorsInRightToLeftLayouts() {
        let anchor = CGRect(x: 250, y: 100, width: 120, height: 28)
        let result = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: CGSize(width: 272, height: 300),
            visibleFrame: display,
            rightToLeft: true,
            trailingAligned: true
        )
        #expect(result.minX == anchor.minX)
    }

    @Test func creditsCardStaysInsideANarrowChatWindow() {
        let chat = CGRect(x: 300, y: 100, width: 260, height: 400)
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 430, y: 120, width: 118, height: 28),
            size: CGSize(width: 272, height: 600),
            visibleFrame: display,
            trailingAligned: true,
            containerFrame: chat
        )
        #expect(chat.insetBy(dx: 12, dy: 12).contains(result))
        #expect(result == CGRect(x: 312, y: 156, width: 236, height: 332))
    }

    @Test func partiallyOffscreenChatClampsToBothWindowAndDisplay() {
        let chat = CGRect(x: 1300, y: 50, width: 700, height: 650)
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 1370, y: 100, width: 100, height: 28),
            size: CGSize(width: 272, height: 300),
            visibleFrame: display,
            trailingAligned: true,
            containerFrame: chat
        )
        #expect(chat.contains(result))
        #expect(display.insetBy(dx: 12, dy: 12).contains(result))
        #expect(result.maxX == 1428)
        #expect(result.width == 116)
    }

    @Test func externalDisplayMayHaveANegativeCoordinateOrigin() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: -200, y: 100, width: 160, height: 28),
            size: cardSize,
            visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )
        #expect(result.maxX == -12)
        #expect(result.minY == 136)
    }

    @Test func constrainedHeightUsesTheLargerAvailableSide() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 200, y: 450, width: 100, height: 28),
            size: cardSize,
            visibleFrame: display
        )
        #expect(result.height == 430)
        #expect(result.minY == 12)
    }

    @Test func preferredAbovePreventsExpansionFromFlippingBelowTheAnchor() {
        let anchor = CGRect(x: 200, y: 400, width: 160, height: 40)
        let shortDisplay = CGRect(x: 0, y: 0, width: 1440, height: 700)
        let compact = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: CGSize(width: 532, height: 236),
            visibleFrame: shortDisplay
        )
        let automaticExpansion = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: cardSize,
            visibleFrame: shortDisplay
        )
        let anchoredExpansion = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: cardSize,
            visibleFrame: shortDisplay,
            preferAbove: true
        )

        #expect(compact == CGRect(x: 200, y: 448, width: 532, height: 236))
        #expect(automaticExpansion == CGRect(x: 200, y: 12, width: 532, height: 380))
        #expect(anchoredExpansion == CGRect(x: 200, y: 448, width: 532, height: 240))
        #expect(anchoredExpansion.minY == compact.minY)
        #expect(anchoredExpansion.maxY == shortDisplay.maxY - 12)
    }

    @Test func preferredBelowKeepsTheTopEdgeFixedWhenTheCardShrinks() {
        let anchor = CGRect(x: 200, y: 400, width: 160, height: 40)
        let shortDisplay = CGRect(x: 0, y: 0, width: 1440, height: 700)
        let expanded = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: cardSize,
            visibleFrame: shortDisplay,
            preferAbove: false
        )
        let compact = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: CGSize(width: 532, height: 236),
            visibleFrame: shortDisplay,
            preferAbove: false
        )

        #expect(expanded == CGRect(x: 200, y: 12, width: 532, height: 380))
        #expect(compact == CGRect(x: 200, y: 156, width: 532, height: 236))
        #expect(compact.maxY == expanded.maxY)
        #expect(compact.maxY == anchor.minY - 8)
    }

    @Test(arguments: [true, false])
    func preferredSideConstrainsTheCardToAvailableSpaceOnANarrowDisplay(preferAbove: Bool) {
        let narrowDisplay = CGRect(x: 0, y: 0, width: 320, height: 260)
        let anchor = CGRect(x: 280, y: 160, width: 28, height: 20)
        let result = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: CGSize(width: 792, height: 440),
            visibleFrame: narrowDisplay,
            preferAbove: preferAbove
        )

        #expect(narrowDisplay.insetBy(dx: 12, dy: 12).contains(result))
        #expect(result.width == 296)
        #expect(result.minX == 12)
        if preferAbove {
            #expect(result.minY == anchor.maxY + 8)
            #expect(result.height == 60)
        } else {
            #expect(result.maxY == anchor.minY - 8)
            #expect(result.height == 140)
        }
    }

    @Test(arguments: [true, false])
    func preferredSideWithNoAvailableSpaceStillStaysWithinDisplayBounds(preferAbove: Bool) {
        let narrowDisplay = CGRect(x: 0, y: 0, width: 320, height: 260)
        let anchor = CGRect(x: 280, y: preferAbove ? 232 : 8, width: 28, height: 20)
        let result = AnchoredCardPlacement.frame(
            anchor: anchor,
            size: cardSize,
            visibleFrame: narrowDisplay,
            preferAbove: preferAbove
        )

        #expect(narrowDisplay.insetBy(dx: 12, dy: 12).contains(result))
        #expect(result.width > 0)
        #expect(result.height > 0)
    }
}


struct HoverPreviewPresenceTests {
    @Test func panelEntryBeforeTriggerExitDoesNotDismiss() {
        var hover = HoverPreviewPresence(isOverTrigger: true)
        hover.isOverPanel = true
        hover.isOverTrigger = false
        #expect(!hover.shouldDismiss(isPinned: false))
    }

    @Test func triggerEntryBeforePanelExitDoesNotDismiss() {
        var hover = HoverPreviewPresence(isOverPanel: true)
        hover.isOverTrigger = true
        hover.isOverPanel = false
        #expect(!hover.shouldDismiss(isPinned: false))
    }

    @Test func delayedDismissalRechecksHoverAndPinState() {
        var hover = HoverPreviewPresence()
        #expect(hover.shouldDismiss(isPinned: false))
        hover.isOverPanel = true
        #expect(!hover.shouldDismiss(isPinned: false))
        hover.isOverPanel = false
        #expect(!hover.shouldDismiss(isPinned: true))
        #expect(hover.shouldDismiss(isPinned: false))
    }
}
