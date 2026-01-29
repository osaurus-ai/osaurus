//
//  PlanBlockView.swift
//  osaurus
//
//  Sleek UI to display agent execution plans.
//  Always expanded to show the full plan with step progress.
//

import SwiftUI

struct PlanBlockView: View {
    let steps: [PlanStep]
    let currentStep: Int?  // Currently executing step (for progress indication)
    let isStreaming: Bool

    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    /// Use theme accent color for the plan
    private var planColor: Color {
        theme.accentColor
    }

    /// Number of completed steps
    private var completedSteps: Int {
        if let current = currentStep {
            return current
        }
        return steps.filter { $0.isComplete }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left accent strip
            accentStrip

            // Main content
            VStack(spacing: 0) {
                header
                divider
                stepsContent
            }
        }
        .background(planBackground)
        .overlay(planBorder)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(theme.animationQuick(), value: isHovered)
        .onHover { isHovered = $0 }
    }

    // MARK: - Accent Strip

    private var accentStrip: some View {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 10, bottomLeading: 10),
            style: .continuous
        )
        .fill(planColor)
        .frame(width: 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Plan icon
            planIcon

            // Title
            Text("Plan")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                .foregroundColor(theme.secondaryText)

            // Streaming indicator
            if isStreaming {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 10, height: 10)
            }

            Spacer()

            // Progress indicator
            progressBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var planIcon: some View {
        ZStack {
            Circle()
                .fill(planColor.opacity(0.15))
                .frame(width: 24, height: 24)

            Image(systemName: "list.clipboard")
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(planColor)
        }
    }

    private let progressBarWidth: CGFloat = 32

    /// Progress badge showing completion status.
    /// Uses fixedSize() to prevent layout compression when sidebar is expanded.
    private var progressBadge: some View {
        HStack(spacing: 4) {
            // Mini progress bar
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.tertiaryBackground)
                Capsule()
                    .fill(planColor)
                    .frame(width: progressBarWidth * progressPercentage)
            }
            .frame(width: progressBarWidth, height: 4)

            // Step count
            Text("\(completedSteps)/\(steps.count)")
                .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private var progressPercentage: CGFloat {
        guard !steps.isEmpty else { return 0 }
        return CGFloat(completedSteps) / CGFloat(steps.count)
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(theme.primaryBorder.opacity(0.15))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    // MARK: - Steps Content

    private var stepsContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                stepRow(step: step, index: index)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func stepRow(step: PlanStep, index: Int) -> some View {
        let isCurrentStep = currentStep == index
        let isCompleted = step.isComplete || (currentStep != nil && index < (currentStep ?? 0))

        return HStack(alignment: .top, spacing: 10) {
            // Status indicator
            stepIndicator(isCompleted: isCompleted, isCurrent: isCurrentStep)

            // Step content
            VStack(alignment: .leading, spacing: 2) {
                Text(step.description)
                    .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: isCurrentStep ? .medium : .regular))
                    .foregroundColor(
                        isCompleted ? theme.secondaryText : isCurrentStep ? theme.primaryText : theme.tertiaryText
                    )
                    .lineLimit(2)

                // Tool badge if present
                if let toolName = step.toolName {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 9, weight: .medium))
                        Text(toolName)
                            .font(theme.monoFont(size: 10, weight: .medium))
                    }
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.tertiaryBackground.opacity(0.6))
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrentStep ? planColor.opacity(0.08) : Color.clear)
        )
    }

    @ViewBuilder
    private func stepIndicator(isCompleted: Bool, isCurrent: Bool) -> some View {
        ZStack {
            if isCompleted {
                // Completed - checkmark
                Circle()
                    .fill(theme.successColor.opacity(0.15))
                    .frame(width: 20, height: 20)

                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.successColor)
            } else if isCurrent {
                // Current - pulsing dot
                Circle()
                    .fill(planColor.opacity(0.2))
                    .frame(width: 20, height: 20)

                Circle()
                    .fill(planColor)
                    .frame(width: 8, height: 8)
            } else {
                // Pending - empty circle
                Circle()
                    .strokeBorder(theme.tertiaryText.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 20, height: 20)
            }
        }
        .frame(width: 20, height: 20)
    }

    // MARK: - Background & Border

    private var planBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.secondaryBackground.opacity(isHovered ? 0.6 : 0.4))
    }

    private var planBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                theme.primaryBorder.opacity(isHovered ? 0.3 : 0.2),
                lineWidth: 0.5
            )
    }
}

// MARK: - Preview

#if DEBUG
    struct PlanBlockView_Previews: PreviewProvider {
        static let sampleSteps: [PlanStep] = [
            PlanStep(
                stepNumber: 1,
                description: "Read the configuration file to understand current settings",
                toolName: "read_file",
                isComplete: true
            ),
            PlanStep(
                stepNumber: 2,
                description: "Parse and validate the configuration data",
                toolName: nil,
                isComplete: true
            ),
            PlanStep(
                stepNumber: 3,
                description: "Apply the requested changes to the settings",
                toolName: "write_file",
                isComplete: false
            ),
            PlanStep(
                stepNumber: 4,
                description: "Verify the changes were applied correctly",
                toolName: "read_file",
                isComplete: false
            ),
            PlanStep(
                stepNumber: 5,
                description: "Generate a summary report of the changes made",
                toolName: nil,
                isComplete: false
            ),
        ]

        static var previews: some View {
            VStack(spacing: 16) {
                PlanBlockView(
                    steps: sampleSteps,
                    currentStep: 2,
                    isStreaming: false
                )

                PlanBlockView(
                    steps: sampleSteps,
                    currentStep: 2,
                    isStreaming: true
                )
            }
            .frame(width: 500)
            .padding()
            .background(Color(hex: "0c0c0b"))
        }
    }
#endif
