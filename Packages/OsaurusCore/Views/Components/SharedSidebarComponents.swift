//
//  SharedSidebarComponents.swift
//  osaurus
//
//  Shared components for AgentTaskSidebar and ChatSessionSidebar.
//

import SwiftUI

// MARK: - Sidebar Style Constants

/// Centralized styling constants for sidebar components (similar to ToastStyle).
enum SidebarStyle {
    // MARK: Layout
    static let width: CGFloat = 240
    static let cornerRadius: CGFloat = 14
    static let rowCornerRadius: CGFloat = 8
    static let searchFieldCornerRadius: CGFloat = 8
    static let actionButtonSize: CGFloat = 24
    static let actionButtonCornerRadius: CGFloat = 5

    // MARK: Glass Background
    static let glassOpacityDark: Double = 0.82
    static let glassOpacityLight: Double = 0.90

    // MARK: Accent Gradient
    static let accentGradientOpacityDark: Double = 0.06
    static let accentGradientOpacityLight: Double = 0.04

    // MARK: Border
    static let edgeLightOpacityDark: Double = 0.18
    static let edgeLightOpacityLight: Double = 0.28
    static let borderOpacityDark: Double = 0.14
    static let borderOpacityLight: Double = 0.22

    // MARK: Accent Edge
    static let accentEdgeHoverOpacity: Double = 0.18
    static let accentEdgeNormalOpacity: Double = 0.10
}

// MARK: - Sidebar Container

/// Container with consistent sidebar styling and glass background support.
/// Supports edge-attached mode for seamless integration with parent views.
struct SidebarContainer<Content: View>: View {
    /// The edge this sidebar is attached to (affects corner radius)
    let attachedEdge: Edge?

    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    init(attachedEdge: Edge? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.attachedEdge = attachedEdge
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(width: SidebarStyle.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { SidebarBackground() }
        .clipShape(containerShape)
        .overlay(SidebarBorder(attachedEdge: attachedEdge))
    }

    private var containerShape: UnevenRoundedRectangle {
        let radius = SidebarStyle.cornerRadius
        switch attachedEdge {
        case .leading:
            // Attached to leading edge - round only leading corners
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .trailing:
            // Attached to trailing edge - round only trailing corners
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        case .top, .bottom, .none:
            // Not attached or attached to top/bottom - round all corners
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        }
    }
}

// MARK: - Sidebar Background

/// Glass-based background for sidebar with accent gradient (similar to ToastBackground).
struct SidebarBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // Layer 1: Glass material (if enabled)
            if theme.glassEnabled {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }

            // Layer 2: Semi-transparent card background
            theme.cardBackground.opacity(
                theme.glassEnabled
                    ? (theme.isDark ? SidebarStyle.glassOpacityDark : SidebarStyle.glassOpacityLight)
                    : 1.0
            )

            // Layer 3: Accent gradient for visual polish
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(
                        theme.isDark ? SidebarStyle.accentGradientOpacityDark : SidebarStyle.accentGradientOpacityLight
                    ),
                    Color.clear,
                    theme.primaryBackground.opacity(theme.isDark ? 0.06 : 0.03),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Sidebar Border

/// Gradient border with accent edge highlight for sidebar (similar to ToastBorder)
struct SidebarBorder: View {
    @Environment(\.theme) private var theme

    let attachedEdge: Edge?

    init(attachedEdge: Edge? = nil) {
        self.attachedEdge = attachedEdge
    }

    var body: some View {
        borderShape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(
                            theme.isDark ? SidebarStyle.edgeLightOpacityDark : SidebarStyle.edgeLightOpacityLight
                        ),
                        theme.primaryBorder.opacity(
                            theme.isDark ? SidebarStyle.borderOpacityDark : SidebarStyle.borderOpacityLight
                        ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay(accentEdge)
    }

    private var borderShape: UnevenRoundedRectangle {
        let radius = SidebarStyle.cornerRadius
        switch attachedEdge {
        case .leading:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .trailing:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        case .top, .bottom, .none:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        }
    }

    private var accentEdge: some View {
        borderShape
            .strokeBorder(
                theme.accentColor.opacity(SidebarStyle.accentEdgeNormalOpacity),
                lineWidth: 1
            )
            .mask(
                LinearGradient(
                    colors: [Color.white, Color.white.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
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
        RoundedRectangle(cornerRadius: SidebarStyle.searchFieldCornerRadius, style: .continuous)
            .fill(theme.isDark ? theme.primaryBackground.opacity(0.5) : theme.tertiaryBackground.opacity(0.8))
    }

    private var focusBorder: some View {
        RoundedRectangle(cornerRadius: SidebarStyle.searchFieldCornerRadius, style: .continuous)
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
                .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: SidebarStyle.actionButtonCornerRadius, style: .continuous)
                        .fill(isHovered ? theme.accentColor.opacity(0.1) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SidebarStyle.actionButtonCornerRadius, style: .continuous)
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

/// Enhanced row background with glass effects and gradient borders (similar to ToastBackground styling).
struct SidebarRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool

    @Environment(\.theme) private var theme

    private var cornerRadius: CGFloat { SidebarStyle.rowCornerRadius }

    var body: some View {
        ZStack {
            // Layer 1: Background fill with glass effect
            if isSelected || isHovered {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            }

            // Layer 2: Accent gradient overlay for selected/hovered states
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(theme.isDark ? 0.12 : 0.08),
                                theme.accentColor.opacity(theme.isDark ? 0.04 : 0.02),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else if isHovered {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryBackground.opacity(theme.isDark ? 0.08 : 0.04),
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
            return theme.accentColor.opacity(theme.isDark ? 0.15 : 0.12)
        } else if isHovered {
            return theme.secondaryBackground.opacity(theme.isDark ? 0.5 : 0.6)
        }
        return .clear
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isSelected {
            // Selected state: gradient border with accent highlight
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(theme.isDark ? 0.35 : 0.28),
                            theme.accentColor.opacity(theme.isDark ? 0.15 : 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .overlay(selectedAccentEdge)
        } else if isHovered {
            // Hovered state: subtle gradient border
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glassEdgeLight.opacity(theme.isDark ? 0.12 : 0.18),
                            theme.primaryBorder.opacity(theme.isDark ? 0.08 : 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    private var selectedAccentEdge: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                theme.accentColor.opacity(SidebarStyle.accentEdgeHoverOpacity),
                lineWidth: 1
            )
            .mask(
                LinearGradient(
                    colors: [Color.white, Color.white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

// MARK: - Utilities

/// Formats a date as a relative time string (e.g., "2h ago", "yesterday").
func formatRelativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
