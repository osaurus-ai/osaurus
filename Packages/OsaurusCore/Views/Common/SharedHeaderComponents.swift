//
//  SharedHeaderComponents.swift
//  osaurus
//
//  Shared header components used by both ChatView and WorkView.
//  Ensures consistent styling and behavior across modes.
//

import SwiftUI

// MARK: - Header Action Button

/// An icon-only button for the toolbar. Relies on the native toolbar item
/// pill for its background; only renders the icon with a hover color change.
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
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                .frame(width: 28, height: 28)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(Text(LocalizedStringKey(help), bundle: .module))
    }
}

// MARK: - Mode Toggle Button

/// Segmented toggle for switching between Chat and Work modes with sliding indicator.
struct ModeToggleButton: View {
    enum Mode { case chat, work }

    let currentMode: Mode
    var isDisabled: Bool = false
    let action: (Mode) -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            segment(icon: "bubble.left.and.bubble.right", label: "Chat", mode: .chat, isSelected: currentMode == .chat)
            segment(icon: "bolt.fill", label: "Work", mode: .work, isSelected: currentMode == .work)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .opacity(isDisabled ? 0.4 : 1.0)
        .disabled(isDisabled)
        .help(
            Text(
                LocalizedStringKey(
                    isDisabled
                        ? "Set up a model to use Work mode"
                        : (currentMode == .chat ? "Switch to Work mode" : "Switch to Chat mode")
                ),
                bundle: .module
            )
        )
    }

    @ViewBuilder
    private func segment(icon: String, label: String, mode: Mode, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .semibold))
        }
        .fixedSize()
        .foregroundColor(isSelected ? theme.primaryText : theme.tertiaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(0.8))
                    .shadow(color: theme.shadowColor.opacity(0.08), radius: 1.5, x: 0, y: 0.5)
                    .matchedGeometryEffect(id: "modeIndicator", in: animation)
            }
        }
        .contentShape(Rectangle())
        .animation(theme.springAnimation(), value: isSelected)
        .onTapGesture { action(mode) }
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
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? Color.red.opacity(0.9) : theme.secondaryText)
                .frame(width: 28, height: 28)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(Text("Close window", bundle: .module))
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
                .foregroundColor(isPinned || isHovered ? theme.accentColor : theme.secondaryText)
                .rotationEffect(.degrees(isPinned ? 0 : 45))
                .frame(width: 28, height: 28)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
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

// MARK: - Agent Pill

/// A capsule-shaped agent selector pill used in empty states.
/// Provides a dropdown menu to switch between agents.
struct AgentPill: View {
    let agents: [Agent]
    let activeAgentId: UUID
    let onSelectAgent: (UUID) -> Void
    var discoveredAgents: [DiscoveredAgent] = []
    var onSelectDiscoveredAgent: ((DiscoveredAgent) -> Void)? = nil
    var activeDiscoveredAgent: DiscoveredAgent? = nil
    var pairedRelayAgents: [PairedRelayAgent] = []
    var onSelectRelayAgent: ((PairedRelayAgent) -> Void)? = nil
    var activeRelayAgent: PairedRelayAgent? = nil

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    private var activeAgent: Agent {
        agents.first { $0.id == activeAgentId } ?? Agent.default
    }

    private func shortHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .replacingOccurrences(of: "\\.local$", with: "", options: .regularExpression)
    }

    private func label(for agent: DiscoveredAgent) -> String {
        var parts = [agent.name]
        if let host = agent.host { parts.append("(\(shortHost(host)))") }
        if !agent.agentDescription.isEmpty { parts.append("– \(agent.agentDescription)") }
        return parts.joined(separator: " ")
    }

    private var displayName: String {
        if let relay = activeRelayAgent { return relay.name }
        guard let discovered = activeDiscoveredAgent else { return activeAgent.name }
        if let host = discovered.host {
            return "\(discovered.name) (\(shortHost(host)))"
        }
        return discovered.name
    }

    private var isRemoteActive: Bool {
        activeDiscoveredAgent != nil || activeRelayAgent != nil
    }

    var body: some View {
        Menu {
            ForEach(agents) { agent in
                Button(action: { onSelectAgent(agent.id) }) {
                    HStack {
                        Text(agent.name)
                        if agent.id == activeAgentId && !isRemoteActive {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
            }

            if !discoveredAgents.isEmpty && onSelectDiscoveredAgent != nil {
                Divider()
                Section {
                    ForEach(discoveredAgents) { remote in
                        Button(action: { onSelectDiscoveredAgent?(remote) }) {
                            Label(
                                label(for: remote),
                                systemImage: activeDiscoveredAgent?.id == remote.id ? "checkmark" : "network"
                            )
                        }
                    }
                } header: {
                    Text("On This Network", bundle: .module)
                }
            }

            if !pairedRelayAgents.isEmpty && onSelectRelayAgent != nil {
                Divider()
                Section {
                    ForEach(pairedRelayAgents) { relay in
                        Button(action: { onSelectRelayAgent?(relay) }) {
                            Label(
                                relay.name,
                                systemImage: activeRelayAgent?.id == relay.id
                                    ? "checkmark" : "antenna.radiowaves.left.and.right"
                            )
                        }
                    }
                } header: {
                    Text("Paired", bundle: .module)
                }
            }

            Divider()

            Button(action: {
                AppDelegate.shared?.showManagementWindow(initialTab: .agents)
            }) {
                Label {
                    Text("Manage Agents...", bundle: .module)
                } icon: {
                    Image(systemName: "person.2.badge.gearshape")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRemoteActive ? "network" : "person.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)

                Text(displayName)
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
