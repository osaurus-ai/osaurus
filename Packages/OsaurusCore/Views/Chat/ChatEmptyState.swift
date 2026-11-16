//
//  ChatEmptyState.swift
//  osaurus
//
//  Immersive empty state with prominent agent selector
//  and staggered entrance animations for a polished first impression.
//

import AppKit
import SwiftUI

// MARK: - Hero Avatar Metrics

/// Diameter for hero-sized agent avatars in the empty-state surfaces. Not
/// the design library's avatar size, which is sized for chat and list rows.
private let heroAvatarDiameter: CGFloat = 64
/// Font size for the icon/monogram inside a hero avatar (built-in `person.fill`
/// placeholder and `AgentAvatarView` monogram fallback).
private let heroAvatarIconFontSize: CGFloat = 28

// MARK: - Hosted Agent

struct HostedAgentHero: Equatable, Sendable {
    let name: String
    let avatar: String?
    let description: String?
    let hostName: String
}

// MARK: - Hero Agent Avatar

/// Renders a hero-sized avatar for a given agent. Built-in and custom
/// agents share the same `AgentAvatarView` path so the default Osaurus
/// agent gets the same gradient-circle backing as every other agent —
/// previously the built-in branch rendered the mascot PNG without that
/// backing, leaving the dino floating against the chat background.
/// Shared by `ChatEmptyState.heroAvatar` and `ChatEmptyStateNoModels.welcomeAvatar`.
private struct HeroAgentAvatar: View {
    @Environment(\.theme) private var theme
    let agent: Agent

    var body: some View {
        AgentAvatarView(
            mascotId: agent.avatar,
            name: agent.name,
            tint: theme.dataInk(seed: agent.name),
            diameter: heroAvatarDiameter,
            customImageURL: agent.customAvatarURL,
            monogramFontSize: heroAvatarIconFontSize,
            borderWidth: 0,
            bleedsToEdge: true,
            followsLibrarySize: false
        )
    }
}

struct ChatEmptyState: View {
    let hasModels: Bool
    let selectedModel: String?
    let agents: [Agent]
    let activeAgentId: UUID
    let quickActions: [AgentQuickAction]
    let onOpenModelManager: () -> Void
    let onUseFoundation: (() -> Void)?
    let onQuickAction: (String) -> Void
    let onOpenOnboarding: (() -> Void)?
    /// The agent's pinned local default model while its download is still in
    /// flight / paused / failed (see `ChatSession.pendingLocalSetupModelId`).
    /// Non-nil replaces the regular ready state with a focused setup card,
    /// including while the temporary Cloud model is active, so local download
    /// progress never disappears.
    var pendingLocalModelId: String? = nil
    /// Display name of the temporary Router model already selected while local
    /// setup runs (the newest DeepSeek Flash for first-run). Nil means Cloud still
    /// needs to connect.
    var temporaryCloudModelName: String? = nil
    /// Automatic temporary Osaurus Cloud selection while the pinned local
    /// download finishes. Async because the Router may need to connect on
    /// demand; false lets the setup card surface a retry.
    var onUseHostedWhilePending: (() async -> Bool)? = nil
    /// Retry the provider/Router connection from the no-models recovery
    /// state. nil hides the Retry action.
    var onRetryConnection: (() async -> Void)? = nil
    /// Open the providers management surface from the no-models recovery
    /// state. nil hides the Connect-a-provider action.
    var onOpenProviders: (() -> Void)? = nil
    var activeRelayAgent: PairedRelayAgent? = nil
    /// Mascot avatar id of the active remote agent (Mode 2), resolved from its
    /// live metadata on connect. nil = monogram fallback on the remote name.
    var remoteAgentAvatar: String? = nil
    /// The active remote agent's description, used as the empty-state subtitle
    /// so the remote agent introduces itself instead of the generic default.
    var remoteAgentDescription: String? = nil
    /// The active remote agent's custom Action Bar (chat quick actions),
    /// resolved from its live metadata on connect. nil/empty = the neutral
    /// chat defaults, so the swap to fetched actions animates in after connect.
    var remoteAgentQuickActions: [AgentQuickAction]? = nil
    /// True while the Mode 2 remote-agent connection (and its secure-channel
    /// handshake) is still resolving. Drives the security badge's loader
    /// variant: the chat isn't actually encrypted until the channel is up, so
    /// the badge shows "Securing connection…" instead of claiming E2E early.
    var isConnecting: Bool = false
    /// Workspace/shared agent this tab talks to, when it is one. Present even
    /// before the agent is paired or while the connect fails, so the hero
    /// never falls back to the local mascot for a remote conversation.
    var sharedAgent: SharedAgentIdentity?
    /// Connection status of `sharedAgent`; drives the badge under the
    /// greeting (one vocabulary with the composer lock notice) and hides the
    /// quick actions while the composer is locked.
    var sharedAgentStatus: SharedAgentStatus?
    /// One of the user's agents on another of their Macs, which runs it.
    var hostedAgent: HostedAgentHero?
    /// The new chat's discovery card, under the greeting.
    var discoveryCard: DiscoveryCard? = nil
    var onOpenDiscovery: ((DiscoveryItem) -> Void)? = nil
    var onDismissDiscovery: ((DiscoveryItem) -> Void)? = nil
    /// What is left in Set Up Osaurus; the link under the greeting shows
    /// while it is above zero.
    var setUpLeft: Int = 0
    var onOpenSetUp: (() -> Void)? = nil
    /// Turns discovery off: the card and the link leave every new chat.
    var onSkipSetUp: (() -> Void)? = nil

    @State private var hasAppeared = false
    @Environment(\.theme) private var theme

    private var activeAgent: Agent {
        agents.first { $0.id == activeAgentId } ?? Agent.default
    }

    /// True when this empty state heads a Mode 2 remote-agent conversation.
    private var isRemoteChat: Bool {
        hostedAgent != nil || sharedAgent != nil || activeRelayAgent != nil
    }

