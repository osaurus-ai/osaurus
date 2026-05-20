//
//  PowerSection.swift
//  osaurus
//
//  Power & Sleep controls (auto sleep, JIT load, wake on request).
//  Persisted today; the host lifecycle bridge is a follow-up.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct PowerSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    var body: some View {
        ServerSettingsCard(
            section: .power,
            status: .needsBridge,
            blurb:
                "Reclaim GPU and disk when the server is idle. Persisted today; host lifecycle bridge ships in a follow-up."
        ) {
            SettingsToggle(
                title: L("Auto Sleep"),
                description: "Let the server release memory when no requests are in flight.",
                isOn: $draft.power.autoSleepEnabled
            )

            OptionalIntField(
                label: "Light Sleep After (seconds)",
                placeholder: "Blank = disabled",
                help: "Release GPU buffers after this much idle time. Weights stay loaded.",
                value: $draft.power.lightSleepAfterSeconds
            )

            OptionalIntField(
                label: "Deep Sleep After (seconds)",
                placeholder: "Blank = disabled",
                help: "Unload model weights after this much idle time. Must exceed light sleep.",
                value: $draft.power.deepSleepAfterSeconds
            )

            SettingsToggle(
                title: L("Wake on Request"),
                description: "Re-load weights automatically when a new request arrives.",
                isOn: $draft.power.wakeOnRequest
            )

            SettingsToggle(
                title: L("Defer First Load"),
                description: "Wait until the first request before loading any model.",
                isOn: $draft.power.jitLoad
            )
        }
    }
}
