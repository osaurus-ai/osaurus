//
//  CredentialEditorSheet.swift
//  osaurus
//
//  Add or edit one key: its name, who can use it (all agents or one), the
//  value, whether the value is hidden, and whether agents can read it when
//  running code.
//

import SwiftUI

struct CredentialEditorRequest: Identifiable {
    let id = UUID()
    /// Key being edited; nil adds a new one.
    var existingKey: String?
    var key: String = ""
    var scope: CredentialScope = .global
    var hideValue = true
    var exposeToSandbox = true
    var description = ""
    var origin: CredentialOrigin = .user
    /// Filling a missing key or adding an agent's own value: the name and
    /// who uses it are fixed.
    var locksKey = false

    static func edit(_ record: CredentialRecord) -> CredentialEditorRequest {
        CredentialEditorRequest(
            existingKey: record.key, key: record.key, scope: record.scope,
            hideValue: record.kind == .secret, exposeToSandbox: record.exposeToSandbox,
            description: record.description, origin: record.origin)
    }

    /// A different value for `agentId`, starting from the shared record.
    static func override(_ record: CredentialRecord?, key: String, agentId: UUID) -> CredentialEditorRequest {
        CredentialEditorRequest(
            key: key, scope: .agent(agentId), hideValue: (record?.kind ?? .secret) == .secret,
            exposeToSandbox: record?.exposeToSandbox ?? true, description: record?.description ?? "",
            locksKey: true)
    }

    static func fill(_ missing: CredentialMissingKey) -> CredentialEditorRequest {
        CredentialEditorRequest(
            key: missing.key, hideValue: missing.slot.kind == .secret, exposeToSandbox: false,
            origin: missing.slot.category.origin, locksKey: true)
    }
}

extension CredentialConsumerCategory {
    var origin: CredentialOrigin {
        switch self {
        case .mcp: return .mcp
        case .plugin: return .plugin
        case .channel: return .channel
        case .workflow: return .workflow
        }
    }
}

struct CredentialEditorSheet: View {
    let request: CredentialEditorRequest
    let usedBy: [CredentialSlot]
    let onClose: () -> Void

    @ObservedObject private var agentManager = AgentManager.shared
    @State private var key: String
    @State private var scope: CredentialScope
    @State private var value = ""
    @State private var hideValue: Bool
    @State private var exposeToSandbox: Bool
    @State private var description: String
    @State private var error: String?
    @State private var isSaving = false

    init(request: CredentialEditorRequest, usedBy: [CredentialSlot], onClose: @escaping () -> Void) {
        self.request = request
        self.usedBy = usedBy
        self.onClose = onClose
        _key = State(initialValue: request.key)
        _scope = State(initialValue: request.scope)
        _hideValue = State(initialValue: request.hideValue)
        _exposeToSandbox = State(initialValue: request.exposeToSandbox)
        _description = State(initialValue: request.description)
    }

