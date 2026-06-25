//
//  SharedHeaderComponents.swift
//  osaurus
//
//  Shared header components used by chat windows.
//  Ensures consistent styling and behavior across modes.
//

import AppKit
import SwiftUI

// MARK: - Header Action Button

/// An icon-only button for the toolbar. On macOS 26+ each icon sits on its
/// own circular Liquid Glass capsule; on earlier systems it relies on the
/// native toolbar item pill for its background and only renders the icon
/// with a hover color change.
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
                .liquidGlassCircle()
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

// MARK: - Liquid Glass

extension View {
    @ViewBuilder
    func liquidGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self
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
        .localizedHelp("Close window")
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
                .liquidGlassCircle()
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(isPinned ? Text(localized: "Unpin from top") : Text(localized: "Pin to top"))
        .animation(theme.springAnimation(), value: isPinned)
    }
}

// MARK: - Agent Picker Keyboard Controller

/// Drives arrow-key / Enter / Esc navigation for the agent picker popover.
/// Held as a `@StateObject` so the long-lived key-monitor closure captures a
/// stable class reference instead of a stale `View` value — mirroring the
/// coordinator pattern the model picker uses.
@MainActor
final class AgentPickerKeyboardController: ObservableObject {
    /// Index (into the popover's flattened item list) the user has arrowed to.
    @Published var highlightedIndex: Int?

    private var monitor: Any?
    private var itemCount: Int = 0
    private var onActivate: ((Int) -> Void)?
    private var onDismiss: (() -> Void)?
    /// Index to resume arrow-key navigation from on the first key press, set to
    /// the current selection. Held separately from `highlightedIndex` so opening
    /// the popover doesn't paint a focus border on the selected row (it's already
    /// marked by its checkmark) — the highlight only appears once the user
    /// actually navigates.
    private var pendingStartIndex: Int?

    /// Begin monitoring keys for an open popover. Safe to call repeatedly; the
    /// monitor is installed once and the callbacks/count are refreshed.
    func start(
        itemCount: Int,
        initialIndex: Int?,
        onActivate: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.itemCount = itemCount
        // Start with nothing highlighted so the selected row isn't bordered on
        // open; remember where to resume arrow-key navigation from.
        self.highlightedIndex = nil
        self.pendingStartIndex = initialIndex
        self.onActivate = onActivate
        self.onDismiss = onDismiss

        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125:  // down arrow
                self.move(by: 1)
                return nil
            case 126:  // up arrow
                self.move(by: -1)
                return nil
            case 36, 76:  // return / numpad enter
                // Activate the highlighted row, or — if the user hasn't arrowed
                // yet — the current selection (so open + Enter confirms it).
                if let index = self.highlightedIndex ?? self.pendingStartIndex {
                    self.onActivate?(index)
                    return nil
                }
                return event
            case 53:  // escape
                self.onDismiss?()
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        highlightedIndex = nil
        pendingStartIndex = nil
        onActivate = nil
        onDismiss = nil
    }

