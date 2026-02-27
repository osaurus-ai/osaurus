//
//  SidebarNavigation.swift
//  osaurus
//
//  A reusable sidebar navigation component with collapsible state,
//  animated selection, hover effects, and search functionality.
//  Inspired by macOS System Settings.
//

import SwiftUI

// MARK: - Sidebar Item Data

/// Data model representing a single item in the sidebar navigation.
struct SidebarItemData: Identifiable, Hashable {
    let id: String
    let icon: String
    let label: String
    var badge: Int?
    var badgeHighlight: Bool = false

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SidebarItemData, rhs: SidebarItemData) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Layout Constants

private enum SidebarLayout {
    static let expandedWidth: CGFloat = 200
    static let collapsedWidth: CGFloat = 64
    static let topPadding: CGFloat = 26
    static let bottomPadding: CGFloat = 16
    static let expandedHorizontalPadding: CGFloat = 12
    static let collapsedHorizontalPadding: CGFloat = 8
    static let expandedItemSpacing: CGFloat = 4
    static let collapsedItemSpacing: CGFloat = 6
}

// MARK: - Sidebar Navigation

/// A sidebar navigation container that displays a list of items with selection state,
/// optional badges, and a content area that changes based on selection.
struct SidebarNavigation<Content: View, Footer: View>: View {

    // MARK: Properties

    @Environment(\.theme) private var theme
    @Binding var selection: String
    @Binding var searchText: String
    let items: [SidebarItemData]
    let content: (String) -> Content
    let footer: () -> Footer

    @State private var isCollapsed = false
    @State private var canScrollDown = true
    @Namespace private var sidebarNamespace

    private var sidebarWidth: CGFloat {
        isCollapsed ? SidebarLayout.collapsedWidth : SidebarLayout.expandedWidth
    }

    // MARK: Initialization

    init(
        selection: Binding<String>,
        searchText: Binding<String>,
        items: [SidebarItemData],
        @ViewBuilder content: @escaping (String) -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self._selection = selection
        self._searchText = searchText
        self.items = items
        self.content = content
        self.footer = footer
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            divider
            contentArea
        }
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Sidebar Components

private extension SidebarNavigation {

    var sidebar: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 0) {
            collapseToggle
            if !isCollapsed { searchField }
            itemList
            if !isCollapsed {
                footer()
                    .padding(.top, 8)
                    .overlay(alignment: .top) { footerScrollShadow }
            }
        }
        .padding(.top, SidebarLayout.topPadding)
        .padding(.bottom, SidebarLayout.bottomPadding)
        .padding(
            .horizontal,
            isCollapsed ? SidebarLayout.collapsedHorizontalPadding : SidebarLayout.expandedHorizontalPadding
        )
        .frame(width: sidebarWidth)
        .background(theme.sidebarBackground)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCollapsed)
    }

    var collapseToggle: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isCollapsed.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: isCollapsed ? 44 : 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground.opacity(0.5))
                )
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .trailing)
        .padding(.bottom, isCollapsed ? 12 : 8)
    }

    var searchField: some View {
        SettingsSidebarSearchField(text: $searchText)
            .padding(.bottom, 8)
    }

    var itemList: some View {
        ScrollView {
            LazyVStack(
                alignment: isCollapsed ? .center : .leading,
                spacing: isCollapsed ? SidebarLayout.collapsedItemSpacing : SidebarLayout.expandedItemSpacing
            ) {
                ForEach(items) { item in
                    SidebarItemView(
                        item: item,
                        isSelected: selection == item.id,
                        isCollapsed: isCollapsed,
                        namespace: sidebarNamespace
                    ) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selection = item.id
                        }
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .onAppear { canScrollDown = false }
                    .onDisappear { canScrollDown = true }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    var footerScrollShadow: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.18), location: 0),
                .init(color: Color.black.opacity(0.06), location: 0.5),
                .init(color: Color.black.opacity(0), location: 1),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: 24)
        .offset(y: -24)
        .opacity(canScrollDown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: canScrollDown)
        .allowsHitTesting(false)
    }

    var divider: some View {
        Rectangle()
            .fill(theme.primaryBorder)
            .frame(width: 1)
            .ignoresSafeArea(edges: .top)
    }

    var contentArea: some View {
        ZStack {
            content(selection)
                .id(selection)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: selection)
    }
}

// MARK: - Convenience Initializer (No Footer)

extension SidebarNavigation where Footer == EmptyView {
    init(
        selection: Binding<String>,
        searchText: Binding<String>,
        items: [SidebarItemData],
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self._selection = selection
        self._searchText = searchText
        self.items = items
        self.content = content
        self.footer = { EmptyView() }
    }
}

