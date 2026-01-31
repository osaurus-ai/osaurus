//
//  SharedSidebarComponents.swift
//  osaurus
//
//  Shared components for AgentTaskSidebar and ChatSessionSidebar.
//

import SwiftUI

// MARK: - Constants

private enum SidebarMetrics {
    static let width: CGFloat = 240
    static let searchFieldCornerRadius: CGFloat = 8
    static let rowCornerRadius: CGFloat = 8
    static let actionButtonSize: CGFloat = 24
    static let actionButtonCornerRadius: CGFloat = 5
}

// MARK: - Sidebar Container

/// Container with consistent sidebar styling and glass background support.
struct SidebarContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(width: SidebarMetrics.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { sidebarBackground }
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        ZStack {
            // Layer 1: Glass material (if enabled)
            if theme.glassEnabled {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }

            // Layer 2: Semi-transparent background
            Rectangle()
                .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.8 : 0.9))

            // Layer 3: Subtle accent gradient at top
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(theme.isDark ? 0.04 : 0.025),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
    }
}

// MARK: - Sidebar Search Field

/// Themed search field for sidebar filtering.
struct SidebarSearchField: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            searchIcon
            searchTextField
            clearButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(fieldBackground)
        .overlay(focusBorder)
        .animation(theme.animationQuick(), value: isFocused.wrappedValue)
        .animation(theme.animationQuick(), value: text.isEmpty)
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isFocused.wrappedValue ? theme.primaryText : theme.secondaryText.opacity(0.7))
    }

    private var searchTextField: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .focused(isFocused)
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        if !text.isEmpty {
            Button {
                withAnimation(theme.animationQuick()) {
                    text = ""
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: SidebarMetrics.searchFieldCornerRadius, style: .continuous)
            .fill(theme.isDark ? theme.primaryBackground.opacity(0.5) : theme.tertiaryBackground.opacity(0.8))
    }

    private var focusBorder: some View {
        RoundedRectangle(cornerRadius: SidebarMetrics.searchFieldCornerRadius, style: .continuous)
            .stroke(isFocused.wrappedValue ? theme.accentColor.opacity(0.3) : .clear, lineWidth: 1)
    }
}

// MARK: - Sidebar No Results View

/// View displayed when search yields no results.
struct SidebarNoResultsView: View {
    let searchQuery: String
    let onClear: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(theme.secondaryText.opacity(0.4))

            VStack(spacing: 4) {
                Text("No matches found")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText.opacity(0.8))

                Text("for \"\(searchQuery)\"")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Button(action: onClear) {
                Text("Clear search")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.accentColor.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

// MARK: - Sidebar Row Action Button

/// Small action button for sidebar rows (delete, rename, etc.).
struct SidebarRowActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                .frame(width: SidebarMetrics.actionButtonSize, height: SidebarMetrics.actionButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: SidebarMetrics.actionButtonCornerRadius, style: .continuous)
                        .fill(isHovered ? theme.accentColor.opacity(0.1) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SidebarMetrics.actionButtonCornerRadius, style: .continuous)
                        .strokeBorder(
                            isHovered ? theme.accentColor.opacity(0.2) : .clear,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Sidebar Row Background

/// Consistent row background based on selection and hover state.
struct SidebarRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // Background fill
            RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                .fill(backgroundColor)

            // Selected state: subtle accent gradient
            if isSelected {
                RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.08),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay(borderOverlay)
    }

    private var backgroundColor: Color {
        if isSelected {
            return theme.accentColor.opacity(0.12)
        } else if isHovered {
            return theme.secondaryBackground.opacity(0.6)
        }
        return .clear
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.25),
                            theme.accentColor.opacity(0.1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
        }
    }
}

// MARK: - Utilities

/// Formats a date as a relative time string (e.g., "2h ago", "yesterday").
func formatRelativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