    /// Display name of the active remote agent (Mode 2), if any. Drives the
    /// empty-state title so a remote conversation is headed by the remote
    /// agent's own name rather than the local agent's greeting.
    private var remoteAgentName: String? {
        if let hosted = hostedAgent {
            let trimmed = hosted.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let shared = sharedAgent {
            let trimmed = shared.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let relay = activeRelayAgent {
            let trimmed = relay.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Remote agent name with a safe fallback, for the hero avatar seed/title
    /// when the advertised name happens to be blank.
    private var remoteDisplayName: String {
        remoteAgentName ?? L("Remote Agent")
    }

    /// Title text rendered above the subtitle. Resolution order:
    /// 1. Remote agent name (Mode 2 — this chat is the remote agent, not the
    /// local one), 2. per-agent override (`Agent.chatGreeting`), 3. time-of-day
    /// default. Whitespace-only strings are treated as nil so a cleared field
    /// falls through to the next layer.
    private var greetingText: String {
        // A remote agent owns the conversation: never surface the local
        // agent's custom greeting here.
        if isRemoteChat {
            return remoteDisplayName
        }
        if let custom = activeAgent.chatGreeting?.trimmingCharacters(in: .whitespacesAndNewlines),
            !custom.isEmpty
        {
            return custom
        }
        return greeting
    }

    /// Subtitle rendered beneath the greeting. Same precedence as
    /// `greetingText`: remote description → per-agent override
    /// (`Agent.chatSubtitle`) → the agent's own description → localized
    /// default. One rule for every agent: each one introduces itself (the
    /// built-in Orchestrator's description carries its role the same way a
    /// custom agent's does).
    private var subtitleText: LocalizedStringKey {
        // Remote agent run: surface the remote agent's own description (so it
        // introduces itself), never the local agent's custom
        // subtitle. Falls back to the neutral default when it has none.
        if isRemoteChat {
            if let d = (remoteAgentDescription ?? sharedAgent?.description ?? hostedAgent?.description)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !d.isEmpty
            {
                return LocalizedStringKey(Self.greetingSubtitle(d))
            }
            return "How can I help you today?"
        }
        if let custom = activeAgent.chatSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !custom.isEmpty
        {
            return LocalizedStringKey(custom)
        }
        let description = activeAgent.displayDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return LocalizedStringKey(Self.greetingSubtitle(description))
        }
        return "How can I help you today?"
    }

    /// Longest subtitle the greeting shows before trimming to sentences.
    nonisolated static let greetingSubtitleLimit = 160

    /// An agent description shortened for the greeting: the leading whole
    /// sentences that fit in `limit` characters, so the subtitle ends on a
    /// full stop instead of an ellipsis mid-clause. A first sentence longer
    /// than the limit is kept whole and left to the line limit; whitespace
    /// runs (including newlines) collapse to single spaces.
    nonisolated static func greetingSubtitle(_ description: String, limit: Int = greetingSubtitleLimit) -> String {
        let text = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count > limit else { return text }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
        }
        var result = ""
        for sentence in sentences where !sentence.isEmpty {
            let next = result.isEmpty ? sentence : result + " " + sentence
            if next.count > limit { break }
            result = next
        }
        return result.isEmpty ? (sentences.first ?? text) : result
    }

    /// "Shared by Maggie · annietest" for a teammate's shared agent, "Your
    /// agent on another device · annietest" for one this identity shared
    /// from a different device; nil for agents hosted here and legacy
    /// Mode 2 peers (no owner to name).
    private var sharedAttribution: String? {
        if let hosted = hostedAgent { return String(format: L("Your agent on %@"), hosted.hostName) }
        guard isRemoteChat, let shared = sharedAgent, !shared.isHostedHere else { return nil }
        let workspace = shared.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if shared.isOwnedElsewhere {
            if let workspace, !workspace.isEmpty {
                return String(format: L("Your agent on another device · %@"), workspace)
            }
            return L("Your agent on another device")
        }
        guard let owner = shared.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty
        else { return nil }
        if let workspace, !workspace.isEmpty {
            return String(format: L("Shared by %@ · %@"), owner, workspace)
        }
        return String(format: L("Shared by %@"), owner)
    }

    /// Quick actions to render. Remote chats use the remote agent's advertised
    /// actions; local chats use the selected agent's configured shortcuts.
    private var effectiveQuickActions: [AgentQuickAction] {
        // Mode 2: surface the remote agent's own Action Bar when it advertised
        // one over the Secure Channel; otherwise fall back to neutral chat
        // defaults (never the local agent's shortcuts — e.g. a local coding
        // agent's actions don't represent a remote research agent).
        if isRemoteChat {
            // Locked composer (offline / not connected / unavailable / read-
            // only): a suggestion the user can't send is a dead end.
            if let status = sharedAgentStatus, !status.canSend { return [] }
            if let remote = remoteAgentQuickActions, !remote.isEmpty { return remote }
            return AgentQuickAction.defaultChatQuickActions
        }
        return quickActions
    }


    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: theme.space.s0) {
                    Spacer(minLength: 20)

                    if let pendingModelId = pendingLocalModelId {
                        ChatEmptyStateLocalSetup(
                            modelId: pendingModelId,
                            hasAppeared: hasAppeared,
                            temporaryCloudModelName: temporaryCloudModelName,
                            onUseHostedMeanwhile: onUseHostedWhilePending,
                            onOpenModelManager: onOpenModelManager
                        )
                    } else if hasModels {
                        readyState
                    } else {
                        ChatEmptyStateNoModels(
                            hasAppeared: hasAppeared,
                            onOpenOnboarding: onOpenOnboarding,
                            onOpenModelManager: onOpenModelManager,
                            onOpenProviders: onOpenProviders,
                            onRetryConnection: onRetryConnection
                        )
                    }

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(theme.motion.slow) {
                    hasAppeared = true
                }
            }
        }
        .onDisappear {
            hasAppeared = false
        }
    }

    // MARK: - Ready State (has models)

    private var readyState: some View {
        VStack(spacing: theme.space.s14) {
            // Hero avatar — agent's mascot as the focal point
            heroAvatar
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.motion.springAnimation.delay(0.0), value: hasAppeared)

            greetingBlock
        }
        .padding(.horizontal, theme.space.s40)
    }

    /// Greeting + subtitle + quick actions block.
    @ViewBuilder
    private var greetingBlock: some View {
        VStack(spacing: theme.space.s14) {
            VStack(spacing: theme.space.s8) {
                HStack(spacing: theme.space.s6) {
                    Text(greetingText)
                        .textStyle(.title)
                        .foregroundColor(theme.text.primary)
                }
                .id("greeting-\(greetingText)")
                .transition(.opacity)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(theme.motion.springAnimation.delay(0.1), value: hasAppeared)

                Text(subtitleText, bundle: .module)
                    .textStyle(.heading)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
                    .transition(.opacity)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.motion.springAnimation.delay(0.17), value: hasAppeared)

                // Teammate's shared agent: who shared it and through which
                // workspace, next to the transport/status badge — the two
                // facts that distinguish it from a local agent of the same
                // name.
                if sharedAttribution != nil || securityBadgeState != nil {
                    HStack(spacing: theme.space.s8) {
                        if let attribution = sharedAttribution {
                            HStack(spacing: theme.space.s4) {
                                Image(systemName: "person.2.fill")
                                    .glyphSize(.tiny, weight: .semibold)
                                Text(verbatim: attribution)
                                    .lineLimit(1)
                            }
                            .textStyle(.footnote, weight: 500)
                            .foregroundColor(theme.text.secondary)
                            .padding(.horizontal, theme.space.s10)
                            .padding(.vertical, theme.space.s4)
                            .background(Capsule().fill(theme.surface.hover))
                            .help(sharedAgent?.shortAddress ?? "")
                        }
                        if securityBadgeState != nil {
                            securityBadge
                        }
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 12)
                    .animation(theme.motion.springAnimation.delay(0.24), value: hasAppeared)
                }
            }

            if let discoveryCard {
                DiscoveryCardView(
                    card: discoveryCard,
                    onOpen: { onOpenDiscovery?(discoveryCard.item) },
                    onDismiss: { onDismissDiscovery?(discoveryCard.item) }
                )
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 12)
                .animation(theme.motion.springAnimation.delay(0.24), value: hasAppeared)
            }

            if setUpLeft > 0, let onOpenSetUp {
                SetUpOsaurusLink(left: setUpLeft, onOpen: onOpenSetUp, onSkip: onSkipSetUp)
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(theme.motion.springAnimation.delay(0.28), value: hasAppeared)
            }

            if !effectiveQuickActions.isEmpty {
                staggeredQuickActions
            }
        }
    }

    @ViewBuilder
    private var heroAvatar: some View {
        if isRemoteChat {
            // Match the local hero: the remote agent's own mascot (surfaced over
            // the Secure Channel), falling back to a monogram on its name.
            AgentAvatarView(
                mascotId: remoteAgentAvatar ?? sharedAgent?.avatar ?? hostedAgent?.avatar,
                name: remoteDisplayName,
                tint: theme.dataInk(seed: remoteDisplayName),
                diameter: heroAvatarDiameter,
                customImageURL: sharedAgent?.customAvatarURL,
                monogramFontSize: heroAvatarIconFontSize,
                borderWidth: 0,
                bleedsToEdge: true,
                followsLibrarySize: false
            )
        } else {
            HeroAgentAvatar(agent: activeAgent)
        }
    }

    /// Presentation state for the security badge under the greeting.
    /// `connecting` takes precedence — the secure channel isn't up yet, so we
    /// must not claim encryption — and once connected it reflects the transport
    /// status. nil = not a remote chat / nothing to show (no badge).
    enum SecurityBadgeState: Hashable {
        case connecting
        case encrypted
        /// Shared agent's host isn't reachable.
        case offline
        /// Shared agent isn't paired / the connect failed.
        case notConnected
        /// Shared agent was unshared / membership lost / Router off.
        case unavailable
        /// Teammate's conversation served by this host.
        case readOnly
    }

    /// Badge for a shared agent from its status. `connecting` and `ready`
    /// keep the security semantics (the channel is what's being secured);
    /// the other states name the reason the composer is locked so the badge
    /// never claims encryption for a chat that can't send.
    nonisolated static func badgeState(for status: SharedAgentStatus) -> SecurityBadgeState {
        switch status {
        case .ready: return .encrypted
        case .checking, .connecting: return .connecting
        case .offline: return .offline
        case .notConnected: return .notConnected
        case .unavailable, .accessRevoked: return .unavailable
        case .readOnlyTeammate: return .readOnly
        }
    }

    private var securityBadgeState: SecurityBadgeState? {
        if let status = sharedAgentStatus { return Self.badgeState(for: status) }
        if isConnecting { return .connecting }
        // Relay agent traffic is Secure Channel or refused, so a connected
        // relay agent is end-to-end encrypted.
        return activeRelayAgent != nil ? .encrypted : nil
    }

    private func securityBadgeTint(_ state: SecurityBadgeState) -> Color {
        switch state {
        case .connecting: return theme.status.info.foreground
        case .encrypted: return theme.status.success.foreground
        case .notConnected: return theme.status.warning.foreground
        case .offline, .unavailable, .readOnly: return theme.text.secondary
        }
    }

    @ViewBuilder
    private func securityBadgeIcon(_ state: SecurityBadgeState) -> some View {
        switch state {
        case .connecting:
            MorphingStatusIcon(state: .active, accentColor: theme.status.info.foreground, size: 12)
        case .encrypted, .offline, .notConnected, .unavailable, .readOnly:
            Image(systemName: securityBadgeSymbol(state))
                .glyphSize(.tiny, weight: .semibold)
        }
    }

    private func securityBadgeSymbol(_ state: SecurityBadgeState) -> String {
        switch state {
        case .connecting: return SharedAgentStatus.connecting.symbolName
        case .encrypted: return SharedAgentStatus.ready.symbolName
        case .offline: return SharedAgentStatus.offline(lastSeen: nil).symbolName
        case .notConnected: return SharedAgentStatus.notConnected(reason: nil, hasAttempted: false).symbolName
        case .unavailable: return SharedAgentStatus.unavailable(reason: "", fix: .none).symbolName
        case .readOnly: return SharedAgentStatus.readOnlyTeammate(callerName: nil).symbolName
        }
    }

    private func securityBadgeLabel(_ state: SecurityBadgeState) -> Text {
        switch state {
        case .connecting:
            return Text("Securing connection…", bundle: .module)
        case .encrypted:
            return Text("End-to-end encrypted", bundle: .module)
        case .offline:
            return Text(verbatim: sharedAgentStatus?.shortLabel ?? L("Offline"))
        case .notConnected:
            return Text("Not connected", bundle: .module)
        case .unavailable:
            return Text(verbatim: sharedAgentStatus?.shortLabel ?? L("Unavailable"))
        case .readOnly:
            return Text("Teammate's chat", bundle: .module)
        }
    }

    private func securityBadgeHelp(_ state: SecurityBadgeState) -> String {
        switch state {
        case .connecting:
            return L(
                "Establishing the Osaurus Secure Channel — forward-secret, mutually authenticated end-to-end encryption. Not encrypted until connected."
            )
        case .encrypted:
            return L(
                "Agent traffic is protected by the Osaurus Secure Channel: forward-secret, mutually authenticated end-to-end encryption."
            )
        case .offline, .notConnected, .unavailable, .readOnly:
            guard let status = sharedAgentStatus else { return "" }
            return status.message(agentName: remoteDisplayName, hostName: sharedAgent?.ownerName)
        }
    }

    /// Single capsule under the greeting that *morphs* between the connect
    /// loader and the resolved transport-security state. Same chrome/padding
    /// across states so it never resize-jumps; the tint springs from accent
    /// (connecting) to success (encrypted) / warning (not connected), the icon
    /// crossfades spinner -> lock, and the label content-transitions in place.
    @ViewBuilder
    private var securityBadge: some View {
        if let state = securityBadgeState {
            let tint = securityBadgeTint(state)
            HStack(spacing: theme.space.s4) {
                securityBadgeIcon(state)
                    .frame(width: 14, height: 14)
                    .id(state)
                    .transition(.opacity)
                securityBadgeLabel(state)
                    .contentTransition(.opacity)
            }
            .textStyle(.footnote, weight: 500)
            .foregroundColor(tint)
            .padding(.horizontal, theme.space.s10)
            .padding(.vertical, theme.space.s4)
            .background(Capsule().fill(theme.wash(behind: tint)))
            .animation(theme.motion.springAnimation, value: state)
            .help(securityBadgeHelp(state))
        }
    }

    /// Compact suggestion pills in a centered, weight-balanced wrapping
    /// flow. Pills are single-line and size to their label, and the layout
    /// repartitions rows to even widths, so any action count lays out
    /// cleanly — no orphan grid cells, wrapped labels, or clipped rows.
    private var staggeredQuickActions: some View {
        FlowLayout(spacing: theme.space.s8, alignment: .center, balanced: true) {
            ForEach(Array(effectiveQuickActions.enumerated()), id: \.element.id) { index, action in
                QuickActionButton(action: action, onTap: onQuickAction)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(
                        theme.motion.springAnimation.delay(0.3 + Double(index) * 0.04),
                        value: hasAppeared
                    )
            }
        }
        .frame(maxWidth: 460)
        .padding(.top, theme.space.s8)
    }

    // MARK: - Helpers

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5 ..< 12: return L("Good morning")
        case 12 ..< 17: return L("Good afternoon")
        case 17 ..< 22: return L("Good evening")
        default: return L("Hello")
        }
    }
}

