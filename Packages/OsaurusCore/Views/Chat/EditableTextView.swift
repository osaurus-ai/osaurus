//
//  EditableTextView.swift
//  osaurus
//
//  A SwiftUI wrapper for NSTextView that supports custom cursor colors
//  and auto-sizing similar to TextEditor.
//

import AppKit
import SwiftUI

/// Imperative side channel for the NSTextView's first-responder state.
///
/// Callers (typically a SwiftUI parent holding it as `@StateObject`)
/// invoke `lockFocus(for:)` to refuse resignation through a
/// state-mutation cascade that would otherwise have AppKit blur the
/// input. Not `@Published` — purely imperative, no SwiftUI re-renders.
@MainActor
final class TextViewFocusController: ObservableObject {
    /// Wired by `EditableTextView.makeNSView`. Tests use `attach(_:)`.
    fileprivate(set) weak var textView: CustomNSTextView?

    /// Test-only injection point.
    func attach(_ textView: CustomNSTextView) {
        self.textView = textView
    }

    /// Arm the resignation-refusal window. Also re-claims first
    /// responder if something has already taken it (e.g. a button's
    /// mouseDown a microsecond before the lock was applied).
    func lockFocus(for duration: TimeInterval = 0.15) {
        guard let tv = textView else { return }
        tv.focusLockUntil = Date().addingTimeInterval(duration)
        if let window = tv.window, window.firstResponder !== tv {
            window.makeFirstResponder(tv)
        }
    }
}

struct EditableTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let textColor: Color
    let cursorColor: Color
    @Binding var isFocused: Bool
    @Binding var isComposing: Bool
    var maxHeight: CGFloat = .infinity
    /// Optional imperative focus controller. `makeNSView` populates
    /// its weak `textView` reference; the parent uses `lockFocus(for:)`
    /// to refuse resignation during state-mutation cascades.
    var focusController: TextViewFocusController? = nil
    var onCommit: (() -> Void)? = nil
    var onShiftCommit: (() -> Void)? = nil
    /// Called on ↑ arrow key. Return true to consume the event (prevents cursor movement).
    var onArrowUp: (() -> Bool)? = nil
    /// Called on ↓ arrow key. Return true to consume the event (prevents cursor movement).
    var onArrowDown: (() -> Bool)? = nil
    /// Called on Escape key. Return true to consume the event.
    var onEscape: (() -> Bool)? = nil
    /// Called when the user pastes plain text (Cmd+V or menu Paste). Return
    /// true to consume the paste (e.g. routed elsewhere as an attachment);
    /// false to let NSTextView insert the text inline as normal.
    var onPasteText: ((String) -> Bool)? = nil

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
        textView.onPasteText = { [weak coordinator] text in
            coordinator?.parent.onPasteText?(text) ?? false
        }

        focusController?.textView = textView

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
    /// Called on Cmd+V / menu Paste with the pasteboard's plain-text string.
    /// Return true to consume the paste (skips the default insertion).
    var onPasteText: ((String) -> Bool)?

    /// While `Date() < focusLockUntil`, `resignFirstResponder` returns
    /// `false`. Set via `TextViewFocusController.lockFocus(for:)` to
    /// keep first responder through a state-mutation cascade. No
    /// scheduled work — the deadline self-expires on the next
    /// resignation attempt past it.
    var focusLockUntil: Date = .distantPast

    /// When true, ChatView's window-level Esc monitor passes the Esc
    /// key event through instead of swallowing it, so this text view's
    /// normal `cancelOperation(_:)` → delegate `doCommandBy` path can
    /// handle it (e.g. the inline message editor cancels the edit
    /// rather than the whole window closing). Defaults to false — the
    /// main composer keeps the window-level Esc cascade.
    var handlesEscapeLocally: Bool = false

    // MARK: First-responder

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChanged?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        if Date() < focusLockUntil { return false }
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

    // MARK: Paste interception

    /// Intercept Cmd+V / menu Paste.
    ///
    /// The plain-text payload is read with the cheap `string(forType:)`
    /// accessor. The default `super.paste(_:)` path instead goes through
    /// `readObjectsForClasses:`, a heavier synchronous XPC round-trip to the
    /// pasteboard server that can block the main thread for seconds (and is
    /// the same accessor implicated in the earlier pasteboard-corruption
    /// crash). This view is a plain-text input (`isRichText == false`), so
    /// `super.paste(_:)` would only insert the string representation anyway —
    /// inserting it ourselves is behavior-preserving and keeps paste fast.
    ///
    /// If `onPasteText` consumes the text (returns true) we swallow the
    /// paste; the owner has routed the content elsewhere (e.g. converted it
    /// to a pasted-content attachment). When there's no string payload at all
    /// (image / file / rich-only), we fall back to the default machinery,
    /// which knows how to read those representations.
    override func paste(_ sender: Any?) {
        let plainText = NSPasteboard.general.string(forType: .string)

        if let handler = onPasteText, let text = plainText, handler(text) {
            return
        }

        if let text = plainText {
            // Route through the normal user-edit path so undo and the
            // delegate's text-change hooks still fire.
            let range = selectedRange()
            if shouldChangeText(in: range, replacementString: text) {
                replaceCharacters(in: range, with: text)
                didChangeText()
            }
            return
        }

        super.paste(sender)
    }
}
