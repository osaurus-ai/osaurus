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

/// Diameter for hero-sized agent avatars in the empty-state surfaces.
private let heroAvatarDiameter: CGFloat = 64
/// Font size for the icon/monogram inside a hero avatar (built-in `person.fill`
/// placeholder and `AgentAvatarView` monogram fallback).
private let heroAvatarIconFontSize: CGFloat = 28

// MARK: - Shimmer Fade-In

/// One-shot shimmer + fade-in run when the bound `trigger` transitions to
/// a non-empty value. Used by `ChatEmptyState` so AI-generated greetings,
/// subtitles, and quick actions arrive with a subtle highlight sweep
/// instead of a hard cut. Idempotent: an unchanged or empty trigger
/// leaves content fully visible without animating, so the regular
/// staggered entrance is unaffected.
private struct ShimmerFadeIn: ViewModifier {
    /// Hashable fingerprint of the content being shimmered. The shimmer
    /// re-fires whenever this value changes to a non-nil, non-empty
    /// string — empty / nil values are treated as "static, no animation".
    let trigger: String?
    /// Highlight color for the sweeping band. Defaults to a soft white
    /// so the shimmer reads cleanly over both light and dark themes.
    var highlight: Color = .white

    /// Phase of the gradient sweep, in unit space across the masked
    /// content. Starts past the trailing edge so the modifier renders
    /// no shimmer at rest; gets reset to the leading edge when `run`
    /// fires and animates back out.
    @State private var phase: CGFloat = 1.5
    /// Fade-in opacity, snapped to 1 at rest so the static path renders
    /// the underlying view unchanged.
    @State private var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .overlay(
                LinearGradient(
                    colors: [.clear, highlight.opacity(0.7), .clear],
                    startPoint: UnitPoint(x: phase - 0.18, y: 0.5),
                    endPoint: UnitPoint(x: phase + 0.18, y: 0.5)
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            )
            .mask(content)
            .onChange(of: trigger ?? "") { oldValue, newValue in
                guard !newValue.isEmpty, oldValue != newValue else { return }
                run()
            }
    }

    private func run() {
        // Pre-roll instantaneously so the previous run's residual state
        // can't bleed into the new sweep.
        phase = -0.5
        opacity = 0
        withAnimation(.easeOut(duration: 0.45)) { opacity = 1 }
        withAnimation(.easeInOut(duration: 1.05).delay(0.05)) { phase = 1.5 }
    }
}

extension View {
    /// Adds a one-shot shimmer + fade-in run when `trigger` transitions to
    /// a non-empty value. See `ShimmerFadeIn` for behavior details.
    fileprivate func shimmerFadeIn(trigger: String?, highlight: Color = .white) -> some View {
        modifier(ShimmerFadeIn(trigger: trigger, highlight: highlight))
    }
}

// MARK: - Hero Agent Avatar

/// Renders a hero-sized avatar for a given agent. Built-in and custom
/// agents share the same `AgentAvatarView` path so the default Osaurus
/// agent gets the same gradient-circle backing as every other agent —
/// previously the built-in branch rendered the mascot PNG without that
/// backing, leaving the dino floating against the chat background.
/// Shared by `ChatEmptyState.heroAvatar` and `ChatEmptyStateNoModels.welcomeAvatar`.
private struct HeroAgentAvatar: View {
    let agent: Agent

    var body: some View {
        AgentAvatarView(
            mascotId: agent.avatar,
            name: agent.name,
            tint: agentColorFor(agent.name),
            diameter: heroAvatarDiameter,
            customImageURL: agent.customAvatarURL,
            monogramFontSize: heroAvatarIconFontSize,
            borderWidth: 0,
            bleedsToEdge: true
        )
    }
}

