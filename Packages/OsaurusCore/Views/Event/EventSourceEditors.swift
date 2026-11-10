//
//  EventSourceEditors.swift
//  osaurus
//
//  The "When" section of the automation editor, one draft and one editor
//  per source kind. `EventSourceDrafts` holds every kind's draft so the
//  sheet keeps one piece of state; adding a kind means a draft, an editor
//  and a case in the four switches below.
//

import SwiftUI

// MARK: - Drafts

struct EventSourceDraftError: Error, Equatable {
    let message: String
}

struct ScheduleSourceDraft: Equatable {
    var frequency = ScheduleFrequencyDraft()

    mutating func load(_ config: ScheduleSourceConfig) {
        frequency = ScheduleFrequencyDraft(config.frequency)
    }

    func build() -> Result<EventSource, EventSourceDraftError> {
        let built = frequency.frequency
        if case .cron(let expression) = built, CronParser(expression) == nil {
            return .failure(EventSourceDraftError(message: L("The cron expression is not valid.")))
        }
        return .success(.schedule(ScheduleSourceConfig(frequency: built)))
    }

    var sample: EventSource { .schedule(ScheduleSourceConfig(frequency: frequency.frequency)) }
}

struct FolderSourceDraft: Equatable {
    var path: String?
    var bookmark: Data?
    var recursive = false
    var responsiveness: Responsiveness = .balanced

    mutating func load(_ config: FolderSourceConfig) {
        path = config.path
        bookmark = config.bookmark
        recursive = config.recursive
        responsiveness = config.responsiveness
    }

    func build(existing: FolderSourceConfig?) -> Result<EventSource, EventSourceDraftError> {
        guard let path else { return .failure(EventSourceDraftError(message: L("Choose a folder to watch."))) }
        var config = existing ?? FolderSourceConfig()
        config.path = path
        config.bookmark = bookmark
        config.recursive = recursive
        config.responsiveness = responsiveness
        return .success(.folder(config))
    }

    var sample: EventSource { .folder(FolderSourceConfig(path: path)) }
}

struct WebhookSourceDraft: Equatable {
    var provider: WebhookProvider = .generic
    /// A signing secret pasted from a provider that issues its own; saved
    /// to the Keychain with the automation, never kept in the event.
    var providerSecret = ""
    var verification: WebhookVerificationMethod = .hmacSHA256
    var signatureHeader = ""
    var maxBodyKB = WebhookSourceConfig.defaultMaxBodyBytes / 1024
    var rateLimit = WebhookSourceConfig.defaultRateLimitPerMinute
    var showAdvanced = false
    var sampleBody = ""

    /// A provider template's starting point: its example body when none is written yet.
    mutating func choose(_ provider: WebhookProvider) {
        let previousSample = self.provider.sampleBody
        self.provider = provider
        let current = sampleBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current == previousSample { sampleBody = provider.sampleBody ?? "" }
    }

