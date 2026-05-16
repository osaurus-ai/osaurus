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
private let heroAvatarDiameter: CGFloat = 128
/// Font size for the icon/monogram inside a hero avatar (built-in `person.fill`
/// placeholder and `AgentAvatarView` monogram fallback).
private let heroAvatarIconFontSize: CGFloat = 56
/// Font size for the SF Symbol inside the remote-hero avatar (relay / discovered).
private let heroAvatarRemoteIconFontSize: CGFloat = 48

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

/// Renders a hero-sized avatar for a given agent: either the built-in
/// placeholder (theme-tinted circle + `person.fill`) or the mascot
/// illustration via `AgentAvatarView` with `bleedsToEdge: true`.
/// Shared by `ChatEmptyState.heroAvatar` and `ChatEmptyStateNoModels.welcomeAvatar`.
private struct HeroAgentAvatar: View {
    let agent: Agent
    @Environment(\.theme) private var theme

    var body: some View {
        if agent.isBuiltIn {
            ZStack {
                Circle()
                    .fill(theme.secondaryText.opacity(theme.isDark ? 0.12 : 0.08))
                Image(systemName: "person.fill")
                    .font(.system(size: heroAvatarIconFontSize, weight: .medium))
                    .foregroundColor(theme.secondaryText.opacity(0.85))
            }
            .frame(width: heroAvatarDiameter, height: heroAvatarDiameter)
        } else {
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
}

struct ChatEmptyState: View {
    let hasModels: Bool
    let selectedModel: String?
    let agents: [Agent]
    let activeAgentId: UUID
    let quickActions: [AgentQuickAction]
    /// Lifecycle of the AI-produced greeting/subtitle/actions. `.idle` and
    /// `.failed` render the static defaults, `.loading` shows an animated
    /// skeleton, and `.ready(payload)` shows the generated content with a
    /// shimmer fade-in. Defaults to `.idle` so previews and tests don't
    /// have to opt in.
    var generativeGreetingState: GenerativeGreetingState = .idle
    let onOpenModelManager: () -> Void
    let onUseFoundation: (() -> Void)?
    let onQuickAction: (String) -> Void
    let onOpenOnboarding: (() -> Void)?
    var activeDiscoveredAgent: DiscoveredAgent? = nil
    var activeRelayAgent: PairedRelayAgent? = nil

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

    /// True while inference is in flight — drives the skeleton render.
    private var isLoadingGenerativeGreeting: Bool {
        if case .loading = generativeGreetingState { return true }
        return false
    }

    /// Title text rendered above the subtitle. Resolution order:
    /// 1. AI-generated greeting (when ready), 2. per-agent override
    /// (`Agent.chatGreeting`), 3. time-of-day default. Whitespace-only
    /// strings are treated as nil so a cleared field falls through to
    /// the next layer.
    private var greetingText: String {
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
        if let g = readyGreeting?.actions, !g.isEmpty { return g }
        return quickActions
    }

    /// Drives the SwiftUI `.animation(value:)` so the title/subtitle/actions
    /// animate together when the generative payload swaps in.
    private var generativeFingerprint: String {
        guard let g = readyGreeting else { return "static" }
        return "gen:\(g.greeting)|\(g.subtitle)|\(g.actions.count)"
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

    /// Coarse identity that flips between skeleton and content blocks. We
    /// fold all non-loading states (idle, ready, failed) into a single
    /// "content" key so the cross-fade plays exactly once on the
    /// loading→content boundary instead of also retriggering on failure.
    private var contentBlockKey: String {
        isLoadingGenerativeGreeting ? "skeleton" : "content"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)

                    if hasModels {
                        readyState
                    } else {
                        ChatEmptyStateNoModels(
                            hasAppeared: hasAppeared,
                            onOpenOnboarding: onOpenOnboarding
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

            // Skeleton vs real content. Pure cross-fade so the arrival
            // reads as a "shimmer fade load": the skeleton dissolves
            // while `realGreetingBlock`'s `shimmerFadeIn` modifiers
            // sweep a gradient across the freshly visible text and
            // quick-actions. A spring would re-introduce a perceptible
            // vertical wiggle here — `easeOut(0.45)` keeps the
            // transition flat and quiet.
            ZStack {
                if isLoadingGenerativeGreeting {
                    GreetingSkeleton()
                        .transition(.opacity)
                } else {
                    realGreetingBlock
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.45), value: contentBlockKey)
        }
        .padding(.horizontal, 40)
    }

    /// The real (non-skeleton) greeting + subtitle + quick actions block.
    /// Rendered for `.idle`, `.failed`, and `.ready`. The shimmer-fade-in
    /// modifier inside is a no-op until the generative fingerprint
    /// becomes non-static, at which point it sweeps once across the new
    /// content.
    @ViewBuilder
    private var realGreetingBlock: some View {
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
            }
            .animation(theme.springAnimation(), value: generativeFingerprint)

            if !effectiveQuickActions.isEmpty {
                staggeredQuickActions
                    .shimmerFadeIn(
                        trigger: generativeFingerprint == "static" ? nil : generativeFingerprint,
                        highlight: theme.accentColorLight
                    )
                    .animation(theme.springAnimation(), value: generativeFingerprint)
            }
        }
    }

    @ViewBuilder
    private var heroAvatar: some View {
        if let relay = activeRelayAgent {
            remoteHeroAvatar(systemImage: "antenna.radiowaves.left.and.right", seed: relay.name)
        } else if let discovered = activeDiscoveredAgent {
            remoteHeroAvatar(systemImage: "network", seed: discovered.name)
        } else {
            HeroAgentAvatar(agent: activeAgent)
        }
    }

    private func remoteHeroAvatar(systemImage: String, seed: String) -> some View {
        ZStack {
            Circle()
                .fill(theme.accentColorLight.opacity(theme.isDark ? 0.18 : 0.12))
            Image(systemName: systemImage)
                .font(.system(size: heroAvatarRemoteIconFontSize, weight: .semibold))
                .foregroundColor(theme.accentColorLight)
        }
        .frame(width: heroAvatarDiameter, height: heroAvatarDiameter)
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

// MARK: - Greeting Skeleton

/// Animated placeholder shown while `GenerativeGreetingService` is in
/// flight. Layout is hand-tuned to match `realGreetingBlock`'s metrics so
/// the loading→ready cross-fade introduces zero layout shift: a wide
/// title bar (greeting), a narrower bar (subtitle), then four
/// rounded-rect cards in the same 2x2 grid as `staggeredQuickActions`.
/// Shimmer pattern mirrors `OnboardingButtons`' `shimmerPhase` —
/// continuous left-to-right sweep that reads as "thinking" without being
/// loud.
private struct GreetingSkeleton: View {
    @Environment(\.theme) private var theme
    @State private var phase: CGFloat = -0.4

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                placeholderBar(width: 200, height: 24, corner: 6)
                placeholderBar(width: 260, height: 16, corner: 5)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                spacing: 12
            ) {
                ForEach(0 ..< 4, id: \.self) { _ in
                    placeholderCard
                }
            }
            .frame(maxWidth: 440)
        }
        .onAppear {
            // Continuous sweep — repeatForever drives the shimmer until
            // the parent swaps the skeleton out for the real content
            // block. SwiftUI tears down the @State on disappear so the
            // next mount restarts cleanly.
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                phase = 1.4
            }
        }
    }

    /// Single horizontal bar (used for the greeting and subtitle lines).
    private func placeholderBar(width: CGFloat, height: CGFloat, corner: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return
            shape
            .fill(baseFill)
            .frame(width: width, height: height)
            .overlay(shimmerBand(width: width).clipShape(shape))
    }

    /// One quick-action card, sized to roughly match `QuickActionButton`'s
    /// 16pt vertical padding + 13pt label height. We only render an inner
    /// label bar instead of mimicking the icon/arrow chrome so the
    /// skeleton reads as "filling in" rather than promising specific
    /// glyphs.
    private var placeholderCard: some View {
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack(alignment: .leading) {
            cardShape
                .fill(baseFill)
                .overlay(
                    cardShape.strokeBorder(
                        theme.primaryBorder.opacity(theme.isDark ? 0.3 : 0.5),
                        lineWidth: 1
                    )
                )

            // Inner "label" bar — placed at the same horizontal inset as
            // a real `QuickActionButton`'s text would sit (16pt padding +
            // 20pt icon column + 10pt gap = ~46pt from leading edge).
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.primaryText.opacity(theme.isDark ? 0.18 : 0.14))
                .frame(width: 110, height: 10)
                .padding(.leading, 46)
        }
        .frame(height: 50)
        .overlay(shimmerBand(width: nil).clipShape(cardShape))
    }

    /// Base fill used by both the bars and the cards. Slightly more
    /// opaque than `QuickActionButton`'s idle background so the skeleton
    /// reads as "placeholder" rather than "empty button".
    private var baseFill: Color {
        theme.secondaryBackground.opacity(theme.isDark ? 0.55 : 0.85)
    }

    /// Moving highlight band layered over each placeholder. We keep the
    /// gradient narrow (40pt-ish) so it feels like a sweep instead of a
    /// flood, and apply a small blur so the edge isn't sharp on Retina.
    private func shimmerBand(width: CGFloat?) -> some View {
        GeometryReader { geo in
            let drawWidth = width ?? geo.size.width
            LinearGradient(
                colors: [
                    .clear,
                    theme.primaryText.opacity(theme.isDark ? 0.20 : 0.14),
                    .clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 60)
            .offset(x: phase * drawWidth)
            .blur(radius: 1.5)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - No-Models / Downloading Wrapper (isolates ModelManager observation)

private struct ChatEmptyStateNoModels: View {
    let hasAppeared: Bool
    let onOpenOnboarding: (() -> Void)?

    @ObservedObject private var modelManager = ModelManager.shared
    @Environment(\.theme) private var theme

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

    private var downloadingModelName: String? {
        guard let modelId = activeDownload?.modelId else { return nil }
        return modelManager.availableModels.first { $0.id == modelId }?.name
            ?? modelManager.suggestedModels.first { $0.id == modelId }?.name
    }

    private var downloadProgressText: String? {
        guard let modelId = activeDownload?.modelId,
            let metrics = modelManager.downloadMetrics[modelId]
        else { return nil }

        var parts: [String] = []

        if let received = metrics.bytesReceived, let total = metrics.totalBytes {
            parts.append("\(formatBytes(received)) / \(formatBytes(total))")
        }

        if let speed = metrics.bytesPerSecond {
            parts.append("\(formatBytes(Int64(speed)))/s")
        }

        if let eta = metrics.etaSeconds, eta > 0 && eta < 3600 {
            let minutes = Int(eta) / 60
            let seconds = Int(eta) % 60
            if minutes > 0 {
                parts.append("\(minutes)m \(seconds)s left")
            } else {
                parts.append("\(seconds)s left")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    /// Default agent avatar used for the no-models / downloading states,
    /// where there is no active chat agent to anchor to.
    private var welcomeAvatar: some View {
        let agent =
            AgentManager.shared.agents.first(where: { $0.id == Agent.defaultId })
            ?? Agent.default
        return HeroAgentAvatar(agent: agent)
    }

    var body: some View {
        if isDownloading {
            downloadingState
        } else {
            noModelsState
        }
    }

    private var noModelsState: some View {
        VStack(spacing: 14) {
            welcomeAvatar
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

    private var downloadingState: some View {
        VStack(spacing: 14) {
            welcomeAvatar
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

            if let progress = downloadProgress {
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                        .tint(theme.accentColor)

                    HStack(spacing: 0) {
                        if let text = downloadProgressText {
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
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Finish setup", bundle: .module)
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