struct ChatEmptyState: View {
    let hasModels: Bool
    let selectedModel: String?
    let agents: [Agent]
    let activeAgentId: UUID
    let quickActions: [AgentQuickAction]
    /// Lifecycle of the AI-produced greeting/subtitle/actions. `.idle`,
    /// `.loading`, and `.failed` all render the static defaults (the
    /// agent's configured greeting + quick actions, or the time-of-day
    /// fallback). Only `.ready(payload)` swaps in the AI content, with
    /// a shimmer fade-in. We deliberately don't render a skeleton during
    /// `.loading` — small Core Models can take several seconds to
    /// produce a greeting, and a skeleton makes that wait feel slow
    /// even though the static greeting is perfectly usable.
    var generativeGreetingState: GenerativeGreetingState = .idle
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
    /// setup runs (DeepSeek V4 Flash for first-run). Nil means Cloud still
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
    var activeDiscoveredAgent: DiscoveredAgent? = nil
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

    @State private var hasAppeared = false
    @Environment(\.theme) private var theme

    private var activeAgent: Agent {
        agents.first { $0.id == activeAgentId } ?? Agent.default
    }

    /// Unwrapped payload for `.ready` so the rest of the file can use a
    /// plain optional check without re-pattern-matching the enum.
    private var readyGreeting: GenerativeGreeting? {
        if case .ready(let g) = generativeGreetingState { return g }
        return nil
    }

    /// True when this empty state heads a Mode 2 remote-agent conversation.
    private var isRemoteChat: Bool {
        activeRelayAgent != nil || activeDiscoveredAgent != nil
    }

