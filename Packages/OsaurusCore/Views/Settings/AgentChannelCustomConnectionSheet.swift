//
//  AgentChannelCustomConnectionSheet.swift
//  osaurus
//
//  Configuration sheet for creating and editing custom JSON channel
//  connections, organized into focused sections: Basics, Capabilities &
//  Access, Send & Receive, and Review & Test. Standard actions are edited
//  with structured fields; the raw action-map JSON stays available as an
//  explicit advanced mode.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

// MARK: - Setup Sections

/// The custom channel sheet's focused sections. Raw values are the section
/// ids used by the setup scaffold rail and by validation findings.
enum AgentChannelCustomSetupSection: String, CaseIterable, Sendable {
    case basics
    case capabilities
    case sendReceive = "send-receive"
    case review

    var title: String {
        switch self {
        case .basics: return L("Basics")
        case .capabilities: return L("Capabilities & Access")
        case .sendReceive: return L("Send & Receive")
        case .review: return L("Review & Test")
        }
    }

    var icon: String {
        switch self {
        case .basics: return "tag"
        case .capabilities: return "curlybraces"
        case .sendReceive: return "arrow.up.arrow.down"
        case .review: return "checkmark.seal"
        }
    }

    var caption: String? {
        switch self {
        case .basics: return L("Name and endpoint")
        case .capabilities: return L("Actions and rooms")
        case .sendReceive: return L("Optional")
        case .review: return L("Checks and tools")
        }
    }

    static var sections: [AgentChannelSetupSection] {
        allCases.map {
            AgentChannelSetupSection(id: $0.rawValue, title: $0.title, icon: $0.icon, caption: $0.caption)
        }
    }
}

// MARK: - Sheet

struct AgentChannelCustomConnectionSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Existing connection to edit, or nil to create a new one.
    let connection: AgentChannelConnection?
    /// Set when this sheet is hosted inside the unified Add Channel picker;
    /// shows a back chevron that returns to the catalog.
    var onBack: (() -> Void)? = nil
    /// Called after any successful save or delete so the channel list refreshes.
    let onDidChange: () -> Void

    @State private var draft = AgentChannelConnectionDraft()
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var diagnosticsText: String?
    @State private var isDiagnosing = false
    @State private var showDeleteConfirmation = false
    @State private var selectedSectionId: String = AgentChannelCustomSetupSection.basics.rawValue
    @State private var attentionSectionId: String?

    private let manager = AgentChannelConnectionManager.shared
    private let service = AgentChannelConnectionService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: draft.kind.icon,
            gradient: draft.kind.brandGradient,
            title: draft.isNew ? L("New Custom Channel") : (draft.name.isEmpty ? draft.id : draft.name),
            subtitle: L("Custom HTTP JSON channel"),
            sections: AgentChannelCustomSetupSection.sections,
            selection: $selectedSectionId,
            sectionStatus: sectionStatus(for:),
            onBack: onBack
        ) { sectionId in
            VStack(alignment: .leading, spacing: 20) {
                switch AgentChannelCustomSetupSection(rawValue: sectionId) {
                case .basics:
                    basicsSectionContent
                case .capabilities:
                    capabilitiesSectionContent
                case .sendReceive:
                    sendReceiveSectionContent
                case .review, nil:
                    reviewSectionContent
                }
            }
        } statusBar: {
            if let statusMessage {
                AgentChannelInlineStatusMessage(
                    message: statusMessage,
                    isError: statusIsError,
                    onAutoClear: { self.statusMessage = nil }
                )
            }
        } footerLeading: {
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
        } footerTrailing: {
            AgentChannelSheetActionButton(
                title: L("Save"),
                busyTitle: L("Saving..."),
                isBusy: false,
                isPrimary: true,
                action: saveDraft
            )
            .disabled(trimmedDraftId.isEmpty)
        }
        .onAppear {
            if let connection {
                draft = AgentChannelConnectionDraft(connection: connection)
            }
            selectedSectionId = AgentChannelSetupFlow.initialSection(
                in: AgentChannelCustomSetupSection.sections,
                required: [
                    AgentChannelCustomSetupSection.basics.rawValue,
                    AgentChannelCustomSetupSection.capabilities.rawValue,
                ],
                isComplete: { sectionCompleted($0) },
                fallback: AgentChannelCustomSetupSection.review.rawValue
            )
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

    // MARK: - Section state

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch AgentChannelCustomSetupSection(rawValue: sectionId) {
        case .basics:
            guard !trimmedDraftId.isEmpty else { return false }
            guard draft.kind == .customHTTP else { return true }
            return !draft.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .capabilities:
            guard !draft.supportedActions.isEmpty else { return false }
            guard draft.kind == .customHTTP else { return true }
            let actions = AgentChannelConnectionDraft.decodedActionsForEditing(draft.customActionsJSON)
            return (actions?.isEmpty == false)
        case .sendReceive:
            let sendsConfigured =
                draft.writeEnabled
                && !AgentChannelConnectionDraft.parseListPreview(draft.writeRoomAllowlistText).isEmpty
            let receivesConfigured =
                !AgentChannelConnectionDraft.parseListPreview(draft.inboundSenderAllowlistText).isEmpty
            return sendsConfigured || receivesConfigured
        case .review:
            return !trimmedDraftId.isEmpty && draft.validationFindings().isEmpty
        case nil:
            return false
        }
    }

    private func sectionStatus(for sectionId: String) -> AgentChannelSetupSectionStatus {
        if attentionSectionId == sectionId { return .attention }
        return sectionCompleted(sectionId) ? .complete : .pending
    }

    // MARK: - Basics

    private var basicsSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            AgentChannelSectionHeading(
                L("Name this channel"),
                detail: L("The connection id is how agent_channel tools refer to this channel.")
            )

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

            if draft.kind == .customHTTP {
                SettingsDivider()

                AgentChannelSectionHeading(
                    L("HTTP endpoint"),
                    detail: L("Requests only run for actions defined in Capabilities and are always confirmed before sending.")
                )

                StyledSettingsTextField(
                    label: L("Base URL (required)"),
                    text: $draft.customBaseURL,
                    placeholder: "https://hooks.example.test",
                    help: L("HTTPS origin agent tools call for this channel.")
                )
            }
        }
    }

    // MARK: - Capabilities & Access

    private var capabilitiesSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            actionsSection

            if draft.kind == .customHTTP {
                SettingsDivider()
                httpActionsSection
            }

            SettingsDivider()
            accessSection
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(
                L("Choose what agents may do"),
                detail: L("Only checked standard actions are offered to agents on this channel.")
            )

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

    private var httpActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Define the HTTP requests"),
                detail: L(
                    "Map each standard action to the HTTP request it performs. Use ${content}, {room_id}, and ${secret:name} placeholders."
                )
            )

            AgentChannelStructuredActionsEditor(jsonText: $draft.customActionsJSON)

            AgentChannelAdvancedSection {
                AgentChannelMultilineSettingsField(
                    title: L("Action Map JSON"),
                    text: $draft.customActionsJSON,
                    help: L(
                        "Raw JSON object keyed by standard action names. Values define method, path, optional query, headers, bodyTemplate, and response handling. Edits here and above stay in sync."
                    )
                )
            }
        }
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(
                L("Where agents may look"),
                detail: L("Allowlists limit which spaces and rooms this connection can inspect.")
            )

            HStack(alignment: .top, spacing: 12) {
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

    // MARK: - Send & Receive

    private var sendReceiveSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            sendingSection
            SettingsDivider()
            inboundAuthorizationSection
        }
    }

    private var sendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Allow sending (optional)"))

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

    private var inboundAuthorizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Authorize incoming messages (optional)"),
                detail: L(
                    "Custom channels are outbound-only until you authorize incoming senders. Anything posted to the inbound inbox API from senders not listed here is denied."
                )
            )

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

    // MARK: - Review & Test

    private var reviewSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            validationSummary

            SettingsDivider()

            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSectionHeading(
                    L("Diagnostics"),
                    detail: canRunLiveDiagnostics
                        ? L("Run Diagnostics below tests the saved connection against its endpoint.")
                        : L("Check Configuration below validates this draft; save it to run live diagnostics.")
                )

                if let diagnosticsText {
                    ScrollView {
                        Text(diagnosticsText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 180)
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

            SettingsDivider()
            advancedSection
        }
    }

    private var validationSummary: some View {
        let findings = draft.validationFindings()
        return VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Configuration check"))

            if findings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.successColor)
                    Text("This configuration looks structurally valid.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                        findingRow(finding)
                    }
                }
            }
        }
    }

    private func findingRow(_ finding: AgentChannelDraftValidationFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.warningColor)
                .padding(.top, 1)

            Text(finding.message)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if finding.sectionId != AgentChannelCustomSetupSection.review.rawValue {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedSectionId = finding.sectionId
                    }
                } label: {
                    Text("Fix", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.07))
        )
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
            // Point at the fields most likely responsible (an unparseable
            // action map or reserved/invalid id) instead of only reporting.
            if let finding = draft.validationFindings().first {
                attentionSectionId = finding.sectionId
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedSectionId = finding.sectionId
                }
            }
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
    /// the check works before saving. Results land in Review & Test.
    private func diagnose() {
        let connectionId = trimmedDraftId
        guard !connectionId.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            selectedSectionId = AgentChannelCustomSetupSection.review.rawValue
        }
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
        if !isError {
            attentionSectionId = nil
        }
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