// MARK: - Shared download formatting

/// "1.2 GB / 7.5 GB · 24 MB/s · 4m 12s left" style status line for an
/// in-flight download, or nil when no metrics are known yet. Shared by the
/// no-models and pending-local-setup empty states.
@MainActor
private func downloadMetricsText(for modelId: String) -> String? {
    guard let metrics = ModelManager.shared.downloadMetrics[modelId] else { return nil }

    var parts: [String] = []

    if let received = metrics.bytesReceived, let total = metrics.totalBytes {
        parts.append("\(formatDownloadBytes(received)) / \(formatDownloadBytes(total))")
    }

    if let speed = metrics.bytesPerSecond {
        parts.append("\(formatDownloadBytes(Int64(speed)))/s")
    }

    if let eta = metrics.etaSeconds, eta > 0 && eta < 3600 {
        let minutes = Int(eta) / 60
        let seconds = Int(eta) % 60
        if minutes > 0 {
            parts.append(String(format: L("%dm %ds left"), minutes, seconds))
        } else {
            parts.append(String(format: L("%ds left"), seconds))
        }
    }

    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private func formatDownloadBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.includesUnit = true
    return formatter.string(fromByteCount: bytes)
}

/// Friendly display name for a model id, resolved from the catalog.
@MainActor
private func displayName(forModelId modelId: String) -> String {
    ModelManager.shared.availableModels.first { $0.id == modelId }?.simplifiedName
        ?? ModelManager.shared.suggestedModels.first { $0.id == modelId }?.simplifiedName
        ?? modelId
}

