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
                        .font(SettingsFont.cardTitle)
                        .foregroundColor(theme.text.primary)
                    Spacer()
                    if let eta = verifyStep.etaSeconds, eta > 0 {
                        Text("≈ \(ProvisioningJourneyView.formatEta(eta))", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .monospacedDigit()
                    }
                }

                if !pluginManager.installProgress.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sortedProgress, id: \.0) { _, progress in
                            HStack(spacing: 8) {
                                Image(systemName: "puzzlepiece.extension")
                                    .glyphSize(11)
                                    .foregroundColor(theme.text.link)
                                Text(progress.pluginName)
                                    .font(SettingsFont.compactLabel)
                                    .foregroundColor(theme.text.primary)
                                Text("·")
                                    .foregroundColor(theme.text.tertiary)
                                Text(progress.phase)
                                    .font(SettingsFont.caption)
                                    .foregroundColor(theme.text.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                        }
                    }
                    .padding(theme.space.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsChrome(.control)
                } else if let detail = verifyStep.detail {
                    Text(detail)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .padding(theme.space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.card)
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