    mutating func load(_ config: WebhookSourceConfig) {
        provider = config.provider
        verification = config.verification
        signatureHeader = config.signatureHeader ?? ""
        maxBodyKB = max(1, config.maxBodyBytes / 1024)
        rateLimit = config.rateLimitPerMinute
        sampleBody = config.sampleBody ?? ""
        showAdvanced =
            !(config.signatureHeader ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || config.maxBodyBytes != WebhookSourceConfig.defaultMaxBodyBytes
            || config.rateLimitPerMinute != WebhookSourceConfig.defaultRateLimitPerMinute
    }

    func build(existing: WebhookSourceConfig?) -> Result<EventSource, EventSourceDraftError> {
        var config = existing ?? WebhookSourceConfig()
        config.provider = provider
        if provider == .generic {
            config.verification = verification
            let header = signatureHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            config.signatureHeader = header.isEmpty ? nil : header
        }
        config.maxBodyBytes = maxBodyKB * 1024
        config.rateLimitPerMinute = rateLimit
        config.sampleBody = trimmedSampleBody
        return .success(.webhook(config))
    }

    var sample: EventSource {
        .webhook(WebhookSourceConfig(token: "sample", provider: provider, sampleBody: trimmedSampleBody))
    }

    /// The pasted secret to store, when the provider issues one.
    var secretToSave: String? {
        guard provider.issuesSecret else { return nil }
        let secret = providerSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        return secret.isEmpty ? nil : secret
    }

    private var trimmedSampleBody: String? {
        let body = sampleBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

struct RSSSourceDraft: Equatable {
    var url = ""
    var pollMinutes = RSSSourceConfig.defaultPollIntervalSeconds / 60
    var catchUp: SourceCatchUpPolicy = .latestOnly
    var maxItems = RSSSourceConfig.defaultMaxItemsPerTick

    mutating func load(_ config: RSSSourceConfig) {
        url = config.url
        pollMinutes = max(1, config.pollIntervalSeconds / 60)
        catchUp = config.catchUp
        maxItems = config.maxItemsPerTick
    }

    func build() -> Result<EventSource, EventSourceDraftError> {
        guard config.feedURL != nil else {
            return .failure(EventSourceDraftError(message: L("Enter the feed's http or https address.")))
        }
        return .success(.rss(config))
    }

    var sample: EventSource { .rss(config) }

    private var config: RSSSourceConfig {
        RSSSourceConfig(url: url, pollIntervalSeconds: pollMinutes * 60, catchUp: catchUp, maxItemsPerTick: maxItems)
    }
}

struct SSESourceDraft: Equatable {
    var url = ""
    var eventNamesText = ""
    /// One `Name: value` per line.
    var headersText = ""
    /// 0 = never reconnect for silence.
    var heartbeatSeconds = 0

    mutating func load(_ config: SSESourceConfig) {
        url = config.url
        eventNamesText = config.eventNames.joined(separator: ", ")
        headersText = config.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        heartbeatSeconds = config.heartbeatTimeoutSeconds ?? 0
    }

    func build() -> Result<EventSource, EventSourceDraftError> {
        guard TriggerSourceURL.parse(url) != nil else {
            return .failure(EventSourceDraftError(message: L("Enter the stream's http or https address.")))
        }
        guard let headers = Self.headers(headersText) else {
            return .failure(EventSourceDraftError(message: L("Write each header as Name: value, one per line.")))
        }
        return .success(.sse(config(headers: headers)))
    }

    var sample: EventSource { .sse(config(headers: Self.headers(headersText) ?? [:])) }

    private func config(headers: [String: String]) -> SSESourceConfig {
        SSESourceConfig(
            url: url, headers: headers, eventNames: EventSourceDrafts.list(eventNamesText),
            heartbeatTimeoutSeconds: heartbeatSeconds > 0 ? heartbeatSeconds : nil)
    }

    /// nil when a non-empty line is not `Name: value`.
    static func headers(_ text: String) -> [String: String]? {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") else { return nil }
            headers[parts[0]] = parts[1]
        }
        return headers
    }
}

struct RunFailedSourceDraft: Equatable {
    var workflowIDs: [UUID] = []
    var includeAutomationRuns = false

    mutating func load(_ config: RunFailedSourceConfig) {
        workflowIDs = config.workflowIDs
        includeAutomationRuns = config.includeAutomationRuns
    }

    func build() -> Result<EventSource, EventSourceDraftError> { .success(sample) }

    var sample: EventSource {
        .runFailed(RunFailedSourceConfig(workflowIDs: workflowIDs, includeAutomationRuns: includeAutomationRuns))
    }
}

struct AppEventsSourceDraft: Equatable {
    var reasons: Set<AppEventReason> = [.appLaunched]

    mutating func load(_ config: AppEventsSourceConfig) {
        reasons = Set(config.reasons)
    }

    func build() -> Result<EventSource, EventSourceDraftError> {
        guard !reasons.isEmpty else {
            return .failure(EventSourceDraftError(message: L("Pick at least one app event.")))
        }
        return .success(sample)
    }

    var sample: EventSource { .app(AppEventsSourceConfig(reasons: Array(reasons))) }
}

struct EmailSourceDraft: Equatable {
    var connectionId = ""
    var mailboxes: [String] = []
    var unreadOnly = false
    var includeBody = true
    var maxBodyChars = EmailSourceConfig.defaultMaxBodyChars
    var pollMinutes = EmailSourceConfig.defaultPollIntervalSeconds / 60
    var catchUp: SourceCatchUpPolicy = .sinceCursor

    mutating func load(_ config: EmailSourceConfig) {
        connectionId = config.connectionId
        mailboxes = config.mailboxes
        unreadOnly = config.unreadOnly
        includeBody = config.includeBody
        maxBodyChars = config.maxBodyChars
        pollMinutes = max(1, config.pollIntervalSeconds / 60)
        catchUp = config.catchUp
    }

    func build() -> Result<EventSource, EventSourceDraftError> {
        guard !connectionId.isEmpty else {
            return .failure(EventSourceDraftError(message: L("Choose the mail account to watch.")))
        }
        return .success(.email(config))
    }

    var sample: EventSource { .email(config) }

    private var config: EmailSourceConfig {
        EmailSourceConfig(
            connectionId: connectionId, mailboxes: mailboxes, unreadOnly: unreadOnly, includeBody: includeBody,
            maxBodyChars: maxBodyChars, pollIntervalSeconds: pollMinutes * 60, catchUp: catchUp)
    }
}

struct ChannelSourceDraft: Equatable {
    var connectionId = ""
    var roomsText = ""
    var aliasesText = ""
    var requireMention = false
    var continueThreads = true

    /// A new rule's defaults for `kind`: its mention rule and first connection.
    mutating func choose(_ kind: AgentChannelKind) {
        requireMention = ChannelMessageSourceConfig.defaultRequiresMention(kind)
        connectionId =
            ChannelMessageSourceConfig.nativeConnectionId(for: kind)
            ?? AgentChannelConfigurationStore.load().connections.first { $0.kind == kind }?.id ?? ""
    }

    mutating func load(_ config: ChannelMessageSourceConfig) {
        connectionId = config.connectionId
        roomsText = config.roomIds.joined(separator: ", ")
        aliasesText = config.aliases.joined(separator: ", ")
        requireMention = config.requireMention
        continueThreads = config.continueThreads
    }

    func build(_ kind: AgentChannelKind) -> Result<EventSource, EventSourceDraftError> {
        guard !connectionId.isEmpty else {
            return .failure(EventSourceDraftError(message: L("Choose a \(kind.displayName) connection.")))
        }
        return .success(
            .channelMessage(
                ChannelMessageSourceConfig(
                    kind: kind, connectionId: connectionId, roomIds: EventSourceDrafts.list(roomsText),
                    aliases: EventSourceDrafts.list(aliasesText),
                    requireMention: ChannelMessageSourceConfig.supportsMentions(kind) ? requireMention : false,
                    continueThreads: continueThreads)))
    }

    func sample(_ kind: AgentChannelKind) -> EventSource {
        .channelMessage(
            ChannelMessageSourceConfig(kind: kind, connectionId: connectionId, roomIds: EventSourceDrafts.list(roomsText)))
    }
}

/// Every kind's draft; the template picks which one is live.
struct EventSourceDrafts: Equatable {
    var schedule = ScheduleSourceDraft()
    var folder = FolderSourceDraft()
    var webhook = WebhookSourceDraft()
    var rss = RSSSourceDraft()
    var sse = SSESourceDraft()
    var runFailed = RunFailedSourceDraft()
    var app = AppEventsSourceDraft()
    var email = EmailSourceDraft()
    var channel = ChannelSourceDraft()

    mutating func load(from source: EventSource) {
        switch source {
        case .schedule(let config): schedule.load(config)
        case .folder(let config): folder.load(config)
        case .webhook(let config): webhook.load(config)
        case .rss(let config): rss.load(config)
        case .sse(let config): sse.load(config)
        case .runFailed(let config): runFailed.load(config)
        case .app(let config): app.load(config)
        case .email(let config): email.load(config)
        case .channelMessage(let config): channel.load(config)
        }
    }

    func build(_ template: EventSourceTemplate, existing: EventSource?) -> Result<EventSource, EventSourceDraftError> {
        switch template {
        case .source(.schedule): schedule.build()
        case .source(.folder): folder.build(existing: existing?.folder)
        case .source(.webhook), .providerWebhook: webhook.build(existing: existing?.webhook)
        case .source(.rss): rss.build()
        case .source(.sse): sse.build()
        case .source(.runFailed): runFailed.build()
        case .source(.app): app.build()
        case .source(.email): email.build()
        case .channel(let kind): channel.build(kind)
        case .source(.channelMessage):
            .failure(EventSourceDraftError(message: L("Choose what starts the automation.")))
        }
    }

    /// The draft as a source, for sample payloads; never fails.
    func sample(_ template: EventSourceTemplate) -> EventSource {
        switch template {
        case .source(.schedule): schedule.sample
        case .source(.folder): folder.sample
        case .source(.webhook), .providerWebhook: webhook.sample
        case .source(.rss): rss.sample
        case .source(.sse): sse.sample
        case .source(.runFailed): runFailed.sample
        case .source(.app): app.sample
        case .source(.email): email.sample
        case .channel(let kind): channel.sample(kind)
        case .source(.channelMessage): channel.sample(.slack)
        }
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

// MARK: - Editor

/// The live kind's fields.
struct EventSourceEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let template: EventSourceTemplate
    @Binding var drafts: EventSourceDrafts

    var body: some View {
        switch template {
        case .source(.schedule):
            ScheduleFrequencyEditor(draft: $drafts.schedule.frequency)
        case .source(.folder):
            FolderSourceEditor(draft: $drafts.folder)
        case .source(.webhook), .providerWebhook:
            WebhookSourceEditor(draft: $drafts.webhook)
        case .source(.rss):
            RSSSourceEditor(draft: $drafts.rss)
        case .source(.sse):
            SSESourceEditor(draft: $drafts.sse)
        case .source(.runFailed):
            RunFailedSourceEditor(draft: $drafts.runFailed)
        case .source(.app):
            AppEventsSourceEditor(draft: $drafts.app)
        case .source(.email):
            EmailSourceRetiredNotice()
        case .channel(let kind):
            ChannelSourceEditor(kind: kind, draft: $drafts.channel)
        case .source(.channelMessage):
            EmptyView()
        }
    }
}

/// The field label above a control, from an already-localized title.
struct EventEditorLabeled<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content
    }

    var body: some View {
        SettingsFieldRow(label: title, hint: hint, verbatimHint: true, verbatimLabel: true, content: content)
    }
}

/// Shown for an automation that still has the retired email trigger.
struct EmailSourceRetiredNotice: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    var body: some View {
        SettingsFindingRow(
            severity: .warning,
            title: L("Email is now a channel"),
            detail: L(
                "Mail reaches agents through Channels → Email, where agents can also reply in the thread. Set up the account and allowed senders there, then add a channel rule for Email."
            ))
    }
}