/// Kick a (re)download for a model id. Uses the onboarding proxy route —
/// these retries happen right after onboarding, before the user has any HF
/// token; a proxy failure silently falls back to the anonymous HF path.
@MainActor
private func restartDownload(forModelId modelId: String) {
    let model =
        ModelManager.shared.availableModels.first { $0.id == modelId }
        ?? ModelManager.shared.suggestedModels.first { $0.id == modelId }
    guard let model else { return }
    ModelManager.shared.downloadModel(model, route: .onboardingProxy)
}

/// Default agent avatar for setup/no-models states, where there is no active
/// chat agent to anchor to.
@MainActor
private func defaultWelcomeAvatar() -> some View {
    let agent =
        AgentManager.shared.agents.first(where: { $0.id == Agent.defaultId })
        ?? Agent.default
    return HeroAgentAvatar(agent: agent)
}

// MARK: - Secondary action pill (setup / recovery states)

/// Quiet capsule-outline action used by the setup and recovery empty states,
/// where several same-weight choices sit side by side (the gradient
/// `GetStartedButton` stays reserved for the single primary action).
private struct EmptyStateSecondaryButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s6) {
                if let icon {
                    Image(systemName: icon)
                        .glyphSize(.footnote, weight: .semibold)
                }
                Text(title, bundle: .module)
                    .textStyle(.label)
            }
            .foregroundColor(isHovered ? theme.text.primary : theme.text.secondary)
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s8)
            .background(
                Capsule()
                    .fill(isHovered ? theme.surface.subtle : Color.clear)
                    .overlay(
                        Capsule().strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovered = hovering }
        }
    }
}

// MARK: - Pending Local Setup (models exist, but the chosen one is arriving)

/// Post-onboarding setup state for the local-first path. The pinned private
/// model is still downloading (or paused / failed), so the included temporary
/// Osaurus Cloud model is connected automatically. It keeps local progress and
/// Cloud readiness in one place until the downloaded model takes over.
private struct ChatEmptyStateLocalSetup: View {
    let modelId: String
    let hasAppeared: Bool
    let temporaryCloudModelName: String?
    /// Automatic temporary Osaurus Cloud selection while local setup runs.
    /// Returns false when the Router couldn't be reached; the card then shows
    /// a retry rather than silently choosing another provider. nil hides the
    /// connection status entirely.
    let onUseHostedMeanwhile: (() async -> Bool)?
    let onOpenModelManager: () -> Void

    @ObservedObject private var modelManager = ModelManager.shared
    @Environment(\.theme) private var theme

    private var downloadState: DownloadState {
        modelManager.downloadStates[modelId] ?? .notStarted
    }

    var body: some View {
        VStack(spacing: theme.space.s16) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.motion.springAnimation.delay(0.0), value: hasAppeared)

            VStack(spacing: theme.space.s6) {
                Text(headline, bundle: .module)
                    .textStyle(.title)
                    .foregroundColor(theme.text.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.motion.springAnimation.delay(0.1), value: hasAppeared)

                Text(subtitle, bundle: .module)
                    .textStyle(.heading)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.motion.springAnimation.delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 560)