// MARK: - Structured Actions Editor

/// Structured editors for the action map: one card per defined action with
/// method / path / headers / body fields, plus a menu to add standard
/// actions. The raw JSON string stays the single source of truth so the
/// advanced JSON editor and these fields never diverge.
private struct AgentChannelStructuredActionsEditor: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @Binding var jsonText: String

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let actions = AgentChannelConnectionDraft.decodedActionsForEditing(jsonText) {
                let names = actions.keys.sorted()

                if names.isEmpty {
                    Text(
                        "No actions defined yet. Add one below — agents can only call actions that are defined here.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(names, id: \.self) { name in
                    AgentChannelActionEditorRow(name: name, jsonText: $jsonText)
                        .id(name)
                }

                addActionMenu(existing: Set(names))
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                    Text(
                        "The action map JSON does not parse, so it can't be edited as fields. Fix it in the Advanced JSON editor below.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.warningColor.opacity(0.08))
                )
            }
        }
    }

    private func addActionMenu(existing: Set<String>) -> some View {
        let available = AgentChannelAction.allCases.filter { !existing.contains($0.rawValue) }
        return Menu {
            ForEach(available, id: \.self) { action in
                Button(action.displayName) {
                    addAction(action)
                }
            }
        } label: {
            Label(L("Add Action"), systemImage: "plus.circle")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundColor(theme.accentColor)
        .disabled(available.isEmpty)
    }

    private func addAction(_ action: AgentChannelAction) {
        let isWrite = action.baseEffect != .readOnly
        let template = AgentChannelCustomHTTPAction(
            method: isWrite ? "POST" : "GET",
            path: "/",
            bodyTemplate: isWrite ? "{\"text\":\"${content}\"}" : nil
        )
        if let updated = AgentChannelConnectionDraft.upsertingAction(
            in: jsonText,
            name: action.rawValue,
            action: template
        ) {
            jsonText = updated
        }
    }
}

