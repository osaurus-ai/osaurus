//
//  RemoteAgentViews.swift
//  osaurus
//
//  UI for agents that the user has paired into this device via the
//  `osaurus://...?pair=...` deeplink flow.
//
//  Two surfaces:
//    - `RemoteAgentCard`        — grid card that lives next to the local
//                                  `AgentCard` in `AgentsView.gridContent`,
//                                  with a "Remote" badge.
//    - `RemoteAgentDetailView`  — the read-only detail panel shown when the
//                                  user taps a remote card.
//

import SwiftUI

// MARK: - Remote Agent Card

struct RemoteAgentCard: View {
    @Environment(\.theme) private var theme

    let remote: RemoteAgent
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onChat: () -> Void
    let onRemove: () -> Void

    @State private var isHovered: Bool = false
    @State private var showRemoveConfirm: Bool = false

    private var color: Color { agentColorFor(remote.name) }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    avatar
                    metadata
                    Spacer(minLength: 8)
                    overflowMenu
                }

                if !remote.description.isEmpty {
                    Text(remote.description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No description", bundle: .module)
                        .font(.system(size: 12).italic())
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
                stats
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
            .padding(16)
            .background(cardBackground)
            .overlay(hoverGradient)
            .overlay(alignment: .bottomTrailing) { hoverChevron }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : (hasAppeared ? 1 : 0.95))
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .themedAlert(
            "Remove this remote agent?",
            isPresented: $showRemoveConfirm,
            message: "You'll lose access to \"\(remote.name)\" via this share link. You can be re-invited later.",
            primaryButton: .destructive("Remove") {
                onRemove()
            },
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: Subviews

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.15), color.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(color.opacity(0.4), lineWidth: 2)
            Text(remote.name.prefix(1).uppercased())
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(color)
            // Tiny "remote" decoration in the bottom-right of the avatar (same
            // badge the detail header / switcher rows use). Reads at a glance
            // even when the card is dense.
            RemoteAvatarBadge()
                .offset(x: 12, y: 12)
        }
        .frame(width: 36, height: 36)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(remote.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                // Pill metrics match local AgentCard's "Active" badge so the
                // grid's status chips read at the same weight/size.
                HStack(spacing: 3) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Remote", bundle: .module)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.accentColor.opacity(0.12)))
            }
            Text(remote.shortAddress)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                onChat()
            } label: {
                Label {
                    Text("Chat", bundle: .module)
                } icon: {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                }
            }
            Button(action: onSelect) {
                Label {
                    Text("Open Details", bundle: .module)
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                showRemoveConfirm = true
            } label: {
                Label {
                    Text("Remove", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            statChip(icon: "calendar", text: "Paired \(remote.pairedAt.formatted(.relative(presentation: .named)))")
            if let used = remote.lastUsedAt {
                statChip(icon: "clock", text: "Used \(used.formatted(.relative(presentation: .named)))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.tertiaryBackground.opacity(0.5)))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        color.opacity(isHovered ? 0.06 : 0),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isHovered ? color.opacity(0.25) : theme.cardBorder,
                lineWidth: isHovered ? 1.5 : 1
            )
    }

    /// Same hover-reveal "open" affordance the local AgentCard uses, tinted to
    /// the agent's deterministic color so local + remote cards share a
    /// hover language.
    private var hoverChevron: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color.opacity(0.12)))
            .padding(10)
            .opacity(isHovered ? 1 : 0)
            .scaleEffect(isHovered ? 1 : 0.85)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Remote Agent Detail View

struct RemoteAgentDetailView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var manager = RemoteAgentManager.shared
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    @ObservedObject private var insights = InsightsService.shared

    let remoteId: UUID
    let onBack: () -> Void
    let onRemoved: () -> Void
    let onChat: (RemoteAgent) -> Void
    /// Switch the detail pane to a local agent picked from the shared switcher.
    let onSwitchAgent: (Agent) -> Void
    /// Switch the detail pane to a different paired remote agent.
    let onSwitchRemoteAgent: (UUID) -> Void

    @State private var note: String = ""
    @State private var showingAgentSwitcher: Bool = false
    @State private var showRemoveConfirm: Bool = false
    /// Live `effective_model` from a `GET /agents/{id}` refresh on appear. The
    /// peer's real runtime model (Mode 2 sends `model:"default"` on the wire),
    /// so we fetch it here rather than infer it from the local picker.
    @State private var liveEffectiveModel: String?
    /// True while the connect-time `GET /agents/{id}` refresh is in flight.
    @State private var isRefreshingMetadata: Bool = false
    @State private var metadataRefreshTask: Task<Void, Never>?
    /// True while a manual Connect is in flight (drives the button spinner).
    @State private var isConnecting: Bool = false
    /// Transient "Saved" pill toggled by `commitNote()` after the debounce
    /// fires. Lives next to the note label so the user has explicit feedback
    /// that their typing was persisted (mirroring the local agent detail's
    /// header `saveIndicator`).
    @State private var noteSaved: Bool = false
    @State private var noteSaveTask: Task<Void, Never>?
    /// Tracks whether the on-disk note matches the typed text. Used to
    /// suppress the initial onChange that fires when `note` is hydrated on
    /// appear, so the user doesn't see a phantom "Saved" pill on every visit.
    @State private var noteHydrated: Bool = false
    /// Which content tab is showing. Mirrors the local agent detail's tabbed
    /// shell so both surfaces navigate the same way.
    @State private var selectedTab: RemoteDetailTab = .overview

    private var remote: RemoteAgent? { manager.remoteAgent(for: remoteId) }
    private var color: Color { agentColorFor(remote?.name ?? "") }

    /// The two content tabs for a paired remote agent. Kept deliberately small
    /// — the remote surface is read-only-ish — but mirrors the local detail
    /// view's tabbed shell so both navigate the same way.
    private enum RemoteDetailTab: Hashable {
        case overview
        case activity
    }

    var body: some View {
        VStack(spacing: 0) {
            if let remote {
                header(for: remote)

                AgentDetailTabStrip(items: tabItems(for: remote), selection: $selectedTab)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Divider()
                    .foregroundColor(theme.primaryBorder)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        tabSections(for: remote)
                    }
                    .padding(24)
                    .id(selectedTab)
                }
                .background(theme.primaryBackground)
            } else {
                unavailableHeader

                ScrollView {
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 32))
                            .foregroundColor(theme.tertiaryText)
                        Text("This remote agent is no longer available.", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                        Button {
                            onBack()
                        } label: {
                            Text("Go back", bundle: .module)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 80)
                }
                .background(theme.primaryBackground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear {
            note = remote?.note ?? ""
            // Mark hydrated on the next runloop tick so the onChange that
            // fires from this assignment is treated as the initial sync, not
            // a user edit.
            DispatchQueue.main.async { noteHydrated = true }
            refreshLiveMetadata()
        }
        .onDisappear {
            noteSaveTask?.cancel()
            metadataRefreshTask?.cancel()
        }
        .themedAlert(
            "Remove this remote agent?",
            isPresented: $showRemoveConfirm,
            message: "You'll lose access via this share link. You can be re-invited later.",
            primaryButton: .destructive("Remove") {
                _ = manager.remove(id: remoteId)
                onRemoved()
            },
            secondaryButton: .cancel("Cancel")
        )
    }

    /// Built-in tab descriptors for the strip. The Activity tab carries a badge
    /// with this session's request count once the agent has been used.
    private func tabItems(for remote: RemoteAgent) -> [AgentDetailTabItem<RemoteDetailTab>] {
        let activity = insights.activity(forProviderId: remote.providerId)
        return [
            AgentDetailTabItem(id: .overview, label: L("Overview"), icon: "info.circle"),
            AgentDetailTabItem(
                id: .activity,
                label: L("Activity"),
                icon: "waveform.path.ecg",
                badgeCount: activity.isEmpty ? nil : activity.requestCount
            ),
        ]
    }

    @ViewBuilder
    private func tabSections(for remote: RemoteAgent) -> some View {
        switch selectedTab {
        case .overview:
            connectionCard(for: remote)
            sourceCard(for: remote)
            noteCard(for: remote)
        case .activity:
            activityCard(for: remote)
        }
    }

    // MARK: Header

    private func header(for remote: RemoteAgent) -> some View {
        AgentDetailHeaderBar(
            onBack: onBack,
            identity: { identityButton(for: remote) },
            status: { connectionStatusPill(for: remote) },
            actions: {
                HStack(spacing: 6) {
                    AgentDetailHeaderActionButton(
                        icon: "bubble.left.and.bubble.right",
                        tint: theme.accentColor,
                        help: "Chat with this Agent",
                        action: { onChat(remote) }
                    )
                    AgentDetailHeaderActionButton(
                        icon: "trash",
                        tint: theme.errorColor,
                        help: "Remove",
                        action: { showRemoveConfirm = true }
                    )
                }
            }
        )
    }

    /// Tappable identity block mirroring the local header: avatar (carrying the
    /// remote antenna glyph instead of a free-floating "Remote" pill) + name +
    /// switcher chevron. Tapping opens the shared agent switcher so the user can
    /// hop between local and remote agents from here too.
    private func identityButton(for remote: RemoteAgent) -> some View {
        Button {
            showingAgentSwitcher = true
        } label: {
            AgentDetailIdentityLabel(
                mascotId: remote.avatar,
                name: remote.name,
                tint: color,
                subtitle: remote.description,
                showsChevron: true,
                maxWidth: 240,
                showsRemoteGlyph: true,
                glyphRingColor: theme.secondaryBackground
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .localizedHelp("Switch agent")
        .popover(isPresented: $showingAgentSwitcher, arrowEdge: .bottom) {
            AgentSwitcherPopover(
                localAgents: AgentManager.shared.agents.filter { !$0.isBuiltIn },
                remoteAgents: manager.remoteAgents,
                currentLocalAgentId: nil,
                currentRemoteAgentId: remote.id,
                onSelectLocal: { agent in
                    showingAgentSwitcher = false
                    onSwitchAgent(agent)
                },
                onSelectRemote: { other in
                    showingAgentSwitcher = false
                    onSwitchRemoteAgent(other.id)
                },
                onDismiss: { showingAgentSwitcher = false }
            )
            .environment(\.theme, theme)
        }
    }

    /// Back-only header shown when the remote agent can no longer be resolved
    /// (e.g. it was removed in another window) so the user can still navigate
    /// back.
    private var unavailableHeader: some View {
        AgentDetailHeaderBar(
            onBack: onBack,
            identity: {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                    Text("Remote Agent", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }
            },
            status: { EmptyView() },
            actions: { EmptyView() }
        )
    }

    /// Compact connection-state pill for the header's status slot so the live
    /// link state is visible regardless of which tab is showing.
    private func connectionStatusPill(for remote: RemoteAgent) -> some View {
        let currentPhase = phase(for: remote)
        return HStack(spacing: 5) {
            Circle()
                .fill(phaseColor(currentPhase))
                .frame(width: 6, height: 6)
            Text(currentPhase.label, bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: Connection

    /// Live connection phase derived from the provider's runtime state, plus
    /// the transient manual-connect flag so the button reflects an in-flight
    /// connect immediately.
    private enum ConnectionPhase: Equatable {
        case connected
        case connecting
        case disconnected
        case failed(String)

        var label: LocalizedStringKey {
            switch self {
            case .connected: return "Connected"
            case .connecting: return "Connecting…"
            case .disconnected: return "Disconnected"
            case .failed: return "Connection failed"
            }
        }
    }

    private func phase(for remote: RemoteAgent) -> ConnectionPhase {
        if isConnecting { return .connecting }
        guard let state = providerManager.providerStates[remote.providerId] else {
            return .disconnected
        }
        if state.isConnected { return .connected }
        if state.isConnecting { return .connecting }
        if let error = state.lastError, !error.isEmpty { return .failed(error) }
        return .disconnected
    }

    private func phaseColor(_ phase: ConnectionPhase) -> Color {
        switch phase {
        case .connected: return theme.successColor
        case .connecting: return .orange
        case .disconnected: return theme.tertiaryText
        case .failed: return theme.errorColor
        }
    }

    private func connectionCard(for remote: RemoteAgent) -> some View {
        let currentPhase = phase(for: remote)
        return AgentDetailSection(
            title: L("Connection"),
            icon: "antenna.radiowaves.left.and.right",
            trailing: {
                HStack(spacing: 6) {
                    if isRefreshingMetadata {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    }
                    Button {
                        refreshLiveMetadata()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Refresh from the agent", bundle: .module))
                    .disabled(isRefreshingMetadata)
                }
            }
        ) {
            AgentDetailStatusRow(
                label: "Status",
                value: currentPhase.label,
                dotColor: phaseColor(currentPhase)
            )
            if case .failed(let message) = currentPhase {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(theme.errorColor.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AgentDetailMetadataRow(
                label: "Mode",
                value: NSLocalizedString("Remote agent run", bundle: .module, comment: "")
            )
            AgentDetailMetadataRow(
                label: "Encryption",
                value: NSLocalizedString("Secure Channel (E2E)", bundle: .module, comment: "")
            )
            AgentDetailMetadataRow(
                label: "Model",
                value: liveEffectiveModel
                    ?? NSLocalizedString("Default (agent decides)", bundle: .module, comment: "")
            )

            connectionActionRow(for: remote, phase: currentPhase)
        }
    }

    @ViewBuilder
    private func connectionActionRow(for remote: RemoteAgent, phase: ConnectionPhase) -> some View {
        HStack(spacing: 10) {
            if phase == .connected {
                Button {
                    providerManager.disconnect(providerId: remote.providerId)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.slash")
                            .font(.system(size: 11))
                        Text("Disconnect", bundle: .module)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button {
                    connect(remote)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt")
                            .font(.system(size: 11))
                        Text("Connect", bundle: .module)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(phase == .connecting)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: Activity

    private func activityCard(for remote: RemoteAgent) -> some View {
        let activity = insights.activity(forProviderId: remote.providerId)
        return AgentDetailSection(
            title: L("Activity"),
            icon: "waveform.path.ecg",
            trailing: {
                if !activity.isEmpty {
                    Button {
                        viewInInsights(remote)
                    } label: {
                        HStack(spacing: 4) {
                            Text("View in Insights", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        ) {
            if activity.isEmpty {
                Text("No requests recorded this session.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    activityStat(
                        value: "\(activity.requestCount)",
                        label: Text("Requests", bundle: .module)
                    )
                    activityStat(
                        value: activity.formattedAvgSpeed,
                        label: Text("Avg speed", bundle: .module)
                    )
                    if let last = activity.lastUsed {
                        activityStat(
                            value: last.formatted(.relative(presentation: .named)),
                            label: Text("Last used", bundle: .module)
                        )
                    }
                }
            }
        }
    }

    private func activityStat(value: String, label: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            label
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.4))
        )
    }

    // MARK: Connection actions

    private func connect(_ remote: RemoteAgent) {
        isConnecting = true
        Task { @MainActor in
            defer { isConnecting = false }
            try? await providerManager.connect(providerId: remote.providerId)
            refreshLiveMetadata()
        }
    }

    /// Pull the agent's live metadata (`GET /agents/{id}` over the Secure
    /// Channel) so the Connection section shows the real effective model and
    /// the local label/avatar stay honest if the owner renamed/re-skinned.
    private func refreshLiveMetadata() {
        guard let remote = remote,
            let provider = providerManager.configuration.provider(id: remote.providerId)
        else { return }
        metadataRefreshTask?.cancel()
        isRefreshingMetadata = true
        metadataRefreshTask = Task { @MainActor in
            defer { isRefreshingMetadata = false }
            let metadata = await RemoteProviderService.fetchOsaurusAgentMetadata(from: provider)
            guard !Task.isCancelled else { return }
            if let model = metadata?.effectiveModel, !model.isEmpty {
                liveEffectiveModel = model
            }
            manager.updateLiveMetadata(
                forAddress: remote.agentAddress,
                name: metadata?.name,
                description: metadata?.description,
                avatar: metadata?.avatar
            )
        }
    }

    private func viewInInsights(_ remote: RemoteAgent) {
        InsightsService.shared.focus(providerId: remote.providerId)
        ManagementStateManager.shared.selectedTab = .insights
    }

    private func sourceCard(for remote: RemoteAgent) -> some View {
        AgentDetailSection(title: L("Source"), icon: "globe") {
            AgentDetailMetadataRow(label: "Address", value: remote.agentAddress, mono: true)
            AgentDetailMetadataRow(label: "Relay URL", value: remote.relayBaseURL, mono: true)
            AgentDetailMetadataRow(
                label: "Paired",
                value: remote.pairedAt.formatted(date: .abbreviated, time: .shortened)
            )
            if let last = remote.lastUsedAt {
                AgentDetailMetadataRow(
                    label: "Last Used",
                    value: last.formatted(date: .abbreviated, time: .shortened)
                )
            }
        }
    }

    private func noteCard(for remote: RemoteAgent) -> some View {
        AgentDetailSection(
            title: L("Your Note"),
            icon: "note.text",
            trailing: {
                if noteSaved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                        Text("Saved", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.successColor)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        ) {
            StyledTextField(
                placeholder: "e.g., Alice's research agent",
                text: $note,
                icon: "text.alignleft",
                axis: .vertical,
                lineLimit: 3
            )
            .onChange(of: note) { _, newValue in
                guard noteHydrated else { return }
                scheduleNoteSave(newValue, for: remote.id)
            }
        }
    }

    /// Debounced autosave — mirrors the local-agent header's `debouncedSave`
    /// pattern. After 500ms of inactivity, persist the note and flash the
    /// "Saved" pill for ~1.5s.
    private func scheduleNoteSave(_ value: String, for id: UUID) {
        noteSaveTask?.cancel()
        noteSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            manager.updateNote(value, for: id)
            withAnimation(.easeOut(duration: 0.2)) { noteSaved = true }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { noteSaved = false }
        }
    }

}
