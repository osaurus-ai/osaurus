//
//  PopoverHoverTracking.swift
//  osaurus
//
//  NSView-based hover tracking that works correctly inside popovers.
//  SwiftUI's `.onHover` can have misaligned tracking areas in popover
//  windows on macOS, so we use NSTrackingArea directly.
//

import AppKit
import SwiftUI

// MARK: - Hover Tracking View

extension View {
    /// Reliable hover tracking that works inside popovers.
    ///
    /// Uses `NSTrackingArea` directly instead of SwiftUI's `.onHover`,
    /// which can have misaligned tracking areas in popover windows on macOS.
    func onPopoverHover(perform action: @escaping (Bool) -> Void) -> some View {
        overlay(PopoverHoverOverlay(onHover: action))
    }
}

// MARK: - Implementation

private struct PopoverHoverOverlay: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverNSView {
        let view = HoverNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HoverNSView, context: Context) {
        nsView.onHover = onHover
    }

    final class HoverNSView: NSView {
        static weak var currentlyHovered: HoverNSView?

        var onHover: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) {
            if let previous = Self.currentlyHovered, previous !== self {
                previous.onHover?(false)
            }
            Self.currentlyHovered = self
            NSCursor.pointingHand.push()
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            if Self.currentlyHovered === self { Self.currentlyHovered = nil }
            NSCursor.pop()
            onHover?(false)
        }
    }
}
