//
//  EditableTextViewFocusLockTests.swift
//  osaurusTests
//
//  Verifies the AppKit-level focus refusal contract used by
//  `FloatingInputCard` to hold input focus through send/queue
//  state-mutation cascades:
//
//  - `CustomNSTextView.resignFirstResponder()` returns `false` while
//    `focusLockUntil` is in the future, and reverts after the deadline.
//  - `TextViewFocusController.lockFocus(for:)` arms the deadline and
//    re-claims first responder if something else has already taken it.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct EditableTextViewFocusLockTests {

    /// Build a borderless host window with the given text view as its
    /// content view. `releasedWhenClosed = false` keeps the NSWindow
    /// alive until the test goes out of scope (avoids double-free
    /// races during cleanup when multiple suites run in parallel).
    /// Caller is expected to `defer { teardown(window) }`.
    private func makeHostedTextView() -> (NSWindow, CustomNSTextView) {
        let textView = CustomNSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(textView)
        // No `orderFront` — first-responder routing works without
        // making the window key/visible, and it keeps the test from
        // touching the shared window list (avoids cross-suite
        // interference under parallel execution).
        #expect(window.makeFirstResponder(textView))
        #expect(window.firstResponder === textView)
        return (window, textView)
    }

    /// Symmetric teardown matched with `makeHostedTextView`.
    private func teardown(_ window: NSWindow) {
        // Resign before closing so the AppKit responder chain unwinds
        // cleanly even if a previous test left the lock armed.
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }

    @Test
    func focusLock_refusesResignWhileWindowOpen() async throws {
        let (window, textView) = makeHostedTextView()
        defer { teardown(window) }

        textView.focusLockUntil = Date().addingTimeInterval(0.15)

        // While the lock is armed, the window cannot move first
        // responder away from the text view. `makeFirstResponder(nil)`
        // honors the refusal and returns false.
        let resigned = window.makeFirstResponder(nil)
        #expect(resigned == false)
        #expect(window.firstResponder === textView)
    }

    @Test
    func focusLock_allowsResignAfterDeadlinePasses() async throws {
        let (window, textView) = makeHostedTextView()
        defer { teardown(window) }

        // Short window so the test isn't slow. 80 ms is comfortably
        // longer than CI runloop jitter but short enough to stay snappy.
        textView.focusLockUntil = Date().addingTimeInterval(0.08)
        #expect(window.makeFirstResponder(nil) == false)
        #expect(window.firstResponder === textView)

        try await Task.sleep(nanoseconds: 150_000_000)

        // After the deadline, resignation goes through normally.
        #expect(window.makeFirstResponder(nil) == true)
        #expect(window.firstResponder !== textView)
    }

    @Test
    func focusLock_isInactiveByDefault() async throws {
        let (window, textView) = makeHostedTextView()
        defer { teardown(window) }

        // Default `focusLockUntil = .distantPast` — never locked.
        #expect(window.makeFirstResponder(nil) == true)
        #expect(window.firstResponder !== textView)
    }

    @Test
    func textViewFocusController_armsLockAndReclaimsFirstResponder() async throws {
        let (window, textView) = makeHostedTextView()
        defer { teardown(window) }

        // Simulate something stealing first responder a microsecond
        // before the lock was applied.
        #expect(window.makeFirstResponder(nil) == true)
        #expect(window.firstResponder !== textView)

        let controller = TextViewFocusController()
        controller.attach(textView)
        controller.lockFocus(for: 0.15)

        // The controller re-claims focus, then armed the lock.
        #expect(window.firstResponder === textView)
        #expect(window.makeFirstResponder(nil) == false)
        #expect(window.firstResponder === textView)
    }

    @Test
    func textViewFocusController_isNoOpWhenTextViewIsNil() {
        let controller = TextViewFocusController()
        // Should not crash or trap when the weak ref is empty.
        controller.lockFocus(for: 0.15)
    }
}