            LocalSetupPanel(
                modelId: modelId,
                temporaryCloudModelName: temporaryCloudModelName,
                onUseHostedMeanwhile: onUseHostedMeanwhile,
                onOpenModelManager: onOpenModelManager
            )
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 12)
            .animation(theme.motion.springAnimation.delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, theme.space.s40)
    }

    private var headline: LocalizedStringKey {
        switch downloadState {
        case .failed:
            return "Your private model needs attention"
        case .paused:
            return "Your private model is paused"
        case .downloading, .completed, .notStarted:
            return "The brain you picked is on the way"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch downloadState {
        case .failed, .paused:
            return "You can keep chatting with Osaurus Cloud."
        case .downloading, .completed, .notStarted:
            return "Start chatting now while Osaurus finishes setting up local AI."
        }
    }
}

/// The local setup strip above a chat's transcript: always in the
/// first-run chat, and in any other chat once the download is paused or
/// failed, so a stalled private model is not missed after setup.
struct PendingLocalSetupStrip: View {
    @ObservedObject var session: ChatSession
    let ownsFirstRun: Bool

    @ObservedObject private var modelManager = ModelManager.shared
    @Environment(\.theme) private var theme

    nonisolated static func shows(ownsFirstRun: Bool, state: DownloadState?) -> Bool {
        if ownsFirstRun { return true }
        switch state {
        case .paused?, .failed?: return true
        case .downloading?, .completed?, .notStarted?, nil: return false
        }
    }

    var body: some View {
        if let modelId = session.pendingLocalSetupModelId,
            Self.shows(ownsFirstRun: ownsFirstRun, state: modelManager.downloadStates[modelId])
        {
            LocalSetupPanel(
                modelId: modelId,
                temporaryCloudModelName: session.temporaryCloudModelDisplayName,
                onUseHostedMeanwhile: {
                    await session.adoptOsaurusRouterModelWhileLocalSetupPending()
                },
                onOpenModelManager: {
                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                },
                style: .strip
            )
            .readableColumnRow()
            .padding(.top, theme.space.s8)
            .transition(.opacity)
        }
    }
}

/// One visual object for the whole transition: local download and the
/// temporary Cloud readiness. The empty state shows it as a card; the
/// first-run chat pins it above the transcript as one compact strip.
/// Either way it starts the temporary Cloud handoff.
struct LocalSetupPanel: View {
    enum Style { case card, strip }

    let modelId: String
    let temporaryCloudModelName: String?
    let onUseHostedMeanwhile: (() async -> Bool)?
    let onOpenModelManager: () -> Void
    var style: Style = .card

    @ObservedObject private var modelManager = ModelManager.shared
    @Environment(\.theme) private var theme

    /// Lifecycle of the automatic Cloud handoff: idle → connecting → ready
    /// (reported by `temporaryCloudModelName`) | failed (retry stays).
    private enum CloudBridgePhase: Equatable {
        case idle
        case connecting
        case failed
    }

    @State private var bridgePhase: CloudBridgePhase = .idle

    private var downloadState: DownloadState {
        modelManager.downloadStates[modelId] ?? .notStarted
    }

    private var modelName: String {
        displayName(forModelId: modelId)
    }

    var body: some View {
        Group {
            switch style {
            case .card: setupPanel
            case .strip: setupStrip
            }
        }
        .task {
            guard temporaryCloudModelName == nil else { return }
            guard bridgePhase == .idle else { return }
            startCloudBridge()
        }
    }

    // MARK: Strip

    private var progress: Double? {
        switch downloadState {
        case .downloading(let progress), .paused(let progress): return progress
        case .completed: return 1
        case .failed, .notStarted: return nil
        }
    }

