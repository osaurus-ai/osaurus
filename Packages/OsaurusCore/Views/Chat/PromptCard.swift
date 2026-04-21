//
//  PromptCard.swift
//  osaurus
//
//  Shared chrome for in-chat prompt overlays (secrets, clarify, …).
//  Owns the header pill, markdown description, optional footnote, glass
//  background, gradient border, layered drop shadow + accent halo, and
//  the spring entry/exit animation. Concrete cards (`SecretPromptCard`,
//  `ClarifyPromptCard`) plug a body and an input row into the slots.
//
//  The visual treatment is intentionally close to a modal: a subtle
//  scrim is drawn by the overlay host (see `PromptOverlayHost`), and
//  the card itself "lands" with a small scale-in + accent-tinted halo
//  so the user's attention is drawn without anything feeling jumpy.
//

import AppKit
import SwiftUI

// MARK: - Cursor helper

extension View {
    /// Set the macOS cursor to a pointing hand while hovered, restore
    /// the default on exit. Matches the existing pattern used in
    /// `ModelRowView` and `PopoverHoverTracking`. No-op on platforms
    /// without `NSCursor` (none today, but keeps the call site clean).
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Public model

/// Optional small footnote shown at the bottom of the description block
/// (e.g. "Stored securely in Keychain as <key>"). Kept structured so
/// callers don't have to redo the formatting.
struct PromptCardFootnote {
    let icon: String
    let text: LocalizedStringKey
}

/// Wraps the description stack in either a boxed (rounded inset) or
/// plain (light padding) treatment. Pulled out as a `ViewModifier` so
/// `PromptCard.descriptionRegion` stays a single ternary-style branch
/// instead of a forked view-builder.
private struct DescriptionTreatment: ViewModifier {
    let boxed: Bool
    let background: Color
    let border: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if boxed {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
        } else {
            content
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .padding(.bottom, 4)
        }
    }
}

// MARK: - PromptCard

