//
//  ToggleRow.swift
//  osaurus
//
//  Title + subtitle with trailing toggle, styled as a glass row.
//

import SwiftUI

struct ToggleRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        GlassListRow {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Toggle("", isOn: $isOn)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
            }
        }
    }
}