    private var setupStrip: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
        return HStack(spacing: theme.space.s12) {
            stripGlyph
            VStack(alignment: .leading, spacing: theme.space.s2) {
                stripTitle
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                if let detail = stripDetail {
                    Text(detail)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                        .help(detail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: theme.space.s8)
            stripDownloadActions
            if onUseHostedMeanwhile != nil {
                ViewThatFits(in: .horizontal) {
                    cloudChip(compact: false)
                    cloudChip(compact: true)
                }
            }
        }
        .padding(.leading, theme.space.s8)
        .padding(.trailing, theme.space.s12)
        .padding(.vertical, theme.space.s6)
        .background(shape.fill(theme.surface.subtle))
        .overlay(alignment: .bottomLeading) { stripProgress }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default))
        .animation(theme.motion.springAnimation, value: bridgePhase)
    }

    static let glyphSize: CGFloat = 28

    /// The download's phase on a tile of its status colour.
    @ViewBuilder
    private var stripGlyph: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
        Group {
            if let style = stripGlyphStyle {
                Image(systemName: style.symbol)
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundStyle(theme.status[style.kind].foreground)
                    .frame(width: Self.glyphSize, height: Self.glyphSize)
                    .background(shape.fill(theme.status[style.kind].background))
                    .contentTransition(.symbolEffect(.replace))
            } else {
                SettingsSpinner()
                    .frame(width: Self.glyphSize, height: Self.glyphSize)
            }
        }
        .padding(.leading, theme.space.s4)
        .accessibilityHidden(true)
    }

    private var stripGlyphStyle: (symbol: String, kind: ThemeStatusKind)? {
        switch downloadState {
        case .downloading: return ("arrow.down", .info)
        case .paused: return ("pause.fill", .warning)
        case .completed: return ("checkmark", .success)
        case .failed: return ("exclamationmark.triangle.fill", .warning)
        case .notStarted: return nil
        }
    }

    private var stripTitle: Text {
        switch downloadState {
        case .downloading: return Text(L("Downloading \(modelName)"))
        case .paused: return Text("Download paused", bundle: .module)
        case .failed: return Text("Local download needs attention", bundle: .module)
        case .completed: return Text("Private model ready", bundle: .module)
        case .notStarted: return Text("Preparing local download…", bundle: .module)
        }
    }

    private var stripDetail: String? {
        switch downloadState {
        case .downloading(let progress):
            let percent = "\(Int(progress * 100))%"
            return downloadMetricsText(for: modelId).map { "\(percent) · \($0)" } ?? percent
        case .paused(let progress):
            return "\(Int(progress * 100))%"
        case .failed(let error):
            return error
        case .completed, .notStarted:
            return nil
        }
    }

    @ViewBuilder
    private var stripDownloadActions: some View {
        switch downloadState {
        case .paused:
            SettingsButton(.tertiary, L("Resume download"), icon: "play.fill", size: .small, verbatim: true) {
                modelManager.resumeDownload(modelId)
            }
        case .failed:
            SettingsButton(.tertiary, L("Try again"), icon: "arrow.clockwise", size: .small, verbatim: true) {
                restartDownload(forModelId: modelId)
            }
            SettingsButton(.tertiary, L("Open Models"), icon: "square.grid.2x2", size: .small, verbatim: true,
                action: onOpenModelManager)
        case .downloading, .completed, .notStarted:
            EmptyView()
        }
    }

    /// Where chat runs until the private model lands.
    @ViewBuilder
    private func cloudChip(compact: Bool) -> some View {
        if let cloudModel = temporaryCloudModelName {
            chipLabel(
                icon: "cloud.fill", tint: theme.status.success.foreground,
                title: compact ? nil : L("Ready to chat now"))
                .help(L("\(cloudModel) on Osaurus Cloud · switches to local automatically"))
        } else {
            switch bridgePhase {
            case .idle, .connecting:
                HStack(spacing: theme.space.s6) {
                    SettingsSpinner(size: .mini)
                    if !compact {
                        Text("Getting Osaurus Cloud ready…", bundle: .module)
                            .textStyle(.caption, weight: 500)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(1)
                    }
                }
            case .failed:
                HStack(spacing: theme.space.s6) {
                    chipLabel(
                        icon: "exclamationmark.icloud", tint: theme.status.warning.foreground,
                        title: compact ? nil : L("Couldn't reach Osaurus Cloud"))
                    SettingsButton(.tertiary, L("Try again"), icon: "arrow.clockwise", size: .small, verbatim: true,
                        action: startCloudBridge)
                }
            }
        }
    }

    private func chipLabel(icon: String, tint: Color, title: String?) -> some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: icon)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(tint)
            if let title {
                Text(title)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// A hairline of progress along the strip's bottom edge.
    @ViewBuilder
    private var stripProgress: some View {
        if let progress {
            let paused: Bool = {
                if case .paused = downloadState { return true }
                return false
            }()
            GeometryReader { proxy in
                Rectangle()
                    .fill(paused ? theme.status.warning.foreground : theme.status.info.foreground)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
            .frame(height: theme.stroke.focus)
            .animation(theme.motion.standard, value: progress)
        }
    }

    private var setupPanel: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
        return VStack(spacing: theme.space.s14) {
            downloadStatus
            if onUseHostedMeanwhile != nil {
                ThemeHairlineDivider()
                cloudStatus
            }
        }
        .padding(theme.space.s16)
        .frame(maxWidth: 480)
        .background(shape.fill(theme.surface.subtle))
        .overlay(shape.strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default))
        .themeElevation(theme.elevation.overlay)
        .animation(theme.motion.springAnimation, value: bridgePhase)
    }

    @ViewBuilder
    private var downloadStatus: some View {
        switch downloadState {
        case .downloading(let progress):
            VStack(spacing: theme.space.s10) {
                HStack(spacing: theme.space.s10) {
                    statusIcon("arrow.down", color: theme.status.info.foreground)
                    Text(L("Downloading \(modelName)"))
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int(progress * 100))%", bundle: .module)
                        .textStyle(.caption, weight: 600, family: .code)
                        .foregroundColor(theme.text.secondary)
                }
                progressTrack(progress)
                if let metrics = downloadMetricsText(for: modelId) {
                    Text(metrics)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .paused(let progress):
            VStack(spacing: theme.space.s10) {
                HStack(spacing: theme.space.s10) {
                    statusIcon("pause.fill", color: theme.status.warning.foreground)
                    Text("Download paused", bundle: .module)
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)
                    Spacer(minLength: 8)
                    Text("\(Int(progress * 100))%", bundle: .module)
                        .textStyle(.caption, weight: 600, family: .code)
                        .foregroundColor(theme.text.secondary)
                }
                progressTrack(progress)
                HStack {
                    Spacer()
                    EmptyStateSecondaryButton(
                        title: "Resume download",
                        icon: "play.fill"
                    ) {
                        modelManager.resumeDownload(modelId)
                    }
                }
            }

        case .failed(let error):
            VStack(alignment: .leading, spacing: theme.space.s10) {
                HStack(spacing: theme.space.s10) {
                    statusIcon("exclamationmark", color: theme.status.warning.foreground)
                    Text("Local download needs attention", bundle: .module)
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)
                }
                Text(error)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.space.s8) {
                    EmptyStateSecondaryButton(title: "Try again", icon: "arrow.clockwise") {
                        restartDownload(forModelId: modelId)
                    }
                    EmptyStateSecondaryButton(
                        title: "Open Models",
                        icon: "square.grid.2x2",
                        action: onOpenModelManager
                    )
                }
            }

        case .completed:
            HStack(spacing: theme.space.s10) {
                statusIcon("checkmark", color: theme.status.success.foreground)
                Text("Private model ready", bundle: .module)
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                Spacer()
            }

        case .notStarted:
            HStack(spacing: theme.space.s10) {
                SettingsSpinner()
                Text("Preparing local download…", bundle: .module)
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var cloudStatus: some View {
        if let cloudModel = temporaryCloudModelName {
            HStack(alignment: .top, spacing: theme.space.s10) {
                statusIcon("checkmark", color: theme.status.success.foreground)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Ready to chat now", bundle: .module)
                        .textStyle(.caption, weight: 600)
                        .foregroundColor(theme.text.primary)
                    Text(L("\(cloudModel) on Osaurus Cloud · switches to local automatically"))
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        } else {
            switch bridgePhase {
            case .idle, .connecting:
                HStack(spacing: theme.space.s10) {
                    SettingsSpinner()
                    Text("Getting Osaurus Cloud ready…", bundle: .module)
                        .textStyle(.caption, weight: 500)
                        .foregroundColor(theme.text.secondary)
                    Spacer()
                }
            case .failed:
                HStack(spacing: theme.space.s10) {
                    statusIcon("exclamationmark", color: theme.status.warning.foreground)
                    VStack(alignment: .leading, spacing: theme.space.s4) {
                        Text("Couldn't reach Osaurus Cloud", bundle: .module)
                            .textStyle(.caption, weight: 600)
                            .foregroundColor(theme.text.primary)
                        EmptyStateSecondaryButton(
                            title: "Try again",
                            icon: "arrow.clockwise",
                            action: startCloudBridge
                        )
                    }
                    Spacer()
                }
            }
        }
    }

    private func statusIcon(_ systemName: String, color: Color) -> some View {
        ZStack {
            Circle().fill(theme.wash(behind: color))
            Image(systemName: systemName)
                .glyphSize(.tiny, weight: .bold)
                .foregroundColor(color)
        }
        .frame(width: 22, height: 22)
    }

    private func progressTrack(_ progress: Double) -> some View {
        GeometryReader { proxy in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surface.pressed)
                Capsule()
                    .fill(theme.status.info.foreground)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 7)
        .animation(theme.motion.standard, value: progress)
    }

    private func startCloudBridge() {
        guard bridgePhase != .connecting, let onUseHostedMeanwhile else { return }
        bridgePhase = .connecting
        Task {
            let succeeded = await onUseHostedMeanwhile()
            // On success the parent passes the selected Cloud model back into
            // this panel; only failure needs a separate recovery state.
            bridgePhase = succeeded ? .idle : .failed
        }
    }
}