    private func move(by offset: Int) {
        guard itemCount > 0 else { return }
        if let current = highlightedIndex {
            highlightedIndex = max(0, min(itemCount - 1, current + offset))
        } else if let resume = pendingStartIndex {
            // First arrow press after open: continue from the current selection.
            highlightedIndex = max(0, min(itemCount - 1, resume + offset))
            pendingStartIndex = nil
        } else {
            highlightedIndex = offset > 0 ? 0 : itemCount - 1
        }
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
    /// Mascot avatar id of the active remote agent (Mode 2), surfaced from its
    /// live metadata over the Secure Channel. nil → monogram on the remote
    /// name, so the connected pill matches the chat hero/thread identity.
    var activeRemoteAgentAvatar: String? = nil
    /// Optional callback to open the active agent's settings via the inline
    /// gear button. When `nil`, the gear is hidden entirely so the pill
    /// collapses back to its original single-button form.
    var onOpenActiveAgentSettings: (() -> Void)? = nil
    /// Optional callback to open the active *remote* agent's detail/settings
    /// view (connection, activity, source). When a discovered/relay agent is
    /// active the gear routes here instead of `onOpenActiveAgentSettings`, so
    /// remote settings live in the same toolbar slot as local ones rather than
    /// floating inline beside the chat hero.
    var onOpenRemoteAgentSettings: (() -> Void)? = nil
    /// Increment to programmatically open the agent picker popover (e.g. from
    /// the `/agent` slash command). Each change pops the popover open.
    var openPickerTrigger: Int = 0

    @State private var isHovered = false
    @State private var isGearHovered = false
    @State private var isPopoverPresented = false
    @StateObject private var keyboard = AgentPickerKeyboardController()
    @Environment(\.theme) private var theme

    // MARK: - Keyboard Navigation Items

    /// Discovered agents that actually render as selectable rows (the section
    /// is hidden when no selection handler is wired).
    private var selectableDiscoveredAgents: [DiscoveredAgent] {
        onSelectDiscoveredAgent != nil ? discoveredAgents : []
    }

    /// Paired relay agents that actually render as selectable rows.
    private var selectableRelayAgents: [PairedRelayAgent] {
        onSelectRelayAgent != nil ? pairedRelayAgents : []
    }

    /// Total number of arrow-navigable rows, in render order:
    /// local agents → discovered → relay.
    private var menuItemCount: Int {
        agents.count + selectableDiscoveredAgents.count + selectableRelayAgents.count
    }

    /// Flat index of the currently-active item so arrow keys start from the
    /// user's current selection rather than the top of the list.
    private var initialHighlightIndex: Int? {
        if let relay = activeRelayAgent,
            let i = selectableRelayAgents.firstIndex(where: { $0.id == relay.id })
        {
            return agents.count + selectableDiscoveredAgents.count + i
        }
        if let discovered = activeDiscoveredAgent,
            let i = selectableDiscoveredAgents.firstIndex(where: { $0.id == discovered.id })
        {
            return agents.count + i
        }
        if let i = agents.firstIndex(where: { $0.id == activeAgentId }) {
            return i
        }
        return agents.isEmpty ? nil : 0
    }

    /// Activate the row at `index` in the flattened list (Enter key path).
    private func activateMenuItem(at index: Int) {
        let agentCount = agents.count
        let discoveredCount = selectableDiscoveredAgents.count
        if index < agentCount {
            isPopoverPresented = false
            onSelectAgent(agents[index].id)
        } else if index < agentCount + discoveredCount {
            let remote = selectableDiscoveredAgents[index - agentCount]
            isPopoverPresented = false
            onSelectDiscoveredAgent?(remote)
        } else if index < menuItemCount {
            let relay = selectableRelayAgents[index - agentCount - discoveredCount]
            isPopoverPresented = false
            onSelectRelayAgent?(relay)
        }
    }

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
        guard let discovered = activeDiscoveredAgent else { return activeAgent.displayName }
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
            // Mirror `NativeMessageCellView`'s mascot resolution so the
            // built-in default agent gets its branded image (e.g. the
            // green dinosaur). Falls back to the generic person glyph
            // when the agent has no `avatar` id or the asset is missing.
            if let mascot = builtInMascotImage(for: agent) {
                Image(nsImage: mascot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(theme.secondaryText.opacity(theme.isDark ? 0.12 : 0.08))
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                }
                .frame(width: size, height: size)
            }
        } else {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: agentColorFor(agent.name),
                diameter: size,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: size * 0.45,
                borderWidth: 0
            )
        }
    }

    private func builtInMascotImage(for agent: Agent) -> NSImage? {
        guard let avatar = agent.avatar, !avatar.isEmpty else { return nil }
        return Bundle.module.image(forResource: "osaurus-avatar-\(avatar)")
    }

    /// A remote agent's mascot (or name monogram) with a small transport badge
    /// in the bottom-trailing corner (`network` = Bonjour LAN peer, `antenna…` =
    /// relay-paired). The badge sits in an `.overlay` (outside the avatar's clip)
    /// so it isn't clipped and doesn't affect layout; `surface` rings it so it
    /// reads as punched into the host background.
    @ViewBuilder
    private func remoteBadgedAvatar(
        mascotId: String?,
        name: String,
        badge: String,
        size: CGFloat,
        surface: Color
    ) -> some View {
        let badgeDiameter = max(9, (size * 0.46).rounded())
        AgentAvatarView(
            mascotId: mascotId,
            name: name,
            tint: agentColorFor(name),
            diameter: size,
            customImageURL: nil,
            monogramFontSize: size * 0.45,
            borderWidth: 0
        )
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(theme.accentColor)
                Image(systemName: badge)
                    .font(.system(size: badgeDiameter * 0.6, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: badgeDiameter, height: badgeDiameter)
            .overlay(Circle().strokeBorder(surface, lineWidth: 1.5))
            .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.15), radius: 1, y: 0.5)
            .offset(x: 1, y: 1)
        }
    }

    /// Name used to seed the active remote avatar's monogram/tint.
    private var remoteAvatarSeedName: String {
        activeRelayAgent?.name ?? activeDiscoveredAgent?.name ?? L("Remote Agent")
    }

    @ViewBuilder
    private var activeAvatar: some View {
        if isRemoteActive {
            // Mirror the chat hero/thread: the remote agent's own mascot,
            // falling back to a monogram on its name (not a generic glyph),
            // plus the transport badge so the selected pill reads as remote.
            remoteBadgedAvatar(
                mascotId: activeRemoteAgentAvatar,
                name: remoteAvatarSeedName,
                badge: activeRemoteBadgeSymbol,
                size: 20,
                surface: theme.secondaryBackground
            )
        } else {
            monogramAvatar(for: activeAgent, size: 20)
        }
    }

    /// Transport glyph for the active remote agent's badge: antenna for a
    /// relay-paired agent, network for a Bonjour LAN peer.
    private var activeRemoteBadgeSymbol: String {
        activeRelayAgent != nil ? "antenna.radiowaves.left.and.right" : "network"
    }

    /// The pill highlights on hover of its tap area. The settings gear is now a
    /// separate sibling button, so it no longer drives the pill's chrome.
    private var isPillHighlighted: Bool { isHovered }

    /// The settings action behind the gear, routed by which kind of agent is
    /// active: remote/relay agents open their connection detail view, local
    /// agents open their editable config. `nil` hides the gear (no destination).
    private var gearAction: (() -> Void)? {
        isRemoteActive ? onOpenRemoteAgentSettings : onOpenActiveAgentSettings
    }

    /// Whether the inline gear button should render. Either way the gear lives
    /// in the pill so settings sit in one consistent toolbar slot regardless of
    /// which kind of agent is active.
    private var showsGearButton: Bool { gearAction != nil }

    var body: some View {
        HStack(spacing: 2) {
            pill

            if showsGearButton {
                settingsButton
            }
        }
        .onChange(of: openPickerTrigger) { _, _ in
            isPopoverPresented = true
        }
        .onChange(of: isPopoverPresented) { _, presented in
            if presented {
                // Lazily begin LAN peer discovery the moment the picker (the
                // only surface that lists discovered agents) opens, so users
                // who never open it don't trigger an always-on mDNS browse or
                // the Local Network permission prompt. Idempotent.
                BonjourBrowser.shared.startIfNeeded()
                keyboard.start(
                    itemCount: menuItemCount,
                    initialIndex: initialHighlightIndex,
                    onActivate: { activateMenuItem(at: $0) },
                    onDismiss: { isPopoverPresented = false }
                )
            } else {
                keyboard.stop()
            }
        }
        .onDisappear { keyboard.stop() }
    }

    // MARK: - Subviews

    /// The dropdown pill — avatar + name + chevron — carrying the capsule
    /// chrome and the agent-picker popover. Reads purely as a selector now that
    /// the gear has moved out to its own button.
    private var pill: some View {
        mainTapArea
            .background(pillBackground)
            .overlay(pillBorder)
            .shadow(
                color: isPillHighlighted ? theme.accentColor.opacity(0.1) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                popoverContent
            }
    }

    /// Standalone settings button beside the pill. A plain icon (no Liquid
    /// Glass capsule) that just tints on hover. Routes to local or remote
    /// agent settings.
    private var settingsButton: some View {
        Button {
            gearAction?()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isGearHovered ? theme.accentColor : theme.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp(isRemoteActive ? "Remote agent settings" : "Edit agent settings")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isGearHovered = hovering
            }
        }
    }

    private var mainTapArea: some View {
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
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Chrome

    private var pillBackground: some View {
        ZStack {
            Capsule()
                .fill(theme.secondaryBackground.opacity(isPillHighlighted ? 0.9 : 0.65))

            if isPillHighlighted {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.08), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }

    private var pillBorder: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(isPillHighlighted ? 0.2 : 0.12),
                        (isPillHighlighted ? theme.accentColor : theme.primaryBorder)
                            .opacity(isPillHighlighted ? 0.25 : 0.15),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { idx, agent in
                            agentRow(agent, index: idx)
                        }

                        if !selectableDiscoveredAgents.isEmpty {
                            sectionHeader(Text("On This Network", bundle: .module))
                            ForEach(Array(selectableDiscoveredAgents.enumerated()), id: \.element.id) {
                                idx,
                                remote in
                                discoveredRow(remote, index: agents.count + idx)
                            }
                        }

                        if !selectableRelayAgents.isEmpty {
                            sectionHeader(Text("Paired", bundle: .module))
                            ForEach(Array(selectableRelayAgents.enumerated()), id: \.element.id) {
                                idx,
                                relay in
                                relayRow(
                                    relay,
                                    index: agents.count + selectableDiscoveredAgents.count + idx
                                )
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .onChange(of: keyboard.highlightedIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }

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

    private func agentRow(_ agent: Agent, index: Int) -> some View {
        let isCurrent = agent.id == activeAgentId && !isRemoteActive
        return PopoverRow(
            isCurrent: isCurrent,
            isHighlighted: keyboard.highlightedIndex == index,
            onTap: {
                isPopoverPresented = false
                onSelectAgent(agent.id)
            }
        ) {
            monogramAvatar(for: agent, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName.isEmpty ? L("Untitled Agent") : agent.displayName)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                let desc = agent.displayDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .id(index)
    }

    private func discoveredRow(_ remote: DiscoveredAgent, index: Int) -> some View {
        let isCurrent = activeDiscoveredAgent?.id == remote.id
        return PopoverRow(
            isCurrent: isCurrent,
            isHighlighted: keyboard.highlightedIndex == index,
            onTap: {
                isPopoverPresented = false
                onSelectDiscoveredAgent?(remote)
            }
        ) {
            remoteBadgedAvatar(
                mascotId: nil,
                name: remote.name,
                badge: "network",
                size: 26,
                surface: theme.cardBackground
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(remote.name)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if remote.supportsSecureChannel {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(theme.successColor)
                            .help(L("End-to-end encrypted"))
                    }
                }
                let subtitle = [
                    remote.host.map(shortHost),
                    remote.agentDescription.isEmpty ? nil : remote.agentDescription,
                ].compactMap { $0 }.joined(separator: " · ")
                if !remote.supportsSecureChannel {
                    // Old peer: we hard-require E2E for agent traffic, so chat
                    // will be refused until it upgrades — say so up front.
                    Text("Needs upgrade for encrypted chat", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.warningColor)
                        .lineLimit(1)
                } else if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .id(index)
    }

    private func relayRow(_ relay: PairedRelayAgent, index: Int) -> some View {
        let isCurrent = activeRelayAgent?.id == relay.id
        return PopoverRow(
            isCurrent: isCurrent,
            isHighlighted: keyboard.highlightedIndex == index,
            onTap: {
                isPopoverPresented = false
                onSelectRelayAgent?(relay)
            }
        ) {
            remoteBadgedAvatar(
                mascotId: relay.avatar,
                name: relay.name,
                badge: "antenna.radiowaves.left.and.right",
                size: 26,
                surface: theme.cardBackground
            )
            HStack(spacing: 4) {
                Text(relay.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                // Relay agent traffic is Secure Channel or refused (426 gate),
                // so a paired agent that chats is end-to-end encrypted.
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(theme.successColor)
                    .help(L("End-to-end encrypted"))
            }
        }
        .id(index)
    }
}

private struct PopoverRow<Content: View>: View {
    let isCurrent: Bool
    /// Keyboard-focus highlight (arrow-key navigation). Distinct from hover so
    /// the user can tell which row Enter will activate.
    var isHighlighted: Bool = false
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var rowBackground: Color {
        // The selected row is marked by the trailing circle checkmark alone — no
        // accent fill — so its corners never clash with the popover's own
        // (larger) corner radius. Hover / keyboard focus still tint the row.
        if isHighlighted { return theme.secondaryBackground.opacity(0.9) }
        if isHovered { return theme.secondaryBackground.opacity(0.6) }
        return .clear
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                content()
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(rowBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isHighlighted ? theme.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: 1
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