// MARK: - Sidebar Item View

/// Individual item row in the sidebar with selection and hover states.
private struct SidebarItemView: View {

    @Environment(\.theme) private var theme

    let item: SidebarItemData
    let isSelected: Bool
    let isCollapsed: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            if isCollapsed {
                collapsedContent
            } else {
                expandedContent
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: Collapsed State

    private var collapsedContent: some View {
        ZStack {
            Image(systemName: item.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                .symbolRenderingMode(.hierarchical)

            if item.badge != nil {
                collapsedBadge
            }
        }
        .frame(width: 44, height: 40)
        .background(collapsedBackground)
        .overlay(collapsedBorder)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(item.label)
    }

    private var collapsedBadge: some View {
        Circle()
            .fill(item.badgeHighlight ? theme.accentColor : theme.tertiaryBackground)
            .overlay(
                Circle().stroke(
                    item.badgeHighlight ? theme.accentColor.opacity(0.5) : theme.primaryBorder.opacity(0.5),
                    lineWidth: 0.5
                )
            )
            .frame(width: 8, height: 8)
            .offset(x: 12, y: -12)
    }

    private var collapsedBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                isSelected
                    ? theme.sidebarSelectedBackground
                    : (isHovering ? theme.tertiaryBackground.opacity(0.6) : Color.clear)
            )
    }

    private var collapsedBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(isSelected ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
    }

    // MARK: Expanded State

    private var expandedContent: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                .frame(width: 24)

            Text(item.label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

            Spacer()

            if let badge = item.badge, badge > 0 {
                expandedBadge(count: badge)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(expandedBackground)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func expandedBadge(count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(item.badgeHighlight ? .white : theme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(item.badgeHighlight ? theme.accentColor : theme.tertiaryBackground))
    }

    private var expandedBackground: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.sidebarSelectedBackground)
                    .matchedGeometryEffect(id: "sidebar_selection", in: namespace)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground.opacity(0.5))
            }
        }
    }
}

// MARK: - Sidebar Section Header

/// Optional section header for grouping sidebar items.
struct SidebarSectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

// MARK: - Sidebar Search Field

/// Search field component for the settings sidebar.
private struct SettingsSidebarSearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    @FocusState private var isFocused: Bool
    @State private var isClearHovering = false

    var body: some View {
        HStack(spacing: 8) {
            searchIcon
            textField
            if !text.isEmpty { clearButton }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(fieldBackground)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isFocused ? theme.accentColor : theme.tertiaryText)
    }

    private var textField: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text("Search Settings")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .focused($isFocused)
        }
    }

    private var clearButton: some View {
        Button {
            text = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(isClearHovering ? theme.secondaryText : theme.tertiaryText)
        }
        .buttonStyle(.plain)
        .onHover { isClearHovering = $0 }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.tertiaryBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused ? theme.accentColor.opacity(0.6) : theme.primaryBorder.opacity(0.5),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - Sidebar Update Button

/// Footer button that shows update status and triggers update checks.
struct SidebarUpdateButton: View {
    @Environment(\.theme) private var theme

    let updateAvailable: Bool
    let availableVersion: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            if updateAvailable {
                updateAvailableContent
            } else {
                checkForUpdatesContent
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(updateAvailable ? "Install the latest update" : "Check for app updates")
        .animation(.easeOut(duration: 0.2), value: updateAvailable)
    }

    private var updateAvailableContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 16, weight: .medium))

            VStack(alignment: .leading, spacing: 2) {
                Text("Update Available")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                if let version = availableVersion {
                    Text("v\(version)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .opacity(0.8)
                }
            }

            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? theme.accentColor.opacity(0.9) : theme.accentColor)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var checkForUpdatesContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 14, weight: .medium))

            Text("Check for Updates")
                .font(.system(size: 12, weight: .medium))

            Spacer()
        }
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? theme.tertiaryBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var selection = "models"
        @State private var searchText = ""

        var body: some View {
            SidebarNavigation(
                selection: $selection,
                searchText: $searchText,
                items: [
                    SidebarItemData(id: "models", icon: "cube.box.fill", label: "Models"),
                    SidebarItemData(id: "tools", icon: "wrench.and.screwdriver.fill", label: "Tools", badge: 2),
                    SidebarItemData(id: "settings", icon: "gearshape.fill", label: "Settings"),
                ]
            ) { selected in
                Text("Content for \(selected)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 800, height: 600)
        }
    }

    return PreviewWrapper()
}
