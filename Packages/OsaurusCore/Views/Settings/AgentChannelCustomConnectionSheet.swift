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
                VStack(alignment: .leading, spacing: 10) {
                    AgentChannelSetupStepHeader(
                        number: 1,
                        title: L("Name this channel"),
                        done: !trimmedDraftId.isEmpty
                    )
                    identitySection
                }

                if draft.kind == .customHTTP {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        AgentChannelSetupStepHeader(
                            number: 2,
                            title: L("Define the HTTP endpoint"),
                            done: endpointStepDone
                        )
                        customHTTPSection
                    }
                }

                SettingsDivider()
                VStack(alignment: .leading, spacing: 10) {
                    AgentChannelSetupStepHeader(
                        number: 3,
                        title: L("Choose what agents may do"),
                        done: !draft.supportedActions.isEmpty
                    )
                    actionsSection
                    accessSection
                }

                SettingsDivider()
                VStack(alignment: .leading, spacing: 10) {
                    AgentChannelSetupStepHeader(
                        number: 4,
                        title: L("Allow sending (optional)"),
                        done: draft.writeEnabled
                    )
                    sendingSection
                }

                SettingsDivider()
                VStack(alignment: .leading, spacing: 10) {
                    AgentChannelSetupStepHeader(
                        number: 5,
                        title: L("Authorize incoming messages (optional)"),
                        done: !AgentChannelConnectionDraft.parseListPreview(
                            draft.inboundSenderAllowlistText
                        ).isEmpty
                    )
                    inboundAuthorizationSection
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
                    title: canRunLiveDiagnostics ? L("Run Diagnostics") : L("Check Configuration"),
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

    /// Live diagnostics need the saved connection under its current id;
    /// otherwise the button performs a local draft check instead.
    private var canRunLiveDiagnostics: Bool {
        guard let originalId = draft.originalId else { return false }
        return AgentChannelConnection.normalizedId(trimmedDraftId) == originalId
    }

    private var endpointStepDone: Bool {
        let url = draft.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return false }
        return (try? AgentChannelConnectionDraft.parsedActionsPreview(draft.customActionsJSON))
            .map { !$0.isEmpty } ?? false
    }

    // MARK: - Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                StyledSettingsTextField(
                    label: L("Connection ID (required)"),
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
                    label: L("Base URL (required)"),
                    text: $draft.customBaseURL,
                    placeholder: "https://hooks.example.test",
                    help: L(
                        "HTTPS origin agent tools call for this channel. Requests only run for actions defined below and are always confirmed before sending."
                    )
                )
                AgentChannelMultilineSettingsField(
                    title: L("Action Map JSON (at least one action required)"),
                    text: $draft.customActionsJSON,
                    help: L(
                        "JSON object keyed by standard action names. Values define method, path, optional query, headers, and bodyTemplate."
                    )
                )
            }
        }
    }

    private var inboundAuthorizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Custom channels are outbound-only until you authorize incoming senders. Anything posted to the inbound inbox API from senders not listed here is denied.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                AgentChannelMultilineSettingsField(
                    title: L("Allowed Senders"),
                    text: $draft.inboundSenderAllowlistText,
                    placeholder: L("sender-id — one per line"),
                    help: L("Sender ids whose incoming messages are stored. Empty denies everyone.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Allowed Rooms"),
                    text: $draft.inboundRoomAllowlistText,
                    placeholder: L("room-id — one per line"),
                    help: L("Room ids incoming messages may come from. Empty allows any allowlisted sender's room.")
                )
            }

            SettingsToggle(
                title: L("Accept Bot Messages"),
                description: L("Store incoming messages flagged as sent by bots."),
                isOn: $draft.inboundAllowBotMessages
            )
            SettingsToggle(
                title: L("Accept Self Messages"),
                description: L("Store messages this connection itself sent (echo events)."),
                isOn: $draft.inboundAllowSelfMessages
            )
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

    /// For saved connections this runs the real service diagnostics; for
    /// unsaved or renamed drafts it falls back to local draft validation so
    /// the check works before saving.
    private func diagnose() {
        let connectionId = trimmedDraftId
        guard !connectionId.isEmpty else { return }
        guard let originalId = draft.originalId,
            AgentChannelConnection.normalizedId(connectionId) == originalId
        else {
            let issues = draft.validationIssues()
            if issues.isEmpty {
                diagnosticsText = L(
                    "Draft configuration looks valid. Save to run live diagnostics against the endpoint.")
                showStatus(L("Draft check passed"), isError: false)
            } else {
                diagnosticsText = issues.map { "• \($0)" }.joined(separator: "\n")
                showStatus(L("Draft check found \(issues.count) issue(s)"), isError: true)
            }
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
    var inboundSenderAllowlistText = ""
    var inboundRoomAllowlistText = ""
    var inboundAllowBotMessages = false
    var inboundAllowSelfMessages = false
    /// Policy fields the sheet does not expose (duplicate behavior, event-id
    /// requirement) are preserved from the loaded connection on save.
    private var baseInboundAuthorization = AgentChannelInboundAuthorizationPolicy()

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
        baseInboundAuthorization = connection.inboundAuthorization
        inboundSenderAllowlistText = connection.inboundAuthorization.senderAllowlist
            .joined(separator: "\n")
        inboundRoomAllowlistText = connection.inboundAuthorization.roomAllowlist
            .joined(separator: "\n")
        inboundAllowBotMessages = connection.inboundAuthorization.allowBotMessages
        inboundAllowSelfMessages = connection.inboundAuthorization.allowSelfMessages
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
            customHTTP: customHTTP,
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: Self.parseList(inboundSenderAllowlistText),
                roomAllowlist: Self.parseList(inboundRoomAllowlistText),
                allowUnscopedSpaces: baseInboundAuthorization.allowUnscopedSpaces,
                allowBotMessages: inboundAllowBotMessages,
                allowSelfMessages: inboundAllowSelfMessages,
                requireProviderEventId: baseInboundAuthorization.requireProviderEventId,
                duplicateBehavior: baseInboundAuthorization.duplicateBehavior,
                auditDecisionReason: baseInboundAuthorization.auditDecisionReason
            )
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

    /// Non-throwing list parse for view-layer step-completion checks.
    static func parseListPreview(_ text: String) -> [String] {
        parseList(text)
    }

    /// Parse the action-map JSON for view-layer validation without building
    /// the full connection.
    static func parsedActionsPreview(
        _ text: String
    ) throws -> [String: AgentChannelCustomHTTPAction] {
        try parseCustomActionsJSON(text)
    }

    /// Configuration problems checkable before the connection is saved, for
    /// the pre-save "Check Configuration" affordance. Returns human-readable
    /// issues; empty means the draft looks structurally valid.
    func validationIssues() -> [String] {
        var issues: [String] = []
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(L("Connection ID is required."))
        }
        if kind == .customHTTP {
            let base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty {
                issues.append(L("Base URL is required."))
            } else if let url = URL(string: base) {
                let scheme = url.scheme?.lowercased()
                if scheme != "https" && scheme != "http" {
                    issues.append(L("Base URL must start with https:// or http://."))
                }
                if url.host == nil {
                    issues.append(L("Base URL is missing a host."))
                }
            } else {
                issues.append(L("Base URL is not a valid URL."))
            }
            do {
                let actions = try Self.parseCustomActionsJSON(customActionsJSON)
                if actions.isEmpty {
                    issues.append(L("Define at least one action in the action map."))
                } else {
                    let known = Set(AgentChannelAction.allCases.map(\.rawValue))
                    for key in actions.keys.sorted() where !known.contains(key) {
                        issues.append(
                            L("Action \"\(key)\" is not a standard action name and will never be called."))
                    }
                }
            } catch {
                issues.append(L("Action map JSON is invalid: \(error.localizedDescription)"))
            }
        }
        if supportedActions.isEmpty {
            issues.append(L("Enable at least one standard action."))
        }
        if writeEnabled && Self.parseList(writeRoomAllowlistText).isEmpty {
            issues.append(L("Sending is enabled but the write room allowlist is empty, so sends will be refused."))
        }
        for secret in Self.parseSecretReferences(secretReferencesText)
        where secret.keychainId.isEmpty {
            issues.append(L("Secret \"\(secret.name)\" has no keychain id (expected name=keychain-id)."))
        }
        return issues
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
        case .diagnostics: L("Diagnostics")
        case .listSpaces: L("List spaces")
        case .listRooms: L("List rooms")
        case .readMessages: L("Read messages")
        case .readThread: L("Read thread")
        case .searchMessages: L("Search messages")
        case .draftMessage: L("Draft message")
        case .sendMessage: L("Send message")
        case .replyThread: L("Reply thread")
        case .editMessage: L("Edit message")
        case .deleteMessage: L("Delete message")
        case .addReaction: L("Add reaction")
        case .removeReaction: L("Remove reaction")
        case .sendTyping: L("Typing indicator")
        }
    }
}
