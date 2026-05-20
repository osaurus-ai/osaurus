//
//  AuthenticationSection.swift
//  osaurus
//
//  API key callout plus planned rate-limit / timeout / log-level
//  controls. Access keys are managed in the Overview tab and stored in
//  the macOS Keychain; this section is read-mostly for the daily user.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct AuthenticationSection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    var body: some View {
        ServerSettingsCard(
            section: .authentication,
            status: .hostOwned,
            blurb: "Who can call your API and how aggressively."
        ) {
            accessKeyCallout

            SettingsDivider()

            SettingsSubsection(label: "Planned Controls") {
                VStack(alignment: .leading, spacing: 12) {
                    ServerSettingsPlannedBanner(
                        blurb:
                            "Saved today; the request pipeline will start enforcing these in a follow-up."
                    )

                    OptionalIntField(
                        label: "Rate Limit (requests / minute)",
                        placeholder: "Empty = unlimited",
                        help: "Per access key. Blocks excess requests with HTTP 429.",
                        value: $draft.network.rateLimitRequestsPerMinute
                    )

                    OptionalIntField(
                        label: "Request Timeout (seconds)",
                        placeholder: "Empty = unlimited",
                        help: "Drop requests that stall longer than this.",
                        value: $draft.network.timeoutSeconds
                    )

                    SettingsField(
                        label: "Log Level",
                        hint: "Verbosity of the server-side request log."
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
        }
    }

    private var accessKeyCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("API access keys", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Manage keys in the Server → Overview tab. They are stored in the macOS Keychain and never leave this device.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ServerSettingsStatusBadge(status: .hostOwned)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }
}
