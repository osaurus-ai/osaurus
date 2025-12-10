//
//  SearchField.swift
//  osaurus
//
//  Reusable search field with magnifier and clear button.
//

import SwiftUI

struct SearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    var placeholder: String
    var width: CGFloat = 240

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(theme.tertiaryText)

            ZStack(alignment: .leading) {
                // Custom placeholder for better visibility in light mode
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 14))
                    .foregroundColor(theme.primaryText)
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
        .padding(.vertical, 8)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground)
        )
    }
}
