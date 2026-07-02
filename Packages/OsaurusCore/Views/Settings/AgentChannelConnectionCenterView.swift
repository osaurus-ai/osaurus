//
//  AgentChannelConnectionCenterView.swift
//  osaurus
//
//  Management UI for provider-neutral agent communication channels.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct AgentChannelConnectionCenterView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var connections: [AgentChannelConnection] = []
    @State private var selectedConnectionId: String?
    @State private var draft = AgentChannelConnectionDraft()
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var diagnosticsText: String?
    @State private var isDiagnosing = false
    @State private var auditSnapshot: AgentChannelAuditWorkbenchSnapshot?
    @State private var auditMessage: String?
    @State private var auditIsError = false
    @State private var isLoadingAudit = false
    @State private var auditLoadID = UUID()
    @State private var globalWriteSnapshot = ChannelWriteKillSwitchSnapshot()
    @State private var globalWritesEnabled = true
    @State private var writeGateMessage: String?
    @State private var writeGateIsError = false

    private let manager = AgentChannelConnectionManager.shared
    private let service = AgentChannelConnectionService.shared
    private let auditWorkbench = AgentChannelAuditWorkbenchService()
    private let writeKillSwitch = ChannelWriteKillSwitch.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                overview
                globalWriteGateSection
                nativeIntegrationsSection
                auditWorkbenchSection
                channelEditorSection
            }
            .padding(24)
        }
        .background(theme.primaryBackground)
        .onAppear {
            reloadWriteGate()
            reloadConnections()
            reloadAuditWorkbench()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("Agent Channels", bundle: .module)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Text(
                "Configure native Discord, Slack, and Telegram integrations plus custom JSON channels agents can inspect or write to through one standard action surface.",
                bundle: .module
            )
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryText)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ChannelMetricCard(
                    title: "Native Providers",
                    value: "3",
                    caption: "Discord, Slack, Telegram",
                    icon: "link"
                )
                ChannelMetricCard(
                    title: "Global Writes",
                    value: globalWritesEnabled ? "On" : "Off",
                    caption: "remote write gate",
                    icon: globalWritesEnabled ? "checkmark.seal.fill" : "hand.raised.fill"
                )
                ChannelMetricCard(
                    title: "Custom JSON",
                    value: "\(connections.count)",
                    caption: "custom HTTP definitions",
                    icon: "curlybraces"
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Config", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                Text(manager.configurationFileURL().path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button(action: revealConfiguration) {
                    Label {
                        Text("Reveal", bundle: .module)
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                .buttonStyle(SettingsButtonStyle())
            }
        }
    }

    private var globalWriteGateSection: some View {
        SettingsSubsection(label: "Global Channel Safety", anchorId: "agentChannels.globalWrites") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: "Global Channel Writes",
                    description:
                        "Master remote/channel write gate used by channel safety checks. Provider write toggles below must also allow the destination.",
                    isOn: Binding(
                        get: { globalWritesEnabled },
                        set: { setGlobalWritesEnabled($0) }
                    )
                )

                HStack(spacing: 10) {
                    Label {
                        Text("Generation \(globalWriteSnapshot.generation)", bundle: .module)
                    } icon: {
                        Image(systemName: "number")
                    }
                    if globalWriteSnapshot.updatedAt.timeIntervalSince1970 > 0 {
                        Label {
                            Text(globalWriteSnapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

                if let writeGateMessage {
                    AgentChannelInlineStatusMessage(message: writeGateMessage, isError: writeGateIsError)
                }
            }
        }
    }

    private var nativeIntegrationsSection: some View {
        SettingsSubsection(label: "Native Integrations", anchorId: "agentChannels.native") {
            VStack(alignment: .leading, spacing: 20) {
                DiscordSettingsView()
                SettingsDivider()
                SlackSettingsView()
                SettingsDivider()
                TelegramSettingsView()
            }
        }
    }

    private var channelEditorSection: some View {
        SettingsSubsection(label: "Custom JSON Connections") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    connectionList
                        .frame(width: 300)
                    editor
                }

                if let statusMessage {
                    StatusMessageView(message: statusMessage, isError: statusIsError)
                }
            }
        }
    }

    private var auditWorkbenchSection: some View {
        SettingsSubsection(label: "Inbox & Audit") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ChannelMetricCard(
                        title: "Messages",
                        value: "\(auditSnapshot?.summary.messageCount ?? 0)",
                        caption: selectedAuditScopeLabel,
                        icon: "tray.full"
                    )
                    ChannelMetricCard(
                        title: "Accepted",
                        value: "\(auditSnapshot?.summary.acceptedCount ?? 0)",
                        caption: "authorized receives",
                        icon: "checkmark.shield.fill"
                    )
                    ChannelMetricCard(
                        title: "Denied",
                        value: "\(auditSnapshot?.summary.deniedCount ?? 0)",
                        caption: "blocked before dispatch",
                        icon: "hand.raised.fill"
                    )
                    ChannelMetricCard(
                        title: "Duplicates",
                        value: "\(auditSnapshot?.summary.duplicateCount ?? 0)",
                        caption: "acknowledged once",
                        icon: "arrow.triangle.2.circlepath"
                    )
                }

                HStack(spacing: 10) {
                    Button(action: reloadAuditWorkbench) {
                        Label {
                            Text(isLoadingAudit ? "Loading..." : "Refresh Audit", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(isLoadingAudit)

                    Button(action: copyAuditExport) {
                        Label {
                            Text("Copy Redacted Export", bundle: .module)
                        } icon: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(isLoadingAudit)

                    Text(selectedAuditScopeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }

                if let auditMessage {
                    StatusMessageView(message: auditMessage, isError: auditIsError)
                }

                HStack(alignment: .top, spacing: 14) {
                    recentAuditEvents
                    recentInboxMessages
                }
            }
        }
    }

    private var recentAuditEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Decisions", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            if auditSnapshot?.auditEvents.isEmpty ?? true {
                Text(
                    "No receive audit events have been recorded for this scope.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
            } else {
                VStack(spacing: 8) {
                    ForEach(auditSnapshot?.auditEvents ?? []) { event in
                        AgentChannelAuditDecisionRow(event: event)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var recentInboxMessages: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Inbox", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            if auditSnapshot?.messages.isEmpty ?? true {
                Text(
                    "No stored message snapshots have been recorded for this scope.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
            } else {
                VStack(spacing: 8) {
                    ForEach(auditSnapshot?.messages ?? []) { message in
                        AgentChannelInboxMessageRow(message: message)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var connectionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: newCustomHTTPConnection) {
                    Label {
                        Text("New Custom HTTP", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(SettingsButtonStyle(isPrimary: true))

                Button(action: reloadConnections) {
                    Label {
                        Text("Reload", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(SettingsButtonStyle())
            }

            if connections.isEmpty {
                Text(
                    "No custom JSON channels yet. Add a custom HTTP connection definition when a provider does not have a native section above.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
            } else {
                VStack(spacing: 8) {
                    ForEach(connections) { connection in
                        Button {
                            select(connection)
                        } label: {
                            ChannelConnectionRow(
                                connection: connection,
                                isSelected: connection.id == selectedConnectionId
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(draft.isNew ? "New Connection" : "Edit Connection", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                ServerSettingsStatusBadge(status: draft.kind == .customHTTP ? .engineReady : .partial)
                Spacer()
            }

            SettingsToggle(
                title: "Enabled",
                description: "Allow this channel definition to be resolved by agent channel diagnostics and tools.",
                isOn: $draft.enabled
            )

            HStack(alignment: .top, spacing: 12) {
                StyledSettingsTextField(
                    label: "Connection ID",
                    text: $draft.id,
                    placeholder: "ops-webhook",
                    help: "Stable id used by agent_channel tools. Native provider ids are reserved."
                )
                StyledSettingsTextField(
                    label: "Display Name",
                    text: $draft.name,
                    placeholder: "Ops Webhook",
                    help: "Human-readable name shown in the channel list."
                )
            }

            kindPicker
            actionPicker

            HStack(alignment: .top, spacing: 12) {
                multilineField(
                    title: "Space Allowlist",
                    text: $draft.spaceAllowlistText,
                    help: "Workspace, server, or team ids this connection may inspect."
                )
                multilineField(
                    title: "Read Room Allowlist",
                    text: $draft.readRoomAllowlistText,
                    help: "Channel or room ids agents may read or search."
                )
                multilineField(
                    title: "Write Room Allowlist",
                    text: $draft.writeRoomAllowlistText,
                    help: "Channel or room ids agents may write to when writes are enabled."
                )
            }

            SettingsToggle(
                title: "Enable Writes",
                description:
                    "Permit send and reply actions only for write-allowlisted rooms. Tool calls still require confirmation.",
                isOn: $draft.writeEnabled
            )

            HStack(alignment: .top, spacing: 12) {
                StyledSettingsTextField(
                    label: "Default Read Limit",
                    text: $draft.defaultReadLimit,
                    placeholder: "50",
                    help: "Default recent-message count. Clamped to 1-100."
                )
                multilineField(
                    title: "Secret References",
                    text: $draft.secretReferencesText,
                    help: "One per line: name=keychain-id. Raw tokens are not stored in this JSON file."
                )
            }

            if draft.kind == .customHTTP {
                customHTTPSection
            }

            actionBar

            if let diagnosticsText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Diagnostics", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    ScrollView {
                        Text(diagnosticsText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 110, maxHeight: 180)
                    .background(cardBackground)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kind", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            HStack(spacing: 8) {
                Image(systemName: draft.kind.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(draft.kind.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            Text(
                "Use the native Discord, Slack, and Telegram sections above for first-party providers. New custom connections use the reviewed HTTP runner.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        }
    }

    private var actionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Standard Actions", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 150), spacing: 8)
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(AgentChannelAction.allCases, id: \.self) { action in
                    Toggle(
                        action.displayName,
                        isOn: Binding(
                            get: { draft.supportedActions.contains(action) },
                            set: { enabled in
                                if enabled {
                                    draft.supportedActions.insert(action)
                                } else {
                                    draft.supportedActions.remove(action)
                                }
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }
            }
            .padding(10)
            .background(cardBackground)
        }
    }

    private var customHTTPSection: some View {
        SettingsSubsection(label: "Custom HTTP") {
            VStack(alignment: .leading, spacing: 12) {
                StyledSettingsTextField(
                    label: "Base URL",
                    text: $draft.customBaseURL,
                    placeholder: "https://hooks.example.test",
                    help:
                        "HTTP or HTTPS origin for this configured channel. Execution remains disabled until the security-reviewed runner lands."
                )
                multilineField(
                    title: "Action Map JSON",
                    text: $draft.customActionsJSON,
                    help:
                        "JSON object keyed by standard action names. Values define method, path, optional query, headers, and bodyTemplate."
                )
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(action: saveDraft) {
                Label {
                    Text("Save Connection", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark")
                }
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: true))

            Button(action: diagnoseSelected) {
                Label {
                    Text(isDiagnosing ? "Diagnosing..." : "Run Diagnostics", bundle: .module)
                } icon: {
                    Image(systemName: "stethoscope")
                }
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(isDiagnosing || draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(action: deleteSelected) {
                Label {
                    Text("Delete", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(SettingsButtonStyle(isDestructive: true))
            .disabled(draft.isNew)

            Spacer()
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.cardBorder, lineWidth: 1)
            )
    }

    private func multilineField(
        title: String,
        text: Binding<String>,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 76)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            Text(LocalizedStringKey(help), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reloadConnections() {
        connections = manager.editableConnections()
        if let selectedConnectionId,
            let selected = connections.first(where: { $0.id == selectedConnectionId }) {
            draft = AgentChannelConnectionDraft(connection: selected)
        } else if let first = connections.first {
            select(first)
        } else {
            newCustomHTTPConnection()
        }
    }

    private func reloadWriteGate() {
        let snapshot = writeKillSwitch.snapshot()
        globalWriteSnapshot = snapshot
        globalWritesEnabled = snapshot.writeEnabled
    }

    private func setGlobalWritesEnabled(_ enabled: Bool) {
        let previousEnabled = globalWritesEnabled
        globalWritesEnabled = enabled
        do {
            globalWriteSnapshot = try writeKillSwitch.setWriteEnabled(enabled)
            writeGateMessage = enabled
                ? "Global channel writes enabled"
                : "Global channel writes disabled"
            writeGateIsError = false
        } catch {
            globalWritesEnabled = previousEnabled
            reloadWriteGate()
            writeGateMessage = error.localizedDescription
            writeGateIsError = true
        }
    }

    private var selectedAuditConnectionId: String? {
        draft.originalId ?? selectedConnectionId
    }

    private var selectedAuditScopeLabel: String {
        guard let selectedAuditConnectionId else {
            return "all channel connections"
        }
        return selectedAuditConnectionId
    }

    private func select(_ connection: AgentChannelConnection) {
        selectedConnectionId = connection.id
        draft = AgentChannelConnectionDraft(connection: connection)
        diagnosticsText = nil
        reloadAuditWorkbench()
    }

    private func newCustomHTTPConnection() {
        selectedConnectionId = nil
        draft = AgentChannelConnectionDraft()
        diagnosticsText = nil
        reloadAuditWorkbench()
    }

    private func saveDraft() {
        do {
            let connection = try draft.connection()
            try manager.upsertConnection(connection, replacingOriginalId: draft.originalId)
            selectedConnectionId = connection.id
            reloadConnections()
            reloadAuditWorkbench()
            showStatus("Agent channel connection saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func deleteSelected() {
        do {
            try manager.deleteConnection(id: draft.id)
            selectedConnectionId = nil
            reloadConnections()
            reloadAuditWorkbench()
            showStatus("Agent channel connection deleted", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func reloadAuditWorkbench() {
        let loadID = UUID()
        auditLoadID = loadID
        isLoadingAudit = true
        let connectionId = selectedAuditConnectionId
        Task {
            do {
                let snapshot = try auditWorkbench.snapshot(
                    connectionId: connectionId,
                    messageLimit: 8,
                    auditLimit: 10
                )
                await MainActor.run {
                    guard auditLoadID == loadID,
                        selectedAuditConnectionId == connectionId
                    else {
                        return
                    }
                    auditSnapshot = snapshot
                    auditMessage = nil
                    auditIsError = false
                    isLoadingAudit = false
                }
            } catch {
                await MainActor.run {
                    guard auditLoadID == loadID,
                        selectedAuditConnectionId == connectionId
                    else {
                        return
                    }
                    auditMessage = error.localizedDescription
                    auditIsError = true
                    isLoadingAudit = false
                }
            }
        }
    }

    private func copyAuditExport() {
        let connectionId = selectedAuditConnectionId
        Task {
            do {
                let export = try auditWorkbench.exportRedactedJSON(
                    connectionId: connectionId,
                    messageLimit: 25,
                    auditLimit: 100
                )
                await MainActor.run {
                    #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(export, forType: .string)
                    #endif
                    auditMessage = "Redacted channel audit export copied"
                    auditIsError = false
                }
            } catch {
                await MainActor.run {
                    auditMessage = error.localizedDescription
                    auditIsError = true
                }
            }
        }
    }

    private func diagnoseSelected() {
        let connectionId = draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connectionId.isEmpty else { return }
        guard let originalId = draft.originalId,
            AgentChannelConnection.normalizedId(connectionId) == originalId
        else {
            showStatus("Save the channel connection before running diagnostics", isError: true)
            return
        }
        isDiagnosing = true
        Task {
            let diagnostics = await service.diagnostics(connectionId: connectionId)
            let rendered = Self.prettyJSON(diagnostics)
            await MainActor.run {
                diagnosticsText = rendered
                isDiagnosing = false
                if diagnostics["failure"] is String {
                    showStatus("Agent channel diagnostics reported a failure", isError: true)
                } else {
                    showStatus("Agent channel diagnostics complete", isError: false)
                }
            }
        }
    }

    private func revealConfiguration() {
        #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([manager.configurationFileURL()])
        #endif
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private static func prettyJSON(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: payload)
        }
        return string
    }
}

private struct ChannelMetricCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let value: String
    let caption: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(themeManager.currentTheme.accentColor)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(LocalizedStringKey(caption), bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct AgentChannelAuditDecisionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let event: AgentChannelAuditRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
                    .frame(width: 18)
                Text(event.status.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(event.action)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
                Spacer()
                Text(event.connectionId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            if !event.redactedSummary.isEmpty {
                Text(event.redactedSummary)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let roomId = event.roomId {
                    Label(roomId, systemImage: "number")
                }
                if let reason = event.reason {
                    Label(reason, systemImage: "info.circle")
                }
                Label(event.shouldDispatch ? "dispatch" : "no dispatch", systemImage: "arrow.turn.down.right")
            }
            .font(.system(size: 10))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var statusIcon: String {
        switch event.status {
        case .accepted: "checkmark.shield.fill"
        case .duplicate: "arrow.triangle.2.circlepath"
        case .denied: "hand.raised.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch event.status {
        case .accepted:
            themeManager.currentTheme.successColor
        case .duplicate:
            themeManager.currentTheme.accentColor
        case .denied, .failed:
            themeManager.currentTheme.warningColor
        }
    }
}

private struct AgentChannelInboxMessageRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let message: AgentChannelInboxMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: message.direction == .inbound ? "tray.and.arrow.down" : "paperplane")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)
                    .frame(width: 18)
                Text(message.direction.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(message.roomId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
                Spacer()
                Text(message.connectionId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            Text(message.preview.isEmpty ? "Empty message" : message.preview)
                .font(.system(size: 12))
                .foregroundColor(themeManager.currentTheme.secondaryText)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let authorDisplay = message.authorDisplay, !authorDisplay.isEmpty {
                    Label(authorDisplay, systemImage: "person")
                }
                Label(message.providerMessageId, systemImage: "number")
            }
            .font(.system(size: 10))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct ChannelConnectionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let connection: AgentChannelConnection
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: connection.kind.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                        .lineLimit(1)
                    Text(connection.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                ServerSettingsStatusBadge(status: connection.enabled ? .engineReady : .partial)
            }

            HStack(spacing: 6) {
                Text(connection.kind.displayName)
                Text("\(connection.supportedActions.count) actions")
                if connection.writeEnabled {
                    Text("writes on")
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(themeManager.currentTheme.secondaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isSelected
                        ? themeManager.currentTheme.accentColor.opacity(0.12)
                        : themeManager.currentTheme.cardBackground
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected
                                ? themeManager.currentTheme.accentColor.opacity(0.45)
                                : themeManager.currentTheme.cardBorder,
                            lineWidth: 1
                        )
                )
        )
    }
}

private struct StatusMessageView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let message: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundColor(isError ? themeManager.currentTheme.warningColor : themeManager.currentTheme.successColor)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    (isError ? themeManager.currentTheme.warningColor : themeManager.currentTheme.successColor).opacity(
                        0.08
                    )
                )
        )
    }
}

private struct AgentChannelConnectionDraft {
    var originalId: String?
    var id = "ops-webhook"
    var name = "Ops Webhook"
    var kind: AgentChannelKind = .customHTTP
    var enabled = true
    var supportedActions: Set<AgentChannelAction> = [.diagnostics, .sendMessage]
    var spaceAllowlistText = ""
    var readRoomAllowlistText = ""
    var writeRoomAllowlistText = "alerts"
    var writeEnabled = false
    var defaultReadLimit = "50"
    var secretReferencesText = "bearer=ops_webhook_token"
    var customBaseURL = "https://hooks.example.test"
    var customActionsJSON = Self.defaultActionsJSON

    var isNew: Bool { originalId == nil }

    init() {}

    init(connection: AgentChannelConnection) {
        originalId = connection.id
        id = connection.id
        name = connection.name
        kind = connection.kind
        enabled = connection.enabled
        supportedActions = Set(connection.supportedActions)
        spaceAllowlistText = connection.spaceAllowlist.joined(separator: "\n")
        readRoomAllowlistText = connection.readRoomAllowlist.joined(separator: "\n")
        writeRoomAllowlistText = connection.writeRoomAllowlist.joined(separator: "\n")
        writeEnabled = connection.writeEnabled
        defaultReadLimit = "\(connection.defaultReadLimit)"
        secretReferencesText = connection.secrets
            .map { "\($0.name)=\($0.keychainId)" }
            .joined(separator: "\n")
        customBaseURL = connection.customHTTP?.baseURL ?? ""
        customActionsJSON = Self.prettyActionsJSON(connection.customHTTP?.actions ?? [:])
    }

    func connection() throws -> AgentChannelConnection {
        let customHTTP: AgentChannelCustomHTTPConfiguration?
        if kind == .customHTTP {
            customHTTP = AgentChannelCustomHTTPConfiguration(
                baseURL: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                actions: try Self.parseCustomActionsJSON(customActionsJSON)
            )
        } else {
            customHTTP = nil
        }

        return AgentChannelConnection(
            id: id,
            name: name,
            kind: kind,
            enabled: enabled,
            supportedActions: Array(supportedActions).sorted { $0.rawValue < $1.rawValue },
            spaceAllowlist: Self.parseList(spaceAllowlistText),
            readRoomAllowlist: Self.parseList(readRoomAllowlistText),
            writeRoomAllowlist: Self.parseList(writeRoomAllowlistText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50,
            secrets: Self.parseSecretReferences(secretReferencesText),
            customHTTP: customHTTP
        )
    }

    private static let defaultActionsJSON = """
        {
          "send_message" : {
            "bodyTemplate" : "{\\"text\\":\\"${content}\\"}",
            "headers" : {
              "Authorization" : "Bearer ${secret:bearer}",
              "Content-Type" : "application/json"
            },
            "method" : "POST",
            "path" : "/rooms/{room_id}/messages",
            "query" : {

            }
          }
        }
        """

    private static func parseList(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseSecretReferences(_ text: String) -> [AgentChannelSecretReference] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                return AgentChannelSecretReference(name: trimmed, keychainId: "")
            }
            return AgentChannelSecretReference(
                name: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                keychainId: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func parseCustomActionsJSON(
        _ text: String
    ) throws -> [String: AgentChannelCustomHTTPAction] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        return try JSONDecoder().decode(
            [String: AgentChannelCustomHTTPAction].self,
            from: Data(trimmed.utf8)
        )
    }

    private static func prettyActionsJSON(
        _ actions: [String: AgentChannelCustomHTTPAction]
    ) -> String {
        guard !actions.isEmpty,
            let data = try? JSONEncoder.prettyAgentChannelEncoder.encode(actions),
            let string = String(data: data, encoding: .utf8)
        else {
            return defaultActionsJSON
        }
        return string
    }
}

private extension JSONEncoder {
    static var prettyAgentChannelEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension AgentChannelKind {
    var displayName: String {
        switch self {
        case .discord: "Discord"
        case .slack: "Slack"
        case .telegram: "Telegram"
        case .customHTTP: "Custom HTTP"
        }
    }

    var icon: String {
        switch self {
        case .discord: "bubble.left.and.bubble.right.fill"
        case .slack: "number"
        case .telegram: "paperplane.fill"
        case .customHTTP: "curlybraces"
        }
    }
}

private extension AgentChannelAction {
    var displayName: String {
        switch self {
        case .diagnostics: "Diagnostics"
        case .listSpaces: "List spaces"
        case .listRooms: "List rooms"
        case .readMessages: "Read messages"
        case .searchMessages: "Search messages"
        case .draftMessage: "Draft message"
        case .sendMessage: "Send message"
        case .replyThread: "Reply thread"
        }
    }
}
