//
//  MTPSection.swift
//  osaurus
//
//  Speculative Decoding controls for the Server → Settings tab.
//  Native MTP launch is host-resolved per request via
//  `resolvedMTPDraftStrategy(...)`; values here persist and validate.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct MTPSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    var body: some View {
        ServerSettingsCard(
            section: .speculative,
            status: .engineReady,
            blurb:
                "Draft tokens with a fast helper model and verify with the main model in a single step. Engaged per request when the model supports it."
        ) {
            SettingsField(
                label: "Mode",
                hint:
                    "Off disables speculation. Auto uses it only when the model ships a verified native MTP head. Force-On requires that head."
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
                label: "Draft Tokens Per Step",
                placeholder: "Blank = engine recommendation",
                help: "How many tokens the draft model proposes before the main model verifies.",
                value: $draft.mtp.draftTokenLimit
            )

            SettingsToggle(
                title: L("Keep Draft Cache Separate"),
                description: "Engine invariant. Disabling produces a validation error.",
                isOn: $draft.mtp.keepDraftCacheSeparate
            )

            SettingsToggle(
                title: L("Only Accepted Tokens Enter Base Cache"),
                description: "Engine invariant. Disabling produces a validation error.",
                isOn: $draft.mtp.acceptedTokensOnlyEnterBaseCache
            )
        }
    }
}
