//
//  TabPill.swift
//  osaurus
//
//  Pill-styled tab button with optional count.
//

import SwiftUI

struct TabPill: View {
    @Environment(\.theme) private var theme
    let title: String
    let isSelected: Bool
    let count: Int?
    var badge: Int? = nil
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title + (count.map { " (\($0))" } ?? ""))
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                // Update badge
                if let badge = badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange)
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.tertiaryBackground : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