    /// Display name of the active remote agent (Mode 2), if any. Drives the
    /// empty-state title so a remote conversation is headed by the remote
    /// agent's own name rather than the local agent's greeting.
    private var remoteAgentName: String? {
        if let relay = activeRelayAgent {
            let trimmed = relay.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let discovered = activeDiscoveredAgent {
            let trimmed = discovered.name.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// local one), 2. AI-generated greeting (when ready), 3. per-agent override
    /// (`Agent.chatGreeting`), 4. time-of-day default. Whitespace-only strings
    /// are treated as nil so a cleared field falls through to the next layer.
    private var greetingText: String {
        // A remote agent owns the conversation: never surface the local
        // agent's generative/custom greeting here.
        if isRemoteChat {
            return remoteDisplayName
        }
        if let g = readyGreeting?.greeting,
            !g.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return g
        }
        if let custom = activeAgent.chatGreeting?.trimmingCharacters(in: .whitespacesAndNewlines),
            !custom.isEmpty
        {
            return custom
        }
        return greeting
    }

    /// Subtitle rendered beneath the greeting. Same precedence as
    /// `greetingText`: AI-generated → per-agent override
    /// (`Agent.chatSubtitle`) → localized default.
    private var subtitleText: LocalizedStringKey {
        // Remote agent run: surface the remote agent's own description (so it
        // introduces itself), never the local agent's generative/custom
        // subtitle. Falls back to the neutral default when it has none.
        if isRemoteChat {
            if let d = remoteAgentDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                !d.isEmpty
            {
                return LocalizedStringKey(d)
            }
            return "How can I help you today?"
        }
        if let s = readyGreeting?.subtitle,
            !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return LocalizedStringKey(s)
        }
        if let custom = activeAgent.chatSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !custom.isEmpty
        {
            return LocalizedStringKey(custom)
        }
        return "How can I help you today?"
    }

    /// Quick actions to render. Generative actions override the agent's
    /// configured shortcuts when they arrive; the user's custom shortcuts
    /// (or the static defaults) act as the fallback.
    private var effectiveQuickActions: [AgentQuickAction] {
        // Mode 2: surface the remote agent's own Action Bar when it advertised
        // one over the Secure Channel; otherwise fall back to neutral chat
        // defaults (never the local agent's shortcuts — e.g. a local coding
        // agent's actions don't represent a remote research agent).
        if isRemoteChat {
            if let remote = remoteAgentQuickActions, !remote.isEmpty { return remote }
            return AgentQuickAction.defaultChatQuickActions
        }
        if let g = readyGreeting?.actions, !g.isEmpty { return g }
        return quickActions
    }

    /// Transport-security status for the active remote agent, if any.
    /// Relay agents are always end-to-end encrypted (the Secure Channel is
    /// hard-required for agent traffic); Bonjour peers advertise support via
    /// `osc=1` — peers without it must upgrade before they can chat.
    private enum RemoteEncryptionStatus {
        case endToEndEncrypted
        case peerNeedsUpgrade
    }

    private var remoteEncryptionStatus: RemoteEncryptionStatus? {
        if activeRelayAgent != nil { return .endToEndEncrypted }
        if let discovered = activeDiscoveredAgent {
            return discovered.supportsSecureChannel ? .endToEndEncrypted : .peerNeedsUpgrade
        }
        return nil
    }

    /// Drives the SwiftUI `.animation(value:)` so the title/subtitle/actions
    /// animate together when the generative payload swaps in.
    private var generativeFingerprint: String {
        guard let g = readyGreeting else { return "static" }
        return "gen:\(g.greeting)|\(g.subtitle)|\(g.actions.count)"
    }

    /// Fingerprint for the quick-action grid so the shimmer + staggered entrance
    /// re-fires when the actions change. Remote: keyed on the *stored* fetched
    /// action ids (stable across renders) so it fires once when the Action Bar
    /// lands. Local: reuse `generativeFingerprint` — default/generative actions
    /// mint fresh ids per access, so id-keying there would churn every render.
    private var quickActionsFingerprint: String {
        if isRemoteChat {
            guard let remote = remoteAgentQuickActions, !remote.isEmpty else { return "static" }
            return "remote:\(remote.count):" + remote.map { $0.id.uuidString }.joined(separator: ",")
        }
        return generativeFingerprint
    }

    /// Stable identity for the subtitle Text so SwiftUI treats each
    /// resolved variant (generative / agent-override / static default)
    /// as a distinct node, enabling the cross-fade.
    private var subtitleFingerprint: String {
        if let s = readyGreeting?.subtitle { return "gen:\(s)" }
        if let custom = activeAgent.chatSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !custom.isEmpty
        {
            return "agent:\(custom)"
        }
        return "static"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
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
                withAnimation(theme.animationSlow()) {
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
        VStack(spacing: 14) {
            // Hero avatar — agent's mascot as the focal point
            heroAvatar
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            // Always paint the greeting block. When the AI response
            // arrives later (state flips to `.ready`), the
            // `shimmerFadeIn` modifiers inside sweep a highlight
            // across the new text + quick actions so the swap reads
            // as intentional rather than a hard cut.
            greetingBlock
        }
        .padding(.horizontal, 40)
    }

    /// Greeting + subtitle + quick actions block. Rendered for every
    /// generative state — including `.loading` — so the empty state
    /// always paints instantly. When `.ready` finally lands, the
    /// `shimmerFadeIn` modifiers below sweep a highlight across the
    /// freshly visible text and quick-action grid as a soft swap-in cue.
    @ViewBuilder
    private var greetingBlock: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(greetingText)
                        .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if readyGreeting != nil {
                        Image(systemName: "sparkles")
                            .font(.system(size: CGFloat(theme.bodySize) + 2, weight: .semibold))
                            .foregroundColor(theme.accentColorLight.opacity(0.85))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .id("greeting-\(greetingText)")
                .shimmerFadeIn(
                    trigger: readyGreeting?.greeting,
                    highlight: theme.accentColorLight
                )
                // Pure-opacity transition for downstream generative
                // refreshes — the slide-from-top duplicate the
                // ZStack-level cross-fade and made the greeting wobble.
                .transition(.opacity)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text(subtitleText, bundle: .module)
                    .id("subtitle-\(subtitleFingerprint)")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .shimmerFadeIn(
                        trigger: readyGreeting?.subtitle,
                        highlight: theme.accentColorLight
                    )
                    .transition(.opacity)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)

                if securityBadgeState != nil {
                    securityBadge
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 12)
                        .animation(theme.springAnimation().delay(0.24), value: hasAppeared)
                }
            }
            .animation(theme.springAnimation(), value: generativeFingerprint)

