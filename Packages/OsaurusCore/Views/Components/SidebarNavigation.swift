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

struct SidebarNavigation<Content: View>: View {
    @Environment(\.theme) private var theme
    @Binding var selection: String
    let items: [SidebarItemData]
    let content: (String) -> Content

    @Namespace private var sidebarNamespace

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    SidebarItemView(
                        item: item,
                        isSelected: selection == item.id,
                        namespace: sidebarNamespace
                    ) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selection = item.id
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .frame(width: 200)
            .background(theme.sidebarBackground)

            // Divider
            Rectangle()
                .fill(theme.primaryBorder)
                .frame(width: 1)

            // Content area with crossfade transition
            ZStack {
                content(selection)
                    .id(selection)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: selection)
        }
    }
}

// MARK: - Sidebar Item View

private struct SidebarItemView: View {
    @Environment(\.theme) private var theme

    let item: SidebarItemData
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
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

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var selection = "models"

        var body: some View {
            SidebarNavigation(
                selection: $selection,
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
