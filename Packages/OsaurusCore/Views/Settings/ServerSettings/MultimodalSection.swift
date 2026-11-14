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
            SettingsRow(
                title: "Vision-Language Mode",
                description:
                    "Auto = follow the model. Force-Off = reject any media. Force-On = require model support."
            ) {
                AssignedBaseSegmentedPicker(
                    selection: $draft.multimodal.vlmMode,
                    options: VMLXVLMServerMode.allCases.map {
                        .init($0, $0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, verbatim: true)
                    }
                )
                .fixedSize()
                .accessibilityLabel(Text("Vision-Language Mode", bundle: .module))
            }

            SettingsToggle(
                title: "Allow Video",
                description: "Permit video-bearing requests on capable models.",
                isOn: $draft.multimodal.enableVideo
            )

            SettingsToggle(
                title: "Allow Audio",
                description: "Permit audio-bearing requests on capable models.",
                isOn: $draft.multimodal.enableAudio
            )

            SettingsToggle(
                title: "Require Media Salt for Cache",
                description:
                    "Engine invariant whenever a cache reuse tier is enabled — keeps prompts with different media from sharing cache entries. Disabling fails validation.",
                isOn: $draft.multimodal.requireMediaSaltForCache
            )
        }
    }
}
