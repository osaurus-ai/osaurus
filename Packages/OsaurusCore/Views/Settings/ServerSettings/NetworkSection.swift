//
//  NetworkSection.swift
//  osaurus
//
//  Network & identity controls for the Server → Settings tab.
//  Edits `runtimeSettings.network` and projects port/host/CORS back
//  into the legacy `ServerConfiguration` on save.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct NetworkSection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    @State private var portText: String = ""
    @State private var corsText: String = ""
    @State private var initialized: Bool = false

    var body: some View {
        SettingsSection(title: "Network & Identity", icon: "network") {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .engineReady,
                    blurb: "Host, port, and CORS map to the Osaurus NIO server."
                )

                SettingsStepperField(
                    label: "Port",
                    help: "Port number (1–65535)",
                    text: $portText,
                    range: 1 ... 65535,
                    step: 1,
                    defaultValue: 1337
                )
                .onChange(of: portText) { _, _ in commitPort() }

                SettingsToggle(
                    title: L("Expose to Network"),
                    description: "Allow devices on your local network to connect (binds on 0.0.0.0)",
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
                        "Loopback (127.0.0.1) is always allowed. Comma-separated. Use * to allow any origin."
                )
                .onChange(of: corsText) { _, _ in commitCors() }

                SettingsDivider()

                OptionalStringField(
                    label: "Served Model Name",
                    placeholder: "Optional. Leave blank to advertise model id directly.",
                    help: "Alias surfaced to OpenAI/Ollama/Anthropic clients.",
                    value: $draft.network.servedModelName
                )

                SettingsDivider()

                SettingsSubsection(label: "Planned Network Controls") {
                    VStack(alignment: .leading, spacing: 12) {
                        ServerSettingsPlannedBanner(
                            blurb: "These persist and validate today; the NIO pipeline bridge is a follow-up."
                        )

                        OptionalIntField(
                            label: "Rate Limit (req/min)",
                            placeholder: "Empty = no rate limit",
                            help: "Server-side rate limit per access key.",
                            value: $draft.network.rateLimitRequestsPerMinute
                        )

                        OptionalIntField(
                            label: "Request Timeout (s)",
                            placeholder: "Empty = no timeout",
                            help: "Drop requests that stall longer than this.",
                            value: $draft.network.timeoutSeconds
                        )

                        SettingsField(
                            label: "Log Level",
                            hint: "Verbosity for server-side log output."
                        ) {
                            Picker("", selection: $draft.network.logLevel) {
                                ForEach(VMLXServerLogLevel.allCases, id: \.self) { level in
                                    Text(level.rawValue.capitalized).tag(level)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "API Authentication") {
                    HStack(spacing: 10) {
                        Image(systemName: "key.horizontal")
                            .foregroundColor(theme.accentColor)
                        Text(
                            "Access keys are managed in the Overview tab and stored in the macOS Keychain.",
                            bundle: .module
                        )
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        Spacer()
                        ServerSettingsStatusBadge(status: .hostOwned)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground.opacity(0.5))
                    )
                }
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            syncTextFromDraft()
        }
        .onChange(of: draft.network.port) { _, _ in syncPortFromDraft() }
        .onChange(of: draft.network.corsOrigins) { _, _ in syncCorsFromDraft() }
    }

    private func syncTextFromDraft() {
        syncPortFromDraft()
        syncCorsFromDraft()
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
