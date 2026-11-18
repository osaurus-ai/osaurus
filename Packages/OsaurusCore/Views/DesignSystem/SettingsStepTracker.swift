//
//  SettingsStepTracker.swift
//  osaurus
//
//  Where a multi-step process stands: numbered markers joined by a rail,
//  each with a title and an optional detail line. One step at a time is
//  working, waiting, or needs attention; earlier ones are done.
//

import SwiftUI

struct SettingsStep: Identifiable, Equatable {
    enum State: Equatable {
        case done
        /// Happening now (spinner).
        case working
        /// Handed off; waiting on someone else.
        case waiting
        /// Stopped on something the user has to act on.
        case attention
        case failed
        case upcoming
        /// Doesn't apply on this path.
        case skipped
    }

    let id: String
    /// Already localized.
    let title: String
    /// Already localized.
    var detail: String?
    var state: State
}

struct SettingsStepTracker: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let steps: [SettingsStep]

    private let marker: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                column(step, index: index)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.standard, value: steps)
        .accessibilityElement(children: .contain)
    }

    private func column(_ step: SettingsStep, index: Int) -> some View {
        VStack(spacing: theme.space.s6) {
            ZStack {
                HStack(spacing: theme.space.s0) {
                    rail(index > 0 ? railTint(into: index) : .clear)
                    rail(index < steps.count - 1 ? railTint(into: index + 1) : .clear)
                }
                markerView(step, index: index)
            }
            .frame(height: marker)
            VStack(spacing: theme.space.s2) {
                Text(verbatim: step.title)
                    .font(SettingsFont.compactLabel.weight(step.state == .upcoming || step.state == .skipped ? .regular : .semibold))
                    .foregroundColor(step.state == .upcoming || step.state == .skipped ? theme.text.tertiary : theme.text.primary)
                    .multilineTextAlignment(.center)
                if let detail = step.detail {
                    Text(verbatim: detail)
                        .font(SettingsFont.caption)
                        .foregroundColor(detailTint(step.state))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, theme.space.s4)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [step.title, step.detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(Text(accessibilityState(step.state), bundle: .module))
    }

    private func rail(_ tint: Color) -> some View {
        Rectangle()
            .fill(tint)
            .frame(height: theme.stroke.focus)
            .frame(maxWidth: .infinity)
    }

    /// The rail into step `index` is solid once the step before it is done.
    private func railTint(into index: Int) -> Color {
        steps[index - 1].state == .done ? theme.status.success.foreground : theme.border.default
    }

    @ViewBuilder
    private func markerView(_ step: SettingsStep, index: Int) -> some View {
        ZStack {
            Circle().fill(markerFill(step.state))
            Circle().strokeBorder(markerStroke(step.state), lineWidth: theme.stroke.focus)
            switch step.state {
            case .working:
                SettingsSpinner(size: .mini)
            case .upcoming:
                Text(verbatim: "\(index + 1)")
                    .font(SettingsFont.chip.monospacedDigit())
                    .foregroundColor(theme.text.tertiary)
            default:
                Image(systemName: glyph(step.state))
                    .glyphSize(.micro, weight: .bold)
                    .foregroundColor(glyphTint(step.state))
            }
        }
        .frame(width: marker, height: marker)
        .background(Circle().fill(theme.surface.canvas))
    }

    private func glyph(_ state: SettingsStep.State) -> String {
        switch state {
        case .done: "checkmark"
        case .waiting: "clock"
        case .attention: "exclamationmark"
        case .failed: "xmark"
        case .skipped: "minus"
        case .working, .upcoming: ""
        }
    }

    private func tone(_ state: SettingsStep.State) -> ThemeStatusKind? {
        switch state {
        case .done: .success
        case .waiting, .working: .info
        case .attention: .warning
        case .failed: .error
        case .upcoming, .skipped: nil
        }
    }

    private func markerFill(_ state: SettingsStep.State) -> Color {
        guard let tone = tone(state) else { return theme.surface.subtle }
        return state == .done ? theme.status[tone].foreground : theme.status[tone].background
    }

    private func markerStroke(_ state: SettingsStep.State) -> Color {
        guard let tone = tone(state) else { return theme.border.default }
        return theme.status[tone].foreground
    }

    private func glyphTint(_ state: SettingsStep.State) -> Color {
        if state == .done { return theme.surface.canvas }
        guard let tone = tone(state) else { return theme.text.tertiary }
        return theme.status[tone].foreground
    }

    private func detailTint(_ state: SettingsStep.State) -> Color {
        switch state {
        case .attention: theme.status.warning.foreground
        case .failed: theme.status.error.foreground
        case .upcoming, .skipped: theme.text.tertiary
        default: theme.text.secondary
        }
    }

    private func accessibilityState(_ state: SettingsStep.State) -> LocalizedStringKey {
        switch state {
        case .done: "Done"
        case .working: "In progress"
        case .waiting: "Waiting"
        case .attention: "Needs attention"
        case .failed: "Failed"
        case .upcoming: "Not started"
        case .skipped: "Skipped"
        }
    }
}
