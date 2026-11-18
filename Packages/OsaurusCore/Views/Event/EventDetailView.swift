//
//  EventDetailView.swift
//  osaurus
//
//  One event: what fires it, what it runs, its webhook URL (for webhook
//  events), and its recent tasks — every fire, including the ones that
//  were filtered, de-duplicated, skipped or refused.
//

import AppKit
import SwiftUI

struct EventDetailView: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject private var relay = RelayTunnelManager.shared
    private var manager = EventManager.shared

    let eventId: UUID
    let onEdit: (OsaurusEvent) -> Void
    let onClose: () -> Void

    @State private var revealedSecret: String?
    @State private var pastedSecret = ""
    @State private var notice: String?
    @State private var serverPort = ServerConfiguration.default.port

    init(
        eventId: UUID,
        onEdit: @escaping (OsaurusEvent) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.eventId = eventId
        self.onEdit = onEdit
        self.onClose = onClose
    }

    private var event: OsaurusEvent? { manager.event(for: eventId) }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            if let event {
                hero(event)
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space.s12) {
                        if let problem = EventInspection.targetProblem(event) {
                            targetProblemBanner(problem, event: event)
                        }
                        summary(event)
                        if let webhook = event.source.webhook {
                            webhookPanel(event, webhook)
                        }
                        ledger
                    }
                    .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer(event)
            } else {
                SettingsSheetHeader(icon: "bolt.fill", title: "Automation", subtitle: nil, onClose: onClose)
                Spacer()
                Text("This automation was deleted.", bundle: .module)
                    .foregroundColor(theme.text.secondary)
                Spacer()
            }
        }
        .fittedSheetFrame(width: 680, height: 680)
        .settingsSheetSurface()
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
        .onAppear {
            serverPort = (ServerConfigurationStore.load() ?? ServerConfiguration.default).port
        }
    }

    // MARK: Hero / footer

    private func hero(_ event: OsaurusEvent) -> some View {
        VStack(spacing: theme.space.s0) {
            SettingsDetailHeader(
                icon: EventSourceTemplate.icon(for: event),
                title: event.name,
                subtitle: event.sourceSummary
            ) {
                statePill(event)
                chip(icon: event.sourceKind.icon, text: Self.kindLabel(event))
                chip(icon: Self.actionChipIcon(event.action.kind), text: EventInspection.actionLabel(event))
            } actions: {
                SettingsIconButton("xmark", help: "Close", size: .compact, action: onClose)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s16)
            .background(theme.surface.subtle)

            ThemeHairlineDivider()
        }
    }

    static func actionChipIcon(_ kind: EventActionKind) -> String {
        switch kind {
        case .agent: "person.fill"
        case .workflow: "flowchart"
        case .prompt: "sparkles"
        }
    }

    static func actionStepIcon(_ kind: EventActionKind) -> String {
        switch kind {
        case .agent: "person.crop.circle"
        case .workflow: "point.3.connected.trianglepath.dotted"
        case .prompt: "sparkles"
        }
    }

    /// "Webhook · GitHub" for a named sender.
    static func kindLabel(_ event: OsaurusEvent) -> String {
        guard let webhook = event.source.webhook, webhook.provider != .generic else {
            return event.sourceKind.displayName
        }
        return "\(event.sourceKind.displayName) · \(webhook.provider.shortName)"
    }

    private func statePill(_ event: OsaurusEvent) -> some View {
        let (text, color): (String, Color) =
            if manager.isRunning(event.id) {
                (L("Running"), theme.action.primary.default.background)
            } else if EventInspection.targetProblem(event) != nil {
                (L("Needs attention"), theme.status.warning.foreground)
            } else if event.isEnabled {
                (L("On"), theme.status.success.foreground)
            } else {
                (L("Off"), theme.text.tertiary)
            }
        return StatusChip(text, tint: color)
    }

    private func chip(icon: String, text: String) -> some View {
        StatusChip(text, tone: .neutral, icon: icon)
    }

    private func footer(_ event: OsaurusEvent) -> some View {
        VStack(spacing: theme.space.s0) {
            ThemeHairlineDivider()
            HStack(spacing: theme.space.s8) {
                if let notice {
                    Text(verbatim: notice)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                        .transition(.opacity)
                }
                Spacer()
                Button {
                    Task {
                        let result = await manager.fireNow(event.id)
                        notice = result.accepted ? L("Started.") : L("Did not run: \(result.status.displayName)")
                    }
                } label: {
                    Label {
                        Text("Run Now", bundle: .module)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                }
                .assignedSettingsButtonStyle(.secondary)
                .settingsLandingAnchor("automations.runNow")
                Button { onEdit(event) } label: { Text("Edit", bundle: .module) }
                    .assignedSettingsButtonStyle(.primary)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s16)
            .background(theme.surface.subtle)
        }
    }

    private func targetProblemBanner(_ problem: EventTargetProblem, event: OsaurusEvent) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.status.warning.foreground)
            Text(problem.message)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { onEdit(event) } label: { Text("Edit", bundle: .module) }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
        }
        .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.warning))
    }

    // MARK: Summary

    /// When → Do → Result: how it is called, what it runs (with the
    /// workflow inputs it passes), and what each run leaves behind.
    private func summary(_ event: OsaurusEvent) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            step(icon: event.sourceKind.icon, title: L("When")) {
                row(L("Trigger"), event.sourceSummary)
                if let next = event.nextRunDescription { row(L("Next run"), next) }
                if !event.filter.isEmpty { row(L("Only when"), filterSummary(event.filter)) }
                row(L("Queueing"), deliverySummary(event))
                sourceStatusRows(event)
            }
            stepConnector
            step(icon: Self.actionStepIcon(event.action.kind), title: L("Do")) {
                row(event.action.kind.displayName, EventInspection.actionLabel(event))
                if case .workflow(let action) = event.action {
                    if let agentId = action.runAsAgentId {
                        row(L("Runs as"), AgentManager.shared.agent(for: agentId)?.name ?? L("Missing agent"))
                    }
                    workflowInputs(event, action)
                } else if let instructions = event.action.agent?.instructions ?? event.action.prompt?.instructions,
                    !instructions.isEmpty
                {
                    row(L("Instructions"), instructions)
                }
            }
            stepConnector
            step(icon: "checkmark.circle", title: L("Result")) {
                row(L("Each run"), EventInspection.resultLabel(event))
                if let status = event.lastStatus { row(L("Last run"), status.displayName) }
                if manager.isRunning(event.id) {
                    row(L("Now"), L("Running · \(manager.queuedCount(event.id)) queued"))
                }
                if event.lastSessionId != nil || manager.isRunning(event.id) {
                    HStack(spacing: theme.space.s12) {
                        if let sessionId = event.lastSessionId {
                            linkButton(L("Open Last Chat")) { openChat(sessionId, agentId: event.agentId) }
                        }
                        if manager.isRunning(event.id) {
                            linkButton(L("Stop Runs"), color: theme.status.error.foreground) {
                                manager.cancelRuns(eventId: event.id)
                            }
                        }
                    }
                    .padding(.top, theme.space.s2)
                }
            }
        }
        .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card)
        .settingsLandingAnchor("automations.overview")
    }

    private func step<Content: View>(
        icon: String, title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            ZStack {
                Circle().fill(theme.status.info.background)
                Image(systemName: icon)
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.text.link)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text(verbatim: title)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                    .padding(.top, theme.space.s6)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the source adapter reports: checks, position, provider setup,
    /// and its last error. Schedules show their next run above instead.
    @ViewBuilder
    private func sourceStatusRows(_ event: OsaurusEvent) -> some View {
        let status = manager.status(of: event.id)
        if event.sourceKind != .schedule {
            if let last = status.lastTickAt { row(L("Last check"), Self.relative(last)) }
            if let next = status.nextTickAt { row(L("Next check"), Self.relative(next)) }
        }
        if case .connected = status.phase { row(L("Connection"), L("Connected")) }
        if let cursor = status.cursor { row(L("Position"), cursor) }
        if let installed = status.installed {
            row(L("Provider setup"), installed ? L("Registered") : L("Not registered"))
        }
        if let note = status.note { row(L("Note"), note) }
        if let error = status.lastError {
            SettingsFindingRow(severity: .warning, title: L("The source reported a problem"), detail: error)
        }
        if let email = event.source.email {
            let account = SourceConnectionStore.shared.connection(id: email.connectionId)
            row(L("Account"), account.map { "\($0.displayName) · \($0.config.summary)" } ?? L("Removed"))
        }
    }

    private static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private var stepConnector: some View {
        Rectangle()
            .fill(theme.border.subtle)
            .frame(width: 1, height: 14)
            .padding(.leading, theme.space.s12)
            .padding(.vertical, theme.space.s2)
    }

    /// Each declared input and what fills it.
    @ViewBuilder
    private func workflowInputs(_ event: OsaurusEvent, _ action: WorkflowEventAction) -> some View {
        if let workflow = InstalledWorkflowStore.shared.workflow(id: action.workflowID) {
            let fields = WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema)
            let values = EventTriggerValues.catalog(for: event.sourceKind)
            ForEach(fields, id: \.key) { field in
                let template = action.inputMapping[field.key]
                let text: String =
                    switch WorkflowInputBinding.kind(of: template) {
                    case .unset: field.required ? L("Not set (required, runs will fail)") : L("Not set")
                    case .triggerValue(let path):
                        values.first { $0.path == path }.map { "\($0.label) {{\(path)}}" } ?? "{{\(path)}}"
                    case .template, .fixed: template ?? ""
                    }
                row(field.label, text)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Text(label)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func linkButton(_ title: String, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(color ?? theme.text.link)
        }
        .buttonStyle(.plain)
    }

    private func filterSummary(_ filter: EventFilter) -> String {
        var parts: [String] = []
        if !filter.senderAllowlist.isEmpty { parts.append(L("from \(filter.senderAllowlist.joined(separator: ", "))")) }
        if !filter.keywordsAny.isEmpty { parts.append(L("mentions any of \(filter.keywordsAny.joined(separator: ", "))")) }
        if !filter.keywordsAll.isEmpty { parts.append(L("mentions all of \(filter.keywordsAll.joined(separator: ", "))")) }
        if !filter.pathGlobs.isEmpty { parts.append(L("files matching \(filter.pathGlobs.joined(separator: ", "))")) }
        for condition in filter.conditions { parts.append("\(condition.path) = \(condition.equals)") }
        return parts.joined(separator: "; ")
    }

    private func deliverySummary(_ event: OsaurusEvent) -> String {
        let delivery = event.delivery
        if event.sourceKind == .channelMessage, event.action.kind == .agent {
            var text = EventDeliveryMode.perConversation.displayName
            text += delivery.maxQueued == 0 ? L(", skip while busy") : L(", hold \(delivery.maxQueued) while busy")
            if delivery.steerRunningTurn { text += L(", follow-ups join the running reply") }
            return text
        }
        var text = delivery.mode.displayName
        if delivery.mode == .parallel { text += " (≤\(delivery.maxConcurrent))" }
        text += delivery.maxQueued == 0 ? L(", skip while busy") : L(", hold \(delivery.maxQueued) while busy")
        return text
    }

    // MARK: Webhook

    private func localURL(_ webhook: WebhookSourceConfig) -> String {
        "http://127.0.0.1:\(serverPort)/events/\(webhook.token)"
    }

    private func webhookPanel(_ event: OsaurusEvent, _ webhook: WebhookSourceConfig) -> some View {
        EventEditorSection(title: L("Webhook URL"), icon: "link") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    urlRow(L("This Mac"), localURL(webhook))
                    if let relayURL = relayURL(for: event, token: webhook.token) {
                        urlRow(L("Relay"), relayURL)
                    } else {
                        Text("Turn on the relay for an agent (Agents → Relay) to get a public URL.", bundle: .module)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ThemeHairlineDivider()

                verificationBlock(event, webhook)

                ThemeHairlineDivider()

                if webhook.provider != .generic {
                    Text(
                        "Use the service's test or redeliver button to try it. Run Now sends the example body.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    tryItBlock(event, webhook)
                }

                HStack {
                    Text(L("Limits: \(webhook.maxBodyBytes / 1024) KB body, \(webhook.rateLimitPerMinute) calls/min"))
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                    Spacer()
                    linkButton(L("Rotate URL"), color: theme.text.secondary) {
                        manager.rotateWebhookToken(event.id)
                        notice = L("New URL created. The old one stopped working.")
                    }
                    .help(L("Makes a new URL. The old one stops working at once."))
                }
            }
        }
        .settingsLandingAnchor("automations.webhookUrl")
    }

    private func tryItBlock(_ event: OsaurusEvent, _ webhook: WebhookSourceConfig) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack {
                fieldLabel(L("Try it"))
                Spacer()
                Button {
                    let secret = secretForCopy(event, webhook)
                    copy(curlCommand(webhook, secret: secret))
                    if webhook.verification != .none, secret == nil {
                        notice = L("No secret stored — rotate to create one.")
                    }
                } label: {
                    Label {
                        Text("Copy", bundle: .module)
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                .help(
                    webhook.verification == .none
                        ? L("Copy") : L("Copies a ready-to-run command, secret included."))
            }
            Text(verbatim: curlCommand(webhook, secret: revealedSecret))
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.inset)
            Text(
                "Osaurus answers 202 with a run id, and the run shows up under Runs below. JSON fields reach the agent as {{webhook.body.<field>}}.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func verificationBlock(_ event: OsaurusEvent, _ webhook: WebhookSourceConfig) -> some View {
        if webhook.provider == .generic {
            genericVerificationBlock(event, webhook)
        } else {
            providerVerificationBlock(event, webhook.provider)
        }
    }

    private func providerVerificationBlock(_ event: OsaurusEvent, _ provider: WebhookProvider) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsRowText(compact: true) {
                HStack(spacing: theme.space.s8) {
                    fieldLabel(L("Verification"))
                    Text(verbatim: provider.verificationSummary)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                }
            } description: {
                Text(verbatim: provider.setupHint)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }
            if provider.issuesSecret {
                let stored = EventSecretsKeychain.hasSecret(eventID: event.id)
                HStack(spacing: theme.space.s8) {
                    secretLabel
                    SettingsTextField(
                        placeholder: stored
                            ? L("Saved. Paste a new one to replace it") : L("Paste from \(provider.shortName)"),
                        text: $pastedSecret, icon: "key", monospaced: true, isSecure: true, revealable: true)
                    Button {
                        let secret = pastedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !secret.isEmpty else { return }
                        let saved = EventSecretsKeychain.saveSecret(secret, eventID: event.id)
                        pastedSecret = ""
                        notice = saved ? L("Secret saved.") : L("Could not save the secret (Keychain unavailable).")
                    } label: {
                        Text("Save", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .disabled(pastedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .settingsLandingAnchor("automations.webhookProviderSecret")
                if !stored {
                    Text(
                        "Requests are refused until the secret is saved.", bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.status.warning.foreground)
                }
            } else if provider.checksSecret {
                generatedSecretRow(event)
            }
        }
    }

    private func genericVerificationBlock(_ event: OsaurusEvent, _ webhook: WebhookSourceConfig) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                fieldLabel(L("Verification"))
                Text(verbatim: webhook.verification.displayName)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(
                        webhook.verification == .none ? theme.status.warning.foreground : theme.text.primary
                    )
            }
            Text(verbatim: Self.verificationExplanation(webhook))
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(webhook.verification == .none ? theme.status.warning.foreground : theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if webhook.verification != .none {
                generatedSecretRow(event)
            }
        }
    }

    private var secretLabel: some View {
        Text("Secret", bundle: .module)
            .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
            .foregroundColor(theme.text.tertiary)
            .frame(width: 60, alignment: .leading)
    }

    /// The secret Osaurus created for the sender, with show, copy and rotate.
    private func generatedSecretRow(_ event: OsaurusEvent) -> some View {
        HStack(spacing: theme.space.s8) {
            secretLabel
            Text(verbatim: revealedSecret ?? String(repeating: "•", count: 24))
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(revealedSecret == nil ? theme.text.tertiary : theme.text.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            linkButton(revealedSecret == nil ? L("Show") : L("Hide")) {
                if revealedSecret != nil {
                    revealedSecret = nil
                } else {
                    revealedSecret = EventSecretsKeychain.secret(eventID: event.id)
                    if revealedSecret == nil { notice = L("No secret stored — rotate to create one.") }
                }
            }
            Button {
                if let secret = revealedSecret ?? EventSecretsKeychain.secret(eventID: event.id) {
                    copy(secret)
                } else {
                    notice = L("No secret stored — rotate to create one.")
                }
            } label: {
                Image(systemName: "doc.on.doc").glyphSize(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.text.link)
            .help(L("Copy"))
            linkButton(L("Rotate Secret"), color: theme.text.secondary) {
                revealedSecret = manager.rotateWebhookSecret(event.id)
                notice =
                    revealedSecret == nil
                    ? L("Could not store a new secret (Keychain unavailable).")
                    : L("New secret created. Update the sender.")
            }
        }
        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
        .settingsChrome(.inset)
    }

    /// What the sender must do for this verification method, in one
    /// paragraph with the real header name and prefix.
    static func verificationExplanation(_ webhook: WebhookSourceConfig) -> String {
        let header = webhook.effectiveHeader ?? ""
        switch webhook.verification {
        case .none:
            return L("No check: anyone who has the URL can start this automation. Edit it to add a signature or a secret.")
        case .sharedSecretHeader:
            return L("Each request must send the secret below, exactly as shown, in the \(header) header.")
        case .hmacSHA256:
            let prefix = webhook.signaturePrefix ?? "sha256="
            return L(
                "Each request must be signed: compute an HMAC-SHA256 of the raw request body using the secret below as the key, and send it as \(prefix)<hex digest> in the \(header) header. Services like GitHub do this for you: paste the URL and the secret into their webhook settings (GitHub sends X-Hub-Signature-256, so set that header name under Edit → Advanced)."
            )
        }
    }

    /// A curl command that calls this automation the way its verification
    /// expects. `secret` fills the secret in; nil leaves a placeholder.
    private func curlCommand(_ webhook: WebhookSourceConfig, secret: String?) -> String {
        Self.curlCommand(url: localURL(webhook), webhook: webhook, secret: secret)
    }

    /// The webhook's sample body on one line (compact JSON when it parses),
    /// safe inside single quotes; a greeting when there is no sample.
    static func shellQuotedBody(_ sample: String?) -> String {
        let trimmed = sample?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: String =
            if trimmed.isEmpty {
                #"{"text":"Hello from curl"}"#
            } else if let parsed = JSONValue.parse(trimmed) {
                parsed.compactJSONString
            } else {
                trimmed.replacingOccurrences(of: "\n", with: " ")
            }
        return body.replacingOccurrences(of: "'", with: #"'\''"#)
    }

    static func curlCommand(url: String, webhook: WebhookSourceConfig, secret: String?) -> String {
        let body = shellQuotedBody(webhook.sampleBody)
        let header = webhook.effectiveHeader ?? ""
        let secretLine = "SECRET='\(secret ?? "<secret>")'"
        switch webhook.verification {
        case .none:
            return """
                curl -X POST '\(url)' \\
                  -H 'Content-Type: application/json' \\
                  -d '\(body)'
                """
        case .sharedSecretHeader:
            return """
                \(secretLine)
                curl -X POST '\(url)' \\
                  -H 'Content-Type: application/json' \\
                  -H "\(header): $SECRET" \\
                  -d '\(body)'
                """
        case .hmacSHA256:
            let prefix = webhook.signaturePrefix ?? "sha256="
            return """
                \(secretLine)
                BODY='\(body)'
                SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
                curl -X POST '\(url)' \\
                  -H 'Content-Type: application/json' \\
                  -H "\(header): \(prefix)$SIG" \\
                  -d "$BODY"
                """
        }
    }

    private func secretForCopy(_ event: OsaurusEvent, _ webhook: WebhookSourceConfig) -> String? {
        guard webhook.checksSecret else { return nil }
        return revealedSecret ?? EventSecretsKeychain.secret(eventID: event.id)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
            .foregroundColor(theme.text.tertiary)
    }

    private func urlRow(_ label: String, _ url: String) -> some View {
        HStack(spacing: theme.space.s8) {
            Text(label)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 60, alignment: .leading)
            Text(url)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            copyButton(url)
        }
        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
        .settingsChrome(.inset)
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            copy(value)
        } label: {
            Image(systemName: "doc.on.doc").glyphSize(.footnote)
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.text.link)
        .help(L("Copy"))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        notice = L("Copied.")
    }

    /// The relay URL through the event's own agent when its tunnel is up,
    /// otherwise through any connected agent (the route is not agent-scoped).
    private func relayURL(for event: OsaurusEvent, token: String) -> String? {
        WebhookEventSource.relayURL(for: event, token: token)
    }

    // MARK: Ledger

    private var ledger: some View {
        EventEditorSection(title: L("Runs"), icon: "list.bullet.rectangle.fill") {
            RecentTasksList(
                query: TaskQuery(subscriptionId: eventId, limit: 50),
                emptyText: "Nothing yet. Every run shows up here — including skipped and filtered ones.")
        }
    }

    private func openChat(_ sessionId: UUID, agentId: UUID?) {
        if let existing = ChatWindowManager.shared.findWindow(bySessionId: sessionId) {
            ChatWindowManager.shared.showWindow(id: existing.id)
        } else if let data = ChatSessionStore.load(id: sessionId) {
            ChatWindowManager.shared.createWindow(agentId: agentId ?? data.agentId, sessionData: data)
        }
    }
}
