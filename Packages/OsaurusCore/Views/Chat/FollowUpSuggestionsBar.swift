//
//  FollowUpSuggestionsBar.swift
//  osaurus
//
//  Renders AI-suggested follow-up questions for the most recent completed
//  turn as one card of clickable rows below the assistant message. Tapping a
//  row submits it as the next user message. Purely presentational: the parent
//  owns generation (`ChatSession.maybeGenerateFollowUps`) and the send
//  callback (`ChatSession.sendFollowUp`). Renders nothing when there are no
//  suggestions, so callers can mount it unconditionally.
//
//  Appearance is animated: the header, then the card, fade in and rise
//  slightly, so the section arrives gently rather than popping in. The animation uses `opacity`/`offset` only (render-time transforms), so
//  it never changes the row's measured height and can't fight the table's
//  height cache.
//

import AppKit
import SwiftUI

struct FollowUpSuggestionsBar: View {
    let suggestions: [String]
    let onSelect: (String) -> Void
    /// Play the entrance animation. False when a recycled table cell re-mounts
    /// a suggestion set the user has already seen (scrolled away and back), so
    /// the section doesn't re-animate on every scroll — mirrors the chart
    /// cell's `hasChartBeenDrawn` suppression.
    let animate: Bool

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(40) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var hoveredIndex: Int? = nil
    /// Drives the entrance animation. Starts already-revealed when `animate`
    /// is false so a replayed cell renders in its final state immediately.
    @State private var appeared: Bool

    init(suggestions: [String], animate: Bool = true, onSelect: @escaping (String) -> Void) {
        self.suggestions = suggestions
        self.onSelect = onSelect
        self.animate = animate
        _appeared = State(initialValue: !animate)
    }

    /// Delay between the header's reveal and the card's.
    private let perRowStagger: Double = 0.06

    /// Inset of a row's text inside the card; the header lines up with it.
    private var rowInset: CGFloat { theme.space.s12 }
    private var cardRadius: CGFloat {
        theme.assignedMetric(NativeComponentInspectionStyle.key(40, "radius"), fallback: theme.radius.medium)
    }
    private var hairline: CGFloat { NativeComponentInspectionStyle.metric(40, "borderWidth", 1 / max(displayScale, 1), theme) }

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                header
                    .padding(.leading, rowInset)
                    .modifier(RevealModifier(appeared: appeared, animation: reveal(index: 0)))

                // One card: the rows share its surface and are told apart by
                // hairlines, so a list of questions reads as one choice.
                VStack(alignment: .leading, spacing: theme.space.s0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        if index > 0 {
                            rowDivider
                        }
                        suggestionRow(index: index, suggestion: suggestion)
                    }
                }
                .background(theme.assignedColor(NativeComponentInspectionStyle.key(40, "background"), fallback: .clear))
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .strokeBorder(theme.border.subtle, lineWidth: hairline)
                )
                // The card arrives just after the header.
                .modifier(RevealModifier(appeared: appeared, animation: reveal(index: 1)))
            }
            // No horizontal padding: the hosting cell already insets this view
            // by 16pt (matching the assistant markdown's leading/trailing), so
            // the card lines up flush with the message text above.
            .padding(.vertical, theme.catalogLayoutMetric("component.library.40.elements.layout.followUpSuggestionsBar.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(40, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.40.elements.layout.followUpSuggestionsBar.body.paddingY")
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // Reveal cascade starts as soon as the section mounts. `reveal`
            // collapses the motion to an instant for reduced-motion users.
            // Skipped entirely when `animate` is false (already revealed).
            .onAppear { if animate { appeared = true } }
        }
    }

    /// Exactly one device pixel: a fixed 0.5pt line straddles two pixels on
    /// 1x displays (or at fractional row offsets) and renders at half
    /// strength, so some rows looked muted.
    private var rowDivider: some View {
        theme.border.subtle
            .frame(height: hairline)
    }

    private var header: some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: "text.append")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(theme.text.tertiary)
            Text("Follow up", bundle: .module)
                .componentInspectionText(40, role: .label, fallback: .label, weight: 600, theme: theme)
                .foregroundStyle(theme.text.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func suggestionRow(index: Int, suggestion: String) -> some View {
        let isHovered = hoveredIndex == index
        return Button {
            onSelect(suggestion)
        } label: {
            HStack(spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.followUpSuggestionsBar.suggestionRow.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(40, "gap", theme.space.s8, theme))) {
                Text(suggestion)
                    .componentInspectionText(40, role: .body, fallback: .bodySmall, theme: theme)
                    .foregroundStyle(theme.text.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Sends on click: quiet at rest, nudged forward on hover.
                Image(systemName: "arrow.right")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundStyle(isHovered ? theme.text.primary : theme.text.tertiary)
                    .offset(x: isHovered ? 2 : 0)
            }.catalogLayoutTarget("component.library.40.elements.layout.followUpSuggestionsBar.suggestionRow.horizontalGap")
            .padding(.horizontal, rowInset)
            .padding(.vertical, theme.catalogLayoutMetric("component.library.40.elements.layout.followUpSuggestionsBar.suggestionRow.paddingY", inheriting: NativeComponentInspectionStyle.metric(40, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.40.elements.layout.followUpSuggestionsBar.suggestionRow.paddingY")
            .frame(minHeight: NativeComponentInspectionStyle.metric(40, "height", 0, theme))
            .background(isHovered ? theme.surface.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.theme, theme)
        .onHover { hovering in
            hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
            // Pointing-hand cursor over a tappable suggestion. push/pop stays
            // balanced because `onHover` fires exactly once per enter/exit.
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(theme.motion.quick, value: hoveredIndex)
        .help(suggestion)
    }

    /// Per-element entrance animation. Reduced motion collapses the stagger and
    /// motion to an instant (no-op) transition.
    private func reveal(index: Int) -> Animation {
        if reduceMotion { return theme.motion.quick }
        return theme.motion.slow.delay(Double(index) * perRowStagger)
    }
}

/// Fade + slight upward slide keyed on `appeared`. Extracted so the header,
/// dividers, and rows share one entrance treatment. Uses render-time
/// transforms only, so it never perturbs the hosting cell's measured height.
private struct RevealModifier: ViewModifier {
    let appeared: Bool
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
            .animation(animation, value: appeared)
    }
}
