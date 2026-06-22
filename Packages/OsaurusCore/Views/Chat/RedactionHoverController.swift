//
//  RedactionHoverController.swift
//  osaurus
//
//  Attaches a single `NSTrackingArea` to a `SelectableNSTextView`
//  and shows a themed popover (`RedactionTooltipView`) whenever the
//  pointer rests over a span the Privacy Filter touched. One
//  controller is shared across textStorage updates so the tracking
//  area survives streaming edits instead of being rebuilt every
//  token.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Tooltip metadata: the placeholder the cloud actually saw and the
/// direction of the rewrite (outbound = user typed, replaced with
/// token; inbound = cloud emitted token, unscrubber restored).
struct RedactionTooltipModel: Equatable {
    let placeholderToken: String
    let direction: RedactionHighlight.Direction
}

@MainActor
final class RedactionHoverController {

    /// Currently-attached text view. Weak so detaching is enough to
    /// let the cell drop the view; we never hold the view alive.
    private weak var textView: SelectableNSTextView?
    private var popover: NSPopover?
    private var ranges: [AppliedRedactionRange] = []
    /// Theme captured at the most recent `attach`. Used by the
    /// popover SwiftUI subtree so its colors match the chat bubble
    /// the placeholder is anchored to.
    private var lastTheme: (any ThemeProtocol)?
    /// Index of the currently-hovered range (in `ranges`). Used to
    /// avoid reopening the popover when the cursor wiggles inside a
    /// single placeholder run.
    private var activeRangeIndex: Int?
    /// Debounce token for hide: when the cursor leaves a range we
    /// give it 80ms to re-enter (e.g. transit across an internal
    /// kerning gap) before closing the popover.
    private var hideWorkItem: DispatchWorkItem?

    init() {}

    /// Attach to `textView` (idempotent — re-attaching keeps the
    /// existing tracking area in place) and refresh the hover map.
    /// Pass an empty `ranges` list to remove the tracking area; the
    /// caller (NativeMarkdownView) does that automatically when
    /// `redactionHighlights` becomes empty.
    func attach(
        to textView: NSTextView,
        theme: any ThemeProtocol,
        ranges: [AppliedRedactionRange]
    ) {
        guard let stv = textView as? SelectableNSTextView else {
            // Only SelectableNSTextView exposes the hover hooks we
            // need. Other NSTextView subclasses won't see any
            // hover events; we silently no-op rather than crashing.
            return
        }
        self.ranges = ranges
        self.lastTheme = theme

        if ranges.isEmpty {
            detach()
            return
        }

        if self.textView !== stv {
            // Stop the previous view from advertising our hover area.
            self.textView?.wantsRedactionHoverTracking = false
            self.textView = stv
        }
        installHooksIfNeeded()
        // The text view owns the `.mouseMoved` area now (installed inside
        // its `updateTrackingAreas()` when this flag is set), so AppKit
        // ties the area's lifetime to the view — no manual add/remove.
        stv.wantsRedactionHoverTracking = true
    }

    /// Remove all observers + tracking + the popover. Called when
    /// the cell's redaction map becomes empty or the cell is reused
    /// for a different turn.
    func detach() {
        textView?.wantsRedactionHoverTracking = false
        clearHooks()
        popover?.close()
        popover = nil
        ranges = []
        activeRangeIndex = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
        textView = nil
    }

    // MARK: Hooks

    private func installHooksIfNeeded() {
        guard let tv = textView else { return }
        // Capture self weakly so the closure doesn't pin the
        // controller alive through the text view's strong refs.
        tv.onMouseHover = { [weak self] event in
            self?.handleMove(event)
        }
        tv.onMouseExitedHover = { [weak self] in
            self?.scheduleHide()
        }
    }

    private func clearHooks() {
        textView?.onMouseHover = nil
        textView?.onMouseExitedHover = nil
    }

    // MARK: Hit Test

    private func handleMove(_ event: NSEvent) {
        guard
            let tv = textView,
            let lm = tv.layoutManager,
            let tc = tv.textContainer
        else { return }

        let point = tv.convert(event.locationInWindow, from: nil)
        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: point, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        // glyphIndex(for:) clamps to the last glyph instead of
        // returning NSNotFound. Filter that out by checking the
        // glyph's bounding rect — if our point sits outside the
        // actual glyph box we're not really hovering text.
        let glyphRange = NSRange(location: glyphIndex, length: 1)
        let glyphRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        if !NSPointInRect(point, glyphRect) {
            scheduleHide()
            return
        }
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)

