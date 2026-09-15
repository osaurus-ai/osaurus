//
//  ModelResidencySection.swift
//  osaurus
//
//  Osaurus-owned model memory policy (eviction + idle residency) for
//  the Server → Settings tab. Persisted to `server.json`.
//

import SwiftUI

struct ModelResidencySection: View {
    @Binding var draft: ServerConfiguration
    @Environment(\.theme) private var theme

    var body: some View {
        ServerSettingsCard(
            section: .modelMemory,
            status: .hostOwned,
            blurb:
                "When to evict a loaded model from RAM, and how long to keep it warm after the last request.",
            spacing: 16
        ) {
            SettingsSubsection(label: "Eviction Policy") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $draft.modelEvictionPolicy) {
                        ForEach(ModelEvictionPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(draft.modelEvictionPolicy.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            SettingsSubsection(label: "Model Residency") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep Model Loaded", isOn: $draft.modelIdleResidencyPolicy.keepsModelLoaded)
                        .accessibilityIdentifier("server.residency.keepLoaded")
                    if !draft.modelIdleResidencyPolicy.keepsModelLoaded {
                        Picker("Unload After", selection: $draft.modelIdleResidencyPolicy) {
                            ForEach(ModelIdleResidencyPolicy.presets.filter { $0 != .never }, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                            // Keep an existing custom timeout representable.
                            if !ModelIdleResidencyPolicy.presets.contains(draft.modelIdleResidencyPolicy) {
                                Text(draft.modelIdleResidencyPolicy.displayName).tag(draft.modelIdleResidencyPolicy)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("server.residency.unloadAfter")
                    }

                    Text(draft.modelIdleResidencyPolicy.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
        .accessibilityIdentifier("server.residency")
        .settingsLandingAnchor("server.residency")
    }
}
