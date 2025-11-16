//
//  ManagerHeader.swift
//  osaurus
//
//  Shared header with title and optional subtitle.
//

import SwiftUI

struct ManagerHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}
