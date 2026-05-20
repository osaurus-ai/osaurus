//
//  MultimodalSection.swift
//  osaurus
//
//  Multimodal (VLM/audio/video) controls for the Server → Settings tab.
//  Enforcement lives in `validateRequest(...)`; the Auto-by-default
//  setting follows the loaded model's capabilities.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct MultimodalSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    var body: some View {
        SettingsSection(title: "Multimodal", icon: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .engineReady,
                    blurb:
                        "validateRequest(...) enforces these toggles. Defaults to Auto so capability comes from the loaded model."
                )

                SettingsField(
                    label: "VLM Mode",
                    hint:
                        "Force-Off rejects any vision/video/audio requests. Auto follows the model's capabilities."
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
                    title: L("Enable Video"),
                    description: "Allow video-bearing requests on capable models.",
                    isOn: $draft.multimodal.enableVideo
                )

                SettingsToggle(
                    title: L("Enable Audio"),
                    description: "Allow audio-bearing requests on capable models.",
                    isOn: $draft.multimodal.enableAudio
                )

                SettingsToggle(
                    title: L("Require Media Salt for Cache"),
                    description:
                        "Required by cacheCoordinatorConfig whenever a cache reuse tier is enabled. Disabling fails validation.",
                    isOn: $draft.multimodal.requireMediaSaltForCache
                )
            }
        }
    }
}
