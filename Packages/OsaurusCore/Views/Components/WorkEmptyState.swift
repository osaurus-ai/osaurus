//
//  WorkEmptyState.swift
//  osaurus
//

import SwiftUI

struct WorkEmptyState: View {
    let hasModels: Bool
    let selectedModel: String?
    let agents: [Agent]
    let activeAgentId: UUID
    let onOpenModelManager: () -> Void
    let onUseFoundation: (() -> Void)?
    let onQuickAction: (String) -> Void
    let onSelectAgent: (UUID) -> Void

    @State private var hasAppeared = false
    @Environment(\.theme) private var theme

    private var activeAgent: Agent {
        agents.first { $0.id == activeAgentId } ?? Agent.default
    }

    private let quickActions = [
        WorkQuickAction(icon: "globe", text: "Build a site", prompt: "Build a landing page for "),
        WorkQuickAction(icon: "magnifyingglass", text: "Research a topic", prompt: "Research "),
        WorkQuickAction(icon: "doc.text", text: "Write a blog post", prompt: "Write a blog post about "),
        WorkQuickAction(icon: "folder", text: "Organize my files", prompt: "Help me organize "),
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    if hasModels { readyState } else { noModelsState }
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(theme.animationSlow()) { hasAppeared = true }
            }
        }
        .onDisappear { hasAppeared = false }
    }

    // MARK: - Ready State

    private var readyState: some View {
        VStack(spacing: 14) {
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: activeAgent.name)
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation(), value: hasAppeared)

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Work")
                        .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                    Text("One goal. It handles the rest.")
                        .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                        .foregroundColor(theme.secondaryText)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
                }

                AgentPill(agents: agents, activeAgentId: activeAgentId, onSelectAgent: onSelectAgent)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 12)
                    .scaleEffect(hasAppeared ? 1 : 0.97)
                    .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
            }

            quickActionsGrid
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Quick Actions

    private var quickActionsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Array(quickActions.enumerated()), id: \.element.id) { index, action in
                QuickActionButton(action: action, onTap: onQuickAction)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.35 + Double(index) * 0.05), value: hasAppeared)
            }
        }
        .frame(maxWidth: 440)
    }

    // MARK: - No Models State

    private var noModelsState: some View {
        VStack(spacing: 28) {
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "work")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation(), value: hasAppeared)

            VStack(spacing: 12) {
                Text("Work")
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

            if let useFoundation = onUseFoundation {
                Button(action: useFoundation) {
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

// MARK: - Supporting Types

private struct WorkQuickAction: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let prompt: String
}

private struct QuickActionButton: View {
    let action: WorkQuickAction
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
                            ? theme.secondaryBackground : theme.secondaryBackground.opacity(theme.isDark ? 0.5 : 0.8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isHovered ? theme.primaryBorder : theme.primaryBorder.opacity(theme.isDark ? 0.3 : 0.5),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(theme.animationQuick(), value: isHovered)
    }
}
