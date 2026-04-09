//
//  EditableTextView.swift
//  osaurus
//
//  A SwiftUI wrapper for NSTextView that supports custom cursor colors
//  and auto-sizing similar to TextEditor.
//

import SwiftUI
import AppKit

struct EditableTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let textColor: Color
    let cursorColor: Color
    @Binding var isFocused: Bool
    @Binding var isComposing: Bool
    var maxHeight: CGFloat = .infinity
    var onCommit: (() -> Void)? = nil
    var onShiftCommit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AutoSizingScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.focusRingType = .none
        scrollView.borderType = .noBorder

        let textView = CustomNSTextView()
        textView.focusRingType = .none
        textView.delegate = context.coordinator
        textView.maxHeight = maxHeight

        // Configuration
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear

        // Layout - align with placeholder padding (.leading: 6, .top: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // Disable automatic quotes/dashes/replacements to behave like code editor/raw input
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let coordinator = context.coordinator
        textView.onMarkedTextChanged = { [weak coordinator] composing in
            coordinator?.parent.isComposing = composing
        }

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CustomNSTextView else { return }

        // only update max height when it changes — avoids triggering NSTextView layout
        if textView.maxHeight != maxHeight {
            textView.maxHeight = maxHeight
            textView.invalidateIntrinsicContentSize()
            scrollView.invalidateIntrinsicContentSize()
        }

        // only update text if it differs — avoids cursor-position reset on every parent re-render
        if textView.string != text {
            textView.string = text
            textView.invalidateIntrinsicContentSize()
            scrollView.invalidateIntrinsicContentSize()
        }

        // guard styling assignments — each one invalidates the NSTextView layout and calls
        // needsDisplay even when the value hasn't changed
        let coord = context.coordinator
        if coord.lastFontSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
            coord.lastFontSize = fontSize
        }
        if coord.lastTextColor != textColor {
            textView.textColor = NSColor(textColor)
            coord.lastTextColor = textColor
        }
        if coord.lastCursorColor != cursorColor {
            textView.insertionPointColor = NSColor(cursorColor)
            coord.lastCursorColor = cursorColor
        }

        // handle focus
        DispatchQueue.main.async {
            let isFirstResponder = textView.window?.firstResponder == textView
            if isFocused && !isFirstResponder {
                textView.window?.makeFirstResponder(textView)
            } else if !isFocused && isFirstResponder {
                textView.window?.makeFirstResponder(nil)
            }
        }

        // only check scroller visibility and tile when max height changes or text changes —
        // contentHeight runs ensureLayout which is expensive; scroller state cannot change
        // without text or maxHeight changing
        if coord.lastScrollerMaxHeight != maxHeight || coord.lastScrollerText != text {
            let needsScroller = textView.contentHeight > maxHeight
            scrollView.verticalScroller?.isHidden = !needsScroller
            scrollView.tile()
            coord.lastScrollerMaxHeight = maxHeight
            coord.lastScrollerText = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextView

        // cached appearance values — guards against needsDisplay on every parent re-render
        var lastFontSize: CGFloat = 0
        var lastTextColor: Color = .clear
        var lastCursorColor: Color = .clear
        var lastScrollerMaxHeight: CGFloat = -1
        var lastScrollerText: String = ""

        init(_ parent: EditableTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // Invalidate intrinsic size to trigger resize
            if let customTextView = textView as? CustomNSTextView {
                customTextView.invalidateIntrinsicContentSize()
            }
            if let scrollView = textView.enclosingScrollView {
                scrollView.invalidateIntrinsicContentSize()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // selection changes (cursor moves) do not affect text content or view size —
            // no-op here; text sync and size invalidation are both handled in textDidChange.
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            parent.isComposing = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    if let shiftCommit = parent.onShiftCommit {
                        shiftCommit()
                        return true
                    }
                    return false  // No shift handler — insert newline
                } else {
                    parent.onCommit?()
                    return true
                }
            }
            return false
        }
    }
}

// Custom ScrollView that reports content size
final class AutoSizingScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        // Return document view's intrinsic size (already capped by maxHeight in CustomNSTextView)
        let docSize = documentView?.intrinsicContentSize ?? NSSize(width: NSView.noIntrinsicMetric, height: 20)
        return docSize
    }
}

// Custom NSTextView to handle cursor color and sizing
final class CustomNSTextView: NSTextView {
    var maxHeight: CGFloat = .infinity
    /// Called when IME marked-text state changes (composing / not composing)
    var onMarkedTextChanged: ((Bool) -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChanged?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChanged?(false)
    }

    /// Total height required to display the content without scrolling
    var contentHeight: CGFloat {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize.height
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        // Use single line height as minimum
        let lineHeight = font?.pointSize ?? 14
        let contentHeight = max(usedRect.height, lineHeight)

        // Add textContainerInset (top + bottom padding)
        return contentHeight + textContainerInset.height * 2
    }

    // Enable auto-growing height
    override var intrinsicContentSize: NSSize {
        // Cap at maxHeight for scrolling behavior
        let constrainedHeight = min(contentHeight, maxHeight)

        // We return noIntrinsicMetric for width so it fills available width
        return NSSize(width: NSView.noIntrinsicMetric, height: constrainedHeight)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}
