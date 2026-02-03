//
//  ChatEmptyState.swift
//  osaurus
//
//  Immersive empty state with ambient floating orbs, prominent persona selector,
//  and staggered entrance animations for a polished first impression.
//

import AppKit
import SwiftUI

struct ChatEmptyState: View {
    let hasModels: Bool
    let selectedModel: String?
    let personas: [Persona]
    let activePersonaId: UUID
    let onOpenModelManager: () -> Void
    let onUseFoundation: (() -> Void)?
    let onQuickAction: (String) -> Void
    let onSelectPersona: (UUID) -> Void
    let onOpenOnboarding: (() -> Void)?

    @State private var hasAppeared = false
    @State private var isVisible = false
    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = ModelManager.shared

    /// Active download info (model ID and progress) if any download is in progress
    private var activeDownload: (modelId: String, progress: Double)? {
        for (modelId, state) in modelManager.downloadStates {
            if case .downloading(let progress) = state {
                return (modelId, progress)
            }
        }
        return nil
    }

    /// Whether a model is currently downloading
    private var isDownloading: Bool { activeDownload != nil }

    /// Current download progress (0-1) if downloading
    private var downloadProgress: Double? { activeDownload?.progress }

    /// Name of the model being downloaded
    private var downloadingModelName: String? {
        guard let modelId = activeDownload?.modelId else { return nil }
        return modelManager.availableModels.first { $0.id == modelId }?.name
            ?? modelManager.suggestedModels.first { $0.id == modelId }?.name
    }

    /// Formatted progress text (speed, ETA)
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

    private var activePersona: Persona {
        personas.first { $0.id == activePersonaId } ?? Persona.default
    }

