//
//  FollowUpSuggestionsBar.swift
//  osaurus
//
//  Renders AI-suggested follow-up questions for the most recent completed
//  turn as a stack of clickable rows below the assistant message. Tapping a
//  row submits it as the next user message. Purely presentational: the parent
//  owns generation (`ChatSession.maybeGenerateFollowUps`) and the send
//  callback (`ChatSession.sendFollowUp`). Renders nothing when there are no
//  suggestions, so callers can mount it unconditionally.
//
//  Appearance is animated: the header and each row fade in and rise slightly,
//  staggered top-to-bottom, so the section arrives gently rather than popping
//  in. The animation uses `opacity`/`offset` only (render-time transforms), so
//  it never changes the row's measured height and can't fight the table's
//  height cache.
//

import SwiftUI

struct FollowUpSuggestionsBar: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredIndex: Int?
    /// Drives the entrance animation. Flips true on first `onAppear`.
    @State private var appeared = false

    /// Base fade/rise duration for each element.
    private let revealDuration: Double = 0.32
    /// Delay added per row so the reveal cascades down the list.
    private let perRowStagger: Double = 0.06

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .modifier(RevealModifier(appeared: appeared, animation: reveal(index: 0)))

                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    if index > 0 {
                        rowDivider
                            .modifier(RevealModifier(appeared: appeared, animation: reveal(index: index)))
                    }
                    suggestionRow(index: index, suggestion: suggestion)
                        // Rows start revealing just after the header, then cascade.
                        .modifier(RevealModifier(appeared: appeared, animation: reveal(index: index + 1)))
                }
            }
            // No horizontal padding: the hosting cell already insets this view
            // by 16pt (matching the assistant markdown's leading/trailing), so
            // the header and rows line up flush with the message text above.
            .padding(.vertical, 8)
            // Reveal cascade starts as soon as the section mounts. `reveal`
            // collapses the motion to an instant for reduced-motion users.
            .onAppear { appeared = true }
        }
    }

    /// Hairline separator between rows. A full-weight `Divider` reads too harsh
    /// here, so this is a thin, low-opacity line.
    private var rowDivider: some View {
        theme.inputBorder
            .opacity(0.35)
            .frame(height: 0.5)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text("Follow up", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.bottom, 6)
    }

    private func suggestionRow(index: Int, suggestion: String) -> some View {
        Button {
            onSelect(suggestion)
        } label: {
            HStack {
                Text(suggestion)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(
            (hoveredIndex == index ? theme.inputBackground : Color.clear)
                .cornerRadius(6)
        )
        .onHover { hovering in
            hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
        }
        .help(suggestion)
    }

    /// Per-element entrance animation. Reduced motion collapses the stagger and
    /// motion to an instant (no-op) transition.
    private func reveal(index: Int) -> Animation {
        if reduceMotion { return .linear(duration: 0) }
        return .easeOut(duration: revealDuration).delay(Double(index) * perRowStagger)
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
