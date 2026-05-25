//
//  RedactionPreviewTextView.swift
//  osaurus / PrivacyFilter
//
//  SwiftUI bridge that drops a `SelectableNSTextView` into the
//  redaction review sheet's right pane so it can render the
//  scrubbed preview with the SAME inline highlight + hover popover
//  UX the chat bubbles use.
//
//  Why an NSViewRepresentable instead of `Text(AttributedString)`:
//    • `Text` cannot host per-run interactive hover state in a way
//      that mirrors the chat's custom themed popover.
//    • Reusing `RedactionHighlighter` + `RedactionHoverController`
//      means the preview's tooltip looks and feels identical to the
//      chat tooltip — same shield card, same accent capsule, same
//      80ms hide debounce — so there's one tooltip vocabulary
//      across the app rather than two.
//

import AppKit
import SwiftUI

struct RedactionPreviewTextView: NSViewRepresentable {
    /// Pre-scrubbed body to render: the user's containing text with
    /// originals already substituted for placeholders. Comes from
    /// `RedactionPreviewBuilder.build(...)`.
    let scrubbedText: String
    /// Placeholder-keyed highlights produced alongside `scrubbedText`.
    /// `direction == .preview` for every entry; values' `placeholderToken`
    /// is the user's ORIGINAL (which the tooltip will reveal).
    let highlights: [String: RedactionHighlight]
    /// Theme to draw from — colors, fonts, accent. Captured fresh
    /// per `updateNSView` so a theme change in Settings re-paints
    /// the preview without rebuilding the SwiftUI hierarchy.
    let theme: any ThemeProtocol

    /// Owns the hover controller so it survives `updateNSView`
    /// calls. SwiftUI tears `NSViewRepresentable` instances down
    /// per-update, but the coordinator persists for the lifetime
    /// of the surrounding View.
    @MainActor
    final class Coordinator {
        var hoverController: RedactionHoverController?
        /// Last-rendered (text, theme-mode) tuple. Re-rendering on
        /// every SwiftUI tick would churn `NSTextStorage` and reset
        /// the user's selection — only mutate when the inputs
        /// actually change.
        var lastFingerprint: String = ""
        /// Last-applied (text, highlights, accent) fingerprint.
        /// Distinct from `lastFingerprint` because the highlighter
        /// pass is a separate write to the same `NSTextStorage` and
        /// we want to skip it when nothing it would change has
        /// moved (a SwiftUI re-render where the body text and
        /// redaction map are identical to the previous tick should
        /// not touch `NSTextStorage` at all). Accent is folded in
        /// so a theme accent change re-stamps the foreground/
        /// underline colors without forcing a full rebuild.
        var lastHighlightFingerprint: String = ""
        /// Last applied range list, kept so the no-change branch
        /// can hand the hover controller the same set without
        /// re-running the highlighter.
        var lastAppliedRanges: [AppliedRedactionRange] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        let textView = SelectableNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Read-only preview — the same NSTextView idle-time hooks
        // we suppress in the chat are pure overhead here too.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selectionColor)
        ]
        textView.insertionPointColor = NSColor(theme.cursorColor)
        textView.accentColor = NSColor(theme.accentColor)
        textView.secondaryBackgroundColor = NSColor(theme.secondaryBackground)

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SelectableNSTextView,
            let storage = textView.textStorage
        else { return }

