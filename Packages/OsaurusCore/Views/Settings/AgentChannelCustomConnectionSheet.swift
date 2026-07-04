//
//  AgentChannelCustomConnectionSheet.swift
//  osaurus
//
//  Configuration sheet for creating and editing custom JSON channel
//  connections.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct AgentChannelCustomConnectionSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Existing connection to edit, or nil to create a new one.
    let connection: AgentChannelConnection?
    /// Called after any successful save or delete so the channel list refreshes.
    let onDidChange: () -> Void

    @State private var draft = AgentChannelConnectionDraft()
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var diagnosticsText: String?
    @State private var isDiagnosing = false
    @State private var showDeleteConfirmation = false

    private let manager = AgentChannelConnectionManager.shared
    private let service = AgentChannelConnectionService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        AgentChannelSheetScaffold(
            icon: draft.kind.icon,
            gradient: draft.kind.brandGradient,
            title: draft.isNew ? L("New Custom Channel") : (draft.name.isEmpty ? draft.id : draft.name),
            subtitle: L("JSON-defined HTTP channel")
        ) {
            VStack(alignment: .leading, spacing: 20) {
                identitySection
                SettingsDivider()
                accessSection
                SettingsDivider()
                sendingSection
                SettingsDivider()
                actionsSection

                if draft.kind == .customHTTP {
                    SettingsDivider()
                    customHTTPSection
                }

                SettingsDivider()
                advancedSection
            }
        } footer: {
            if let statusMessage {
                AgentChannelInlineStatusMessage(
                    message: statusMessage,
                    isError: statusIsError,
                    onAutoClear: { self.statusMessage = nil }
                )
            }

            if let diagnosticsText {
                ScrollView {
                    Text(diagnosticsText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )
            }

            HStack(spacing: 10) {
                AgentChannelSheetActionButton(
                    title: L("Run Diagnostics"),
                    busyTitle: L("Diagnosing..."),
                    isBusy: isDiagnosing,
                    action: diagnose
                )
                .disabled(isDiagnosing || trimmedDraftId.isEmpty)

                if !draft.isNew {
                    AgentChannelSheetActionButton(
                        title: L("Delete"),
                        busyTitle: L("Delete"),
                        isBusy: false,
                        isDestructive: true,
                        action: { showDeleteConfirmation = true }
                    )
                }

                Spacer()

                AgentChannelSheetActionButton(
                    title: L("Save"),
                    busyTitle: L("Saving..."),
                    isBusy: false,
                    isPrimary: true,
                    action: saveDraft
                )
                .disabled(trimmedDraftId.isEmpty)
            }
        }
        .onAppear {
            if let connection {
                draft = AgentChannelConnectionDraft(connection: connection)
            }
        }
        .themedAlert(
            L("Delete Connection?"),
            isPresented: $showDeleteConfirmation,
            message: L(
                "This removes the \"\(draft.id)\" channel definition from the configuration file. Keychain secrets it references are not deleted."
            ),
            primaryButton: .destructive(L("Delete")) { performDelete() },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
    }

    private var trimmedDraftId: String {
        draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                StyledSettingsTextField(
                    label: L("Connection ID"),
                    text: $draft.id,
                    placeholder: "ops-webhook",
                    help: L("Stable id used by agent_channel tools. Native provider ids are reserved.")
                )
                StyledSettingsTextField(
                    label: L("Display Name"),
                    text: $draft.name,
                    placeholder: "Ops Webhook",
                    help: L("Human-readable name shown in the channel list.")
                )
            }

            SettingsToggle(
                title: L("Enabled"),
                description: L("Allow this channel definition to be resolved by agent channel diagnostics and tools."),
                isOn: $draft.enabled
            )
        }
    }

    private var accessSection: some View {
        SettingsSubsection(label: L("Access")) {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelMultilineSettingsField(
                    title: L("Space Allowlist"),
                    text: $draft.spaceAllowlistText,
                    placeholder: L("team-alpha — one per line"),
                    help: L("Workspace, server, or team ids this connection may inspect.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Read Room Allowlist"),
                    text: $draft.readRoomAllowlistText,
                    placeholder: L("room-id — one per line"),
                    help: L("Channel or room ids agents may read or search.")
                )
            }
        }
    }

    private var sendingSection: some View {
        SettingsSubsection(label: L("Sending")) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Allow Sending"),
                    description: L(
                        "Permit send and reply actions only for write-allowlisted rooms. Tool calls still require confirmation."
                    ),
                    isOn: $draft.writeEnabled.animation(.easeOut(duration: 0.2))
                )

                if draft.writeEnabled {
                    AgentChannelMultilineSettingsField(
                        title: L("Write Room Allowlist"),
                        text: $draft.writeRoomAllowlistText,
                        placeholder: L("room-id — one per line"),
                        help: L("Channel or room ids agents may write to when writes are enabled.")
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var actionsSection: some View {
        SettingsSubsection(label: L("Standard Actions")) {
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
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
        }
    }

    private var customHTTPSection: some View {
        SettingsSubsection(label: L("Custom HTTP")) {
            VStack(alignment: .leading, spacing: 12) {
                StyledSettingsTextField(
                    label: L("Base URL"),
                    text: $draft.customBaseURL,
                    placeholder: "https://hooks.example.test",
                    help: L(
                        "HTTP or HTTPS origin for this configured channel. Execution remains disabled until the security-reviewed runner lands."
                    )
                )
                AgentChannelMultilineSettingsField(
                    title: L("Action Map JSON"),
                    text: $draft.customActionsJSON,
                    help: L(
                        "JSON object keyed by standard action names. Values define method, path, optional query, headers, and bodyTemplate."
                    )
                )
            }
        }
    }

    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    StyledSettingsTextField(
                        label: L("Default Read Limit"),
                        text: $draft.defaultReadLimit,
                        placeholder: "50",
                        help: L("Default recent-message count. Clamped to 1-100.")
                    )
                    AgentChannelMultilineSettingsField(
                        title: L("Secret References"),
                        text: $draft.secretReferencesText,
                        placeholder: L("bearer=my-keychain-id — one per line"),
                        help: L("One per line: name=keychain-id. Raw tokens are not stored in this JSON file.")
                    )
                }

                Button(action: revealConfigurationFile) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text("Open configuration file", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("Show agent-channels.json in Finder"))
            }
        }
    }

    // MARK: - Actions

    private func saveDraft() {
        do {
            let saved = try draft.connection()
            try manager.upsertConnection(saved, replacingOriginalId: draft.originalId)
            _ = ToastManager.shared.success(L("Channel connection saved"))
            onDidChange()
            dismiss()
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func performDelete() {
        do {
            try manager.deleteConnection(id: draft.id)
            _ = ToastManager.shared.success(L("Channel connection deleted"))
            onDidChange()
            dismiss()
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func diagnose() {
        let connectionId = trimmedDraftId
        guard !connectionId.isEmpty else { return }
        guard let originalId = draft.originalId,
            AgentChannelConnection.normalizedId(connectionId) == originalId
        else {
            showStatus(L("Save the channel connection before running diagnostics"), isError: true)
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
                    showStatus(L("Channel diagnostics reported a failure"), isError: true)
                } else {
                    showStatus(L("Channel diagnostics complete"), isError: false)
                }
            }
        }
    }

    private func revealConfigurationFile() {
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

// MARK: - Draft

struct AgentChannelConnectionDraft {
    var originalId: String?
    var id = ""
    var name = ""
    var kind: AgentChannelKind = .customHTTP
    var enabled = true
    var supportedActions: Set<AgentChannelAction> = [.diagnostics, .sendMessage]
    var spaceAllowlistText = ""
    var readRoomAllowlistText = ""
    var writeRoomAllowlistText = ""
    var writeEnabled = false
    var defaultReadLimit = "50"
    var secretReferencesText = ""
    var customBaseURL = ""
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

    /// Format template shown in new drafts so the action-map schema is
    /// discoverable; harmless without a connection id, which Save requires.
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

extension JSONEncoder {
    fileprivate static var prettyAgentChannelEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension AgentChannelAction {
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
