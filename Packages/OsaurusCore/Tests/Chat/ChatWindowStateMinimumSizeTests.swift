//
//  ChatWindowStateMinimumSizeTests.swift
//  osaurusTests
//
//  The chat root view's `.frame(minWidth:minHeight:)` floor is mirrored
//  into the window's `contentMinSize`, so it must never exceed what the
//  window's screen can show: a 1024x665 display otherwise gets a window
//  AppKit cannot shrink to fit, hanging off the bottom of the screen with
//  the composer cut off. Regression coverage for #2728.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatWindowStateMinimumSizeTests {

    @Test("starts at the design minimum")
    func initialFloor_isDesignMinimum() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.minimumContentSize == ChatWindowState.designMinimumContentSize)
            #expect(ChatWindowState.designMinimumContentSize == CGSize(width: 800, height: 620))
        }
    }

    @Test("a screen larger than the design minimum keeps it verbatim")
    func largeScreen_keepsDesignMinimum() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.updateMinimumContentSize(availableContentSize: CGSize(width: 1512, height: 900))
            #expect(window.minimumContentSize == ChatWindowState.designMinimumContentSize)
        }
    }

    @Test("a small screen clamps the floor to what it can show")
    func smallScreen_clampsFloor() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            // 14" MacBook Pro at "Larger Text": 1024x665 screen, 24pt menu
            // bar, 52pt unified toolbar chrome -> 589pt of content height.
            window.updateMinimumContentSize(availableContentSize: CGSize(width: 1024, height: 589.5))
            #expect(window.minimumContentSize == CGSize(width: 800, height: 589))
        }
    }

    @Test("both axes clamp independently")
    func narrowAndShortScreen_clampsBothAxes() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.updateMinimumContentSize(availableContentSize: CGSize(width: 700, height: 500))
            #expect(window.minimumContentSize == CGSize(width: 700, height: 500))
        }
    }

    @Test("moving back to a large screen restores the design minimum")
    func largerScreen_restoresDesignMinimum() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.updateMinimumContentSize(availableContentSize: CGSize(width: 1024, height: 589))
            window.updateMinimumContentSize(availableContentSize: CGSize(width: 1920, height: 1055))
            #expect(window.minimumContentSize == ChatWindowState.designMinimumContentSize)
        }
    }

    @Test("a missing or degenerate measurement leaves the floor alone")
    func zeroMeasurement_isIgnored() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.updateMinimumContentSize(availableContentSize: CGSize(width: 1024, height: 589))
            window.updateMinimumContentSize(availableContentSize: .zero)
            // No screen known: each axis keeps the design value rather than
            // collapsing to zero.
            #expect(window.minimumContentSize == ChatWindowState.designMinimumContentSize)
            window.updateMinimumContentSize(availableContentSize: CGSize(width: -10, height: 400))
            #expect(window.minimumContentSize == CGSize(width: 800, height: 400))
        }
    }
}