struct FolderSourceEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var draft: FolderSourceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            EventFolderField(
                path: draft.path, placeholder: L("Choose a folder to watch"),
                onPick: { path, bookmark in
                    draft.path = path
                    draft.bookmark = bookmark
                }, onClear: nil)
            Toggle(L("Include subfolders"), isOn: $draft.recursive).settingsSwitch(showsLabel: true)
                .settingsCheckbox()
            EventEditorLabeled(L("Responsiveness"), hint: draft.responsiveness.displayDescription) {
                SettingsMenuPicker(selection: $draft.responsiveness) {
                    ForEach(Responsiveness.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
            }
        }
    }
}

struct WebhookSourceEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var draft: WebhookSourceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            SettingsRow(title: "Sender", description: "") {
                SettingsMenuPicker(selection: providerBinding) {
                    ForEach(WebhookProvider.allCases) { Text(verbatim: $0.displayName).tag($0) }
                }
            }
            .settingsLandingAnchor("automations.webhookProvider")

            if draft.provider == .generic {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("How does the sender prove it's them?", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    ForEach(WebhookVerificationMethod.allCases.reversed(), id: \.self) { method in
                        verificationOption(method)
                    }
                }
                .settingsLandingAnchor("automations.webhookVerification")
            } else {
                Text(verbatim: L("Checked the \(draft.provider.shortName) way: \(draft.provider.verificationSummary)."))
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.provider.issuesSecret { providerSecretField }
            }

            HStack(alignment: .top, spacing: theme.space.s6) {
                Image(systemName: "info.circle")
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                Text(verbatim: setupHint)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(theme.text.tertiary)

            sampleBodyField

            DisclosureGroup(isExpanded: $draft.showAdvanced) {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    if draft.provider == .generic, draft.verification != .none {
                        SettingsFieldRow(
                            label: "Header name",
                            hint: draft.verification == .hmacSHA256
                                ? L("Leave empty to use \(WebhookSourceConfig.defaultSignatureHeader). Set it only when the sender uses its own header, such as X-Hub-Signature-256 for GitHub.")
                                : L("Leave empty to use \(WebhookSourceConfig.defaultSecretHeader). Set it only when the sender can't change the header it sends."),
                            verbatimHint: true
                        ) {
                            SettingsTextField(placeholder: defaultHeader, text: $draft.signatureHeader, monospaced: true)
                        }
                    }
                    SettingsRow(title: "Max Body Size", description: "") {
                        SettingsStepper(value: $draft.maxBodyKB, range: 1 ... 10240, step: 64, unit: "KB")
                    }
                    SettingsRow(title: "Rate Limit", description: "Requests per minute.") {
                        SettingsStepper(value: $draft.rateLimit, range: 1 ... 600)
                    }
                }
                .padding(.top, theme.space.s8)
            } label: {
                Text("Advanced", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
            }
        }
    }

    private var providerBinding: Binding<WebhookProvider> {
        Binding(get: { draft.provider }, set: { draft.choose($0) })
    }

    private var setupHint: String {
        switch draft.provider {
        case .generic:
            draft.verification == .none
                ? L("After you save, open the automation to copy its URL and a ready-to-run test command.")
                : L("Osaurus creates the secret when you save. Open the automation to copy the URL, the secret and a ready-to-run test command.")
        case let provider:
            provider.setupHint
        }
    }

    private var providerSecretField: some View {
        SettingsFieldRow(
            label: "Signing Secret",
            hint: L("Optional now. \(draft.provider.shortName) shows it after you add the URL there; you can paste it later on the automation. Stored in the Keychain."),
            anchorId: "automations.webhookProviderSecret",
            verbatimHint: true
        ) {
            SettingsTextField(
                placeholder: L("Paste from \(draft.provider.shortName)"), text: $draft.providerSecret, icon: "key",
                monospaced: true, isSecure: true, revealable: true)
        }
    }

    private var sampleBodyField: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Text("What does the sender post?", bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            Text(
                "Optional. Paste an example body. Its fields become values you can pass to a workflow, and Run Now sends it.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            EventMultilineField(
                text: $draft.sampleBody, placeholder: #"{"issue": {"title": "Login fails", "number": 42}}"#,
                minHeight: 70, straightQuotes: true)
            let trimmed = draft.sampleBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let parsed = EventTriggerValues.parsedSampleBody(trimmed), parsed.objectValue != nil {
                    let count = EventTriggerValues.bodyFields(parsed, prefix: "webhook.body").count
                    Label(
                        count == 1 ? L("1 field found") : L("\(count) fields found"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.status.success.foreground)
                } else {
                    Label(L("Not a JSON object, so the body is passed as one value."), systemImage: "info.circle")
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }
        }
        .settingsLandingAnchor("automations.webhookSampleBody")
    }

    private var defaultHeader: String {
        draft.verification == .hmacSHA256
            ? WebhookSourceConfig.defaultSignatureHeader : WebhookSourceConfig.defaultSecretHeader
    }

    private func verificationOption(_ method: WebhookVerificationMethod) -> some View {
        let selected = draft.verification == method
        return Button {
            withAnimation(theme.motion.quick) { draft.verification = method }
        } label: {
            HStack(alignment: .top, spacing: theme.space.s8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                    .foregroundColor(selected ? theme.text.link : theme.text.tertiary)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    HStack(spacing: theme.space.s6) {
                        Text(verbatim: method.displayName)
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        if method == .hmacSHA256 {
                            StatusChip(L("Recommended"), tone: .success)
                        }
                    }
                    Text(verbatim: Self.verificationHint(method))
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(method == .none ? theme.status.warning.foreground : theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(selected ? .selected : .control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func verificationHint(_ method: WebhookVerificationMethod) -> String {
        switch method {
        case .hmacSHA256:
            L("The sender signs each request with a secret, so a leaked URL alone can't start it. GitHub, Stripe and most services that send webhooks can do this.")
        case .sharedSecretHeader:
            L("The sender puts the secret in a header on each request. Easy from Zapier, n8n, Shortcuts or curl.")
        case .none:
            L("No check: anyone who has the URL can start this automation.")
        }
    }
}

struct ChannelSourceEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let kind: AgentChannelKind
    @Binding var draft: ChannelSourceDraft

    /// The kind's accounts, the primary first.
    private var accounts: [ChannelAccount] { ChannelAccounts.accounts(kind: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            if ChannelMessageSourceConfig.nativeConnectionId(for: kind) == nil {
                let connections = AgentChannelConfigurationStore.load().connections.filter { $0.kind == kind }
                if connections.isEmpty {
                    Text(L("No \(kind.displayName) connection yet — add one in Channels first."))
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.status.warning.foreground)
                } else {
                    EventEditorLabeled(L("Connection")) {
                        SettingsMenuPicker(selection: $draft.connectionId) {
                            ForEach(connections) { Text($0.name).tag($0.id) }
                        }
                        .fixedSize()
                    }
                }
            } else if accounts.count > 1 {
                SettingsFieldRow(
                    label: "Account", hint: L("Which \(kind.displayName) account this trigger listens on."),
                    anchorId: "agentChannels.ruleAccount", verbatimHint: true
                ) {
                    SettingsMenuPicker(selection: $draft.connectionId) {
                        ForEach(accounts) { Text(verbatim: $0.displayName).tag($0.connectionId) }
                    }
                    .fixedSize()
                }
            }
            EventEditorLabeled(L("Rooms (ids, comma separated; empty = any allowed room)")) {
                SettingsTextField(placeholder: L("e.g. C0123456, C0987654"), text: $draft.roomsText, icon: "number")
            }
            EventEditorLabeled(L("Aliases (a message starting with one goes to this rule)")) {
                SettingsTextField(placeholder: L("e.g. sales, ops"), text: $draft.aliasesText, icon: "at")
            }
            if ChannelMessageSourceConfig.supportsMentions(kind) {
                Toggle(L("Only when the bot is mentioned"), isOn: $draft.requireMention)
                    .settingsSwitch(showsLabel: true)
                if draft.requireMention {
                    Toggle(L("Keep answering in threads it replied in"), isOn: $draft.continueThreads)
                        .settingsSwitch(showsLabel: true)
                }
            }
            Text(
                "Sender and room allowlists on the connection still apply. A message goes to the rules whose alias it starts with; if none, to the rules for its room; if none, to the rules for any room. Every rule in that group runs.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
        }
    }
}

struct RSSSourceEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var draft: RSSSourceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            SettingsFieldRow(
                label: "Feed URL", hint: L("An RSS, Atom or JSON Feed address."), anchorId: "automations.rssFeedUrl",
                verbatimHint: true
            ) {
                SettingsTextField(
                    placeholder: "https://example.com/feed.xml", text: $draft.url, icon: "link",
                    isInvalid: !draft.url.isEmpty && TriggerSourceURL.parse(draft.url) == nil)
            }
            SettingsRow(title: "Check Every", description: "") {
                SettingsStepper(value: $draft.pollMinutes, range: 1 ... 1440, step: 5, unit: "min")
            }
            .settingsLandingAnchor("automations.rssPollInterval")
            SettingsRow(title: "Items per Check", description: "Older items in a burst are skipped.") {
                SettingsStepper(value: $draft.maxItems, range: RSSSourceConfig.maxItemsPerTickRange)
            }
            .settingsLandingAnchor("automations.rssMaxItems")
            SettingsRow(title: "After a Restart", description: "") {
                SettingsMenuPicker(selection: $draft.catchUp) {
                    ForEach(SourceCatchUpPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            .settingsLandingAnchor("automations.rssCatchUp")
            Text(
                "The first check notes what is in the feed now; each item published after that runs the automation once. Feed text is treated as untrusted.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SSESourceEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var draft: SSESourceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            SettingsFieldRow(
                label: "Stream URL", hint: L("An endpoint that answers with text/event-stream."),
                anchorId: "automations.sseUrl", verbatimHint: true
            ) {
                SettingsTextField(
                    placeholder: "https://example.com/events", text: $draft.url, icon: "link",
                    isInvalid: !draft.url.isEmpty && TriggerSourceURL.parse(draft.url) == nil)
            }
            SettingsFieldRow(
                label: "Event Names", hint: L("Comma separated. Empty runs on every message."),
                anchorId: "automations.sseEventNames", verbatimHint: true
            ) {
                SettingsTextField(placeholder: L("e.g. update, alert"), text: $draft.eventNamesText, icon: "tag")
            }
            SettingsFieldRow(
                label: "Request Headers",
                hint: L("One Name: value per line, sent when connecting. Stored as written, so don't put secrets here."),
                anchorId: "automations.sseHeaders", verbatimHint: true
            ) {
                EventMultilineField(
                    text: $draft.headersText, placeholder: "Accept-Language: en", minHeight: 50, straightQuotes: true)
            }
            SettingsRow(
                title: "Reconnect When Silent",
                description: draft.heartbeatSeconds == 0
                    ? L("Off") : L("After \(draft.heartbeatSeconds) s with nothing received"),
                verbatimDescription: true
            ) {
                SettingsStepper(value: $draft.heartbeatSeconds, range: 0 ... 3600, step: 10, unit: "s")
            }
            .settingsLandingAnchor("automations.sseHeartbeat")
            Text(
                "Osaurus stays connected while the automation is on and reconnects after drops, resuming from the last event id the server sent. Stream data is treated as untrusted.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RunFailedSourceEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject private var workflowStore = InstalledWorkflowStore.shared
    @Binding var draft: RunFailedSourceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            EventEditorLabeled(
                draft.workflowIDs.isEmpty
                    ? L("Workflows (none picked: any workflow)") : L("Workflows")
            ) {
                if workflowStore.workflows.isEmpty {
                    Text("No workflows installed yet. Add one in Workflows.", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: theme.space.s6) {
                        ForEach(workflowStore.workflows) { workflow in
                            Toggle(isOn: binding(workflow.id)) { Text(verbatim: workflow.name) }
                                .settingsCheckbox()
                        }
                    }
                }
            }
            .settingsLandingAnchor("automations.runFailedWorkflows")
            Toggle(L("Also when an automation's run fails"), isOn: $draft.includeAutomationRuns)
                .settingsSwitch(showsLabel: true)
                .settingsLandingAnchor("automations.runFailedIncludeAutomations")
            Text(
                "Runs this automation starts never fire it again, and neither do test runs. The error, the failed step and the run id are trigger values.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.workflowIDs.contains(id) },
            set: { on in
                draft.workflowIDs.removeAll { $0 == id }
                if on { draft.workflowIDs.append(id) }
            })
    }
}

struct AppEventsSourceEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var draft: AppEventsSourceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            EventEditorLabeled(L("Run when")) {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    ForEach(AppEventReason.allCases) { reason in
                        Toggle(isOn: binding(reason)) { Text(verbatim: reason.displayName) }
                            .settingsCheckbox()
                    }
                }
            }
            Text(
                "Use it to set things up when Osaurus opens, or to run once right after you turn the automation on or change it.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .settingsLandingAnchor("automations.appEventReasons")
    }

    private func binding(_ reason: AppEventReason) -> Binding<Bool> {
        Binding(
            get: { draft.reasons.contains(reason) },
            set: { on in
                if on { draft.reasons.insert(reason) } else { draft.reasons.remove(reason) }
            })
    }
}
