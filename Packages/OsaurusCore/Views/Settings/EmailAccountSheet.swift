//
//  EmailAccountSheet.swift
//  osaurus
//
//  Adds or edits a mail account the Email channel reads: an account from
//  the Mail app, or an IMAP server (plus an optional SMTP server for
//  replies) with a password kept in the Keychain.
//

import SwiftUI

struct EmailAccountSheet: View {
    enum Mode: Identifiable {
        case add
        case edit(SourceConnection)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let connection): connection.id
            }
        }
    }

    @Environment(\.theme) private var theme
    let mode: Mode
    let onSaved: (SourceConnection) -> Void
    let onDeleted: () -> Void
    let onClose: () -> Void

    @State private var type: SourceConnectionType = .imap
    @State private var name = ""
    @State private var mailAccount = ""
    @State private var mailAccounts: [String] = []
    @State private var host = ""
    @State private var port = IMAPSecurity.tls.defaultPort
    @State private var security: IMAPSecurity = .tls
    @State private var username = ""
    @State private var password = ""
    @State private var smtpHost = ""
    @State private var smtpPort = SMTPSecurity.tls.defaultPort
    @State private var smtpSecurity: SMTPSecurity = .tls
    @State private var fromAddress = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var loaded = false
    @State private var confirmingDelete = false
    @State private var deleteProblem: String?

    init(
        mode: Mode,
        onSaved: @escaping (SourceConnection) -> Void,
        onDeleted: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.mode = mode
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        self.onClose = onClose
    }

    private var existing: SourceConnection? {
        if case .edit(let connection) = mode { return connection }
        return nil
    }

    var body: some View {
        SettingsSheet(
            icon: "envelope.badge",
            title: existing == nil ? "Add Mail Account" : "Edit Mail Account",
            subtitle: "The Email channel reads mail from this account and replies through it.",
            width: SettingsSheetWidth.regular,
            primary: .init(label: "Save", isEnabled: canSave, handler: save),
            secondary: .init(label: "Cancel", handler: onClose),
            warning: problem,
            onClose: onClose
        ) {
            if existing == nil {
                SettingsFieldRow(label: "Account Type") {
                    AssignedBaseSegmentedPicker(
                        selection: $type,
                        options: [.init(SourceConnectionType.imap, "IMAP server"), .init(SourceConnectionType.mailApp, "Mail app")]
                    )
                    .fixedSize()
                    .accessibilityLabel(Text("Account Type", bundle: .module))
                }
            }
            SettingsFieldRow(label: "Name", hint: L("Shown in Email channel settings."), verbatimHint: true) {
                SettingsTextField(placeholder: L("e.g. Work mail"), text: $name)
            }
            if type == .imap { imapFields } else { mailAppFields }
            if existing != nil { deleteRow }
        }
        .onAppear(perform: load)
        .confirmationDialog(L("Delete this mail account?"), isPresented: $confirmingDelete) {
            Button(L("Delete Account"), role: .destructive, action: delete)
        } message: {
            Text("Its saved password is removed from the Keychain.", bundle: .module)
        }
    }

    private var deleteRow: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsButton(.destructive, "Delete Account", icon: "trash", size: .compact) {
                confirmingDelete = true
            }
            if let deleteProblem {
                Text(verbatim: deleteProblem)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Fields

    private var imapFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsFieldRow(label: "Server", hint: L("For example imap.gmail.com or imap.mail.me.com."), verbatimHint: true) {
                SettingsTextField(placeholder: "imap.example.com", text: $host, icon: "server.rack", monospaced: true)
            }
            .onChange(of: host) { old, new in
                let previous = IMAPConnectionConfig.suggestedSMTPHost(forIMAPHost: old) ?? ""
                if smtpHost.isEmpty || smtpHost == previous {
                    smtpHost = IMAPConnectionConfig.suggestedSMTPHost(forIMAPHost: new) ?? ""
                }
            }
            if let note = imapConfig.passwordSignInNote {
                SettingsFindingRow(severity: .warning, title: L("This server needs a different sign-in"), detail: note)
            }
            SettingsRow(title: "Security", description: "") {
                SettingsMenuPicker(selection: $security) {
                    ForEach(IMAPSecurity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            .onChange(of: security) { old, new in
                if port == old.defaultPort { port = new.defaultPort }
            }
            SettingsRow(title: "Port", description: "") {
                SettingsStepper(value: $port, range: 1 ... 65535)
            }
            SettingsFieldRow(label: "User name", hint: L("Usually your full email address."), verbatimHint: true) {
                SettingsTextField(placeholder: "you@example.com", text: $username, icon: "person")
            }
            SettingsFieldRow(
                label: "Password",
                hint: existing == nil
                    ? L("Gmail and iCloud need an app password when two-step sign-in is on. Kept in the Keychain.")
                    : L("Leave empty to keep the saved password."),
                verbatimHint: true
            ) {
                SettingsTextField(placeholder: L("App password"), text: $password, icon: "key", isSecure: true)
            }
            smtpFields
            HStack(spacing: theme.space.s8) {
                SettingsButton(.secondary, "Test Connection", icon: "bolt.horizontal", isLoading: testing) {
                    Task { await test() }
                }
                .disabled(!imapComplete)
                if let testResult {
                    Label(
                        testResult.message,
                        systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(testResult.ok ? theme.status.success.foreground : theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(
                "Osaurus opens the mailbox read-only: checking never marks mail as read. It reads up to 256 KB of each new message.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var smtpFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsFieldRow(
                label: "Reply Server (SMTP)",
                hint: L("Replies are sent through this server with the same user name and password. Leave empty to only read."),
                verbatimHint: true
            ) {
                SettingsTextField(placeholder: "smtp.example.com", text: $smtpHost, icon: "paperplane", monospaced: true)
            }
            if !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty {
                if let note = imapConfig.smtpNote {
                    SettingsFindingRow(severity: .warning, title: L("This server can't send from Osaurus"), detail: note)
                }
                SettingsRow(title: "Reply Server Security", description: "") {
                    SettingsMenuPicker(selection: $smtpSecurity) {
                        ForEach(SMTPSecurity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                .onChange(of: smtpSecurity) { old, new in
                    if smtpPort == old.defaultPort { smtpPort = new.defaultPort }
                }
                SettingsRow(title: "Reply Server Port", description: "") {
                    SettingsStepper(value: $smtpPort, range: 1 ... 65535)
                }
                SettingsFieldRow(
                    label: "From Address",
                    hint: L("Replies come from this address. Empty uses the user name."),
                    verbatimHint: true
                ) {
                    SettingsTextField(placeholder: "you@example.com", text: $fromAddress, icon: "at")
                }
            }
        }
    }

    private var mailAppFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            EventEditorLabeled(L("Mail account")) {
                HStack(spacing: theme.space.s8) {
                    SettingsMenuPicker(selection: $mailAccount) {
                        Text("All accounts", bundle: .module).tag("")
                        ForEach(accountChoices, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    SettingsButton(.secondary, "Load Accounts", icon: "arrow.clockwise", isLoading: testing, size: .compact) {
                        Task { await loadMailAccounts() }
                    }
                }
            }
            if let testResult, !testResult.ok {
                Text(verbatim: testResult.message)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "Reads the accounts already set up in Mail, so no password is needed. Mail must be open for new mail to be noticed and replies are sent by Mail; macOS asks once to let Osaurus control Mail.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountChoices: [String] {
        var out = mailAccounts
        if !mailAccount.isEmpty, !out.contains(mailAccount) { out.insert(mailAccount, at: 0) }
        return out
    }

    // MARK: State

    private var imapComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (!password.isEmpty || existing != nil)
    }

    private var imapConfig: IMAPConnectionConfig {
        IMAPConnectionConfig(
            host: host, port: port, security: security, username: username,
            smtpHost: smtpHost, smtpPort: smtpPort, smtpSecurity: smtpSecurity, fromAddress: fromAddress)
    }

    private var problem: String? {
        guard type == .imap else { return nil }
        if let security = imapConfig.securityProblem { return security }
        if !imapConfig.smtpHost.isEmpty, imapConfig.effectiveFromAddress == nil {
            return L("Enter a From address: the user name isn't an email address.")
        }
        return nil
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return type == .mailApp || (imapComplete && problem == nil)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let existing else { return }
        name = existing.displayName
        type = existing.type
        switch existing.config {
        case .imap(let config):
            host = config.host
            port = config.port
            security = config.security
            username = config.username
            smtpHost = config.smtpHost
            smtpPort = config.smtpPort
            smtpSecurity = config.smtpSecurity
            fromAddress = config.fromAddress
        case .mailApp(let config):
            mailAccount = config.account ?? ""
        case .apiToken:
            break
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let id = existing?.id ?? "test"
        let config = imapConfig
        let typed = password
        let resolvePassword: @Sendable () -> String? = {
            typed.isEmpty
                ? SourceCredentialVault.read(connectionId: id, field: SourceCredentialVault.passwordField) : typed
        }
        var fetcher = IMAPMailboxFetcher(connectionId: id, config: config)
        fetcher.password = resolvePassword
        let reading: String
        do {
            let boxes = try await fetcher.mailboxes()
            reading = boxes.count == 1 ? L("Signed in. 1 mailbox.") : L("Signed in. \(boxes.count) mailboxes.")
        } catch {
            testResult = (false, error.localizedDescription)
            return
        }
        guard !config.smtpHost.isEmpty else {
            testResult = (true, reading)
            return
        }
        do {
            guard let password = resolvePassword() else { throw SMTPError.passwordMissing }
            try await SMTPClient(config: SMTPClient.Config(imap: config, password: password)).verifySignIn()
            testResult = (true, reading + " " + L("Reply server signed in."))
        } catch {
            testResult = (false, reading + " " + error.localizedDescription)
        }
    }

    private func loadMailAccounts() async {
        testing = true
        defer { testing = false }
        do {
            let boxes = try await AppleScriptMailService().mailboxes()
            mailAccounts = Array(Set(boxes.map(\.account).filter { $0 != MailboxPath.localAccount })).sorted()
            testResult = nil
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }

    private func save() {
        let config: SourceConnectionConfig =
            type == .imap ? .imap(imapConfig) : .mailApp(MailAppConnectionConfig(account: mailAccount))
        var connection = existing ?? SourceConnection(displayName: name, config: config)
        connection.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.config = config
        if type == .imap, !password.isEmpty {
            guard SourceCredentialVault.save(password, connectionId: connection.id, field: SourceCredentialVault.passwordField)
            else {
                testResult = (false, L("The password couldn't be saved to the Keychain."))
                return
            }
        }
        onSaved(SourceConnectionStore.shared.save(connection))
    }

    private func delete() {
        guard let existing else { return }
        switch SourceConnectionStore.shared.delete(id: existing.id) {
        case .deleted, .notFound:
            onDeleted()
        case .inUse(let names):
            deleteProblem = L("Still used by \(names.joined(separator: ", ")). Remove it there first.")
        }
    }
}
