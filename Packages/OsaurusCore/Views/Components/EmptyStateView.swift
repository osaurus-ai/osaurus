//
//  EmptyStateView.swift
//  osaurus
//
//  Empty state placeholder component shown when no models match filters.
//  Provides contextual messages and actions based on the current state.
//

import SwiftUI

struct EmptyStateView: View {
    // MARK: - Dependencies

    @Environment(\.theme) private var theme

    // MARK: - Properties

    /// Currently selected tab to customize the message
    let selectedTab: ModelListTab

    /// Current search text (used to show "Clear search" button)
    let searchText: String

    /// Callback when user taps "Clear search"
    let onClearSearch: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(theme.tertiaryText)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                if !searchText.isEmpty {
                    Button(action: onClearSearch) {
                        Text("Clear search")
                            .font(.system(size: 13))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content Helpers

    /// Icon to display based on whether a search is active
    private var iconName: String {
        searchText.isEmpty ? "cube.box" : "magnifyingglass"
    }

    /// Title text that adapts to search state and selected tab
    private var title: String {
        if !searchText.isEmpty {
            return "No models found"
        }

        switch selectedTab {
        case .all:
            return "No models available"
        case .suggested:
            return "No suggested models"
        case .downloaded:
            return "No downloaded models"
        }
    }

    /// Description text that provides helpful context
    private var description: String {
        if !searchText.isEmpty {
            return "Try adjusting your search terms"
        }

        switch selectedTab {
        case .all:
            return "Language models will appear here"
        case .suggested:
            return "Suggested models will appear here"
        case .downloaded:
            return "Downloaded models will appear here"
        }
    }
}
