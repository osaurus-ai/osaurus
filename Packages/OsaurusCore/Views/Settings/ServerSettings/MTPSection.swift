//
//  MTPSection.swift
//  osaurus
//
//  MTP / speculative decode controls for the Server → Settings tab.
//  Native MTP launch is host-resolved per request via
//  `resolvedMTPDraftStrategy(...)`; values here persist and validate.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct MTPSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    var body: some View {
        SettingsSection(title: "MTP / Speculative Decode", icon: "bolt.horizontal") {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .needsBridge,
                    blurb:
                        "Validated and persisted. Native MTP launch is host-resolved per request via resolvedMTPDraftStrategy(...)."
                )

                SettingsField(
                    label: "Mode",
                    hint:
                        "Off disables MTP entirely. Auto enables it only when the bundle proves a tensor-backed native MTP recommendation. Force-On requires verified support."
                ) {
                    Picker("", selection: $draft.mtp.mode) {
                        ForEach(VMLXMTPServerMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                OptionalIntField(
                    label: "Draft Token Limit",
                    placeholder: "Empty = engine recommendation",
                    help: "Caps native MTP draft depth per step.",
                    value: $draft.mtp.draftTokenLimit
                )

                SettingsToggle(
                    title: L("Keep Draft Cache Separate"),
                    description: "Required invariant. Disabling produces a validation error.",
                    isOn: $draft.mtp.keepDraftCacheSeparate
                )

                SettingsToggle(
                    title: L("Only Accepted Tokens Enter Base Cache"),
                    description: "Required invariant. Disabling produces a validation error.",
                    isOn: $draft.mtp.acceptedTokensOnlyEnterBaseCache
                )
            }
        }
    }
}
