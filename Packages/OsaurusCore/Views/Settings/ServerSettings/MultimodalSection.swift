//
//  MultimodalSection.swift
//  osaurus
//
//  Multimodal (vision/audio/video) toggles for the Server → Settings
//  tab. Enforcement lives in `validateRequest(...)`; the Auto default
//  follows the loaded model's capabilities.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct MultimodalSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    var body: some View {
        ServerSettingsCard(
            section: .multimodal,
            status: .engineReady,
            blurb:
                "Vision / video / audio gating. Auto follows the loaded model; Force-Off rejects media regardless of model capability."
        ) {
            SettingsField(
                label: "Vision-Language Mode",
                hint:
                    "Auto = follow the model. Force-Off = reject any media. Force-On = require model support."
            ) {
                Picker("", selection: $draft.multimodal.vlmMode) {
                    ForEach(VMLXVLMServerMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SettingsToggle(
                title: L("Allow Video"),
                description: "Permit video-bearing requests on capable models.",
                isOn: $draft.multimodal.enableVideo
            )

            SettingsToggle(
                title: L("Allow Audio"),
                description: "Permit audio-bearing requests on capable models.",
                isOn: $draft.multimodal.enableAudio
            )

            SettingsToggle(
                title: L("Require Media Salt for Cache"),
                description:
                    "Engine invariant whenever a cache reuse tier is enabled — keeps prompts with different media from sharing cache entries. Disabling fails validation.",
                isOn: $draft.multimodal.requireMediaSaltForCache
            )
        }
    }
}
