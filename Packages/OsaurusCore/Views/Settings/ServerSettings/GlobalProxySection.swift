//
//  GlobalProxySection.swift
//  osaurus
//
//  Optional outbound proxy endpoint. This edits the legacy
//  `ServerConfiguration` field because network clients need a tiny,
//  synchronous setting that is available before the server controller
//  has finished building runtime state.
//

import SwiftUI

struct GlobalProxySection: View {
    @Binding var draft: ServerConfiguration

    @Environment(\.theme) private var theme
    @State private var proxyText: String = ""
    @State private var validationMessage: String?
    @State private var initialized: Bool = false

    var body: some View {
        ServerSettingsCard(
            section: .globalProxy,
            status: .engineReady,
            blurb: "Outbound provider, plugin, and model-download sessions use this endpoint when they are created."
        ) {
            StyledSettingsTextField(
                label: "Proxy URL",
                text: $proxyText,
                placeholder: "http://proxy.example.com:8080",
                help:
                    "Supports http, https, socks, and socks5 URLs with an explicit host and port. Credentials are not accepted here."
            )
            .onChange(of: proxyText) { _, _ in commitProxy() }

            if let validationMessage {
                Text(LocalizedStringKey(validationMessage), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            proxyText = draft.globalProxyURL ?? ""
        }
        .onChange(of: draft.globalProxyURL) { _, newValue in
            let desired = newValue ?? ""
            if proxyText != desired { proxyText = desired }
        }
    }

    private func commitProxy() {
        let trimmed = proxyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = nil
            if draft.globalProxyURL != nil { draft.globalProxyURL = nil }
            return
        }

        do {
            let proxy = try GlobalProxyConfiguration(urlString: trimmed)
            validationMessage = nil
            if draft.globalProxyURL != proxy.redactedDescription {
                draft.globalProxyURL = proxy.redactedDescription
            }
            if proxyText != proxy.redactedDescription {
                proxyText = proxy.redactedDescription
            }
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
