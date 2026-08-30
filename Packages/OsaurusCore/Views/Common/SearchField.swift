//
//  SearchField.swift
//  osaurus
//
//  Reusable search field with magnifier and clear button.
//

import AppKit
import SwiftUI

struct SearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var width: CGFloat = 240
    /// Lets responsive toolbars use the remaining width while preserving the
    /// fixed-width default used by existing management screens.
    var fillsAvailableWidth: Bool = false
    /// When `true`, matches the metrics of adjacent 13pt control buttons
    /// (Sort/Filter pills) so the field lines up visually next to them.
    var compact: Bool = false

    /// Tracks IME composition so the placeholder hides while composing.
    @State private var isComposing: Bool = false

    private var fontSize: CGFloat { compact ? 12 : 14 }
    private var verticalPadding: CGFloat { compact ? 7 : 8 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: fontSize))
                .foregroundColor(theme.tertiaryText)

            ZStack(alignment: .leading) {
                // Custom placeholder for better visibility in light mode
                if text.isEmpty && !isComposing {
                    Text(localized: placeholder)
                        .font(.system(size: fontSize))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }
                IMEAwareTextField(
                    text: $text,
                    isComposing: $isComposing,
                    font: .systemFont(ofSize: fontSize),
                    textColor: NSColor(theme.primaryText)
                )
                .frame(height: fontSize + 4)
            }

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(width: fillsAvailableWidth ? nil : width)
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground)
        )
    }
}
