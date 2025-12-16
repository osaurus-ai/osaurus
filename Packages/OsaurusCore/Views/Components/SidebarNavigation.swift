//
//  SidebarNavigation.swift
//  osaurus
//
//  Modern sidebar navigation with animated selection and hover states.
//  Inspired by macOS System Settings.
//

import SwiftUI

// MARK: - Sidebar Item Model

struct SidebarItemData: Identifiable, Hashable {
    let id: String
    let icon: String
    let label: String
    var badge: Int?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SidebarItemData, rhs: SidebarItemData) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Sidebar Navigation View

struct SidebarNavigation<Content: View, Footer: View>: View {
    @Environment(\.theme) private var theme
    @Binding var selection: String
    @Binding var searchText: String
    let items: [SidebarItemData]
    let content: (String) -> Content
    let footer: () -> Footer

    @State private var isCollapsed = false
    @Namespace private var sidebarNamespace

    private var sidebarWidth: CGFloat {
        isCollapsed ? 64 : 200
    }

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

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: isCollapsed ? .center : .leading, spacing: isCollapsed ? 6 : 4) {
                // Toggle button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isCollapsed.toggle()
                    }
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: isCollapsed ? 44 : 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground.opacity(0.5))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .help(isCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
                .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .trailing)
                .padding(.bottom, isCollapsed ? 12 : 8)

                // Search field (only shown when expanded)
                if !isCollapsed {
                    SidebarSearchField(text: $searchText)
                        .padding(.bottom, 8)
                }

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

                Spacer()

                // Footer (hidden when collapsed for cleaner look)
                if !isCollapsed {
                    footer()
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 16)
            .padding(.horizontal, isCollapsed ? 8 : 12)
            .frame(width: sidebarWidth)
            .background(theme.sidebarBackground)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCollapsed)

            // Divider
            Rectangle()
                .fill(theme.primaryBorder)
                .frame(width: 1)
                .ignoresSafeArea(edges: .top)

            // Content area with crossfade transition
            ZStack {
                content(selection)
                    .id(selection)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: selection)
        }
        .ignoresSafeArea(edges: .top)
    }
}

// Convenience initializer without footer
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
                // Collapsed: icon only, centered with clean styling
                ZStack {
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                        .symbolRenderingMode(.hierarchical)

                    // Badge overlay for collapsed state
                    if let badge = item.badge, badge > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .offset(x: 12, y: -12)
                    }
                }
                .frame(width: 44, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            isSelected
                                ? theme.sidebarSelectedBackground
                                : (isHovering ? theme.tertiaryBackground.opacity(0.6) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .help(item.label)
            } else {
                // Expanded: full row
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
                        Text("\(badge)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.orange)
                            )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
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
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Sidebar Section Header

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

struct SidebarSearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isFocused ? theme.accentColor : theme.tertiaryText)

            ZStack(alignment: .leading) {
                // Custom placeholder for better visibility
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

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(isHovering ? theme.secondaryText : theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    isHovering = hovering
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused ? theme.accentColor.opacity(0.6) : theme.primaryBorder.opacity(0.5),
                            lineWidth: 1
                        )
                )
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Sidebar Update Button

struct SidebarUpdateButton: View {
    @Environment(\.theme) private var theme
    let updateAvailable: Bool
    let availableVersion: String?
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPulsing = false

    var body: some View {
        Button(action: action) {
            if updateAvailable {
                // Update available state - prominent styling
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)

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

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        // Base gradient background
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accentColor,
                                        theme.accentColor.opacity(0.8),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        // Pulsing glow effect
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.accentColor.opacity(0.3))
                            .blur(radius: 8)
                            .scaleEffect(isPulsing ? 1.05 : 1.0)
                            .opacity(isPulsing ? 0.8 : 0.4)

                        // Hover highlight
                        if isHovering {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.15))
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: theme.accentColor.opacity(0.4), radius: isPulsing ? 8 : 4, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }
            } else {
                // Normal state - subtle styling
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
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(updateAvailable ? "Install the latest update" : "Check for app updates")
        .animation(.easeOut(duration: 0.3), value: updateAvailable)
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
