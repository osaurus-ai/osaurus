//
//  SharedHeaderComponents.swift
//  osaurus
//
//  Shared header components used by both ChatView and AgentView.
//  Ensures consistent styling and behavior across modes.
//

import SwiftUI

// MARK: - Header Action Button

/// A circular icon button used in the header for actions like sidebar toggle, new chat, etc.
struct HeaderActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background
                Circle()
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.6))

                // Subtle accent gradient on hover
                if isHovered {
                    Circle()
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

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
            }
            .frame(width: 30, height: 30)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.2 : 0.1),
                                theme.primaryBorder.opacity(isHovered ? 0.15 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.accentColor.opacity(0.12) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(help)
    }
}

// MARK: - Mode Toggle Button

/// Segmented toggle for switching between Chat and Agent modes with sliding indicator.
struct ModeToggleButton: View {
    enum Mode { case chat, agent }

    let currentMode: Mode
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme
    @Namespace private var animation

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                segment(icon: "bubble.left.and.bubble.right", label: "Chat", isSelected: currentMode == .chat)
                segment(icon: "bolt.fill", label: "Agent", isSelected: currentMode == .agent)
            }
            .padding(3)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.7))

                    // Subtle accent glow at top on hover
                    if isHovered {
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.06),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.18 : 0.12),
                                theme.primaryBorder.opacity(isHovered ? 0.12 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help(currentMode == .chat ? "Switch to Agent mode" : "Switch to Chat mode")
    }

    @ViewBuilder
    private func segment(icon: String, label: String, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(isSelected ? theme.primaryText : theme.tertiaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.primaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: theme.shadowColor.opacity(0.1), radius: 2, x: 0, y: 1)
                    .matchedGeometryEffect(id: "modeIndicator", in: animation)
            }
        }
        .animation(theme.springAnimation(), value: isSelected)
    }
}

// MARK: - Mode Indicator Badge

/// A badge showing the current mode (model name for chat, "Agent Mode" for agent).
struct ModeIndicatorBadge: View {
    enum Style {
        case model(name: String)
        case agent
    }

    let style: Style

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            switch style {
            case .model(let name):
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            case .agent:
                Image(systemName: "bolt.circle.fill")
                    .foregroundColor(.orange)
                Text("Agent Mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(style.backgroundColor.opacity(0.15))
        )
    }
}

extension ModeIndicatorBadge.Style {
    var backgroundColor: Color {
        switch self {
        case .model:
            return .green
        case .agent:
            return .orange
        }
    }
}

// MARK: - Settings Button

struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        HeaderActionButton(icon: "gearshape.fill", help: "Settings", action: action)
    }
}

// MARK: - Close Button

struct CloseButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.6))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.red.opacity(0.1),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isHovered ? Color.red.opacity(0.9) : theme.secondaryText)
            }
            .frame(width: 30, height: 30)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.2 : 0.1),
                                (isHovered ? Color.red : theme.primaryBorder).opacity(isHovered ? 0.2 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? Color.red.opacity(0.15) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help("Close window")
    }
}

// MARK: - Pin Button

struct PinButton: View {
    let windowId: UUID

    @State private var isHovered = false
    @State private var isPinned = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            isPinned.toggle()
            ChatWindowManager.shared.setWindowPinned(id: windowId, pinned: isPinned)
        } label: {
            ZStack {
                Circle()
                    .fill(theme.secondaryBackground.opacity(isHovered || isPinned ? 0.9 : 0.6))

                if isHovered || isPinned {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(isPinned ? 0.12 : 0.08),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isPinned || isHovered ? theme.accentColor : theme.secondaryText)
                    .rotationEffect(.degrees(isPinned ? 0 : 45))
            }
            .frame(width: 30, height: 30)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered || isPinned ? 0.2 : 0.1),
                                (isPinned ? theme.accentColor : theme.primaryBorder).opacity(
                                    isHovered || isPinned ? 0.2 : 0.08
                                ),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isPinned || isHovered ? theme.accentColor.opacity(0.12) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(isPinned ? "Unpin from top" : "Pin to top")
        .animation(theme.springAnimation(), value: isPinned)
    }
}

// MARK: - Persona Pill

/// A capsule-shaped persona selector pill used in empty states.
/// Provides a dropdown menu to switch between personas.
struct PersonaPill: View {
    let personas: [Persona]
    let activePersonaId: UUID
    let onSelectPersona: (UUID) -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    private var activePersona: Persona {
        personas.first { $0.id == activePersonaId } ?? Persona.default
    }

    var body: some View {
        Menu {
            ForEach(personas) { persona in
                Button(action: { onSelectPersona(persona.id) }) {
                    HStack {
                        Text(persona.name)
                        if persona.id == activePersonaId {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
            }

            Divider()

            Button(action: {
                AppDelegate.shared?.showManagementWindow(initialTab: .personas)
            }) {
                Label("Manage Personas...", systemImage: "person.2.badge.gearshape")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)

                Text(activePersona.name)
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(theme.primaryText)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isHovered ? theme.secondaryText : theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Capsule()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.65))

                    if isHovered {
                        Capsule()
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
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.2 : 0.12),
                                (isHovered ? theme.accentColor : theme.primaryBorder).opacity(isHovered ? 0.25 : 0.15),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.accentColor.opacity(0.1) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