    private let quickActions = [
        QuickAction(icon: "lightbulb", text: "Explain a concept", prompt: "Explain "),
        QuickAction(icon: "doc.text", text: "Summarize text", prompt: "Summarize the following: "),
        QuickAction(icon: "chevron.left.forwardslash.chevron.right", text: "Write code", prompt: "Write code that "),
        QuickAction(icon: "pencil.line", text: "Help me write", prompt: "Help me write "),
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Ambient floating orbs background
                AmbientOrbsView(isVisible: isVisible, hasAppeared: hasAppeared)

                // Main content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 20)

                        if hasModels {
                            readyState
                        } else if isDownloading {
                            downloadingState
                        } else {
                            noModelsState
                        }

                        Spacer(minLength: 20)
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        .onAppear {
            isVisible = true

            // Defer expensive orb animations to avoid blocking window appearance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(theme.animationSlow()) {
                    hasAppeared = true
                }
            }
        }
        .onDisappear {
            // Stop animations when view is hidden
            isVisible = false
            hasAppeared = false
        }
    }

    // MARK: - Ready State (has models)

    private var readyState: some View {
        VStack(spacing: 14) {
            // Hero Orb - mesmerizing animated orb as the focal point
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: activePersona.name)
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            // Greeting section
            VStack(spacing: 20) {
                // Greeting text - staggered entrance
                VStack(spacing: 8) {
                    Text(greeting)
                        .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                    Text("How can I help you today?")
                        .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                        .foregroundColor(theme.secondaryText)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
                }

                // Persona selector - prominent card with delayed entrance
                personaCard
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 12)
                    .scaleEffect(hasAppeared ? 1 : 0.97)
                    .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
            }

            // Quick actions with staggered entrance
            staggeredQuickActions
        }
        .padding(.horizontal, 40)
    }

    private var staggeredQuickActions: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            spacing: 12
        ) {
            ForEach(Array(quickActions.enumerated()), id: \.element.id) { index, action in
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

    // MARK: - No Models State

    private var noModelsState: some View {
        VStack(spacing: 14) {
            // Hero Orb - consistent with ready state
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "welcome")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            // Welcome text - staggered entrance
            VStack(spacing: 8) {
                Text("One more step")
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text("Osaurus needs an AI to work — either a cloud provider or a local model.")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
            }
            .frame(maxWidth: 340)

            // Get Started button
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

    // MARK: - Downloading State (model download in progress)

    private var downloadingState: some View {
        VStack(spacing: 14) {
            // Animated orb - consistent with other states
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "downloading")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            // Headline and model name
            VStack(spacing: 8) {
                Text("Almost ready...")
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                if let name = downloadingModelName {
                    Text("Downloading \(name)")
                        .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
                }
            }
            .frame(maxWidth: 340)

            // Progress section
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
                        Text("\(Int(progress * 100))%")
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

    // MARK: - Persona Card (uses shared component)

    private var personaCard: some View {
        PersonaPill(
            personas: personas,
            activePersonaId: activePersonaId,
            onSelectPersona: onSelectPersona
        )
    }

    // MARK: - Helpers

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5 ..< 12: return "Good morning"
        case 12 ..< 17: return "Good afternoon"
        case 17 ..< 22: return "Good evening"
        default: return "Hello"
        }
    }
}

// MARK: - Quick Action Model

private struct QuickAction: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let prompt: String
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    let action: QuickAction
    let onTap: (String) -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: { onTap(action.prompt) }) {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                    .frame(width: 20)

                Text(action.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

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
                Text("Finish setup")
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

// MARK: - Ambient Orbs Animation

private struct AmbientOrb: Identifiable {
    let id = UUID()
    let baseSize: CGFloat
    let xOffset: CGFloat  // Normalized -1 to 1
    let yOffset: CGFloat  // Normalized -1 to 1
    let phaseOffset: Double
    let speed: Double
    let opacity: Double
    let blurRadius: CGFloat
}

struct AmbientOrbsView: View {
    let isVisible: Bool
    let hasAppeared: Bool

    @Environment(\.theme) private var theme

    // Reduced opacity to complement the hero orb without visual clutter
    private let orbs: [AmbientOrb] = [
        AmbientOrb(
            baseSize: 180,
            xOffset: -0.35,
            yOffset: -0.25,
            phaseOffset: 0,
            speed: 0.4,
            opacity: 0.12,
            blurRadius: 60
        ),
        AmbientOrb(
            baseSize: 140,
            xOffset: 0.4,
            yOffset: -0.15,
            phaseOffset: 1.5,
            speed: 0.55,
            opacity: 0.10,
            blurRadius: 55
        ),
        AmbientOrb(
            baseSize: 160,
            xOffset: 0.25,
            yOffset: 0.35,
            phaseOffset: 3.0,
            speed: 0.45,
            opacity: 0.08,
            blurRadius: 60
        ),
        AmbientOrb(
            baseSize: 100,
            xOffset: -0.3,
            yOffset: 0.4,
            phaseOffset: 4.5,
            speed: 0.6,
            opacity: 0.10,
            blurRadius: 50
        ),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geometry in
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    ForEach(orbs) { orb in
                        orbView(orb: orb, time: time, size: geometry.size)
                    }
                }
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 1.0), value: hasAppeared)
        .allowsHitTesting(false)
    }

    private func orbView(orb: AmbientOrb, time: TimeInterval, size: CGSize) -> some View {
        let animatedTime = time * orb.speed + orb.phaseOffset

        // Create gentle floating motion
        let xDrift = sin(animatedTime * 0.8) * 20 + cos(animatedTime * 0.5) * 10
        let yDrift = cos(animatedTime * 0.6) * 15 + sin(animatedTime * 0.4) * 8

        // Subtle breathing/pulsing
        let breathe = 1.0 + sin(animatedTime * 1.2) * 0.08

        // Calculate position from normalized offset
        let centerX = size.width / 2 + orb.xOffset * size.width * 0.4
        let centerY = size.height / 2 + orb.yOffset * size.height * 0.35

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        theme.accentColor.opacity(orb.opacity * 2.0),
                        theme.accentColor.opacity(orb.opacity),
                        theme.accentColor.opacity(0),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: orb.baseSize * 0.7
                )
            )
            .frame(width: orb.baseSize * breathe, height: orb.baseSize * breathe)
            .blur(radius: orb.blurRadius)
            .position(
                x: centerX + xDrift,
                y: centerY + yDrift
            )
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
                    personas: [.default],
                    activePersonaId: Persona.default.id,
                    onOpenModelManager: {},
                    onUseFoundation: {},
                    onQuickAction: { _ in },
                    onSelectPersona: { _ in },
                    onOpenOnboarding: nil
                )
            }
            .frame(width: 700, height: 600)
            .background(Color(hex: "0f0f10"))

            VStack {
                ChatEmptyState(
                    hasModels: false,
                    selectedModel: nil,
                    personas: [.default],
                    activePersonaId: Persona.default.id,
                    onOpenModelManager: {},
                    onUseFoundation: {},
                    onQuickAction: { _ in },
                    onSelectPersona: { _ in },
                    onOpenOnboarding: {}
                )
            }
            .frame(width: 700, height: 600)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
