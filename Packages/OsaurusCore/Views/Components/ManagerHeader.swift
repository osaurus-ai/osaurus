//
//  ManagerHeader.swift
//  osaurus
//
//  Unified header component for all management views.
//  Provides consistent styling for titles, actions, sub-tabs, and search.
//

import SwiftUI

// MARK: - Manager Header

/// A unified header component for management views.
/// Use the specific initializers for different configurations:
/// - `ManagerHeader(title:subtitle:)` for simple headers
/// - `ManagerHeaderWithActions` for headers with action buttons
/// - `ManagerHeaderWithTabs` for headers with tabs row
/// - `ManagerHeaderFull` for headers with both actions and tabs
struct ManagerHeader: View {
    @Environment(\.theme) private var theme

    let title: String
    let subtitle: String?
    let count: Int?

    init(title: String, subtitle: String? = nil, count: Int? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.count = count
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(theme.primaryText)

                        if let count = count {
                            Text("\(count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground)
                                )
                        }
                    }

                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }
}

// MARK: - Manager Header With Actions

/// Header with action buttons on the right side
struct ManagerHeaderWithActions<Actions: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let subtitle: String?
    let count: Int?
    @ViewBuilder let actions: Actions

    init(
        title: String,
        subtitle: String? = nil,
        count: Int? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(theme.primaryText)

                        if let count = count {
                            Text("\(count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground)
                                )
                        }
                    }

                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    actions
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }
}

// MARK: - Manager Header With Tabs

/// Header with a second row for tabs/search
struct ManagerHeaderWithTabs<Actions: View, TabsRow: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let subtitle: String?
    let count: Int?
    @ViewBuilder let actions: Actions
    @ViewBuilder let tabsRow: TabsRow

    init(
        title: String,
        subtitle: String? = nil,
        count: Int? = nil,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder tabsRow: () -> TabsRow
    ) {
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.actions = actions()
        self.tabsRow = tabsRow()
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(theme.primaryText)

                        if let count = count {
                            Text("\(count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground)
                                )
                        }
                    }

                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    actions
                }
            }

            tabsRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }
}

// MARK: - Header Primary Button

/// Accent-filled button for primary actions (Create, Add, etc.)
struct HeaderPrimaryButton: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String?
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor)
                    .opacity(isHovering ? 0.9 : 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Header Secondary Button

/// Subtle background button for secondary actions (Import, Reset, etc.)
struct HeaderSecondaryButton: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String?
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
                    .opacity(isHovering ? 0.8 : 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Header Icon Button

/// Icon-only button for compact actions (Refresh, etc.)
struct HeaderIconButton: View {
    @Environment(\.theme) private var theme

    let icon: String
    let action: () -> Void
    var isLoading: Bool = false
    var help: String? = nil

    @State private var isHovering = false

    init(_ icon: String, isLoading: Bool = false, help: String? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.isLoading = isLoading
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundColor(theme.secondaryText)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .opacity(isHovering ? 0.8 : 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isLoading)
        .help(help ?? "")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Header Tabs Row

/// Standard tabs row with AnimatedTabSelector and optional search
struct HeaderTabsRow<Tab: AnimatedTabItem>: View where Tab.AllCases: RandomAccessCollection {
    @Environment(\.theme) private var theme

    @Binding var selection: Tab
    var counts: [Tab: Int]?
    var badges: [Tab: Int]?
    @Binding var searchText: String
    var searchPlaceholder: String
    var showSearch: Bool

    init(
        selection: Binding<Tab>,
        counts: [Tab: Int]? = nil,
        badges: [Tab: Int]? = nil,
        searchText: Binding<String> = .constant(""),
        searchPlaceholder: String = "Search",
        showSearch: Bool = true
    ) {
        self._selection = selection
        self.counts = counts
        self.badges = badges
        self._searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.showSearch = showSearch
    }

    var body: some View {
        HStack(spacing: 12) {
            AnimatedTabSelector(
                selection: $selection,
                counts: counts,
                badges: badges
            )

            Spacer()

            if showSearch {
                SearchField(text: $searchText, placeholder: searchPlaceholder, width: 200)
            }
        }
    }
}

// Convenience initializer for tabs-only (no search)
extension HeaderTabsRow {
    init(
        selection: Binding<Tab>,
        counts: [Tab: Int]? = nil,
        badges: [Tab: Int]? = nil
    ) {
        self._selection = selection
        self.counts = counts
        self.badges = badges
        self._searchText = .constant("")
        self.searchPlaceholder = ""
        self.showSearch = false
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 0) {
        ManagerHeader(title: "Server", subtitle: "Developer tools and API reference")

        Divider()

        ManagerHeaderWithActions(
            title: "Personas",
            subtitle: "Create custom assistant personalities",
            count: 4
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh") {}
            HeaderSecondaryButton("Import", icon: "square.and.arrow.down") {}
            HeaderPrimaryButton("Create Persona", icon: "plus") {}
        }
    }
    .frame(width: 700)
    .background(Color.black)
    .environment(\.theme, DarkTheme())
}