        // Reapply selection/theme colors so a live theme change in
        // Settings is picked up without reconstructing the view.
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selectionColor)
        ]
        textView.accentColor = NSColor(theme.accentColor)

        let fingerprint = makeFingerprint()
        let textRebuilt: Bool
        if context.coordinator.lastFingerprint != fingerprint {
            let attributed = Self.buildAttributedString(
                scrubbedText: scrubbedText,
                theme: theme
            )
            storage.setAttributedString(attributed)
            context.coordinator.lastFingerprint = fingerprint
            textRebuilt = true
        } else {
            textRebuilt = false
        }

        let highlightFingerprint = makeHighlightFingerprint()
        let highlightChanged =
            textRebuilt || context.coordinator.lastHighlightFingerprint != highlightFingerprint
        let applied: [AppliedRedactionRange]
        if highlightChanged {
            applied = RedactionHighlighter.apply(
                on: storage,
                highlights: highlights,
                accentColor: NSColor(theme.accentColor),
                a11yLabelBuilder: { Self.accessibilityLabel(for: $0) }
            )
            context.coordinator.lastHighlightFingerprint = highlightFingerprint
            context.coordinator.lastAppliedRanges = applied
        } else {
            // Inputs unchanged since the last apply ⇒ existing
            // `redactionPlaceholder` runs are still valid. Reuse the
            // last `applied` list so the hover controller can be
            // re-attached without rescanning the storage.
            applied = context.coordinator.lastAppliedRanges
        }

        // Lazy-create the hover controller — chats / previews
        // without any redactions never allocate the tracking-area
        // machinery.
        if applied.isEmpty {
            context.coordinator.hoverController?.detach()
            context.coordinator.hoverController = nil
        } else {
            if context.coordinator.hoverController == nil {
                context.coordinator.hoverController = RedactionHoverController()
            }
            context.coordinator.hoverController?.attach(
                to: textView,
                theme: theme,
                ranges: applied
            )
        }
    }

    /// Build the body attributed string. Plain text, body font,
    /// theme primaryText color. Line spacing matches the chat
    /// bubble paragraph spacing so the preview reads as a quote of
    /// the message the user is about to send.
    private static func buildAttributedString(
        scrubbedText: String,
        theme: any ThemeProtocol
    ) -> NSAttributedString {
        let body = NSMutableAttributedString(string: scrubbedText)
        let fontSize = CGFloat(theme.bodySize)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        // ~1.4 line height — same value the chat bubble uses for
        // paragraph blocks so the preview looks like a quote of the
        // outgoing message.
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(theme.primaryText),
            .paragraphStyle: paragraph,
        ]
        body.addAttributes(attributes, range: NSRange(location: 0, length: body.length))
        return body
    }

    private static func accessibilityLabel(for highlight: RedactionHighlight) -> String {
        let key = "privacy.highlight.a11y.preview"
        let format = String(localized: String.LocalizationValue(key), bundle: .module)
        if format == key { return highlight.placeholderToken }
        return String(format: format, highlight.placeholderToken)
    }

    /// (text, theme-mode) fingerprint. Theme mode is folded in so a
    /// dark/light switch counts as a change and re-rebuilds the
    /// attributed string with the new foreground/background colors.
    /// Body text fingerprint INTENTIONALLY excludes `highlights`
    /// because they're applied as a separate pass on the same
    /// storage; folding them in here would rebuild the attributed
    /// string (and drop the user's selection) every time the
    /// redaction map ticked.
    private func makeFingerprint() -> String {
        return "\(scrubbedText.count)|\(theme.isDark ? 1 : 0)|\(theme.bodySize)"
    }

    /// (scrubbedText, highlights, accent) fingerprint used to gate
    /// the highlighter pass. Hashes the full highlight contents so
    /// a placeholder-token change is detected even when the key
    /// set is identical (very rare — `[PHONE_1]` would never become
    /// `[PHONE_2]` for the same original — but the cost of folding
    /// in `placeholderToken` is two hashes per call, so we just
    /// do it).
    private func makeHighlightFingerprint() -> String {
        var hasher = Hasher()
        hasher.combine(scrubbedText)
        hasher.combine(highlights.count)
        for key in highlights.keys.sorted() {
            hasher.combine(key)
            if let h = highlights[key] {
                hasher.combine(h.placeholderToken)
                hasher.combine(h.direction.rawValue)
            }
        }
        // Accent description is `(red, green, blue, alpha)`-ish via
        // NSColor's debug description — stable enough to detect a
        // user-driven theme accent change.
        hasher.combine(NSColor(theme.accentColor).description)
        return String(hasher.finalize())
    }
}