// MARK: - No-Models / Downloading Wrapper (isolates ModelManager observation)

private struct ChatEmptyStateNoModels: View {
    let hasAppeared: Bool
    let onOpenOnboarding: (() -> Void)?
    var onOpenModelManager: (() -> Void)? = nil
    var onOpenProviders: (() -> Void)? = nil
    var onRetryConnection: (() async -> Void)? = nil

    @ObservedObject private var modelManager = ModelManager.shared
    @Environment(\.theme) private var theme
    @State private var isRetryingConnection = false

    /// Active download info (model ID and progress) if any download is in progress
    private var activeDownload: (modelId: String, progress: Double)? {
        for (modelId, state) in modelManager.downloadStates {
            if case .downloading(let progress) = state {
                return (modelId, progress)
            }
        }
        return nil
    }

    private var isDownloading: Bool { activeDownload != nil }
    private var downloadProgress: Double? { activeDownload?.progress }

    /// A download that gave up (no model landed, nothing else to chat on).
    /// Surfaced with a retry so the user isn't dumped back into the wizard.
    private var failedDownload: (modelId: String, message: String)? {
        for (modelId, state) in modelManager.downloadStates {
            if case .failed(let error) = state {
                return (modelId, error)
            }
        }
        return nil
    }

    private var downloadingModelName: String? {
        guard let modelId = activeDownload?.modelId else { return nil }
        return modelManager.availableModels.first { $0.id == modelId }?.name
            ?? modelManager.suggestedModels.first { $0.id == modelId }?.name
    }

    var body: some View {
        if isDownloading {
            downloadingState
        } else if let failure = failedDownload {
            failedDownloadState(failure)
        } else if !OnboardingService.shared.shouldShowOnboarding {
            // Onboarding finished but no model is reachable — most commonly
            // the managed Osaurus connection failed (offline, server hiccup).
            // Recover in place: retry, go local, or connect a provider —
            // never send the user back through the whole wizard.
            connectionRecoveryState
        } else {
            noModelsState
        }
    }

    private var noModelsState: some View {
        VStack(spacing: theme.space.s14) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.motion.springAnimation.delay(0.0), value: hasAppeared)

            VStack(spacing: theme.space.s8) {
                Text("One more step", bundle: .module)
                    .textStyle(.title)
                    .foregroundColor(theme.text.primary)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.motion.springAnimation.delay(0.1), value: hasAppeared)

                Text("Osaurus needs an AI to work — either a cloud provider or a local model.", bundle: .module)
                    .textStyle(.heading)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.motion.springAnimation.delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 340)

            GetStartedButton {
                onOpenOnboarding?()
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 12)
            .scaleEffect(hasAppeared ? 1 : 0.97)
            .animation(theme.motion.springAnimation.delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, theme.space.s40)
    }

    /// Recoverable first-chat state for a completed onboarding whose brain
    /// isn't reachable (e.g. the Osaurus connection failed while offline).
    private var connectionRecoveryState: some View {
        VStack(spacing: theme.space.s14) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.motion.springAnimation.delay(0.0), value: hasAppeared)

            VStack(spacing: theme.space.s8) {
                Text("Couldn't reach your AI", bundle: .module)
                    .textStyle(.title)
                    .foregroundColor(theme.text.primary)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.motion.springAnimation.delay(0.1), value: hasAppeared)

                Text(
                    "Osaurus couldn't connect to a model just now. Retry the connection, run a private model on this Mac, or use your own provider.",
                    bundle: .module
                )
                .textStyle(.heading)
                .foregroundColor(theme.text.secondary)
                .multilineTextAlignment(.center)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(theme.motion.springAnimation.delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 420)

            VStack(spacing: theme.space.s10) {
                if onRetryConnection != nil {
                    GetStartedButton(
                        title: isRetryingConnection ? "Retrying…" : "Retry connection"
                    ) {
                        retryConnection()
                    }
                }
                HStack(spacing: theme.space.s10) {
                    if let onOpenModelManager {
                        EmptyStateSecondaryButton(
                            title: "Run a local model",
                            icon: "cpu",
                            action: onOpenModelManager
                        )
                    }
                    if let onOpenProviders {
                        EmptyStateSecondaryButton(
                            title: "Connect a provider",
                            icon: "key.fill",
                            action: onOpenProviders
                        )
                    }
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 12)
            .animation(theme.motion.springAnimation.delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, theme.space.s40)
    }

    private func retryConnection() {
        guard !isRetryingConnection, let onRetryConnection else { return }
        isRetryingConnection = true
        Task {
            await onRetryConnection()
            isRetryingConnection = false
        }
    }

    /// The only download that could have produced a model failed and nothing
    /// else is available — surface the error with a way forward in place.
    private func failedDownloadState(_ failure: (modelId: String, message: String)) -> some View {
        VStack(spacing: theme.space.s14) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.motion.springAnimation.delay(0.0), value: hasAppeared)

            VStack(spacing: theme.space.s8) {
                Text("Download hit a snag", bundle: .module)
                    .textStyle(.title)
                    .foregroundColor(theme.text.primary)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.motion.springAnimation.delay(0.1), value: hasAppeared)

                Text(failure.message)
                    .textStyle(.heading)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.motion.springAnimation.delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 420)

            HStack(spacing: theme.space.s10) {
                GetStartedButton(title: "Try again") {
                    restartDownload(forModelId: failure.modelId)
                }
                if let onOpenModelManager {
                    EmptyStateSecondaryButton(title: "Open Models", action: onOpenModelManager)
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 12)
            .animation(theme.motion.springAnimation.delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, theme.space.s40)
    }

    private var downloadingState: some View {
        VStack(spacing: theme.space.s14) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.motion.springAnimation.delay(0.0), value: hasAppeared)

            VStack(spacing: theme.space.s8) {
                Text("Almost ready...", bundle: .module)
                    .textStyle(.title)
                    .foregroundColor(theme.text.primary)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.motion.springAnimation.delay(0.1), value: hasAppeared)

                if let name = downloadingModelName {
                    Text("Downloading \(name)", bundle: .module)
                        .textStyle(.heading)
                        .foregroundColor(theme.text.secondary)
                        .multilineTextAlignment(.center)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.motion.springAnimation.delay(0.17), value: hasAppeared)
                }
            }
            .frame(maxWidth: 340)

            if let progress = downloadProgress, let modelId = activeDownload?.modelId {
                VStack(spacing: theme.space.s10) {
                    SettingsProgressBar(value: progress, tint: theme.status.info.foreground)
                        .frame(maxWidth: 280)

                    HStack(spacing: theme.space.s0) {
                        if let text = downloadMetricsText(for: modelId) {
                            Text(text)
                                .textStyle(.caption)
                                .foregroundColor(theme.text.tertiary)
                        }
                        Spacer()
                        Text("\(Int(progress * 100))%", bundle: .module)
                            .textStyle(.caption, weight: 500, family: .code)
                            .foregroundColor(theme.text.tertiary)
                    }
                    .frame(maxWidth: 280)
                }
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.motion.springAnimation.delay(0.25), value: hasAppeared)
            }
        }
        .padding(.horizontal, theme.space.s40)
    }
}

