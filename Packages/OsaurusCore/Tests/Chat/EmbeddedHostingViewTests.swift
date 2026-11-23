//
//  EmbeddedHostingViewTests.swift
//  osaurusTests
//
//  A hosting view nested in a chat row must keep its size wherever the row
//  sits. Under the chat window's transparent full-size titlebar a default
//  NSHostingView adds the titlebar overlap to its own height, so a row that
//  moves under the strip resizes, moves out, resizes back, and the window
//  runs out of Update Constraints passes.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct EmbeddedHostingViewTests {
    private struct Probe {
        let window: NSWindow
        let container: NSView
    }

    private static func titlebarWindow() -> Probe {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 500),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let root = NSHostingView(rootView: Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.contentView = root
        let container = NSView(frame: root.bounds)
        container.autoresizingMask = [.width, .height]
        root.addSubview(container)
        window.orderFrontRegardless()
        return Probe(window: window, container: container)
    }

    /// Fitting heights of `host` with its frame below the titlebar and then under it.
    private static func heights(of host: NSHostingView<some View>, in probe: Probe) -> (clear: CGFloat, under: CGFloat) {
        probe.container.addSubview(host)
        func height(atY y: CGFloat) -> CGFloat {
            host.frame = NSRect(x: 20, y: y, width: 300, height: 40)
            probe.window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let clear = height(atY: 200)
        let under = height(atY: probe.container.bounds.height - 20)
        return (clear, under)
    }

    @Test func defaultNestedHostGrowsUnderTheTitlebar() {
        let probe = Self.titlebarWindow()
        defer { probe.window.close() }
        let sizes = Self.heights(of: NSHostingView(rootView: Text(verbatim: "Row").padding(8)), in: probe)
        #expect(sizes.under > sizes.clear, "precondition: the default host's size depends on where it sits")
    }

    @Test func embeddedHostKeepsItsSizeUnderTheTitlebar() {
        let probe = Self.titlebarWindow()
        defer { probe.window.close() }
        let host = NSHostingView.embedded(rootView: Text(verbatim: "Row").padding(8))
        let sizes = Self.heights(of: host, in: probe)
        #expect(host.safeAreaRegions.isEmpty)
        #expect(sizes.under == sizes.clear)
    }

    @Test func chatRowsCreateOnlyEmbeddedHosts() throws {
        let chatViews = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Views/Chat")
        for file in ["NativeMessageCellView.swift", "NativeToolCallGroupView.swift", "NativeBlockViews.swift"] {
            let source = try String(contentsOf: chatViews.appendingPathComponent(file), encoding: .utf8)
            #expect(!source.contains("NSHostingView(rootView:"), "\(file) creates a hosting view with the default safe area")
        }
    }
}
