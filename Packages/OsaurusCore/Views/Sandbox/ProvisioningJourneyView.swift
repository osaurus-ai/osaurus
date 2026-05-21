//
//  ProvisioningJourneyView.swift
//  osaurus
//
//  Fullscreen "Setting up sandbox" experience driven by
//  `SandboxManager.State.journey`. Shows the ordered step list with
//  live status icons, byte/rate progress on the active step, the
//  best-effort total ETA, and a live "now doing" subtitle.
//
//  Falls back to the legacy single-line progress layout when the
//  journey is `nil` so any code path that bypasses `beginJourney`
//  (e.g. a third-party caller starting the sandbox without going
//  through `provision()`) still gets a usable progress UI.
//

import SwiftUI

#if os(macOS)

    struct ProvisioningJourneyView: View {
        @ObservedObject private var sandboxState = SandboxManager.State.shared
        @Environment(\.theme) private var theme

        /// External error surface from `SandboxView.performProvision`.
        let provisionError: String?
        let onRetry: () -> Void

        var body: some View {
            VStack(spacing: 20) {
                Spacer(minLength: 0)

                header

                if let journey = sandboxState.journey {
                    journeyContent(journey: journey)
                        .frame(maxWidth: 460)
                } else {
                    legacyContent
                        .frame(maxWidth: 320)
                }

                if let provisionError {
                    retryBanner(message: provisionError)
                        .frame(maxWidth: 460)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - Header (title + elapsed)

        private var header: some View {
            VStack(spacing: 6) {
                Text("Setting up sandbox", bundle: .module)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                if let startedAt = sandboxState.journey?.startedAt,
                    sandboxState.journey?.finishedAt == nil
                {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        // Count up MM:SS from `startedAt`. The default
                        // `countsDown: true` would render time until
                        // `.distantFuture` (~17M hours).
                        Text(
                            timerInterval: startedAt ... .distantFuture,
                            countsDown: false,
                            showsHours: false
                        )
                        .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(theme.tertiaryText)
                }
            }
        }

        // MARK: - Journey content

        private func journeyContent(journey: ProvisioningJourney) -> some View {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    ForEach(journey.steps) { step in
                        StepRow(step: step, isActive: journey.currentStepID == step.id)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )

                activityAndETA(journey: journey)
            }
        }

        @ViewBuilder
        private func activityAndETA(journey: ProvisioningJourney) -> some View {
            HStack(alignment: .top, spacing: 12) {
                if let activity = sandboxState.currentActivity, !activity.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                        Text(activity)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                if let remaining = journey.remainingTotalSeconds {
                    Text("≈ \(Self.formatEta(remaining)) remaining", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .monospacedDigit()
                }
            }
        }

        // MARK: - Legacy fallback

        private var legacyContent: some View {
            VStack(spacing: 16) {
                if let progress = sandboxState.provisioningProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                        .tint(theme.accentColor)
                        .animation(.easeOut(duration: 0.3), value: progress)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.accentColor)
                }

                if let phase = sandboxState.provisioningPhase {
                    HStack(spacing: 6) {
                        Text(phase)
                        if let progress = sandboxState.provisioningProgress {
                            Text("\(Int(progress * 100))%", bundle: .module)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.2), value: phase)
                }
            }
        }

        // MARK: - Retry banner

        private func retryBanner(message: String) -> some View {
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(message)
                        .font(.system(size: 12))
                        .lineLimit(3)
                }
                .foregroundColor(theme.warningColor)

                Button(action: onRetry) {
                    Label {
                        Text("Retry", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(.plain)
            }
        }

        // MARK: - Helpers

        /// "<1m" if seconds ≤ 60, else "Xm Ys" with seconds dropped past 5 min.
        /// Used by both the per-step row footer and the aggregate
        /// "≈ Xm Ys remaining" line under the journey card.
        /// `nonisolated` so non-SwiftUI callers (tests, the
        /// post-start tasks card) can use it without an implicit
        /// MainActor hop.
        nonisolated static func formatEta(_ seconds: Double) -> String {
            let s = max(seconds, 0)
            if s < 1 { return "<1s" }
            if s < 60 { return "\(Int(s.rounded()))s" }
            let minutes = Int(s / 60)
            let remSeconds = Int(s.truncatingRemainder(dividingBy: 60))
            if minutes >= 5 { return "\(minutes)m" }
            return "\(minutes)m \(remSeconds)s"
        }
    }

    // MARK: - Step Row

    private struct StepRow: View {
        let step: ProvisioningStepState
        let isActive: Bool

        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    statusIcon
                        .frame(width: 16)
                    Text(step.label)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundColor(labelColor)
                    Spacer()
                    if isActive {
                        if let eta = step.etaSeconds, eta > 0 {
                            Text("≈ \(ProvisioningJourneyView.formatEta(eta))", bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .monospacedDigit()
                        }
                    } else if step.status == .skipped {
                        Text("Cached", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    } else if step.status == .completed,
                        let elapsed = stepElapsed
                    {
                        Text(ProvisioningJourneyView.formatEta(elapsed))
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .monospacedDigit()
                    }
                }

                if isActive {
                    activeProgress
                        .padding(.leading, 26)
                }
            }
            .padding(.vertical, 4)
        }

        @ViewBuilder
        private var activeProgress: some View {
            VStack(alignment: .leading, spacing: 4) {
                if let progress = step.progress {
                    ProgressView(value: max(0, min(progress, 1)))
                        .progressViewStyle(.linear)
                        .tint(theme.accentColor)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(theme.accentColor)
                }

                if let total = step.bytesTotal, total > 0 {
                    let processed = step.bytesProcessed ?? 0
                    Text(
                        SandboxManager.formatByteActivity(
                            bytes: processed,
                            total: total,
                            bytesPerSecond: step.bytesPerSecond
                        )
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                } else if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch step.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.successColor)
            case .skipped:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.tertiaryText)
            case .inProgress:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            case .pending:
                Image(systemName: "circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.errorColor)
            }
        }

        private var labelColor: Color {
            switch step.status {
            case .completed, .skipped: return theme.primaryText
            case .inProgress: return theme.primaryText
            case .pending: return theme.tertiaryText
            case .failed: return theme.errorColor
            }
        }

        private var stepElapsed: Double? {
            guard let start = step.startedAt, let end = step.finishedAt else { return nil }
            let seconds = end.timeIntervalSince(start)
            return seconds > 0 ? seconds : nil
        }
    }

#endif
