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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AutoSizingScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = CustomNSTextView()
        textView.delegate = context.coordinator
        textView.maxHeight = maxHeight

        // Configuration
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear

        // Layout
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = .zero
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
    }
}

// Custom ScrollView that reports content size
final class AutoSizingScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        // Return document view's size
        return documentView?.intrinsicContentSize ?? NSSize(width: NSView.noIntrinsicMetric, height: 50)
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

        // Add a small buffer for cursor/line height
        let height = max(usedRect.height, font?.pointSize ?? 14)

        // Cap at maxHeight
        let constrainedHeight = min(height, maxHeight)

        // We return noIntrinsicMetric for width so it fills available width
        return NSSize(width: NSView.noIntrinsicMetric, height: constrainedHeight)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}
