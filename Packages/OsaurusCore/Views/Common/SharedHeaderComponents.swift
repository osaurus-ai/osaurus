//
//  SharedHeaderComponents.swift
//  osaurus
//
//  Shared header components used by chat windows.
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
    @State private var isPopoverPresented = false
    @Environment(\.theme) private var theme

    private var activeAgent: Agent {
        agents.first { $0.id == activeAgentId } ?? Agent.default
    }

    private func shortHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .replacingOccurrences(of: "\\.local$", with: "", options: .regularExpression)
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

    @ViewBuilder
    private func monogramAvatar(for agent: Agent, size: CGFloat) -> some View {
        if agent.isBuiltIn {
            ZStack {
                Circle()
                    .fill(theme.secondaryText.opacity(theme.isDark ? 0.12 : 0.08))
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundColor(theme.secondaryText.opacity(0.85))
            }
            .frame(width: size, height: size)
        } else {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: agentColorFor(agent.name),
                diameter: size,
                monogramFontSize: size * 0.45,
                borderWidth: 1.5
            )
        }
    }

    @ViewBuilder
    private func remoteAvatar(systemImage: String, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(theme.accentColorLight.opacity(theme.isDark ? 0.18 : 0.12))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(theme.accentColorLight)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var activeAvatar: some View {
        if activeDiscoveredAgent != nil {
            remoteAvatar(systemImage: "network", size: 22)
        } else if activeRelayAgent != nil {
            remoteAvatar(systemImage: "antenna.radiowaves.left.and.right", size: 22)
        } else {
            monogramAvatar(for: activeAgent, size: 22)
        }
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                activeAvatar

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
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            popoverContent
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(agents) { agent in
                        agentRow(agent)
                    }

                    if !discoveredAgents.isEmpty && onSelectDiscoveredAgent != nil {
                        sectionHeader(Text("On This Network", bundle: .module))
                        ForEach(discoveredAgents) { remote in
                            discoveredRow(remote)
                        }
                    }

                    if !pairedRelayAgents.isEmpty && onSelectRelayAgent != nil {
                        sectionHeader(Text("Paired", bundle: .module))
                        ForEach(pairedRelayAgents) { relay in
                            relayRow(relay)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)

            Divider().opacity(0.5)

            Button {
                isPopoverPresented = false
                AppDelegate.shared?.showManagementWindow(initialTab: .agents)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.badge.gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 22)
                    Text("Manage Agents...", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
        .background(theme.cardBackground)
    }

    private func sectionHeader(_ text: Text) -> some View {
        text
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(theme.tertiaryText)
            .tracking(0.5)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func agentRow(_ agent: Agent) -> some View {
        let isCurrent = agent.id == activeAgentId && !isRemoteActive
        return PopoverRow(
            isCurrent: isCurrent,
            onTap: {
                isPopoverPresented = false
                onSelectAgent(agent.id)
            }
        ) {
            monogramAvatar(for: agent, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name.isEmpty ? L("Untitled Agent") : agent.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                if !agent.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(agent.description)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private func discoveredRow(_ remote: DiscoveredAgent) -> some View {
        let isCurrent = activeDiscoveredAgent?.id == remote.id
        return PopoverRow(
            isCurrent: isCurrent,
            onTap: {
                isPopoverPresented = false
                onSelectDiscoveredAgent?(remote)
            }
        ) {
            remoteAvatar(systemImage: "network", size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(remote.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                let subtitle = [
                    remote.host.map(shortHost),
                    remote.agentDescription.isEmpty ? nil : remote.agentDescription,
                ].compactMap { $0 }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private func relayRow(_ relay: PairedRelayAgent) -> some View {
        let isCurrent = activeRelayAgent?.id == relay.id
        return PopoverRow(
            isCurrent: isCurrent,
            onTap: {
                isPopoverPresented = false
                onSelectRelayAgent?(relay)
            }
        ) {
            remoteAvatar(systemImage: "antenna.radiowaves.left.and.right", size: 26)
            Text(relay.name)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
        }
    }
}

private struct PopoverRow<Content: View>: View {
    let isCurrent: Bool
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                content()
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isCurrent
                            ? theme.accentColor.opacity(0.10)
                            : (isHovered ? theme.secondaryBackground.opacity(0.6) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