// MARK: - Quick Action Button (shared by Chat & Work empty states)

/// One compact suggestion pill: glyph + single-line label in a capsule.
/// Sized to its content so a wrapping flow can pack any number of actions
/// into tidy centered rows.
/// One discovery under the greeting: tap to open it, or dismiss it for good.
struct DiscoveryCardView: View {
    let card: DiscoveryCard
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        HStack(spacing: theme.space.s8) {
            Button(action: onOpen) {
                HStack(spacing: theme.space.s8) {
                    SettingsIconTile(icon: card.icon, size: 24)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous))
                    Text(card.title)
                        .textStyle(.caption, weight: 500)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityHint(Text("Opens a short walkthrough", bundle: .module))

            SettingsIconButton("xmark", help: L("Dismiss"), size: .extraSmall, action: onDismiss)
                .accessibilityLabel(Text("Dismiss", bundle: .module))
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .frame(maxWidth: 420)
        .background(
            shape.fill(theme.action.secondary[isHovered ? .hover : .default].background)
                .overlay(
                    shape.strokeBorder(
                        isHovered ? theme.border.strong : theme.action.border, lineWidth: theme.stroke.default))
        )
        .onHover { isHovered = $0 }
        .padding(.top, theme.space.s4)
    }
}

/// The quiet link under the greeting to what is left in Set Up Osaurus,
/// and Skip setup beside it, which stops offering setup in new chats.
struct SetUpOsaurusLink: View {
    let left: Int
    let onOpen: () -> Void
    var onSkip: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isSkipHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space.s8) {
            Button(action: onOpen) {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "checklist")
                        .glyphSize(.footnote, weight: .medium)
                    Text(String(format: L("Set Up Osaurus: %lld left"), left))
                        .textStyle(.caption, weight: 500)
                }
                .foregroundColor(isHovered ? theme.text.primary : theme.text.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { isHovered = $0 }
            .accessibilityHint(Text("Lists what is left to set up", bundle: .module))

            if let onSkip {
                Text(verbatim: "·")
                    .textStyle(.caption)
                    .foregroundColor(theme.text.tertiary)
                    .accessibilityHidden(true)
                Button(action: onSkip) {
                    Text("Skip setup", bundle: .module)
                        .textStyle(.caption)
                        .foregroundColor(isSkipHovered ? theme.text.primary : theme.text.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .onHover { isSkipHovered = $0 }
                .help(Text("Stop suggesting setup in new chats", bundle: .module))
                .accessibilityHint(Text("Stop suggesting setup in new chats", bundle: .module))
            }
        }
        .padding(.top, theme.space.s2)
    }
}

struct QuickActionButton: View {
    let action: AgentQuickAction
    let onTap: (String) -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            onTap(action.prompt)
        } label: {
            HStack(spacing: theme.space.s6) {
                Image(systemName: action.icon)
                    .glyphSize(.caption, weight: .medium)
                    .foregroundColor(isHovered ? theme.text.primary : theme.text.secondary)

                // Single line, capped so an unusually long custom-agent
                // label truncates instead of producing a pill wider than
                // the flow container.
                Text(action.text)
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(isHovered ? theme.text.primary : theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .background(
                Capsule()
                    .fill(theme.action.secondary[isHovered ? .hover : .default].background)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isHovered ? theme.border.strong : theme.action.border,
                                lineWidth: theme.stroke.default
                            )
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Get Started Button

private struct GetStartedButton: View {
    var title: LocalizedStringKey = "Finish setup"
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s8) {
                Text(title, bundle: .module)
                    .textStyle(.label, weight: 600)

                Image(systemName: "arrow.right")
                    .glyphSize(.caption, weight: .semibold)
                    .offset(x: isHovered ? 2 : 0)
            }
            .foregroundColor(theme.action.primary[isHovered ? .hover : .default].foreground)
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s12)
            .background(
                Capsule()
                    .fill(theme.action.primary[isHovered ? .hover : .default].background)
            )
            .themeElevation(theme.elevation.raised)
        }
        .buttonStyle(.plain)
        .padding(.top, theme.space.s8)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ChatEmptyState_Previews: PreviewProvider {
        static var previews: some View {
            VStack {
                ChatEmptyState(
                    hasModels: true,
                    selectedModel: "foundation",
                    agents: [.default],
                    activeAgentId: Agent.default.id,
                    quickActions: AgentQuickAction.defaultChatQuickActions,
                    onOpenModelManager: {},
                    onUseFoundation: {},
                    onQuickAction: { _ in },
                    onOpenOnboarding: nil
                )
            }
            .frame(width: 700, height: 600)
            .background(CustomizableTheme.dark().surface.canvas)

            VStack {
                ChatEmptyState(
                    hasModels: false,
                    selectedModel: nil,
                    agents: [.default],
                    activeAgentId: Agent.default.id,
                    quickActions: AgentQuickAction.defaultChatQuickActions,
                    onOpenModelManager: {},
                    onUseFoundation: {},
                    onQuickAction: { _ in },
                    onOpenOnboarding: {}
                )
            }
            .frame(width: 700, height: 600)
            .background(CustomizableTheme.dark().surface.canvas)
        }
    }
#endif
