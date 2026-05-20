//
//  ConnectionSection.swift
//  osaurus
//
//  Listening port + LAN exposure + CORS + served-model alias. Edits
//  `runtimeSettings.network` and projects port/host/CORS back into
//  `ServerConfiguration` on save (handled by the parent's save path).
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct ConnectionSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    @State private var portText: String = ""
    @State private var corsText: String = ""
    @State private var initialized: Bool = false

    var body: some View {
        ServerSettingsCard(
            section: .connection,
            status: .engineReady,
            blurb: "Where Osaurus listens for client requests. Changes restart the server."
        ) {
            SettingsStepperField(
                label: "Listening Port",
                help: "Most clients default to 1337 (Osaurus) or 11434 (Ollama-compatible).",
                text: $portText,
                range: 1 ... 65535,
                step: 1,
                defaultValue: 1337
            )
            .onChange(of: portText) { _, _ in commitPort() }

            SettingsToggle(
                title: L("Expose to Network"),
                description:
                    "Off binds to 127.0.0.1 (this Mac only). On binds to 0.0.0.0 so phones, iPads, and other devices on your network can connect.",
                isOn: Binding(
                    get: { draft.network.host == "0.0.0.0" },
                    set: { draft.network.host = $0 ? "0.0.0.0" : "127.0.0.1" }
                )
            )

            StyledSettingsTextField(
                label: "Allowed Origins (CORS)",
                text: $corsText,
                placeholder: "* or https://app.example.com, https://other.example.com",
                help:
                    "Browser apps only. Loopback is always allowed. Use * to allow any origin; comma-separated otherwise."
            )
            .onChange(of: corsText) { _, _ in commitCors() }

            SettingsDivider()

            OptionalStringField(
                label: "Served Model Name",
                placeholder: "Optional. Leave blank to advertise the model id directly.",
                help: "Alias the server reports to OpenAI / Ollama / Anthropic clients.",
                value: $draft.network.servedModelName
            )
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            syncPortFromDraft()
            syncCorsFromDraft()
        }
        .onChange(of: draft.network.port) { _, _ in syncPortFromDraft() }
        .onChange(of: draft.network.corsOrigins) { _, _ in syncCorsFromDraft() }
    }

    private func syncPortFromDraft() {
        let desired = draft.network.port.map(String.init) ?? "1337"
        if portText != desired { portText = desired }
    }

    private func syncCorsFromDraft() {
        let desired = draft.network.corsOrigins.joined(separator: ", ")
        if corsText != desired { corsText = desired }
    }

    private func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), (1 ..< 65536).contains(parsed) else { return }
        if draft.network.port != parsed { draft.network.port = parsed }
    }

    private func commitCors() {
        let parsed: [String] =
            corsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalized = parsed.isEmpty ? ["*"] : parsed
        if draft.network.corsOrigins != normalized { draft.network.corsOrigins = normalized }
    }
}
