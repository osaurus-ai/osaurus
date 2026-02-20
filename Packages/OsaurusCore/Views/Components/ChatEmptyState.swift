//
//  ChatEmptyState.swift
//  osaurus
//
//  Immersive empty state with prominent agent selector
//  and staggered entrance animations for a polished first impression.
//

import AppKit
import SwiftUI

struct ChatEmptyState: View {
    let hasModels: Bool
    let selectedModel: String?
    let agents: [Agent]
    let activeAgentId: UUID
    let quickActions: [AgentQuickAction]
    let onOpenModelManager: () -> Void
    let onUseFoundation: (() -> Void)?
    let onQuickAction: (String) -> Void
    let onSelectAgent: (UUID) -> Void
    let onOpenOnboarding: (() -> Void)?

    @State private var hasAppeared = false
    @Environment(\.theme) private var theme

    private var activeAgent: Agent {
        agents.first { $0.id == activeAgentId } ?? Agent.default
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
            // Hero Orb - mesmerizing animated orb as the focal point
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: activeAgent.name)
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

                // Agent selector - prominent card with delayed entrance
                agentCard
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 12)
                    .scaleEffect(hasAppeared ? 1 : 0.97)
                    .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
            }

            if !quickActions.isEmpty {
                staggeredQuickActions
            }
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

    // MARK: - Agent Card (uses shared component)

    private var agentCard: some View {
        AgentPill(
            agents: agents,
            activeAgentId: activeAgentId,
            onSelectAgent: onSelectAgent
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

    var body: some View {
        if isDownloading {
            downloadingState
        } else {
            noModelsState
        }
    }

    private var noModelsState: some View {
        VStack(spacing: 14) {
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "welcome")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

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
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "downloading")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation().delay(0.0), value: hasAppeared)

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

                Text(action.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

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
                    onSelectAgent: { _ in },
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
                    onSelectAgent: { _ in },
                    onOpenOnboarding: {}
                )
            }
            .frame(width: 700, height: 600)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
