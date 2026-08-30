//
//  IMEAwareTextField.swift
//  osaurus
//
//  A single-line text field that reports IME marked-text (composition) state.
//
//  Plain SwiftUI `TextField` only updates its binding once an IME commits its
//  composition, so any manually overlaid placeholder keyed on `text.isEmpty`
//  stays visible and overlaps the composing text. This wraps an `NSTextView`
//  so callers can hide the placeholder as soon as composition begins.
//

import AppKit
import SwiftUI

struct IMEAwareTextField: NSViewRepresentable {
    @Binding var text: String
    /// `true` while an IME composition (marked text) is active.
    @Binding var isComposing: Bool
    var font: NSFont
    var textColor: NSColor
    var onSubmit: (() -> Void)? = nil

    func makeNSView(context: Context) -> IMETrackingTextView {
        let textView = IMETrackingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.focusRingType = .none
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.string = text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0

        // Fill whatever frame SwiftUI hands us; let the container track the view
        // width so the single line stays visible and the caret draws correctly.
        textView.autoresizingMask = [.width, .height]
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let coordinator = context.coordinator
        textView.onMarkedTextChanged = { [weak coordinator] composing in
            coordinator?.parent.isComposing = composing
        }
        textView.onSubmit = { [weak coordinator] in
            coordinator?.parent.onSubmit?()
        }

        return textView
    }

    func updateNSView(_ textView: IMETrackingTextView, context: Context) {
        context.coordinator.parent = self
        // Don't stomp the field editor mid-composition.
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        if textView.font != font { textView.font = font }
        if textView.textColor != textColor { textView.textColor = textColor }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IMEAwareTextField
        init(_ parent: IMEAwareTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Marked (composing) text is not yet committed; leave the binding alone.
            if textView.hasMarkedText() { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }

        func textView(
            _ textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                (textView as? IMETrackingTextView)?.onSubmit?()
                return true
            }
            return false
        }
    }
}

/// `NSTextView` that reports IME marked-text state changes.
final class IMETrackingTextView: NSTextView {
    /// Called when IME marked-text state changes (composing / not composing).
    var onMarkedTextChanged: ((Bool) -> Void)?
    var onSubmit: (() -> Void)?

    override func setMarkedText(
        _ string: Any, selectedRange: NSRange, replacementRange: NSRange
    ) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChanged?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChanged?(false)
    }
}
