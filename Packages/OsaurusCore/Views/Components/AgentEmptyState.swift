//
//  AgentEmptyState.swift
//  osaurus
//
//  Empty state for Agent Mode - follows the same visual language as ChatEmptyState
//  with agent-specific messaging.
//

import SwiftUI

struct AgentEmptyState: View {
    let hasModels: Bool
    let selectedModel: String?
    let personas: [Persona]
    let activePersonaId: UUID
    let onOpenModelManager: () -> Void
    let onUseFoundation: (() -> Void)?
    let onSelectPersona: (UUID) -> Void

    @StateObject private var modelManager = ModelManager.shared
    @State private var hasAppeared = false
    @State private var isVisible = false
    @Environment(\.theme) private var theme

    private var activePersona: Persona {
        personas.first { $0.id == activePersonaId } ?? Persona.default
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Ambient floating orbs background (same as ChatEmptyState)
                AmbientOrbsView(isVisible: isVisible, hasAppeared: hasAppeared)

                // Main content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 20)

                        if hasModels {
                            agentReadyState
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(theme.animationSlow()) {
                    hasAppeared = true
                }
            }
        }
        .onDisappear {
            isVisible = false
        }
    }

    // MARK: - Agent Ready State

    private var agentReadyState: some View {
        VStack(spacing: 10) {
            // Hero Orb - same as ChatEmptyState for visual consistency
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: activePersona.name)
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            // Title and description section
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Agent Mode")
                        .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                    Text("Describe a task and let the agent handle it")
                        .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                        .foregroundColor(theme.secondaryText)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
                }

                // Persona selector - same style as ChatEmptyState
                personaCard
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 12)
                    .scaleEffect(hasAppeared ? 1 : 0.97)
                    .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
            }

            // Subtle feature hints
            featureHints
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.35), value: hasAppeared)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Persona Pill (uses shared component)

    private var personaCard: some View {
        PersonaPill(
            personas: personas,
            activePersonaId: activePersonaId,
            onSelectPersona: onSelectPersona
        )
    }

    // MARK: - Feature Hints (subtle, theme-appropriate)

    private var featureHints: some View {
        HStack(spacing: 24) {
            featureHint(text: "Breaks down tasks")

            Text("·")
                .foregroundColor(theme.tertiaryText.opacity(0.5))

            featureHint(text: "Executes step by step")

            Text("·")
                .foregroundColor(theme.tertiaryText.opacity(0.5))

            featureHint(text: "Tracks progress")
        }
        .padding(.top, 16)
    }

    private func featureHint(text: String) -> some View {
        Text(text)
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
            .foregroundColor(theme.tertiaryText)
    }

    // MARK: - No Models State

    private var noModelsState: some View {
        VStack(spacing: 28) {
            // Use AnimatedOrb for consistency
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "agent")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

            VStack(spacing: 12) {
                Text("Agent Mode")
                    .font(theme.font(size: CGFloat(theme.titleSize) + 2, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text("Add a model to get started")
                    .font(theme.font(size: CGFloat(theme.bodySize)))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
            }

            Button(action: onOpenModelManager) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Model")
                }
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.95)
            .animation(theme.springAnimation().delay(0.25), value: hasAppeared)

            if onUseFoundation != nil {
                Button(action: { onUseFoundation?() }) {
                    Text("Use Apple Intelligence")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.3), value: hasAppeared)
            }
        }
        .padding(.horizontal, 40)
    }
}
