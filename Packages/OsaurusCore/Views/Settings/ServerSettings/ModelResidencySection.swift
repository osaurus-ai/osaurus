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
            SettingsFieldRow(label: "Eviction Policy") {
                VStack(alignment: .leading, spacing: 8) {
                    AssignedBaseSegmentedPicker(
                        selection: $draft.modelEvictionPolicy,
                        options: ModelEvictionPolicy.allCases.map { .init($0, $0.displayName, verbatim: true) }
                    )
                    .fixedSize()
                    .accessibilityLabel(Text("Eviction Policy", bundle: .module))

                    Text(draft.modelEvictionPolicy.description)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }

            SettingsFieldRow(label: "Model Residency") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep Model Loaded", isOn: $draft.modelIdleResidencyPolicy.keepsModelLoaded)
                        .settingsCheckbox()
                        .accessibilityIdentifier("server.residency.keepLoaded")
                    if !draft.modelIdleResidencyPolicy.keepsModelLoaded {
                        SettingsRow(title: "Unload After", description: "") {
                            SettingsMenuPicker(selection: $draft.modelIdleResidencyPolicy) {
                                ForEach(ModelIdleResidencyPolicy.presets.filter { $0 != .never }, id: \.self) {
                                    policy in
                                    Text(policy.displayName).tag(policy)
                                }
                                // Keep an existing custom timeout representable.
                                if !ModelIdleResidencyPolicy.presets.contains(draft.modelIdleResidencyPolicy) {
                                    Text(draft.modelIdleResidencyPolicy.displayName).tag(draft.modelIdleResidencyPolicy)
                                }
                            }
                            .accessibilityIdentifier("server.residency.unloadAfter")
                        }
                    }

                    Text(draft.modelIdleResidencyPolicy.description)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }
        }
        .accessibilityIdentifier("server.residency")
        .settingsLandingAnchor("server.residency")
    }
}
