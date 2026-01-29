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
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(theme.animationQuick(), value: isHovered)
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

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
        .help("Settings")
    }
}

// MARK: - Close Button

struct CloseButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
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
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isPinned ? theme.accentColor : (isHovered ? theme.primaryText : theme.secondaryText))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
                .rotationEffect(.degrees(isPinned ? 0 : 45))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
        .help(isPinned ? "Unpin from top" : "Pin to top")
        .animation(theme.animationQuick(), value: isPinned)
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
                    .foregroundColor(theme.secondaryText)

                Text(activePersona.name)
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(theme.primaryText)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.6))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isHovered
                            ? theme.accentColor.opacity(0.3)
                            : theme.primaryBorder.opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }
}
