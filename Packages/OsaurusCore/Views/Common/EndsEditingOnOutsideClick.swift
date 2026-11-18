//
//  EndsEditingOnOutsideClick.swift
//  osaurus
//
//  On macOS a click on empty space, or on a view that can't take focus,
//  leaves a text field editing. For fields that save when they lose
//  focus, a click anywhere outside the field's frame (or in another
//  window) ends the editing.
//

import AppKit
import SwiftUI

extension View {
    /// While `isFocused`, a click outside this view's frame calls `end`.
    func endsEditingOnOutsideClick(_ isFocused: Bool, end: @escaping () -> Void) -> some View {
        background(OutsideClickMonitor(isActive: isFocused, onOutsideClick: end))
    }
}

private struct OutsideClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onOutsideClick = onOutsideClick
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.setActive(false)
    }

    final class MonitorView: NSView {
        var onOutsideClick: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setActive(false) }
        }

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                    [weak self] event in
                    self?.handle(event)
                    return event
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window else { return }
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
                onOutsideClick()
            }
        }
    }
}
