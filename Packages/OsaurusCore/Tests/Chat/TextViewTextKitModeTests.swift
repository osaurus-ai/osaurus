//
//  TextViewTextKitModeTests.swift
//  osaurusTests
//
//  Regression coverage for Sentry APPLE-MACOS-YG (NSInvalidArgumentException in
//  -[NSLayoutManager glyphRangeForTextContainer:]): text views that later read
//  `.layoutManager` must be built as TextKit 1 from birth. A default-init view
//  starts as TextKit 2 and lazily downgrades on first `.layoutManager` access,
//  which can leave AppKit key-binding code holding a stale layout-manager /
//  text-container pairing.
//

import AppKit
import Testing

@testable import OsaurusCore

@MainActor
struct TextViewTextKitModeTests {

    /// The view must have no TextKit 2 stack and a correctly paired
    /// TextKit 1 stack: the text container appears in its layout
    /// manager's container list (the exact invariant whose violation
    /// throws in `glyphRangeForTextContainer:`).
    private func expectTextKit1Paired(_ textView: NSTextView) {
        #expect(textView.textLayoutManager == nil, "expected no TextKit 2 layout manager")

        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        #expect(layoutManager != nil)
        #expect(textContainer != nil)
        if let layoutManager, let textContainer {
            #expect(layoutManager.textContainers.contains(textContainer))
            #expect(textContainer.layoutManager === layoutManager)
        }
    }

    @Test
    func customNSTextView_isTextKit1FromBirth() {
        let textView = CustomNSTextView(usingTextLayoutManager: false)
        expectTextKit1Paired(textView)

        // `contentHeight` reads `.layoutManager` — the access that used to
        // trigger the lazy downgrade. It must not disturb the pairing.
        _ = textView.contentHeight
        expectTextKit1Paired(textView)
    }

    @Test
    func selectableNSTextView_isTextKit1FromBirth() {
        let textView = SelectableNSTextView(usingTextLayoutManager: false)
        expectTextKit1Paired(textView)
    }

    /// Exercises the exact code path that crashed in production:
    /// `moveDown:` runs `_rangeForMoveDownFromRange:` which calls
    /// `glyphRangeForTextContainer:` on the view's text container. With a
    /// mispaired stack this throws NSInvalidArgumentException.
    @Test
    func customNSTextView_arrowNavigationAfterLayoutManagerAccess() {
        let textView = CustomNSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
        textView.isEditable = true
        textView.string = "line one\nline two\nline three"

        // Read `.layoutManager` first, as the composer does for sizing.
        _ = textView.contentHeight

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.moveDown(nil)
        textView.moveDown(nil)
        textView.moveUp(nil)

        expectTextKit1Paired(textView)
    }
}
