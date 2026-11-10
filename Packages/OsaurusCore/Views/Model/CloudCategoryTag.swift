//
//  CloudCategoryTag.swift
//  osaurus
//

import SwiftUI

/// Category color is independent of the action accent.
struct CloudCategoryTag: View {
    let category: CloudModelCategory
    @Environment(\.theme) private var theme

    var body: some View {
        StatusChip(
            String(localized: String.LocalizationValue(category.label), bundle: .module),
            tint: category.tagColor(isDark: theme.isDark)
        )
    }
}