/// Field-level editor for one action in the map. Reads the current values
/// out of the JSON on every render and writes edits straight back, so the
/// advanced raw editor and these fields always agree.
private struct AgentChannelActionEditorRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let name: String
    @Binding var jsonText: String

    private static let standardMethods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var currentAction: AgentChannelCustomHTTPAction? {
        AgentChannelConnectionDraft.decodedActionsForEditing(jsonText)?[name]
    }

    private var displayName: String {
        AgentChannelAction(rawValue: name)?.displayName ?? name
    }

    private var isStandardAction: Bool {
        AgentChannelAction(rawValue: name) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)

                if !isStandardAction {
                    Text("Not a standard action", bundle: .module)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.warningColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.warningColor.opacity(0.12)))
                }

                Spacer()

                Button {
                    if let updated = AgentChannelConnectionDraft.removingAction(in: jsonText, name: name) {
                        jsonText = updated
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.errorColor)
                }
                .buttonStyle(PlainButtonStyle())
                .help(Text("Remove this action", bundle: .module))
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(L("Method"))
                    Picker("", selection: methodBinding) {
                        ForEach(methodChoices, id: \.self) { method in
                            Text(method).tag(method)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 92, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(L("Path"))
                    TextField("/rooms/{room_id}/messages", text: pathBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(L("Headers"))
                headersEditor
                Text("One per line: Header-Name: value. Use ${secret:name} for tokens.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(L("Body Template (optional)"))
                bodyEditor
                Text("Request body sent for this action. ${content} is replaced with the message text.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .textCase(.uppercase)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(theme.tertiaryText)
            .tracking(0.5)
    }

    private var methodChoices: [String] {
        let current = currentAction?.method.uppercased() ?? "GET"
        if Self.standardMethods.contains(current) {
            return Self.standardMethods
        }
        return Self.standardMethods + [current]
    }

    private func update(_ mutate: (inout AgentChannelCustomHTTPAction) -> Void) {
        guard var action = currentAction else { return }
        mutate(&action)
        if let updated = AgentChannelConnectionDraft.upsertingAction(
            in: jsonText,
            name: name,
            action: action
        ) {
            jsonText = updated
        }
    }

    private var methodBinding: Binding<String> {
        Binding(
            get: { currentAction?.method.uppercased() ?? "GET" },
            set: { value in update { $0.method = value.uppercased() } }
        )
    }

    private var pathBinding: Binding<String> {
        Binding(
            get: { currentAction?.path ?? "" },
            set: { value in update { $0.path = value } }
        )
    }

    /// Headers are edited through local text so partially typed lines (no
    /// colon yet) aren't normalized out from under the user; parsed values
    /// write through on every change.
    private var headersEditor: some View {
        AgentChannelActionRowTextEditor(
            initialText: AgentChannelConnectionDraft.headerLines(currentAction?.headers ?? [:]),
            placeholder: L("Authorization: Bearer ${secret:bearer}"),
            minHeight: 44
        ) { text in
            update { $0.headers = AgentChannelConnectionDraft.parsedHeaderLines(text) }
        }
    }

    private var bodyEditor: some View {
        AgentChannelActionRowTextEditor(
            initialText: currentAction?.bodyTemplate ?? "",
            placeholder: "{\"text\":\"${content}\"}",
            minHeight: 44
        ) { text in
            update { $0.bodyTemplate = text.isEmpty ? nil : text }
        }
    }
}

/// Small monospaced text editor with local state that writes through on
/// every change without re-deriving its own display text, so lenient
/// parsing can't fight the user's in-progress typing.
private struct AgentChannelActionRowTextEditor: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let initialText: String
    let placeholder: String
    let minHeight: CGFloat
    let onChange: (String) -> Void

    @State private var text: String

    init(
        initialText: String,
        placeholder: String,
        minHeight: CGFloat,
        onChange: @escaping (String) -> Void
    ) {
        self.initialText = initialText
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.onChange = onChange
        self._text = State(initialValue: initialText)
    }

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.placeholderText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
        }
        .frame(minHeight: minHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
        .onChange(of: text) {
            onChange(text)
        }
    }
}

// MARK: - Validation Findings

/// One pre-save configuration problem, pointed at the setup section whose
/// fields can fix it.
struct AgentChannelDraftValidationFinding: Equatable, Sendable {
    let sectionId: String
    let message: String
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

    // MARK: Structured action editing

    /// Actions decoded for the structured editors, or nil when the JSON does
    /// not parse (the raw editor is then the only way to fix it). An empty
    /// or whitespace-only string is a valid empty map.
    static func decodedActionsForEditing(_ json: String) -> [String: AgentChannelCustomHTTPAction]? {
        try? parseCustomActionsJSON(json)
    }

    /// Deterministic pretty encoding shared by the structured editors and the
    /// draft loader, so structured edits and raw JSON edits stay in sync.
    static func encodedActionsJSON(_ actions: [String: AgentChannelCustomHTTPAction]) -> String {
        guard let data = try? JSONEncoder.prettyAgentChannelEncoder.encode(actions),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    /// Insert or replace one action in the map, preserving every other entry
    /// and all schema fields the structured editors do not expose. Returns
    /// nil when the existing JSON does not parse.
    static func upsertingAction(
        in json: String,
        name: String,
        action: AgentChannelCustomHTTPAction
    ) -> String? {
        guard var actions = decodedActionsForEditing(json) else { return nil }
        actions[name] = action
        return encodedActionsJSON(actions)
    }

    /// Remove one action from the map. Returns nil when the existing JSON
    /// does not parse.
    static func removingAction(in json: String, name: String) -> String? {
        guard var actions = decodedActionsForEditing(json) else { return nil }
        actions.removeValue(forKey: name)
        return encodedActionsJSON(actions)
    }

    /// Render a headers dictionary as editable "Name: value" lines.
    static func headerLines(_ headers: [String: String]) -> String {
        headers.keys.sorted()
            .map { "\($0): \(headers[$0] ?? "")" }
            .joined(separator: "\n")
    }

    /// Parse "Name: value" lines back into a headers dictionary. Lines
    /// without a colon become a header with an empty value so in-progress
    /// typing isn't discarded.
    static func parsedHeaderLines(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            headers[name] = value
        }
        return headers
    }

    // MARK: Validation

    /// Configuration problems checkable before the connection is saved, each
    /// pointed at the sheet section whose fields can fix it. Empty means the
    /// draft looks structurally valid.
    func validationFindings() -> [AgentChannelDraftValidationFinding] {
        var findings: [AgentChannelDraftValidationFinding] = []

        func add(_ section: AgentChannelCustomSetupSection, _ message: String) {
            findings.append(
                AgentChannelDraftValidationFinding(sectionId: section.rawValue, message: message)
            )
        }

        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.basics, L("Connection ID is required."))
        }
        if kind == .customHTTP {
            let base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty {
                add(.basics, L("Base URL is required."))
            } else if let url = URL(string: base) {
                let scheme = url.scheme?.lowercased()
                if scheme != "https" && scheme != "http" {
                    add(.basics, L("Base URL must start with https:// or http://."))
                }
                if url.host == nil {
                    add(.basics, L("Base URL is missing a host."))
                }
            } else {
                add(.basics, L("Base URL is not a valid URL."))
            }
            do {
                let actions = try Self.parseCustomActionsJSON(customActionsJSON)
                if actions.isEmpty {
                    add(.capabilities, L("Define at least one action in the action map."))
                } else {
                    let known = Set(AgentChannelAction.allCases.map(\.rawValue))
                    for key in actions.keys.sorted() where !known.contains(key) {
                        add(
                            .capabilities,
                            L("Action \"\(key)\" is not a standard action name and will never be called.")
                        )
                    }
                }
            } catch {
                add(.capabilities, L("Action map JSON is invalid: \(error.localizedDescription)"))
            }
        }
        if supportedActions.isEmpty {
            add(.capabilities, L("Enable at least one standard action."))
        }
        if writeEnabled && Self.parseList(writeRoomAllowlistText).isEmpty {
            add(
                .sendReceive,
                L("Sending is enabled but the write room allowlist is empty, so sends will be refused.")
            )
        }
        for secret in Self.parseSecretReferences(secretReferencesText)
        where secret.keychainId.isEmpty {
            add(.review, L("Secret \"\(secret.name)\" has no keychain id (expected name=keychain-id)."))
        }
        return findings
    }

    /// Flat message list, kept for callers that don't care about sections.
    func validationIssues() -> [String] {
        validationFindings().map(\.message)
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
        case .sendTyping: L("Send typing")
        }
    }
}
