//
//  BackgroundTaskToastView.swift
//  osaurus
//
//  Toast view for background agent tasks with support for running,
//  clarification, and completed states.
//

import SwiftUI

// MARK: - Background Task Toast View

/// A toast notification for background agent tasks
struct BackgroundTaskToastView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var taskState: BackgroundTaskState
    let onDismiss: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var showCancelConfirmation = false
    @State private var selectedOption: String?

    var body: some View {
        HStack(spacing: 0) {
            // Type indicator bar
            accentBar

            // Content
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                headerRow

                // Divider
                divider

                // Main content based on status
                contentSection
            }
        }
        .background(toastBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity),
            radius: isHovering ? 12 : 8,
            x: 0,
            y: isHovering ? 4 : 2
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Cancel Background Task?", isPresented: $showCancelConfirmation) {
            Button("Cancel Task", role: .destructive) {
                BackgroundTaskManager.shared.cancelTask(taskState.id)
                onDismiss()
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("The agent task is still running. Dismissing will cancel the task.")
        }
    }

    // MARK: - Accent Bar

    private var accentBar: some View {
        Rectangle()
            .fill(accentColor)
            .frame(width: 4)
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 10) {
            // Status icon
            statusIcon

            // Task title
            VStack(alignment: .leading, spacing: 2) {
                Text(taskState.taskTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(taskState.status.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer(minLength: 4)

            // Dismiss button
            dismissButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(0.15))
                .frame(width: 32, height: 32)

            switch taskState.status {
            case .running:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                    .scaleEffect(0.7)
            case .awaitingClarification:
                Image(systemName: "questionmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accentColor)
            case .completed(let success, _):
                Image(systemName: success ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accentColor)
            case .cancelled:
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(accentColor)
            }
        }
    }

    @ViewBuilder
    private var dismissButton: some View {
        Button {
            handleDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(theme.tertiaryBackground)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(isHovering ? 1 : 0.6)
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(theme.primaryBorder.opacity(0.15))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        switch taskState.status {
        case .running:
            runningContent
        case .awaitingClarification:
            clarificationContent
        case .completed(_, let summary):
            completedContent(summary: summary)
        case .cancelled:
            cancelledContent
        }
    }

    // MARK: - Running State

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show plan steps if available
            if let plan = taskState.currentPlan, !plan.steps.isEmpty {
                planStepsView(plan: plan)
            } else if let step = taskState.currentStep {
                // Fallback to current step text if no plan
                Text(step)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }

            // Progress bar - indeterminate if progress < 0
            if taskState.progress >= 0 {
                ProgressView(value: taskState.progress)
                    .progressViewStyle(BackgroundTaskProgressStyle(color: accentColor))
                    .frame(height: 4)

                // Progress info
                let total = taskState.currentPlan?.steps.count ?? 0
                if total > 0 {
                    let completed = min(taskState.currentPlanStep, total)
                    Text("\(completed)/\(total) steps complete")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text("\(Int(taskState.progress * 100))% complete")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            } else {
                // Indeterminate progress for tasks without plan
                IndeterminateProgressView(color: accentColor)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
    }

    // MARK: - Plan Steps List

    private func planStepsView(plan: ExecutionPlan) -> some View {
        let currentStepIndex = taskState.currentPlanStep

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(plan.steps.prefix(5).enumerated()), id: \.element.stepNumber) { index, step in
                let isComplete = index < currentStepIndex
                let isCurrent = index == currentStepIndex
                planStepRow(step, isComplete: isComplete, isCurrentStep: isCurrent)
            }

            // Show count if more steps
            if plan.steps.count > 5 {
                Text("+\(plan.steps.count - 5) more steps")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.leading, 20)
            }
        }
    }

    private func planStepRow(_ step: PlanStep, isComplete: Bool, isCurrentStep: Bool) -> some View {
        HStack(spacing: 6) {
            // Status icon
            ZStack {
                if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.successColor)
                } else if isCurrentStep {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .strokeBorder(theme.tertiaryText.opacity(0.4), lineWidth: 1)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 14, height: 14)

            // Description
            Text(step.description)
                .font(.system(size: 11, weight: isCurrentStep ? .medium : .regular))
                .foregroundColor(
                    isComplete ? theme.tertiaryText : (isCurrentStep ? theme.primaryText : theme.secondaryText)
                )
                .strikethrough(isComplete, color: theme.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Clarification State

    @ViewBuilder
    private var clarificationContent: some View {
        if let clarification = taskState.pendingClarification {
            VStack(alignment: .leading, spacing: 10) {
                // Question
                Text(clarification.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(3)

                // Options or prompt to open window for text input
                if let options = clarification.options, !options.isEmpty {
                    optionsView(options: options)

                    // Submit button for options
                    HStack {
                        Spacer()
                        submitButton
                    }
                } else {
                    // For text input, prompt user to open the window
                    // (Toast panel can't receive keyboard focus)
                    Button {
                        onOpen()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 11))
                            Text("Click to respond")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func optionsView(options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                optionButton(option)
            }
        }
    }

    private func optionButton(_ option: String) -> some View {
        let isSelected = selectedOption == option

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedOption = isSelected ? nil : option
            }
        } label: {
            HStack(spacing: 8) {
                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? accentColor : theme.tertiaryText.opacity(0.4),
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(option)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.1) : theme.tertiaryBackground.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
    }

    private var submitButton: some View {
        let canSubmit = selectedOption != nil

        return Button {
            if let option = selectedOption {
                BackgroundTaskManager.shared.submitClarification(taskState.id, response: option)
                selectedOption = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text("Continue")
                    .font(.system(size: 11, weight: .semibold))

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(canSubmit ? .white : theme.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(canSubmit ? accentColor : theme.tertiaryBackground)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    // MARK: - Completed State

    private func completedContent(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)

            Button {
                onOpen()
                // Finalize since user is viewing the completed task
                BackgroundTaskManager.shared.finalizeTask(taskState.id)
            } label: {
                Text("View Details")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(accentColor.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Cancelled State

    private var cancelledContent: some View {
        HStack {
            Text("Task was cancelled")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("Dismiss")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func handleDismiss() {
        // If task is still active, show confirmation
        if taskState.status.isActive {
            showCancelConfirmation = true
        } else {
            // Task is completed or cancelled, just dismiss and finalize
            BackgroundTaskManager.shared.finalizeTask(taskState.id)
            onDismiss()
        }
    }

    private var toastBackground: some View {
        theme.cardBackground
    }

    private var accentColor: Color {
        switch taskState.status {
        case .running:
            return theme.accentColor
        case .awaitingClarification:
            return theme.warningColor
        case .completed(let success, _):
            return success ? theme.successColor : theme.errorColor
        case .cancelled:
            return theme.tertiaryText
        }
    }
}

// MARK: - Progress Styles

private struct BackgroundTaskProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.2))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0), height: 4)
                    .animation(.easeInOut(duration: 0.3), value: configuration.fractionCompleted)
            }
        }
        .frame(height: 4)
    }
}

/// Animated indeterminate progress indicator
private struct IndeterminateProgressView: View {
    let color: Color
    @State private var animationOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.2))
                    .frame(height: 4)

                // Animated bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geometry.size.width * 0.3, height: 4)
                    .offset(x: animationOffset * (geometry.size.width * 0.7))
            }
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                    .repeatForever(autoreverses: true)
            ) {
                animationOffset = 1.0
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct BackgroundTaskToastView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                Text("Preview requires runtime BackgroundTaskState")
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: 420)
            .background(Color.black.opacity(0.8))
        }
    }
#endif
