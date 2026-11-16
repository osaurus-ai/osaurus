//
//  ArchitectModelGuidanceNotice.swift
//  osaurus
//
//  Above the Architect's composer when it would build on an on-device
//  model: building a workflow is a long run of tool calls, which small
//  local models often lose track of. Offers the Osaurus Cloud model, or
//  keeping the local one for good. Never blocks sending.
//

import SwiftUI

enum ArchitectModelGuidance {
    /// On-device sources come from the picker catalog: local bundles and
    /// Apple Foundation. Remote providers and harness runtimes never show it.
    static func applies(
        agentId: UUID?,
        source: ModelPickerItem.Source?,
        isHarness: Bool,
        isLocked: Bool,
        isStreaming: Bool
    ) -> Bool {
        guard agentId == Agent.architectId, !isHarness, !isLocked, !isStreaming else { return false }
        switch source {
        case .local?, .foundation?: return true
        default: return false
        }
    }

    static func shouldShow(applies: Bool, acknowledged: Bool) -> Bool {
        applies && !acknowledged
    }
}

struct ArchitectModelGuidanceNotice: View {
    @ObservedObject var session: ChatSession
    @Environment(\.theme) private var theme
    @State private var acknowledged = ArchitectConfigurationStore.load().localModelAcknowledged
    @State private var isConnecting = false
    @State private var connectFailed = false

    var body: some View {
        Group {
            if ArchitectModelGuidance.shouldShow(
                applies: session.architectModelGuidanceApplies, acknowledged: acknowledged)
            {
                notice
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentUpdated)) { note in
            guard note.object as? UUID == Agent.architectId else { return }
            acknowledged = ArchitectConfigurationStore.load().localModelAcknowledged
        }
    }

    private var notice: some View {
        ComposerNoticeRow(tone: theme.status.info) {
            Image(systemName: "sparkles")
                .glyphSize(.caption, weight: .semibold)
                .foregroundColor(theme.status.info.foreground)
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("The Architect works best with a frontier model.", bundle: .module)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: detail)
                    .textStyle(.caption)
                    .foregroundColor(connectFailed ? theme.status.warning.foreground : theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.space.s8) {
                    if connectFailed {
                        SettingsButton(.primary, "Choose a model", size: .compact) {
                            SettingsLanding.open(id: "settings.architect.model")
                        }
                    } else {
                        SettingsButton(
                            .primary,
                            String(format: L("Use %@"), session.architectCloudModelDisplayName),
                            isLoading: isConnecting,
                            size: .compact,
                            verbatim: true,
                            action: useCloud
                        )
                    }
                    SettingsButton(.tertiary, "Keep local model, I understand the trade-offs", size: .compact) {
                        ArchitectConfigurationStore.update { $0.localModelAcknowledged = true }
                        acknowledged = true
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detail: String {
        if connectFailed {
            return L("Osaurus Cloud didn't connect. Pick another model for the Architect in Settings.")
        }
        return String(
            format: L(
                "Building a workflow takes many tool calls in a row, and local models often lose the thread. %@ runs on Osaurus Cloud and uses your credits."
            ),
            session.architectCloudModelDisplayName
        )
    }

    private func useCloud() {
        guard !isConnecting else { return }
        isConnecting = true
        Task { @MainActor in
            let switched = await session.useOsaurusCloudForArchitect()
            isConnecting = false
            connectFailed = !switched
        }
    }
}
