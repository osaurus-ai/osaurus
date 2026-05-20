//
//  AdvancedHTTPSection.swift
//  osaurus
//
//  HTTP body limits for the Server → Settings tab. Persisted to
//  `server.json` and enforced by Osaurus's HTTP pipeline (`/v1/...`
//  endpoints and the unauthenticated `/pair` route).
//

import SwiftUI

struct AdvancedHTTPSection: View {
    @Binding var draft: ServerConfiguration

    var body: some View {
        SettingsSection(title: "Advanced HTTP", icon: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .hostOwned,
                    blurb: "Hard caps applied by Osaurus's HTTP pipeline."
                )

                OptionalIntField(
                    label: "Max Request Body (MB)",
                    placeholder: "32",
                    help: "Reject bodies larger than this with 413.",
                    value: requestBodyBinding,
                    clamp: 1 ... 8192
                )

                OptionalIntField(
                    label: "Max Pairing Body (KB)",
                    placeholder: "64",
                    help: "Tighter cap for the unauthenticated /pair endpoint.",
                    value: pairingBodyBinding,
                    clamp: 1 ... 1024 * 1024
                )
            }
        }
    }

    /// Stored in bytes; surfaced and edited in MB.
    private var requestBodyBinding: Binding<Int?> {
        Binding(
            get: { draft.maxRequestBodyBytes / (1024 * 1024) },
            set: { newValue in
                guard let mb = newValue, mb > 0 else { return }
                draft.maxRequestBodyBytes = mb * 1024 * 1024
            }
        )
    }

    /// Stored in bytes; surfaced and edited in KB.
    private var pairingBodyBinding: Binding<Int?> {
        Binding(
            get: { draft.maxPairingBodyBytes / 1024 },
            set: { newValue in
                guard let kb = newValue, kb > 0 else { return }
                draft.maxPairingBodyBytes = kb * 1024
            }
        )
    }
}
