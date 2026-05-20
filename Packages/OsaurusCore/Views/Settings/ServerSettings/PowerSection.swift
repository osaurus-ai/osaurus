//
//  PowerSection.swift
//  osaurus
//
//  Power & lifecycle controls (auto sleep, JIT load, wake on request)
//  for the Server → Settings tab. Persisted today; the host lifecycle
//  bridge is a follow-up.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct PowerSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    var body: some View {
        SettingsSection(title: "Power & Lifecycle", icon: "powersleep") {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .needsBridge,
                    blurb:
                        "Validated and persisted. Host lifecycle (sleep/wake/JIT) bridge is a follow-up."
                )

                SettingsToggle(
                    title: L("Auto Sleep"),
                    description: "Allow the server to unload models on idle.",
                    isOn: $draft.power.autoSleepEnabled
                )

                OptionalIntField(
                    label: "Light Sleep After (s)",
                    placeholder: "Empty = disabled",
                    help: "Drop GPU buffers after this idle time.",
                    value: $draft.power.lightSleepAfterSeconds
                )

                OptionalIntField(
                    label: "Deep Sleep After (s)",
                    placeholder: "Empty = disabled",
                    help: "Unload weights after this idle time. Must be > light sleep.",
                    value: $draft.power.deepSleepAfterSeconds
                )

                SettingsToggle(
                    title: L("Wake on Request"),
                    description: "Reload weights automatically when a new request arrives.",
                    isOn: $draft.power.wakeOnRequest
                )

                SettingsToggle(
                    title: L("JIT Load"),
                    description: "Defer first-load until the first request after launch.",
                    isOn: $draft.power.jitLoad
                )
            }
        }
    }
}
