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
    var maxHeight: CGFloat = .infinity
    var onCommit: (() -> Void)? = nil

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

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CustomNSTextView else { return }

        textView.maxHeight = maxHeight

        // Only update text if it's different to avoid cursor jumping
        if textView.string != text {
            textView.string = text
        }

        // Update styling
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = NSColor(textColor)
        textView.insertionPointColor = NSColor(cursorColor)

        // Handle focus
        DispatchQueue.main.async {
            let isFirstResponder = textView.window?.firstResponder == textView
            if isFocused && !isFirstResponder {
                textView.window?.makeFirstResponder(textView)
            } else if !isFocused && isFirstResponder {
                textView.window?.makeFirstResponder(nil)
            }
        }

        // Force layout update for height calculation
        textView.invalidateIntrinsicContentSize()
        scrollView.invalidateIntrinsicContentSize()
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextView

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

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    return false  // Let text view handle Shift+Enter (newline)
                } else {
                    parent.onCommit?()
                    return true  // Handled (don't insert newline)
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

    // Enable auto-growing height
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        // Use single line height as minimum (compact when empty)
        let lineHeight = font?.pointSize ?? 14
        let contentHeight = max(usedRect.height, lineHeight)

        // Add textContainerInset (top + bottom padding)
        let totalHeight = contentHeight + textContainerInset.height * 2

        // Cap at maxHeight for scrolling behavior
        let constrainedHeight = min(totalHeight, maxHeight)

        // We return noIntrinsicMetric for width so it fills available width
        return NSSize(width: NSView.noIntrinsicMetric, height: constrainedHeight)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}
