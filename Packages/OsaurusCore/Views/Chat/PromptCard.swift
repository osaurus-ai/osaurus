//
//  PromptCard.swift
//  osaurus
//
//  Shared chrome for in-chat prompt overlays (secrets, clarify, …).
//  Owns the header pill, markdown description, optional footnote, opaque
//  surface, border, elevation, and
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
    /// `PopoverHoverTracking`. No-op on platforms
    /// without `NSCursor` (none today, but keeps the call site clean).
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    // Tracks whether THIS instance currently has a cursor pushed, so push/pop
    // stay strictly balanced. Without it, view-identity churn during frequent
    // re-renders (e.g. the input card's chips repainting every streamed token)
    // can deliver an `onHover(false)` with no matching `true`, popping a cursor
    // this view never pushed — corrupting the process-wide `NSCursor` stack and
    // leaving the wrong cursor stuck. `onDisappear` releases a push left
    // outstanding when a hovered view is torn down.
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    guard !pushed else { return }
                    NSCursor.pointingHand.push()
                    pushed = true
                } else {
                    guard pushed else { return }
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
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
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(36) }
    let boxed: Bool
    let background: Color
    let border: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if boxed {
            content
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.descriptionTreatment.body.padding.horizontal", inheriting: PromptInspectionStyle.metric("padding", theme.space.s16, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.descriptionTreatment.body.padding.vertical", inheriting: PromptInspectionStyle.metric("padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.36.elements.layout.descriptionTreatment.body.padding.horizontal").catalogLayoutTarget("component.library.36.elements.layout.descriptionTreatment.body.padding.vertical")
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                        .strokeBorder(border, lineWidth: theme.stroke.default)
                )
        } else {
            content
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.descriptionTreatment.body.paddingX", inheriting: PromptInspectionStyle.metric("padding", theme.space.s4, theme))).catalogLayoutTarget("component.library.36.elements.layout.descriptionTreatment.body.paddingX")
                .padding(.top, theme.space.s2)
                .padding(.bottom, theme.space.s4)
        }
    }
}

// MARK: - PromptCard

