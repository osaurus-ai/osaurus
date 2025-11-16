//
//  InfoRow.swift
//  osaurus
//
//  Simple label-value pair component used in detail views.
//  Provides consistent formatting for displaying model metadata.
//

import SwiftUI

/// The label is styled as secondary text and the value as primary text.
struct InfoRow: View {
    // MARK: - Dependencies

    @Environment(\.theme) private var theme

    // MARK: - Properties

    /// Label text (shown on the left in secondary color)
    let label: String

    /// Value text (shown on the right in primary color)
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }
}
