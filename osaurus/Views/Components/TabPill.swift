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
  var action: () -> Void = {}

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title + (count.map { " (\($0))" } ?? ""))
          .font(.system(size: 14, weight: isSelected ? .medium : .regular))
          .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
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
