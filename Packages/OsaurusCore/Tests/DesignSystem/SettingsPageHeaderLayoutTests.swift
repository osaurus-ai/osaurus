//
//  SettingsPageHeaderLayoutTests.swift
//  osaurusTests
//
//  Renders a `SettingsPageHeader` with every slot filled and checks the
//  left-to-right order every page relies on:
//  [leading] Title [status] [refresh] [utilities] [secondary] [primary] [⋯].
//  Refresh and the overflow menu are drawn by the kit, so their positions
//  are proven by rendering with and without them.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct SettingsPageHeaderLayoutTests {
    private enum Slot: String, CaseIterable {
        case leading, status, utilities, secondary, primary
    }

    @MainActor
    private final class FrameLog {
        var frames: [Slot: CGRect] = [:]
    }

    private struct Tagged: View {
        let slot: Slot
        let log: FrameLog
        let width: CGFloat

        var body: some View {
            Color.gray
                .frame(width: width, height: 20)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { log.frames[slot] = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, frame in log.frames[slot] = frame }
                    }
                )
        }
    }

    private func layout(refresh: Bool, overflow: Bool) async throws -> [Slot: CGRect] {
        let log = FrameLog()
        let width: CGFloat = 1100
        let header = Group {
            if overflow {
                SettingsPageHeader(
                    title: "Title",
                    verbatimTitle: true,
                    onRefresh: refresh ? {} : nil,
                    leading: { Tagged(slot: .leading, log: log, width: 32) },
                    status: { Tagged(slot: .status, log: log, width: 60) },
                    utilities: { Tagged(slot: .utilities, log: log, width: 28) },
                    secondary: { Tagged(slot: .secondary, log: log, width: 80) },
                    primary: { Tagged(slot: .primary, log: log, width: 90) },
                    overflow: { Text(verbatim: "Export") }
                )
            } else {
                SettingsPageHeader(
                    title: "Title",
                    verbatimTitle: true,
                    onRefresh: refresh ? {} : nil,
                    leading: { Tagged(slot: .leading, log: log, width: 32) },
                    status: { Tagged(slot: .status, log: log, width: 60) },
                    utilities: { Tagged(slot: .utilities, log: log, width: 28) },
                    secondary: { Tagged(slot: .secondary, log: log, width: 80) },
                    primary: { Tagged(slot: .primary, log: log, width: 90) }
                )
            }
        }
        let root = header
            .padding(24)
            .frame(width: width, height: 200, alignment: .topLeading)
            .environment(\.theme, CustomizableTheme.light())
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        for attempt in 1...5 {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 200_000_000)
            host.layoutSubtreeIfNeeded()
            if log.frames.count == Slot.allCases.count { break }
        }
        return log.frames
    }

    @Test func slotsRunLeftToRightOnOneRow() async throws {
        let frames = try await layout(refresh: true, overflow: true)
        let ordered = try Slot.allCases.map { slot in try #require(frames[slot], "\(slot) never laid out") }

        for (left, right) in zip(ordered, ordered.dropFirst()) {
            #expect(left.maxX <= right.minX, "slot order broke: \(left) before \(right)")
        }
        let actions = ordered.dropFirst()
        let midY = try #require(actions.first).midY
        for frame in actions {
            #expect(abs(frame.midY - midY) < 1, "actions are not on one row: \(frame)")
        }
    }

    @Test func refreshSitsBetweenStatusAndUtilities() async throws {
        let with = try await layout(refresh: true, overflow: false)
        let without = try await layout(refresh: false, overflow: false)
        let gapWith = try #require(with[.utilities]).minX - #require(with[.status]).maxX
        let gapWithout = try #require(without[.utilities]).minX - #require(without[.status]).maxX
        #expect(gapWith > gapWithout + 16, "refresh is not between status and utilities: \(gapWith) vs \(gapWithout)")
        #expect(
            abs(try #require(with[.primary]).maxX - #require(without[.primary]).maxX) < 1,
            "refresh moved the trailing edge"
        )
    }

    @Test func overflowTrailsPrimary() async throws {
        let with = try await layout(refresh: false, overflow: true)
        let without = try await layout(refresh: false, overflow: false)
        let primaryWith = try #require(with[.primary])
        let primaryWithout = try #require(without[.primary])
        #expect(primaryWith.maxX < primaryWithout.maxX - 16, "overflow is not after primary")
        let statusShift = try #require(without[.status]).minX - #require(with[.status]).minX
        #expect(
            abs(statusShift - (primaryWithout.maxX - primaryWith.maxX)) < 1,
            "overflow changed spacing inside the actions row"
        )
    }

    private enum ProbeTab: String, AnimatedTabItem {
        case first, second, third
        var title: String { rawValue.capitalized }
    }

    /// A trailing filter counts toward the stacking decision, so it never
    /// spills past the row's trailing edge (Vault's agent scope picker).
    @Test func tabsRowTrailingStaysInsideTheRow() async throws {
        let width: CGFloat = 600
        let log = FrameLog()
        let row = SettingsTabsRow(
            selection: .constant(ProbeTab.first),
            searchText: .constant(""),
            searchPlaceholder: "Search"
        ) {
            Tagged(slot: .primary, log: log, width: 200)
        }
        .frame(width: width)
        .environment(\.theme, CustomizableTheme.light())
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for attempt in 1...5 {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 200_000_000)
            host.layoutSubtreeIfNeeded()
        }
        let trailing = try #require(log.frames[.primary], "trailing never laid out")
        #expect(trailing.maxX <= width + 0.5, "trailing control overflows the row: \(trailing)")
    }
}
