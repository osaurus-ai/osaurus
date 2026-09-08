//
//  TourAnchorMarkerWindowTeardownTests.swift
//  osaurusTests
//
//  Window-close crash (2026-09-06, nine reports; NSZombie named the freed
//  object: "-[…ChatPanel release]: message sent to deallocated instance").
//  `TourAnchorMarker.MarkerView.viewWillMove(toWindow: nil)` runs while the
//  window is deallocating and used to hand the window itself to a deferred
//  main-queue block; the block's dispose helper then released a freed
//  window. The marker must never retain its window past that call: with a
//  window that is deallocated the moment its last reference drops, draining
//  the main queue afterwards must be uneventful and the window must be gone.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
struct TourAnchorMarkerWindowTeardownTests {
    @Test func markerTeardownDoesNotRetainTheDeallocatingWindow() throws {
        weak var released: NSWindow?
        autoreleasepool {
            var window: NSWindow? = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window?.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: Color.clear
                    .frame(width: 120, height: 40)
                    .background(TourAnchorMarker(anchor: .historyButton))
            )
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
            window?.contentView = host
            host.layoutSubtreeIfNeeded()
            released = window
            // Last reference: the window deallocates here, tearing its content
            // view down — the marker's `viewWillMove(toWindow: nil)` fires
            // with the window mid-dealloc.
            window = nil
        }
        // Drain the main queue: any block the marker deferred runs (and is
        // disposed) now. Before the fix this released the freed window.
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(released == nil, "the marker must not keep the window alive past its teardown")
    }
}
