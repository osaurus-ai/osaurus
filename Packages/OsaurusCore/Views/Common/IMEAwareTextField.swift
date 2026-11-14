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
    /// Reports first-responder changes so the host can draw the focus ring.
    var onFocusChange: ((Bool) -> Void)? = nil
    var tracking: CGFloat? = nil
    var editable: Bool = true
    /// ↑ / ↓ while typing: -1 / +1. Nil leaves the arrows to the text view.
    var onMove: ((Int) -> Void)? = nil
    /// Escape. Nil leaves it to the text view, or to `clearsOnEscape`.
    var onCancel: (() -> Void)? = nil
    /// Escape without `onCancel`: empties the field and gives up focus,
    /// so Esc never reaches a handler further out while the field has focus.
    var clearsOnEscape: Bool = false
    /// Take keyboard focus once the field is in a window.
    var focusOnAppear: Bool = false
    /// False leaves the field out of Tab order and out of the window's own
    /// pick of what to focus first; a click or `focusOnAppear` still focuses it.
    var joinsKeyLoop: Bool = true

    func makeNSView(context: Context) -> IMETrackingTextView {
        let textView = IMETrackingTextView()
        textView.focusOnAppear = focusOnAppear
        textView.joinsKeyLoop = joinsKeyLoop
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = editable
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
        textView.onFocusChange = { [weak coordinator] focused in
            coordinator?.parent.onFocusChange?(focused)
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
        textView.insertionPointColor = textColor
        textView.isEditable = editable
        if let tracking, !textView.hasMarkedText() {
            textView.typingAttributes[.kern] = tracking
            textView.textStorage?.addAttribute(.kern, value: tracking, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        }
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
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                (textView as? IMETrackingTextView)?.onSubmit?()
                return true
            case #selector(NSResponder.moveUp(_:)) where parent.onMove != nil:
                parent.onMove?(-1)
                return true
            case #selector(NSResponder.moveDown(_:)) where parent.onMove != nil:
                parent.onMove?(1)
                return true
            case #selector(NSResponder.cancelOperation(_:)) where parent.onCancel != nil:
                parent.onCancel?()
                return true
            case #selector(NSResponder.cancelOperation(_:)) where parent.clearsOnEscape:
                if !textView.string.isEmpty {
                    textView.string = ""
                    parent.text = ""
                }
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// `NSTextView` that reports IME marked-text state changes.
final class IMETrackingTextView: NSTextView {
    /// Called when IME marked-text state changes (composing / not composing).
    var onMarkedTextChanged: ((Bool) -> Void)?
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var focusOnAppear = false
    var joinsKeyLoop = true

    override var canBecomeKeyView: Bool { joinsKeyLoop && super.canBecomeKeyView }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

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