/// Generic prompt card. Both `SecretPromptCard` and `ClarifyPromptCard`
/// render through this so visual changes apply to all in-chat prompts
/// in one place.
struct PromptCard<BodyContent: View, InputRow: View>: View {
    let pillIcon: String
    let pillLabel: String.LocalizationValue
    let title: String?
    let descriptionMarkdown: String?
    let footnote: PromptCardFootnote?
    let onCancel: () -> Void
    // Slot names intentionally distinct from the `View.body` requirement
    // (`bodyContent` / `inputRow`) so they don't collide with SwiftUI's
    // protocol-required `body` property below.
    @ViewBuilder let bodyContent: () -> BodyContent
    @ViewBuilder let inputRow: () -> InputRow

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(36, enabled: componentEnabled) }

    var body: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.body.verticalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s16, theme))) {
            header
            // The header and actions stay put; only the middle scrolls, and
            // only once the card is taller than the space the host offers.
            // Both branches build the body slot, so its state must live
            // outside it or it resets when the window resizes across the fit.
            ViewThatFits(in: .vertical) {
                middle
                scrollingMiddle
            }
            inputRow()
        }.catalogLayoutTarget("component.library.36.elements.layout.promptCard.body.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.body.paddingX", inheriting: PromptInspectionStyle.metric("padding", theme.space.s24, theme))).catalogLayoutTarget("component.library.36.elements.layout.promptCard.body.paddingX")
        .padding(.top, theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.body.paddingY", inheriting: PromptInspectionStyle.metric("padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.36.elements.layout.promptCard.body.paddingY")
        .padding(.bottom, theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.body.paddingY2", inheriting: PromptInspectionStyle.metric("padding", theme.space.s24, theme))).catalogLayoutTarget("component.library.36.elements.layout.promptCard.body.paddingY2")
        .frame(minHeight: PromptInspectionStyle.metric("height", 0, theme))
        .background(overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous))
        .overlay(borderOverlay)
        .themeElevation(theme.elevation.overlay)
        .environment(\.theme, theme)
    }

    private var middle: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.middle.verticalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s16, theme))) {
            descriptionRegion
            bodyContent()
        }.catalogLayoutTarget("component.library.36.elements.layout.promptCard.middle.verticalGap")
    }

    /// The scroll view clips at its bounds, so the content is inset by a
    /// focus ring's outset to keep rings and borders whole.
    private var scrollingMiddle: some View {
        let room = SettingsFocusRingGeometry(theme: theme, controlRadius: 0).outset + 1
        return ScrollView {
            middle
                .padding(room)
        }
        .scrollBounceBehavior(.basedOnSize)
        .padding(.horizontal, -room)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.header.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s12, theme))) {
            pill
            Spacer()
            cancelButton
        }.catalogLayoutTarget("component.library.36.elements.layout.promptCard.header.horizontalGap")
    }

    private var pill: some View {
        StatusChip(L(pillLabel), icon: pillIcon)
            .environment(\.theme, PromptInspectionStyle.badgeTheme(environmentTheme))
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("Cancel", bundle: .module)
                .promptText(.label, fallback: .footnote, weight: 500, theme: theme)
                .foregroundColor(theme.text.tertiary)
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
                        background: theme.surface.raised,
                        border: theme.border.default
                    )
                )
        }
    }

    private var descriptionStack: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.descriptionStack.verticalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s12, theme))) {
            if let title {
                Text(title)
                    .promptText(.heading, fallback: .body, weight: 500, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let descriptionMarkdown {
                Text(parsedMarkdown(descriptionMarkdown))
                    .promptText(.body, fallback: .body, theme: theme)
                    .foregroundColor(theme.text.secondary)
                    .tint(theme.text.link)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let footnote {
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.descriptionStack.verticalGap2", inheriting: PromptInspectionStyle.metric("gap", theme.space.s8, theme))) {
                    if title != nil || descriptionMarkdown != nil {
                        ThemeHairlineDivider()
                    }
                    HStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.promptCard.descriptionStack.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s4, theme))) {
                        Image(systemName: footnote.icon)
                            .glyphSize(.micro)
                        Text(footnote.text, bundle: .module)
                            .promptText(.caption, fallback: .footnote, theme: theme)
                    }.catalogLayoutTarget("component.library.36.elements.layout.promptCard.descriptionStack.horizontalGap")
                    .foregroundColor(theme.text.tertiary)
                }.catalogLayoutTarget("component.library.36.elements.layout.promptCard.descriptionStack.verticalGap2")
            }
        }.catalogLayoutTarget("component.library.36.elements.layout.promptCard.descriptionStack.verticalGap")
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
            attributed.foregroundColor = theme.text.secondary
            return attributed
        }
        return AttributedString(raw)
    }

    // MARK: - Background & Border

    private var overlayBackground: some View {
        RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
            // The modal shell is not a selectable control. Keep its surface
            // while descendants handle their own translucent hover highlights.
            .fill(theme.assignedColor(PromptInspectionStyle.key + "background", fallback: theme.surface.overlay))
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
            .strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
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

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(36) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAppearing = false

    var body: some View {
        VStack(spacing: theme.space.s0) {
            Spacer(minLength: ChatView.headerHeight(theme) + theme.space.s12)

            card()
                .opacity(isAppearing ? 1 : 0)
                .offset(y: isAppearing ? 0 : (reduceMotion ? 0 : 30))
                .scaleEffect(isAppearing ? 1.0 : (reduceMotion ? 1.0 : 0.985))
                .padding(.bottom, ChatShellLayout.columnInset)
                // Same column as the thread and the composer card it
                // stands in for, centered in the chat column.
                .readableColumnRow()
        }
        .onAppear {
            if reduceMotion {
                isAppearing = true
            } else {
                withAnimation(theme.motion.springAnimation) {
                    isAppearing = true
                }
            }
        }
        .onExitCommand { onCancelDismiss() }
    }
}
