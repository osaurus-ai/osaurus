//
//  PickerCardStyle.swift
//  Osaurus
//
//  Shared surface, typography and row chrome for the composer's anchored
//  cards (model picker, context budget, credits) so they read as one family.
//

import SwiftUI

enum PickerCardMetrics {
    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 16
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    static let rowCornerRadius: CGFloat = 8
    /// Leading/trailing inset of row content, section titles and footnotes
    /// inside a column; headings sit flush with the column edge.
    static let rowInset: CGFloat = 12
    /// Vertical gap between sections in a column.
    static let sectionSpacing: CGFloat = 10
    /// Height of a section sub-heading, including its bottom gap.
    static let sectionTitleHeight: CGFloat = 22
    /// Read-only label/value rows (token counts, balances) sit tighter than
    /// selectable rows.
    static let valueRowHeight: CGFloat = 26
    /// Width of the single-column info cards (context budget, credits).
    static let infoCardWidth: CGFloat = 300
    /// Gap between sections on the info cards, which have no dividers.
    static let infoSectionSpacing: CGFloat = 14
}

/// Type scale for the single-column info cards. Four sizes only: the
/// picker's heading, a hero figure, body rows, and captions.
extension ThemeProtocol {
    var pickerCardHeroSize: CGFloat { CGFloat(bodySize) + 10 }
    var pickerCardBodySize: CGFloat { CGFloat(smallBodySize) - 1 }
    var pickerCardCaptionSize: CGFloat { 11 }
}

extension View {
    /// The flat themed card surface: secondary background, continuous 16pt
    /// corners and the theme border. Cards in their own panel get the
    /// window server's shadow; `elevated` adds one for cards drawn inside
    /// the chat window (composer popups, voice input).
    func pickerCardSurface(elevated: Bool = false) -> some View {
        modifier(PickerCardSurfaceModifier(elevated: elevated))
    }

    /// Row chrome: inset content, minimum row height, and the rounded fill
    /// shown for a selected, hovered or focused row.
    func pickerCardRowChrome(highlighted: Bool, minHeight: CGFloat = PickerCardMetrics.rowHeight) -> some View {
        modifier(PickerCardRowChromeModifier(highlighted: highlighted, minHeight: minHeight))
    }
}

private struct PickerCardSurfaceModifier: ViewModifier {
    let elevated: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PickerCardMetrics.cornerRadius, style: .continuous)
        content
            .background(theme.secondaryBackground, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(theme.primaryBorder.opacity(theme.borderOpacity), lineWidth: theme.defaultBorderWidth)
            }
            .shadow(color: elevated ? theme.shadowColor.opacity(theme.isDark ? 0.35 : 0.12) : .clear, radius: 16, y: 6)
            .font(theme.font(size: CGFloat(theme.bodySize)))
            .foregroundStyle(theme.primaryText)
    }
}

/// Keyboard hints in a list card's heading ("↑↓ navigate  ↵ select  esc dismiss").
struct PickerCardKeyHints: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("↑↓ navigate  ↵ select  esc dismiss", bundle: .module)
            .font(theme.font(size: theme.pickerCardCaptionSize))
            .foregroundStyle(theme.tertiaryText)
            .lineLimit(1)
    }
}

private struct PickerCardRowChromeModifier: ViewModifier {
    let highlighted: Bool
    let minHeight: CGFloat
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PickerCardMetrics.rowInset)
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
            .background(
                highlighted ? theme.tertiaryBackground : .clear,
                in: RoundedRectangle(cornerRadius: PickerCardMetrics.rowCornerRadius, style: .continuous)
            )
    }
}

/// Column heading ("Provider", "Model", "Context").
struct PickerCardHeading<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(theme.font(size: CGFloat(theme.smallBodySize) + 2))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

extension PickerCardHeading where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title, accessory: { EmptyView() })
    }
}

/// Quiet sub-heading above a group of rows ("Thinking", "Sources").
struct PickerCardSectionTitle<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(title)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
        .font(theme.font(size: CGFloat(theme.smallBodySize) - 1, weight: .medium))
        .foregroundStyle(theme.tertiaryText)
        .padding(.horizontal, PickerCardMetrics.rowInset)
        .frame(height: PickerCardMetrics.sectionTitleHeight, alignment: .bottomLeading)
        .padding(.bottom, 2)
    }
}

extension PickerCardSectionTitle where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title, accessory: { EmptyView() })
    }
}

/// Small explanatory text under a section, aligned with row content.
struct PickerCardFootnote: View {
    let text: String
    var color: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        Text(verbatim: text)
            .font(theme.font(size: 11))
            .foregroundStyle(color ?? theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PickerCardMetrics.rowInset)
    }
}

/// Quiet inline link with its icon beside the text ("More models →").
struct PickerCardTextLink: View {
    let title: String
    let icon: String
    var focused = false
    /// Accent for a primary action; nil keeps the quiet subdued link.
    var tint: Color? = nil
    /// False lets two links share a row instead of each claiming the width.
    var fillsWidth = true
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    private var subduedTextColor: Color { theme.isDark ? theme.tertiaryText : theme.secondaryText }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).underline(hovered)
                    .foregroundStyle(tint ?? (hovered ? theme.primaryText : subduedTextColor))
                Image(systemName: icon).font(.system(size: 11)).accessibilityHidden(true)
            }
            .font(theme.font(size: CGFloat(theme.smallBodySize) - 1, weight: tint == nil ? .regular : .medium))
            .foregroundStyle(tint ?? (hovered ? theme.primaryText : theme.tertiaryText))
            .padding(.horizontal, PickerCardMetrics.rowInset)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if focused { Rectangle().fill(theme.secondaryText).frame(height: 1) }
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .onKeyPress(.return) { action(); return .handled }
    }
}
