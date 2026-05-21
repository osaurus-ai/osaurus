//
//  PostStartTasksCard.swift
//  osaurus
//
//  Inline card surfaced on the sandbox dashboard while the
//  post-start `verifyPlugins` step is running. Tells the user
//  "your plugins are being restored" (with the current activity
//  line) so the silent-but-busy window that used to follow
//  `_status = .running` is no longer a UX surprise.
//
//  Renders nothing once the verifyPlugins step finishes (or when
//  no plugins need verifying), so the dashboard reclaims the
//  vertical space without a layout pop.
//

import SwiftUI

#if os(macOS)

    struct PostStartTasksCard: View {
        @ObservedObject private var sandboxState = SandboxManager.State.shared
        @ObservedObject private var pluginManager = SandboxPluginManager.shared
        @Environment(\.theme) private var theme

        var body: some View {
            if let verifyStep = sandboxState.journey?.step(.verifyPlugins),
                verifyStep.status == .inProgress
            {
                content(verifyStep: verifyStep)
            }
        }

        private func content(verifyStep: ProvisioningStepState) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                    Text("Restoring plugins", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    if let eta = verifyStep.etaSeconds, eta > 0 {
                        Text("≈ \(ProvisioningJourneyView.formatEta(eta))", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .monospacedDigit()
                    }
                }

                if !pluginManager.installProgress.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sortedProgress, id: \.0) { _, progress in
                            HStack(spacing: 8) {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.accentColor)
                                Text(progress.pluginName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                Text("·")
                                    .foregroundColor(theme.tertiaryText)
                                Text(progress.phase)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                } else if let detail = verifyStep.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
        }

        /// Stable ordering so the rows don't churn between snapshots:
        /// dictionaries don't promise iteration order, and SwiftUI
        /// `ForEach` will flicker without a consistent key sequence.
        private var sortedProgress: [(String, SandboxPluginManager.InstallProgress)] {
            pluginManager.installProgress
                .sorted { lhs, rhs in lhs.key < rhs.key }
                .map { ($0.key, $0.value) }
        }
    }

#endif
