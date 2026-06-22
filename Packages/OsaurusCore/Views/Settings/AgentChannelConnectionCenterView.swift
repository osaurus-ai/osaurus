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

    private let manager = AgentChannelConnectionManager.shared
    private let service = AgentChannelConnectionService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                overview
                DiscordSettingsView()
                channelEditorSection
            }
            .padding(24)
        }
        .background(theme.primaryBackground)
        .onAppear(perform: reloadConnections)
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
                "Configure communication channels agents can inspect or write to through one standard action surface.",
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
                    title: "Configured",
                    value: "\(connections.count + 1)",
                    caption: "including Discord",
                    icon: "link"
                )
                ChannelMetricCard(
                    title: "Enabled",
                    value: "\(connections.filter(\.enabled).count + 1)",
                    caption: "available to diagnose",
                    icon: "checkmark.seal.fill"
                )
                ChannelMetricCard(
                    title: "JSON Channels",
                    value: "\(connections.count)",
                    caption: "from agent-channels.json",
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

    private var channelEditorSection: some View {
        SettingsSubsection(label: "JSON Channel Connections") {
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

    private var connectionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: newCustomHTTPConnection) {
                    Label {
                        Text("New Custom", bundle: .module)
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
                    "No JSON-backed channels yet. Add a custom HTTP, Slack, or Telegram connection definition to prepare agent communication without storing secrets in the file.",
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
                ServerSettingsStatusBadge(status: draft.kind == .customHTTP ? .partial : .future)
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
                    help: "Stable id used by agent_channel tools. The native Discord id is reserved."
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
            Picker("", selection: $draft.kind) {
                Text("Custom HTTP", bundle: .module).tag(AgentChannelKind.customHTTP)
                Text("Slack", bundle: .module).tag(AgentChannelKind.slack)
                Text("Telegram", bundle: .module).tag(AgentChannelKind.telegram)
            }
            .pickerStyle(.segmented)
            Text(
                "Slack and Telegram definitions can be prepared now; native execution lands in their adapter PRs.",
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
            let selected = connections.first(where: { $0.id == selectedConnectionId })
        {
            draft = AgentChannelConnectionDraft(connection: selected)
        } else if let first = connections.first {
            select(first)
        } else {
            newCustomHTTPConnection()
        }
    }

    private func select(_ connection: AgentChannelConnection) {
        selectedConnectionId = connection.id
        draft = AgentChannelConnectionDraft(connection: connection)
        diagnosticsText = nil
    }

    private func newCustomHTTPConnection() {
        selectedConnectionId = nil
        draft = AgentChannelConnectionDraft()
        diagnosticsText = nil
    }

    private func saveDraft() {
        do {
            let connection = try draft.connection()
            try manager.upsertConnection(connection, replacingOriginalId: draft.originalId)
            selectedConnectionId = connection.id
            reloadConnections()
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
            showStatus("Agent channel connection deleted", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
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
                ServerSettingsStatusBadge(status: connection.enabled ? .engineReady : .future)
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
