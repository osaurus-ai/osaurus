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
        @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

        /// External error surface from `SandboxView.performProvision`.
        let provisionError: String?
        let onRetry: () -> Void
        /// Nil once nothing is running to cancel.
        var onCancel: (() -> Void)? = nil
        var onCopyDetails: (() -> Void)? = nil
        var onOpenTroubleshooting: (() -> Void)? = nil

        var body: some View {
            VStack(spacing: theme.settingsSectionGap) {
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
                } else if let onCancel {
                    SettingsButton(
                        .secondary,
                        "Cancel",
                        size: .compact,
                        help: "Stops setup. Downloads pick up where they left off next time.",
                        action: onCancel
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

        // MARK: - Header (title + elapsed)

        private var header: some View {
            VStack(spacing: theme.space.s6) {
                Text("Setting up sandbox", bundle: .module)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.pageTitle)
                    .foregroundColor(theme.text.primary)

                if let startedAt = sandboxState.journey?.startedAt,
                    sandboxState.journey?.finishedAt == nil
                {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: "clock")
                            .glyphSize(.footnote)
                        // Count up MM:SS from `startedAt`. The default
                        // `countsDown: true` would render time until
                        // `.distantFuture` (~17M hours).
                        Text(
                            timerInterval: startedAt ... .distantFuture,
                            countsDown: false,
                            showsHours: false
                        )
                        .componentInspectionText(49, role: .body, fallback: .code, theme: theme)
                    }
                    .foregroundColor(theme.text.tertiary)
                }
            }
        }

        // MARK: - Journey content

        private func journeyContent(journey: ProvisioningJourney) -> some View {
            VStack(spacing: theme.space.s12) {
                VStack(spacing: theme.space.s6) {
                    // Asset steps run concurrently, so every running row
                    // carries its own progress rather than one "current" row.
                    ForEach(journey.steps) { step in
                        StepRow(step: step, isActive: step.status == .inProgress)
                    }
                }
                .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
                .settingsChrome(.card)

                activityAndETA(journey: journey)
            }
        }

        @ViewBuilder
        private func activityAndETA(journey: ProvisioningJourney) -> some View {
            HStack(alignment: .top, spacing: theme.space.s12) {
                if let activity = sandboxState.currentActivity, !activity.isEmpty {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: "waveform")
                            .glyphSize(.footnote, weight: .semibold)
                            .foregroundColor(theme.text.link)
                        Text(activity)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                if let remaining = journey.remainingTotalSeconds {
                    Text("≈ \(Self.formatEta(remaining)) remaining", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                        .monospacedDigit()
                }
            }
        }

        // MARK: - Legacy fallback

        private var legacyContent: some View {
            VStack(spacing: theme.space.s16) {
                if let progress = sandboxState.provisioningProgress {
                    SettingsProgressBar(value: progress, tint: theme.action.primary.default.background)
                        .frame(width: 220)
                } else {
                    SettingsSpinner(size: .large, tint: theme.action.primary.default.background)
                }

                if let phase = sandboxState.provisioningPhase {
                    HStack(spacing: theme.space.s6) {
                        Text(phase)
                        if let progress = sandboxState.provisioningProgress {
                            Text("\(Int(progress * 100))%", bundle: .module)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .componentInspectionText(49, role: .body, fallback: .bodySmall, theme: theme)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .animation(theme.motion.quick, value: phase)
                }
            }
        }

        // MARK: - Retry banner

        private func retryBanner(message: String) -> some View {
            VStack(spacing: theme.space.s8) {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .glyphSize(.caption)
                    Text(message)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .foregroundColor(theme.status.warning.foreground)

                HStack(spacing: theme.space.s8) {
                    SettingsButton(.primary, "Retry", icon: "arrow.clockwise", size: .compact, action: onRetry)
                    if let onCopyDetails {
                        SettingsButton(.secondary, "Copy Details", icon: "doc.on.doc", size: .compact, action: onCopyDetails)
                    }
                    if let onOpenTroubleshooting {
                        SettingsButton(.tertiary, "Open Troubleshooting", size: .compact, action: onOpenTroubleshooting)
                    }
                }
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
            ProvisioningJourney.formatEta(seconds)
        }
    }

    // MARK: - Step Row

    private struct StepRow: View {
        let step: ProvisioningStepState
        let isActive: Bool

        @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

        var body: some View {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s8) {
                    statusIcon
                        .frame(width: 16)
                    Text(step.label)
                        .componentInspectionText(49, role: .label, fallback: .label, weight: isActive ? 600 : 400, theme: theme)
                        .foregroundColor(labelColor)
                    Spacer()
                    if isActive {
                        if let eta = step.etaSeconds, eta > 0 {
                            Text("≈ \(ProvisioningJourneyView.formatEta(eta))", bundle: .module)
                                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                                .monospacedDigit()
                        }
                    } else if step.status == .skipped {
                        Text("Cached", bundle: .module)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    } else if step.status == .completed,
                        let elapsed = stepElapsed
                    {
                        Text(ProvisioningJourneyView.formatEta(elapsed))
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .monospacedDigit()
                    }
                }

                if isActive {
                    activeProgress
                        .padding(.leading, theme.space.s24)
                }
            }
            .padding(.vertical, theme.space.s4)
    }

        @ViewBuilder
        private var activeProgress: some View {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                if let progress = step.progress {
                    SettingsProgressBar(value: progress, tint: theme.action.primary.default.background)
                } else {
                    SettingsProgressBar(value: nil, tint: theme.action.primary.default.background)
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
                    .componentInspectionText(49, role: .code, fallback: .footnote, family: .code, theme: theme)
                    .foregroundColor(theme.text.tertiary)
                } else if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
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
                    .glyphSize(.body)
                    .foregroundColor(theme.status.success.foreground)
            case .skipped:
                Image(systemName: "checkmark.circle")
                    .glyphSize(.body)
                    .foregroundColor(theme.text.tertiary)
            case .inProgress:
                SettingsSpinner(size: .mini)
            case .pending:
                Image(systemName: "circle")
                    .glyphSize(.body)
                    .foregroundColor(theme.text.tertiary)
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .glyphSize(.body)
                    .foregroundColor(theme.status.error.foreground)
            }
        }

        private var labelColor: Color {
            switch step.status {
            case .completed, .skipped: return theme.text.primary
            case .inProgress: return theme.text.primary
            case .pending: return theme.text.tertiary
            case .failed: return theme.status.error.foreground
            }
        }

        private var stepElapsed: Double? {
            guard let start = step.startedAt, let end = step.finishedAt else { return nil }
            let seconds = end.timeIntervalSince(start)
            return seconds > 0 ? seconds : nil
        }
    }

extension ProvisioningJourneyView {
    @MainActor static func inspectionRows() -> some View {
        let theme = ThemeManager.shared.currentTheme
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            StepRow(step: .init(id: .downloadKernel, label: "Local download display", status: .inProgress, progress: 0.5, bytesProcessed: 32_000_000, bytesTotal: 64_000_000, bytesPerSecond: 8_000_000, etaSeconds: 4), isActive: true)
            StepRow(step: .init(id: .downloadInitFS, label: "Cached local display", status: .skipped), isActive: false)
            StepRow(step: .init(id: .createContainer, label: "Failed local display", status: .failed), isActive: false)
        }
    }
}
#endif
