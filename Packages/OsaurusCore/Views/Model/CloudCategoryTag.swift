//
//  CloudCategoryTag.swift
//  osaurus
//

import SwiftUI

/// Category color is independent of the action accent. Opaque foreground /
/// background pairs retain readable labels over native selected list rows.
struct CloudCategoryTag: View {
    let category: CloudModelCategory
    @Environment(\.theme) private var theme

    private var palette: (foreground: String, background: String) {
        switch (category, theme.isDark) {
        case (.textToText, false): return ("1E40AF", "DBEAFE")
        case (.textToText, true): return ("BFDBFE", "1E3A5F")
        case (.imageToText, false): return ("115E59", "CCFBF1")
        case (.imageToText, true): return ("99F6E4", "153F3D")
        case (.image, false): return ("6B21A8", "F3E8FF")
        case (.image, true): return ("E9D5FF", "3D2458")
        case (.textToVideo, false): return ("92400E", "FEF3C7")
        case (.textToVideo, true): return ("FDE68A", "4C3519")
        case (.imageToVideo, false): return ("9F1239", "FFE4E6")
        case (.imageToVideo, true): return ("FECDD3", "4C2330")
        case (.all, false): return ("374151", "F3F4F6")
        case (.all, true): return ("E5E7EB", "374151")
        }
    }

    var body: some View {
        Text(LocalizedStringKey(category.label), bundle: .module)
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
            .foregroundStyle(Color(hex: palette.foreground))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: palette.background)))
    }
}