        guard let hitIdx = ranges.firstIndex(where: { NSLocationInRange(charIndex, $0.range) }) else {
            scheduleHide()
            return
        }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if activeRangeIndex == hitIdx, popover?.isShown == true {
            return
        }
        activeRangeIndex = hitIdx
        showPopover(for: ranges[hitIdx], in: tv)
    }

    // MARK: Popover

    private func showPopover(for entry: AppliedRedactionRange, in tv: NSTextView) {
        guard let theme = lastTheme else { return }
        let model = RedactionTooltipModel(
            placeholderToken: entry.highlight.placeholderToken,
            direction: entry.highlight.direction
        )

        let anchorRect = rect(for: entry.range, in: tv)
        let pop: NSPopover
        if let existing = popover {
            pop = existing
        } else {
            pop = NSPopover()
            // `.semitransient` so dragging the cursor across the
            // glyph (or briefly leaving via a sub-pixel kerning gap)
            // doesn't instantly dismiss; the 80ms hide debounce on
            // the controller handles the final close cleanly.
            pop.behavior = .semitransient
            pop.animates = false
            popover = pop
        }
        // Match the popover chrome to the theme's polarity so its
        // border/arrow stop looking like a stock-Aqua bubble pasted
        // onto a custom-themed chat — the existing styling left a
        // bright-white card sitting over dark themes.
        pop.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        pop.contentViewController = NSHostingController(
            rootView: RedactionTooltipView(model: model)
                .environment(\.theme, theme)
        )
        if pop.isShown {
            pop.positioningRect = anchorRect
        } else {
            pop.show(relativeTo: anchorRect, of: tv, preferredEdge: .maxY)
        }
    }

    private func scheduleHide() {
        guard activeRangeIndex != nil else { return }
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activeRangeIndex = nil
            self.popover?.close()
        }
        hideWorkItem = work
        // 80ms matches AppKit's standard `.transient` hide latency
        // and is long enough that the cursor can cross sub-pixel
        // kerning gaps inside a placeholder without closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func rect(for range: NSRange, in tv: NSTextView) -> NSRect {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return .zero }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        return rect
    }
}

// MARK: - Tooltip View

/// SwiftUI body of the hover popover. Pulls the chat's theme so the
/// popover's surface, accent, and text colors match the bubble it's
/// anchored to (themes are user-pickable from Settings).
///
/// Layout: a single horizontal card with a shield glyph, a one-line
/// title ("Replaced with" / "Restored from"), an accent capsule
/// holding the placeholder token, and a small secondary subtitle
/// ("before leaving your Mac" / "after the cloud responded") so the
/// user understands the privacy direction without parsing a verb.
struct RedactionTooltipView: View {
    @Environment(\.theme) private var theme
    let model: RedactionTooltipModel

    private var titleKey: String {
        switch model.direction {
        case .outbound: return "privacy.tooltip.outbound.title"
        case .inbound: return "privacy.tooltip.inbound.title"
        case .preview: return "privacy.tooltip.preview.title"
        }
    }

    private var subtitleKey: String {
        switch model.direction {
        case .outbound: return "privacy.tooltip.outbound.subtitle"
        case .inbound: return "privacy.tooltip.inbound.subtitle"
        case .preview: return "privacy.tooltip.preview.subtitle"
        }
    }

    /// The preview popover renders the user's original value, which
    /// can be a free-text email/URL/phone. Monospaced + capsule is
    /// the right visual for placeholder tokens (`[PHONE_1]`) but
    /// reads as fake-data for an email — drop the capsule treatment
    /// for the preview case so the original is just colored text.
    private var rendersValueAsCapsule: Bool {
        model.direction != .preview
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: String.LocalizationValue(titleKey), bundle: .module))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                valueText
                Text(String(localized: String.LocalizationValue(subtitleKey), bundle: .module))
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var valueText: some View {
        let base = Text(model.placeholderToken)
            .foregroundColor(theme.accentColor)
        if rendersValueAsCapsule {
            base
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(theme.accentColor.opacity(0.12))
                )
        } else {
            // Preview direction: an email / phone / URL reads
            // better in the body font without a capsule wrapper.
            base
                .font(.system(size: 12, weight: .medium))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
