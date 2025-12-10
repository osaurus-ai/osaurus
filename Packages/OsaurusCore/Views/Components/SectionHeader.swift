//
//  SectionHeader.swift
//  osaurus
//
//  Reusable section header with title, description, and optional action button.
//

import SwiftUI

/// A consistent section header for sub-views within tabs.
/// Follows the pattern established in ProvidersView for MCP Providers.
struct SectionHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let description: String
    let trailing: Trailing

    init(
        title: String,
        description: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.description = description
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            trailing
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        SectionHeader(
            title: "Available Tools",
            description: "Tools from installed plugins and connected providers"
        )

        SectionHeader(
            title: "Plugin Repository",
            description: "Browse and install plugins to add new capabilities"
        ) {
            Button(action: {}) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Refresh")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    .padding(24)
    .background(Color.black.opacity(0.9))
    .environment(\.theme, DarkTheme())
}
