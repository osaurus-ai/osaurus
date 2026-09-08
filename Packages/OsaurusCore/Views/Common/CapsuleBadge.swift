//
//  CapsuleBadge.swift
//  osaurus
//
//  The one 9–10pt tinted capsule used for status/role chips everywhere:
//  "Active" on agent cards, "Remote" on paired cards, "YOU" / role / tier on
//  workspace rows. Replaces the half-dozen hand-rolled copies that had
//  drifted in size, padding, and tint opacity.
//

import SwiftUI

struct CapsuleBadge: View {
    /// Two weights: `.label` (10pt semibold, sentence case — "Active",
    /// "Remote", "Business") and `.tag` (9pt bold, UPPERCASE with tracking —
    /// "YOU", "OWNER", "YOURS").
    enum Style {
        case label
        case tag
    }

    /// Already-localized text (rendered verbatim).
    let text: String
    let tint: Color
    var icon: String?
    var style: Style = .label
    /// Already-localized tooltip.
    var help: String?

    init(
        _ text: String,
        tint: Color,
        icon: String? = nil,
        style: Style = .label,
        help: String? = nil
    ) {
        self.text = text
        self.tint = tint
        self.icon = icon
        self.style = style
        self.help = help
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: style == .tag ? 7 : 8, weight: .bold))
            }
            Text(text)
                .font(font)
                .kerning(style == .tag ? 0.5 : 0)
                .lineLimit(1)
        }
        .foregroundColor(tint)
        .textCase(style == .tag ? .uppercase : nil)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .help(help ?? "")
    }

    private var font: Font {
        switch style {
        case .label: return .system(size: 10, weight: .semibold)
        case .tag: return .system(size: 9, weight: .bold)
        }
    }
}