    private var store: CredentialStore { .current }
    private var isNew: Bool { request.existingKey == nil }
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Multiline values (PEM keys, certificates) are kept exactly as typed;
    /// single-line values lose surrounding whitespace.
    private var trimmedValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(where: \.isNewline) ? value : trimmed
    }
    private var existing: CredentialRecord? { request.existingKey.flatMap { store.record($0, scope: scope) } }
    private var kindChanged: Bool { existing.map { ($0.kind == .secret) != hideValue } ?? false }

    private var validationMessage: String? {
        if !trimmedKey.isEmpty, !CredentialKeys.isValid(trimmedKey) {
            return CredentialWriteOutcome.invalidKey.failureDescription
        }
        if trimmedKey != request.existingKey, store.hasValue(trimmedKey, scope: scope) {
            return L("This name is already used. Pick another or edit the existing key.")
        }
        if kindChanged, trimmedValue.isEmpty {
            return L("Enter the value again to change whether it is hidden.")
        }
        if trimmedValue.utf8.count > CredentialStore.maxValueBytes {
            return CredentialWriteOutcome.valueTooLong.failureDescription
        }
        return nil
    }

    private var canSave: Bool {
        guard !trimmedKey.isEmpty, validationMessage == nil else { return false }
        return !isNew || !trimmedValue.isEmpty
    }

    private var scopeOptions: [SettingsPickerRow<CredentialScope>.Option] {
        [.init(.global, L("All agents"), verbatim: true)]
            + agentManager.agents.map {
                .init(.agent($0.id), L("Only for \($0.displayName)"), verbatim: true)
            }
    }

    var body: some View {
        SettingsSheet(
            icon: "key.fill",
            title: isNew ? "Add Key" : "Edit Key",
            subtitle: subtitle,
            width: SettingsSheetWidth.regular,
            primary: .init(label: isNew ? "Add Key" : "Save Changes", isEnabled: canSave && !isSaving, handler: save),
            secondary: .init(label: "Cancel", handler: onClose),
            warning: error ?? validationMessage,
            onClose: onClose
        ) {
            SettingsSection(title: "Key") {
                if request.locksKey {
                    SettingsRow(
                        title: "Name", description: trimmedKey, anchorId: "keys.editor.name", verbatimDescription: true
                    ) { EmptyView() }
                } else {
                    SettingsTextFieldRow(
                        label: "Name",
                        text: $key,
                        placeholder: "GITHUB_TOKEN",
                        help: L("Letters, numbers and underscores. Programs read it by this name."),
                        anchorId: "keys.editor.name",
                        monospaced: true)
                }
                if isNew, !request.locksKey {
                    SettingsPickerRow(
                        title: "Who Can Use It",
                        description: L("A value for one agent replaces the value for all agents."),
                        anchorId: "keys.editor.scope",
                        style: .menu,
                        selection: $scope,
                        options: scopeOptions)
                }
                SettingsFieldRow(
                    label: "Value",
                    hint: !isNew
                        ? L("Leave blank to keep the current value.")
                        : hideValue ? nil : L("Shift-Return starts a new line, for values like PEM keys."),
                    anchorId: "keys.editor.value"
                ) {
                    SettingsTextField(
                        placeholder: isNew ? "" : L("Unchanged"),
                        text: $value,
                        axis: hideValue ? .horizontal : .vertical,
                        lineLimit: hideValue ? nil : 4,
                        monospaced: true,
                        isSecure: hideValue,
                        revealable: hideValue)
                }
                SettingsTextFieldRow(
                    label: "Description",
                    text: $description,
                    placeholder: "",
                    help: L("Optional. What this key is for."))
            }

            SettingsSection(title: "Options") {
                SettingsRow(
                    title: "Hide Value",
                    description: L("Hidden values are masked here and removed from tool output."),
                    anchorId: "keys.editor.hideValue",
                    verbatimDescription: true
                ) {
                    Toggle("", isOn: $hideValue).settingsSwitch()
                        .accessibilityLabel(L("Hide Value"))
                }
                SettingsRow(
                    title: "Agents Can Use This When Running Code",
                    description: L("Available as an environment variable in the sandbox."),
                    anchorId: "keys.editor.exposeToSandbox",
                    verbatimDescription: true
                ) {
                    Toggle("", isOn: $exposeToSandbox).settingsSwitch()
                        .accessibilityLabel(L("Agents Can Use This When Running Code"))
                }
                if exposeToSandbox, CredentialResolver.isReservedEnvVar(trimmedKey) {
                    SettingsCallout(
                        icon: "exclamationmark.triangle.fill",
                        title: L("Not Available When Running Code"),
                        message: L("\(trimmedKey) is a name the system sets, so agents' code never sees this value. Pick another name to use it there."),
                        tone: .warning)
                }
            }

            if !usedBy.isEmpty {
                SettingsSection(
                    title: "Used By",
                    footer: trimmedKey != request.existingKey && request.existingKey != nil
                        ? L("Renaming keeps these connected to the new name.") : nil
                ) {
                    ForEach(usedBy) { slot in
                        LibraryRow(
                            title: slot.consumer,
                            subtitle: "\(slot.category.label) · \(slot.field)",
                            leading: {
                                LibraryIcon(
                                    symbol: slot.category.origin.symbol, tint: slot.category.origin.tint, size: 28)
                            }
                        )
                    }
                }
            }
        }
    }

    private var subtitle: LocalizedStringKey? {
        switch scope {
        case .global: return "Shared by every agent unless an agent has its own value."
        case .agent(let id):
            let name = agentManager.agent(for: id)?.displayName ?? L("this agent")
            return "Only \(name) uses this value."
        }
    }

    private func save() {
        guard !isSaving else { return }
        error = nil
        isSaving = true
        let oldKey = request.existingKey
        let newKey = trimmedKey
        let value = trimmedValue
        let scope = scope
        let kind: CredentialKind = hideValue ? .secret : .variable
        let description = description
        let exposeToSandbox = exposeToSandbox
        let origin = existing?.origin ?? request.origin
        Task {
            let failure: String? = await store.perform { store in
                var name = oldKey ?? newKey
                if let oldKey, newKey != oldKey {
                    let outcome = store.rename(oldKey, to: newKey)
                    guard outcome.isSuccess else { return outcome.failureDescription }
                    name = newKey
                }
                if value.isEmpty {
                    store.updateMetadata(name, scope: scope, description: description, exposeToSandbox: exposeToSandbox)
                    return nil
                }
                let outcome = store.save(
                    name, scope: scope, value: value, kind: kind, description: description,
                    exposeToSandbox: exposeToSandbox, origin: origin)
                return outcome.isSuccess ? nil : outcome.failureDescription
            }
            isSaving = false
            if let failure { error = failure } else { onClose() }
        }
    }
}