            if !effectiveQuickActions.isEmpty {
                staggeredQuickActions
                    .shimmerFadeIn(
                        trigger: quickActionsFingerprint == "static" ? nil : quickActionsFingerprint,
                        highlight: theme.accentColorLight
                    )
                    .animation(theme.springAnimation(), value: quickActionsFingerprint)
            }
        }
    }

    @ViewBuilder
    private var heroAvatar: some View {
        if isRemoteChat {
            // Match the local hero: the remote agent's own mascot (surfaced over
            // the Secure Channel), falling back to a monogram on its name.
            AgentAvatarView(
                mascotId: remoteAgentAvatar,
                name: remoteDisplayName,
                tint: agentColorFor(remoteDisplayName),
                diameter: heroAvatarDiameter,
                customImageURL: nil,
                monogramFontSize: heroAvatarIconFontSize,
                borderWidth: 0,
                bleedsToEdge: true
            )
        } else {
            HeroAgentAvatar(agent: activeAgent)
        }
    }

    /// Presentation state for the security badge under the greeting.
    /// `connecting` takes precedence — the secure channel isn't up yet, so we
    /// must not claim encryption — and once connected it reflects the transport
    /// status. nil = not a remote chat / nothing to show (no badge).
    private enum SecurityBadgeState: Hashable {
        case connecting
        case encrypted
        case peerNeedsUpgrade
    }

    private var securityBadgeState: SecurityBadgeState? {
        if isConnecting { return .connecting }
        switch remoteEncryptionStatus {
        case .endToEndEncrypted: return .encrypted
        case .peerNeedsUpgrade: return .peerNeedsUpgrade
        case nil: return nil
        }
    }

    private func securityBadgeTint(_ state: SecurityBadgeState) -> Color {
        switch state {
        case .connecting: return theme.accentColor
        case .encrypted: return theme.successColor
        case .peerNeedsUpgrade: return theme.warningColor
        }
    }

    @ViewBuilder
    private func securityBadgeIcon(_ state: SecurityBadgeState) -> some View {
        switch state {
        case .connecting:
            MorphingStatusIcon(state: .active, accentColor: theme.accentColor, size: 12)
        case .encrypted, .peerNeedsUpgrade:
            Image(systemName: state == .encrypted ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
        }
    }

    private func securityBadgeLabel(_ state: SecurityBadgeState) -> Text {
        switch state {
        case .connecting:
            return Text("Securing connection…", bundle: .module)
        case .encrypted:
            return Text("End-to-end encrypted", bundle: .module)
        case .peerNeedsUpgrade:
            return Text("Peer needs an Osaurus upgrade for encrypted chat", bundle: .module)
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
        case .peerNeedsUpgrade:
            return L(
                "This peer runs an older Osaurus without the Secure Channel. Agent chat is refused until it upgrades — no plaintext fallback."
            )
        }
    }

    /// Single capsule under the greeting that *morphs* between the connect
    /// loader and the resolved transport-security state. Same chrome/padding
    /// across states so it never resize-jumps; the tint springs from accent
    /// (connecting) to success (encrypted) / warning (needs upgrade), the icon
    /// crossfades spinner -> lock, and the label content-transitions in place.
    @ViewBuilder
    private var securityBadge: some View {
        if let state = securityBadgeState {
            let tint = securityBadgeTint(state)
            HStack(spacing: 5) {
                securityBadgeIcon(state)
                    .frame(width: 14, height: 14)
                    .id(state)
                    .transition(.opacity)
                securityBadgeLabel(state)
                    .contentTransition(.opacity)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(theme.isDark ? 0.14 : 0.10)))
            .animation(theme.springAnimation(), value: state)
            .help(securityBadgeHelp(state))
        }
    }

    private var staggeredQuickActions: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            spacing: 12
        ) {
            ForEach(Array(effectiveQuickActions.enumerated()), id: \.element.id) { index, action in
                QuickActionButton(action: action, onTap: onQuickAction)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(
                        theme.springAnimation().delay(0.35 + Double(index) * 0.05),
                        value: hasAppeared
                    )
            }
        }
        .frame(maxWidth: 440)
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
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title, bundle: .module)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(isHovered ? theme.secondaryBackground : Color.clear)
                    .overlay(
                        Capsule().strokeBorder(theme.primaryBorder.opacity(0.6), lineWidth: 1)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) { isHovered = hovering }
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
        VStack(spacing: 16) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            VStack(spacing: 6) {
                Text(headline, bundle: .module)
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text(subtitle, bundle: .module)
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 560)

            setupPanel
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 12)
                .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, 40)
        .task {
            guard temporaryCloudModelName == nil else { return }
            guard bridgePhase == .idle else { return }
            startCloudBridge()
        }
    }

    /// One visual object for the whole transition: local download on top,
    /// temporary Cloud readiness below. This replaces the old loose progress
    /// bar + tiny caption, which looked disconnected in the large empty state.
    private var setupPanel: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 14) {
            downloadStatus
            if onUseHostedMeanwhile != nil {
                Rectangle()
                    .fill(theme.primaryBorder.opacity(0.35))
                    .frame(height: 1)
                cloudStatus
            }
        }
        .padding(18)
        .frame(maxWidth: 480)
        .background(shape.fill(theme.secondaryBackground.opacity(theme.isDark ? 0.42 : 0.62)))
        .overlay(shape.strokeBorder(theme.primaryBorder.opacity(0.45), lineWidth: 1))
        .shadow(color: theme.shadowColor.opacity(0.07), radius: 14, y: 5)
        .animation(theme.springAnimation(), value: bridgePhase)
    }

    @ViewBuilder
    private var downloadStatus: some View {
        switch downloadState {
        case .downloading(let progress):
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    statusIcon("arrow.down", color: theme.accentColor)
                    Text(L("Downloading \(modelName)"))
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int(progress * 100))%", bundle: .module)
                        .font(theme.font(size: 12, weight: .semibold).monospaced())
                        .foregroundColor(theme.secondaryText)
                }
                progressTrack(progress)
                if let metrics = downloadMetricsText(for: modelId) {
                    Text(metrics)
                        .font(theme.font(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .paused(let progress):
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    statusIcon("pause.fill", color: theme.warningColor)
                    Text("Download paused", bundle: .module)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer(minLength: 8)
                    Text("\(Int(progress * 100))%", bundle: .module)
                        .font(theme.font(size: 12, weight: .semibold).monospaced())
                        .foregroundColor(theme.secondaryText)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    statusIcon("exclamationmark", color: theme.warningColor)
                    Text("Local download needs attention", bundle: .module)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }
                Text(error)
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
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
            HStack(spacing: 10) {
                statusIcon("checkmark", color: theme.successColor)
                Text("Private model ready", bundle: .module)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }

        case .notStarted:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing local download…", bundle: .module)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var cloudStatus: some View {
        if let cloudModel = temporaryCloudModelName {
            HStack(alignment: .top, spacing: 10) {
                statusIcon("checkmark", color: theme.successColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to chat now", bundle: .module)
                        .font(theme.font(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(L("\(cloudModel) on Osaurus Cloud · switches to local automatically"))
                        .font(theme.font(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        } else {
            switch bridgePhase {
            case .idle, .connecting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Getting Osaurus Cloud ready…", bundle: .module)
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                }
            case .failed:
                HStack(spacing: 10) {
                    statusIcon("exclamationmark", color: theme.warningColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Couldn't reach Osaurus Cloud", bundle: .module)
                            .font(theme.font(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
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
            Circle().fill(color.opacity(0.14))
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
        }
        .frame(width: 22, height: 22)
    }

    private func progressTrack(_ progress: Double) -> some View {
        GeometryReader { proxy in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.primaryBorder.opacity(0.25))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.72)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.25), value: progress)
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
        VStack(spacing: 14) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            VStack(spacing: 8) {
                Text("One more step", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text("Osaurus needs an AI to work — either a cloud provider or a local model.", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 340)

            GetStartedButton {
                onOpenOnboarding?()
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 12)
            .scaleEffect(hasAppeared ? 1 : 0.97)
            .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, 40)
    }

    /// Recoverable first-chat state for a completed onboarding whose brain
    /// isn't reachable (e.g. the Osaurus connection failed while offline).
    private var connectionRecoveryState: some View {
        VStack(spacing: 14) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            VStack(spacing: 8) {
                Text("Couldn't reach your AI", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text(
                    "Osaurus couldn't connect to a model just now. Retry the connection, run a private model on this Mac, or use your own provider.",
                    bundle: .module
                )
                .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 420)

            VStack(spacing: 10) {
                if onRetryConnection != nil {
                    GetStartedButton(
                        title: isRetryingConnection ? "Retrying…" : "Retry connection"
                    ) {
                        retryConnection()
                    }
                }
                HStack(spacing: 10) {
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
            .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, 40)
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
        VStack(spacing: 14) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            VStack(spacing: 8) {
                Text("Download hit a snag", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text(failure.message)
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 420)

            HStack(spacing: 10) {
                GetStartedButton(title: "Try again") {
                    restartDownload(forModelId: failure.modelId)
                }
                if let onOpenModelManager {
                    EmptyStateSecondaryButton(title: "Open Models", action: onOpenModelManager)
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 12)
            .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, 40)
    }

    private var downloadingState: some View {
        VStack(spacing: 14) {
            defaultWelcomeAvatar()
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            VStack(spacing: 8) {
                Text("Almost ready...", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                if let name = downloadingModelName {
                    Text("Downloading \(name)", bundle: .module)
                        .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
                }
            }
            .frame(maxWidth: 340)

            if let progress = downloadProgress, let modelId = activeDownload?.modelId {
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                        .tint(theme.accentColor)

                    HStack(spacing: 0) {
                        if let text = downloadMetricsText(for: modelId) {
                            Text(text)
                                .font(theme.font(size: 12))
                                .foregroundColor(theme.tertiaryText)
                        }
                        Spacer()
                        Text("\(Int(progress * 100))%", bundle: .module)
                            .font(theme.font(size: 12, weight: .medium).monospaced())
                            .foregroundColor(theme.tertiaryText)
                    }
                    .frame(maxWidth: 280)
                }
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
            }
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Quick Action Button (shared by Chat & Work empty states)

struct QuickActionButton: View {
    let action: AgentQuickAction
    let onTap: (String) -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            onTap(action.prompt)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                    .frame(width: 20)

                // 2-line ceiling lets long localized labels and the rare
                // 2-word AI emit ("Strategy Review") wrap instead of
                // truncating with an ellipsis. `minimumScaleFactor`
                // shrinks the type as a last resort. `fixedSize(vertical)`
                // grows the row instead of clipping when wrapping fires.
                Text(action.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : -5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isHovered
                            ? theme.secondaryBackground
                            : theme.secondaryBackground.opacity(theme.isDark ? 0.5 : 0.8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isHovered
                                    ? theme.primaryBorder
                                    : theme.primaryBorder.opacity(theme.isDark ? 0.3 : 0.5),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
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
            HStack(spacing: 8) {
                Text(title, bundle: .module)
                    .font(.system(size: 14, weight: .semibold))

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .offset(x: isHovered ? 2 : 0)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.85),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(
                        color: theme.accentColor.opacity(isHovered ? 0.4 : 0.2),
                        radius: isHovered ? 12 : 8,
                        x: 0,
                        y: 4
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
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
            .background(Color(hex: "0f0f10"))

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
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
