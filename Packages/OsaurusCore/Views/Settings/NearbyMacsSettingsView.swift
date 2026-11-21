//
//  NearbyMacsSettingsView.swift
//  osaurus
//
//  Model Sources → Nearby Macs: share chosen models with other Osaurus Macs
//  on this network, and copy models from them instead of the internet.
//

import SwiftUI

struct NearbyMacsSettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var service = ModelShareService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            SettingsToggle(
                title: "Share Models on This Network",
                description:
                    "Let other Osaurus Macs on this Wi-Fi or Ethernet network copy the models you choose below. Nothing is shared until you pick a model.",
                badge: sharedCount > 0 ? "\(sharedCount)" : nil,
                anchorId: "models.sharing.share",
                isOn: Binding(
                    get: { service.configuration.shareOnLocalNetwork },
                    set: { service.setShareOnLocalNetwork($0) }
                )
            )

            if service.configuration.shareOnLocalNetwork {
                sharedModels
            }

            SettingsToggle(
                title: "Find Models on Nearby Macs",
                description:
                    "Show models other Osaurus Macs share on this network, and copy them from there instead of downloading from the internet.",
                anchorId: "models.sharing.nearby",
                isOn: Binding(
                    get: { service.configuration.useNearbyMacs },
                    set: { service.setUseNearbyMacs($0) }
                )
            )

            statusRow
        }
    }

    private var sharedCount: Int {
        service.shareable.filter { service.isShared($0.id) }.count
    }

    private var sharedModels: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text("Shared Models", bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
                .settingsLandingAnchor("models.sharing.sharedModels")

            if service.shareable.isEmpty {
                Text("No models on this Mac can be shared yet.", bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            } else {
                ForEach(ModelShareKind.allCases, id: \.self) { kind in
                    let models = service.shareable.filter { $0.kind == kind }
                    if !models.isEmpty {
                        VStack(alignment: .leading, spacing: theme.space.s6) {
                            Text(kind.localModelKind.title)
                                .textStyle(.footnote, weight: 500)
                                .foregroundColor(theme.text.tertiary)
                            ForEach(models, id: \.id) { model in
                                SettingsToggle(
                                    title: model.name,
                                    description: detail(for: model),
                                    style: .checkbox,
                                    verbatim: true,
                                    isOn: Binding(
                                        get: { service.isShared(model.id) },
                                        set: { service.setShared(model.id, $0) }
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, theme.space.s8)
    }

    private func detail(for model: ShareableModel) -> String {
        let size = ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)
        if service.preparingIds.contains(model.id) {
            return L("\(size) · Preparing…")
        }
        return size
    }

    private var statusRow: some View {
        HStack(spacing: theme.space.s8) {
            if service.status == .starting {
                SettingsSpinner(size: .mini)
            }
            Text(statusText)
                .font(SettingsFont.rowDescription)
                .foregroundColor(statusIsError ? theme.status.warning.foreground : theme.text.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if service.configuration.useNearbyMacs {
                SettingsButton(.secondary, "Refresh", icon: "arrow.clockwise", size: .compact) {
                    service.refreshHosts()
                }
                .disabled(service.status != .running)
            }
        }
    }

    private var statusIsError: Bool {
        if case .failed = service.status { return true }
        return false
    }

    private var statusText: String {
        switch service.status {
        case .off:
            return L("Off")
        case .starting:
            return L("Starting…")
        case .failed(let message):
            return message
        case .running:
            var parts: [String] = []
            if service.configuration.shareOnLocalNetwork {
                let shared = service.publishedIds.count
                parts.append(shared == 1 ? L("Sharing 1 model") : L("Sharing \(shared) models"))
            }
            if service.configuration.useNearbyMacs {
                let macs = service.hosts.filter { !$0.models.isEmpty }.count
                parts.append(
                    macs == 0
                        ? L("No nearby Macs sharing models")
                        : macs == 1 ? L("1 nearby Mac sharing models") : L("\(macs) nearby Macs sharing models")
                )
            }
            return parts.joined(separator: " · ")
        }
    }
}