/// Generic prompt card. Both `SecretPromptCard` and `ClarifyPromptCard`
/// render through this so visual changes apply to all in-chat prompts
/// in one place.
struct PromptCard<BodyContent: View, InputRow: View>: View {
    let pillIcon: String
    let pillLabel: LocalizedStringKey
    let title: String?
    let descriptionMarkdown: String?
    let footnote: PromptCardFootnote?
    let onCancel: () -> Void
    // Slot names intentionally distinct from the `View.body` requirement
    // (`bodyContent` / `inputRow`) so they don't collide with SwiftUI's
    // protocol-required `body` property below.
    @ViewBuilder let bodyContent: () -> BodyContent
    @ViewBuilder let inputRow: () -> InputRow

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var haloOpacity: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            header
            descriptionRegion
            bodyContent()
            inputRow()
        }
        .padding(16)
        .background(overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(borderOverlay)
        .shadow(color: theme.shadowColor.opacity(0.20), radius: 28, x: 0, y: 14)
        // Soft accent halo around the card. Filled with `.clear` so the
        // shape contributes geometry for the shadow but doesn't paint
        // any pixels itself — the rendered effect is purely the glow.
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .shadow(color: theme.accentColor.opacity(haloOpacity), radius: 22, x: 0, y: 0)
                .allowsHitTesting(false)
        )
        .onAppear {
            // Halo animates from transparent → 0.18 → settles at 0.10 so
            // the card "lands" with a soft accent glow then stays calmly
            // outlined while it's active.
            if reduceMotion {
                haloOpacity = 0.10
            } else {
                withAnimation(.easeOut(duration: 0.25)) { haloOpacity = 0.18 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    withAnimation(.easeInOut(duration: 0.5)) { haloOpacity = 0.10 }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            pill
            Spacer()
            cancelButton
        }
    }

    private var pill: some View {
        HStack(spacing: 6) {
            Image(systemName: pillIcon)
                .font(.system(size: 12, weight: .semibold))
            Text(pillLabel, bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
        }
        .foregroundColor(theme.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.accentColor.opacity(theme.isDark ? 0.15 : 0.1)))
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("Cancel", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .pointingHandCursor()
    }

    // MARK: - Description

    /// Description region. Renders nothing when the card has no
    /// description content. Picks one of two visual treatments:
    ///
    /// - **Boxed** (when `title` or `footnote` is set): structured
    ///   secrets case — title + markdown body + keychain footnote
    ///   share an inset rounded background, so the structured info
    ///   reads as one unit.
    /// - **Plain** (clarify — markdown only): just the markdown text
    ///   with comfortable padding. Nesting another rounded rect inside
    ///   the card chrome made clarify feel boxy; for a single
    ///   paragraph question, plain text inside the card is cleaner.
    @ViewBuilder
    private var descriptionRegion: some View {
        if title != nil || descriptionMarkdown != nil || footnote != nil {
            let needsBox = title != nil || footnote != nil
            descriptionStack
                .modifier(
                    DescriptionTreatment(
                        boxed: needsBox,
                        background: theme.inputBackground,
                        border: theme.inputBorder
                    )
                )
        }
    }

    private var descriptionStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let descriptionMarkdown {
                Text(parsedMarkdown(descriptionMarkdown))
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .regular))
                    .foregroundColor(theme.secondaryText)
                    .tint(theme.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let footnote {
                HStack(spacing: 4) {
                    Image(systemName: footnote.icon)
                        .font(.system(size: 10))
                    Text(footnote.text, bundle: .module)
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                }
                .foregroundColor(theme.tertiaryText.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Parse markdown inline (`**bold**`, `_italic_`, `[link](url)`,
    /// inline `code`) while preserving whitespace and newlines. We stay
    /// on `.inlineOnlyPreservingWhitespace` because SwiftUI `Text` won't
    /// render block-level constructs (list bullets, headings, code
    /// fences) from `AttributedString` anyway — `.full` would strip the
    /// `1.` / `-` markers without giving us bullets in return, leaving
    /// numbered menus unreadable. Inline-only keeps the literal markers
    /// and the line breaks so the menu still reads naturally.
    private func parsedMarkdown(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if var attributed = try? AttributedString(markdown: raw, options: options) {
            attributed.foregroundColor = theme.secondaryText
            return attributed
        }
        return AttributedString(raw)
    }

    // MARK: - Background & Border

    private var overlayBackground: some View {
        ZStack {
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardBackground.opacity(theme.isDark ? 0.85 : 0.92))

            LinearGradient(
                colors: [theme.accentColor.opacity(theme.isDark ? 0.08 : 0.05), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(0.2),
                        theme.cardBorder,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

// MARK: - PromptOverlayHost

/// Bottom-pinned host shared by all prompt overlays. Owns the entry
/// animation (fade + slight rise + scale-in) so concrete overlays only
/// need to wire up their card.
///
/// Concrete overlays (e.g. `SecretPromptOverlay`, `ClarifyPromptOverlay`)
/// embed their card via this host so animation/placement stays
/// identical across all prompt types.
struct PromptOverlayHost<Card: View>: View {
    let onCancelDismiss: () -> Void
    @ViewBuilder let card: () -> Card

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAppearing = false

    var body: some View {
        VStack {
            Spacer()

            card()
                .frame(maxWidth: 720)
                .opacity(isAppearing ? 1 : 0)
                .offset(y: isAppearing ? 0 : (reduceMotion ? 0 : 30))
                .scaleEffect(isAppearing ? 1.0 : (reduceMotion ? 1.0 : 0.985))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        // Center the capped-width card horizontally so it sits in the
        // middle of wide chat windows instead of pinning to the leading
        // edge with a huge empty trailing margin.
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear {
            if reduceMotion {
                isAppearing = true
            } else {
                withAnimation(theme.springAnimation()) {
                    isAppearing = true
                }
            }
        }
        .onExitCommand { onCancelDismiss() }
    }
}
