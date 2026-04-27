//
//  EditableTextView.swift
//  osaurus
//
//  A SwiftUI wrapper for NSTextView that supports custom cursor colors
//  and auto-sizing similar to TextEditor.
//

import AppKit
import SwiftUI

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
    /// Called on ↑ arrow key. Return true to consume the event (prevents cursor movement).
    var onArrowUp: (() -> Bool)? = nil
    /// Called on ↓ arrow key. Return true to consume the event (prevents cursor movement).
    var onArrowDown: (() -> Bool)? = nil
    /// Called on Escape key. Return true to consume the event.
    var onEscape: (() -> Bool)? = nil

    // MARK: - NSViewRepresentable

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

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear

        // Align with placeholder padding (.leading: 6, .top: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // Behave like a code editor / raw input.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let coordinator = context.coordinator
        textView.onMarkedTextChanged = { [weak coordinator] in coordinator?.parent.isComposing = $0 }
        textView.onFocusChanged = { [weak coordinator] in coordinator?.parent.isFocused = $0 }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CustomNSTextView else { return }
        let coord = context.coordinator

        syncMaxHeight(textView, scrollView: scrollView)
        syncText(textView, scrollView: scrollView)
        syncStyling(textView, coord: coord)
        syncFocus(textView)
        syncScrollerVisibility(textView, scrollView: scrollView, coord: coord)
    }

    // MARK: - updateNSView helpers

    private func syncMaxHeight(_ textView: CustomNSTextView, scrollView: NSScrollView) {
        // Avoids triggering NSTextView layout when nothing changed.
        guard textView.maxHeight != maxHeight else { return }
        textView.maxHeight = maxHeight
        textView.invalidateIntrinsicContentSize()
        scrollView.invalidateIntrinsicContentSize()
    }

    private func syncText(_ textView: CustomNSTextView, scrollView: NSScrollView) {
        // Skip if unchanged (avoids cursor-position reset on every parent re-render).
        // Never overwrite while an IME composition is active: assigning `string`
        // unmarks the marked text and breaks CJK input.
        guard textView.string != text, !textView.hasMarkedText() else { return }
        textView.string = text
        textView.invalidateIntrinsicContentSize()
        scrollView.invalidateIntrinsicContentSize()
    }

    private func syncStyling(_ textView: CustomNSTextView, coord: Coordinator) {
        // Each assignment invalidates layout / triggers needsDisplay even when unchanged,
        // so we cache the last-applied value and only write on a real diff.
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
    }

    private func syncFocus(_ textView: CustomNSTextView) {
        let wantsFocus = isFocused
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            let isFirstResponder = window.firstResponder == textView
            if wantsFocus, !isFirstResponder {
                window.makeFirstResponder(textView)
            } else if !wantsFocus, isFirstResponder {
                window.makeFirstResponder(nil)
            }
        }
    }

    private func syncScrollerVisibility(
        _ textView: CustomNSTextView,
        scrollView: NSScrollView,
        coord: Coordinator
    ) {
        // contentHeight runs ensureLayout (expensive) — only re-check when something
        // that could change scroller state has changed.
        guard coord.lastScrollerMaxHeight != maxHeight || coord.lastScrollerText != text else {
            return
        }
        let needsScroller = textView.contentHeight > maxHeight
        scrollView.verticalScroller?.isHidden = !needsScroller
        scrollView.tile()
        coord.lastScrollerMaxHeight = maxHeight
        coord.lastScrollerText = text
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextView

        // Cached appearance values — guards against needsDisplay on every parent re-render.
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
            // Skip while an IME composition is active; the binding is pushed once the
            // composition commits (next textDidChange after unmarkText) or via textDidEndEditing.
            // Propagating mid-composition would re-enter updateNSView and clobber the
            // marked text, breaking CJK input.
            if !textView.hasMarkedText() {
                parent.text = textView.string
            }
            // The textView's intrinsic size is already invalidated by `didChangeText` —
            // only the enclosing scrollView needs a nudge so SwiftUI re-measures.
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isComposing = false
        }

        @MainActor
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onArrowUp?() ?? false
            case #selector(NSResponder.moveDown(_:)):
                return parent.onArrowDown?() ?? false
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape?() ?? false
            case #selector(NSResponder.insertNewline(_:)):
                return handleNewline()
            default:
                return false
            }
        }

        @MainActor
        private func handleNewline() -> Bool {
            let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if isShift {
                guard let shiftCommit = parent.onShiftCommit else {
                    return false  // No shift handler — let NSTextView insert a newline.
                }
                shiftCommit()
                return true
            }
            parent.onCommit?()
            return true
        }
    }
}

// MARK: - AutoSizingScrollView

/// Scroll view that reports its document view's intrinsic size so SwiftUI can
/// auto-size the input area.
final class AutoSizingScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        documentView?.intrinsicContentSize
            ?? NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }
}

// MARK: - CustomNSTextView

/// NSTextView subclass that:
/// - reports an intrinsic content size capped at `maxHeight` so the input grows
///   with text up to a limit and then scrolls;
/// - exposes IME composition state via `onMarkedTextChanged`;
/// - exposes first-responder transitions via `onFocusChanged`.
final class CustomNSTextView: NSTextView {
    var maxHeight: CGFloat = .infinity

    /// Called when IME marked-text state changes (composing / not composing).
    var onMarkedTextChanged: ((Bool) -> Void)?
    /// Called when first-responder state changes (focused / not focused).
    var onFocusChanged: ((Bool) -> Void)?

    // MARK: First-responder

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChanged?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChanged?(false) }
        return resigned
    }

    // MARK: IME composition

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        notifyMarkedTextChanged(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        notifyMarkedTextChanged(false)
    }

    /// Notify observers of IME composition state on the next runloop tick.
    /// Deferring avoids SwiftUI re-entering `updateNSView` while the textView is
    /// still inside its IME callback, which would clobber the marked text and
    /// break CJK input.
    private func notifyMarkedTextChanged(_ composing: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onMarkedTextChanged?(composing)
        }
    }

    // MARK: Sizing

    /// Total height required to display the content without scrolling.
    ///
    /// Uses the layout manager's actual `usedRect.height` (which respects per-script
    /// font substitution — e.g. CJK falls back to taller fonts than SF) and then
    /// `ceil`s to whole pixels so the reported intrinsic size doesn't wobble by
    /// fractional pixels between layout passes (which would cause visible "jiggle"
    /// as the user types, especially under IME marked-text composition).
    ///
    /// A single-line floor based on the textView's primary font keeps the empty
    /// state sized like one Latin line.
    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else {
            return super.intrinsicContentSize.height
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height

        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let oneLine = font.ascender - font.descender + font.leading
        let measured = max(usedHeight, oneLine)

        // ceil for stable whole-pixel sizing; add textContainerInset (top + bottom).
        return ceil(measured) + textContainerInset.height * 2
    }

    override var intrinsicContentSize: NSSize {
        // Width: noIntrinsicMetric so the textView fills available width.
        // Height: capped at maxHeight to enable scrolling beyond the visible cap.
        NSSize(width: NSView.noIntrinsicMetric, height: min(contentHeight, maxHeight))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}
