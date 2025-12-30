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

    @StateObject private var modelManager = ModelManager.shared
    @State private var glowIntensity: CGFloat = 0.6
    @State private var hasAppeared = false
    @State private var isVisible = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var activePersona: Persona {
        personas.first { $0.id == activePersonaId } ?? Persona.default
    }

    /// Top suggested models to display in empty state
    private var topSuggestions: [MLXModel] {
        modelManager.suggestedModels.filter { $0.isTopSuggestion }
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
            withAnimation(theme.animationSlow().delay(0.1)) {
                hasAppeared = true
            }
            startGradientAnimation()
        }
        .onDisappear {
            // Stop animations when view is hidden
            isVisible = false
            stopGradientAnimation()
        }
    }

    // MARK: - Ready State (has models)

    private var readyState: some View {
        VStack(spacing: 32) {
            // Greeting section
            VStack(spacing: 20) {
                // Greeting text - staggered entrance
                VStack(spacing: 8) {
                    Text(greeting)
                        .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(theme.springAnimation().delay(0.05), value: hasAppeared)

                    Text("How can I help you today?")
                        .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                        .foregroundColor(theme.secondaryText)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.12), value: hasAppeared)
                }

                // Persona selector - prominent card with delayed entrance
                personaCard
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 12)
                    .scaleEffect(hasAppeared ? 1 : 0.97)
                    .animation(theme.springAnimation().delay(0.2), value: hasAppeared)
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
                        theme.springAnimation().delay(0.3 + Double(index) * 0.05),
                        value: hasAppeared
                    )
            }
        }
        .frame(maxWidth: 440)
    }

    // MARK: - No Models State

    private var noModelsState: some View {
        VStack(spacing: 28) {
            // Glowing icon
            ZStack {
                // Outer glow
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 80, height: 80)
                    .blur(radius: 20)
                    .opacity(glowIntensity * 0.3)

                // Inner glow
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 80, height: 80)
                    .blur(radius: 10)
                    .opacity(glowIntensity * 0.2)

                // Base circle
                Circle()
                    .fill(theme.secondaryBackground)
                    .frame(width: 80, height: 80)

                // Icon
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.8)
            .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

            // Title and description - uses theme typography
            VStack(spacing: 8) {
                Text("Get started with a model")
                    .font(theme.font(size: CGFloat(theme.headingSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Download a recommended model to start chatting")
                    .font(theme.font(size: CGFloat(theme.bodySize)))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(theme.springAnimation().delay(0.15), value: hasAppeared)

            // Top suggested model cards
            VStack(spacing: 12) {
                ForEach(Array(topSuggestions.enumerated()), id: \.element.id) { index, model in
                    SuggestedModelCard(
                        model: model,
                        onDownload: onOpenModelManager
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.25 + Double(index) * 0.08), value: hasAppeared)
                }
            }

            // Secondary actions - uses theme caption size
            HStack(spacing: 16) {
                Button(action: onOpenModelManager) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.grid.2x2")
                            .font(theme.font(size: CGFloat(theme.captionSize) - 1))
                        Text("Browse all models")
                    }
                    .font(theme.font(size: CGFloat(theme.captionSize) + 1, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                if let useFoundation = onUseFoundation {
                    Text("·")
                        .foregroundColor(theme.tertiaryText)

                    Button(action: useFoundation) {
                        HStack(spacing: 5) {
                            Image(systemName: "cpu")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 1))
                            Text("Use Apple Foundation")
                        }
                        .font(theme.font(size: CGFloat(theme.captionSize) + 1, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .animation(.easeOut(duration: 0.4).delay(0.5), value: hasAppeared)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Persona Card

    @State private var isPersonaHovered = false

    /// Get a preview of the persona's system prompt (truncated)
    private var personaDescriptionPreview: String {
        let systemPrompt = activePersona.systemPrompt
        if systemPrompt.isEmpty {
            return "A helpful AI assistant"
        }
        // Take first 80 characters and add ellipsis if truncated
        let preview = String(systemPrompt.prefix(80))
        return preview.count < systemPrompt.count ? "\(preview)..." : preview
    }

    private var personaCard: some View {
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
            HStack(spacing: 14) {
                // Persona avatar
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.2),
                                    theme.accentColor.opacity(0.1),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "person.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }

                // Persona info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(activePersona.name)
                            .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                    }

                    Text(personaDescriptionPreview)
                        .font(theme.font(size: CGFloat(theme.captionSize)))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(isPersonaHovered ? 0.9 : (theme.isDark ? 0.6 : 0.8)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isPersonaHovered
                                    ? theme.accentColor.opacity(0.3)
                                    : theme.primaryBorder.opacity(theme.isDark ? 0.3 : 0.5),
                                lineWidth: 1
                            )
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isPersonaHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
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

    private func startGradientAnimation() {
        guard isVisible else { return }
        // Glow pulse animation - subtle breathing effect
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            glowIntensity = 1.0
        }
    }

    private func stopGradientAnimation() {
        // Reset animation values without animation to stop the repeating animations
        withAnimation(.linear(duration: 0)) {
            glowIntensity = 0.6
        }
        hasAppeared = false
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
    @Environment(\.colorScheme) private var colorScheme

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
            .padding(.vertical, 14)
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

// MARK: - Suggested Model Card

private struct SuggestedModelCard: View {
    let model: MLXModel
    let onDownload: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isVLM: Bool {
        model.isLikelyVLM
    }

    private var modelTypeIcon: String {
        isVLM ? "eye" : "text.bubble"
    }

    private var modelTypeLabel: String {
        isVLM ? "Vision" : "Text"
    }

    var body: some View {
        Button(action: onDownload) {
            HStack(spacing: 16) {
                // Model icon with gradient background
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.2),
                                    theme.accentColor.opacity(0.1),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)

                    Image(systemName: "cube.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }

                // Model info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        // Model type badge
                        HStack(spacing: 3) {
                            Image(systemName: modelTypeIcon)
                                .font(.system(size: 8, weight: .semibold))
                            Text(modelTypeLabel)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(isVLM ? .purple : theme.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill((isVLM ? Color.purple : theme.accentColor).opacity(0.12))
                        )

                        // Quantization badge if available
                        if let quant = model.quantization {
                            Text(quant)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground)
                                )
                        }
                    }

                    Text(model.description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Download button
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : (theme.isDark ? 0.5 : 0.8)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isHovered
                                    ? theme.accentColor.opacity(0.3)
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
        .frame(maxWidth: 520)
    }
}

// MARK: - Ambient Orbs Animation

private struct Orb: Identifiable {
    let id = UUID()
    let baseSize: CGFloat
    let xOffset: CGFloat  // Normalized -1 to 1
    let yOffset: CGFloat  // Normalized -1 to 1
    let phaseOffset: Double
    let speed: Double
    let opacity: Double
    let blurRadius: CGFloat
}

private struct AmbientOrbsView: View {
    let isVisible: Bool
    let hasAppeared: Bool

    @Environment(\.theme) private var theme

    private let orbs: [Orb] = [
        Orb(baseSize: 180, xOffset: -0.35, yOffset: -0.25, phaseOffset: 0, speed: 0.4, opacity: 0.25, blurRadius: 50),
        Orb(baseSize: 140, xOffset: 0.4, yOffset: -0.15, phaseOffset: 1.5, speed: 0.55, opacity: 0.20, blurRadius: 45),
        Orb(baseSize: 160, xOffset: 0.25, yOffset: 0.35, phaseOffset: 3.0, speed: 0.45, opacity: 0.18, blurRadius: 50),
        Orb(baseSize: 100, xOffset: -0.3, yOffset: 0.4, phaseOffset: 4.5, speed: 0.6, opacity: 0.22, blurRadius: 40),
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

    private func orbView(orb: Orb, time: TimeInterval, size: CGSize) -> some View {
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
                    onSelectPersona: { _ in }
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
                    onSelectPersona: { _ in }
                )
            }
            .frame(width: 700, height: 600)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
