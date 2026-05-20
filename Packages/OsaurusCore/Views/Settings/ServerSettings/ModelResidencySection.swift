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
        SettingsSection(title: "Model Residency", icon: "memorychip") {
            VStack(alignment: .leading, spacing: 16) {
                ServerSettingsSectionStatus(
                    status: .hostOwned,
                    blurb: "Osaurus-owned model memory policy. Persisted to server.json."
                )

                SettingsSubsection(label: "Eviction Policy") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $draft.modelEvictionPolicy) {
                            ForEach(ModelEvictionPolicy.allCases, id: \.self) { policy in
                                Text(policy.rawValue).tag(policy)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text(draft.modelEvictionPolicy.description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }

                SettingsSubsection(label: "Keep Model Loaded") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $draft.modelIdleResidencyPolicy) {
                            ForEach(ModelIdleResidencyPolicy.presets, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        Text(draft.modelIdleResidencyPolicy.description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }
        }
    }
}
