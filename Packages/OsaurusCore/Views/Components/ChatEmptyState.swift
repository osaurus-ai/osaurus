//
//  ChatEmptyState.swift
//  osaurus
//
//  Cinematic empty state with animated gradient and quick actions
//

import AppKit
import SwiftUI

struct ChatEmptyState: View {
    let hasModels: Bool
    let selectedModel: String?
    let onOpenModelManager: () -> Void
    let onUseFoundation: (() -> Void)?
    let onQuickAction: (String) -> Void

    @StateObject private var modelManager = ModelManager.shared
    @State private var shimmerPhase: CGFloat = 0
    @State private var glowIntensity: CGFloat = 0.6
    @State private var hasAppeared = false
    @State private var isVisible = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

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
        VStack(spacing: 0) {
            Spacer()

            if hasModels {
                readyState
            } else {
                noModelsState
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Greeting
            VStack(spacing: 12) {
                // Animated accent line
                accentLine
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 10)

                Text(greeting)
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)

                Text("How can I help you today?")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 10)
            }
            .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

            // Quick actions
            quickActionsGrid
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(theme.springAnimation().delay(0.25), value: hasAppeared)

            // Model indicator
            if let model = selectedModel {
                modelIndicator(model)
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.4), value: hasAppeared)
            }
        }
        .padding(.horizontal, 40)
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

    // MARK: - Accent Line

    private var accentLine: some View {
        ZStack {
            // Outer glow layer
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.accentColor)
                .blur(radius: 8)
                .opacity(glowIntensity * 0.5)

            // Inner glow layer
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.accentColor)
                .blur(radius: 4)
                .opacity(glowIntensity * 0.7)

            // Main solid bar
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.accentColor)

            // Shimmer highlight overlay
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.6),
                            Color.clear,
                        ],
                        startPoint: UnitPoint(x: shimmerPhase - 0.3, y: 0.5),
                        endPoint: UnitPoint(x: shimmerPhase + 0.1, y: 0.5)
                    )
                )
        }
        .frame(width: 64, height: 4)
    }

    // MARK: - Quick Actions

    private var quickActionsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            spacing: 12
        ) {
            ForEach(quickActions) { action in
                QuickActionButton(action: action, onTap: onQuickAction)
            }
        }
        .frame(maxWidth: 440)
    }

    // MARK: - Model Indicator

    private func modelIndicator(_ model: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)

            Text("Using \(displayModelName(model))")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.secondaryBackground.opacity(colorScheme == .dark ? 0.5 : 0.8))
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

    private func displayModelName(_ raw: String) -> String {
        if raw.lowercased() == "foundation" { return "Foundation" }
        if let last = raw.split(separator: "/").last { return String(last) }
        return raw
    }

    private func startGradientAnimation() {
        guard isVisible else { return }
        // Shimmer animation - smooth continuous flow
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            shimmerPhase = 1.5
        }

        // Glow pulse animation - subtle breathing effect
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            glowIntensity = 1.0
        }
    }

    private func stopGradientAnimation() {
        // Reset animation values without animation to stop the repeating animations
        withAnimation(.linear(duration: 0)) {
            shimmerPhase = 0
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
                            : theme.secondaryBackground.opacity(colorScheme == .dark ? 0.5 : 0.8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isHovered
                                    ? theme.primaryBorder
                                    : theme.primaryBorder.opacity(colorScheme == .dark ? 0.3 : 0.5),
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
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : (colorScheme == .dark ? 0.5 : 0.8)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isHovered
                                    ? theme.accentColor.opacity(0.3)
                                    : theme.primaryBorder.opacity(colorScheme == .dark ? 0.3 : 0.5),
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

// MARK: - Preview

#if DEBUG
    struct ChatEmptyState_Previews: PreviewProvider {
        static var previews: some View {
            VStack {
                ChatEmptyState(
                    hasModels: true,
                    selectedModel: "foundation",
                    onOpenModelManager: {},
                    onUseFoundation: {},
                    onQuickAction: { _ in }
                )
            }
            .frame(width: 700, height: 600)
            .background(Color(hex: "0f0f10"))

            VStack {
                ChatEmptyState(
                    hasModels: false,
                    selectedModel: nil,
                    onOpenModelManager: {},
                    onUseFoundation: {},
                    onQuickAction: { _ in }
                )
            }
            .frame(width: 700, height: 600)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
