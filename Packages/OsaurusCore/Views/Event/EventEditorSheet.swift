//
//  EventEditorSheet.swift
//  osaurus
//
//  Add / edit one event: pick what fires it, optionally narrow when it
//  runs, pick what it does (an agent, a workflow, or one model answer), and
//  how fires are queued.
//

import AppKit
import SwiftUI

// MARK: - Source templates

/// The choices in "Add Automation": one per source kind the registry
/// offers, one per named webhook sender, one per channel platform.
enum EventSourceTemplate: Hashable, Identifiable {
    case source(EventSourceKind)
    /// A webhook from a known service, checked the way it signs.
    case providerWebhook(WebhookProvider)
    case channel(AgentChannelKind)

    static let schedule = EventSourceTemplate.source(.schedule)
    static let folder = EventSourceTemplate.source(.folder)
    static let webhook = EventSourceTemplate.source(.webhook)

    var id: String {
        switch self {
        case .source(let kind): kind.rawValue
        case .providerWebhook(let provider): "webhook.\(provider.rawValue)"
        case .channel(let kind): "channel.\(kind.rawValue)"
        }
    }

    static var all: [EventSourceTemplate] {
        triggers + providerWebhooks + AgentChannelKind.allCases.map { .channel($0) }
    }

    /// What "Add Automation" offers.
    static var triggers: [EventSourceTemplate] { EventSourceRegistry.pickerKinds.map { .source($0) } }

    /// "App webhooks" in "Add Automation".
    static var providerWebhooks: [EventSourceTemplate] { WebhookProvider.services.map { .providerWebhook($0) } }

    /// The template for a webhook from `provider`.
    static func webhook(_ provider: WebhookProvider) -> EventSourceTemplate {
        provider == .generic ? .webhook : .providerWebhook(provider)
    }

    var sourceKind: EventSourceKind {
        switch self {
        case .source(let kind): kind
        case .providerWebhook: .webhook
        case .channel: .channelMessage
        }
    }

    var title: String {
        switch self {
        case .source(let kind): kind.displayName
        case .providerWebhook(let provider): provider.shortName
        case .channel(let kind): kind.displayName
        }
    }

    var subtitle: String {
        switch self {
        case .providerWebhook(let provider): provider.templateSubtitle
        default: sourceKind.descriptor.subtitle
        }
    }

    var icon: String {
        switch self {
        case .source(let kind): kind.icon
        case .providerWebhook(let provider): provider.icon
        case .channel(let kind): kind.icon
        }
    }

    init(_ event: OsaurusEvent) {
        switch event.source {
        case .channelMessage(let m): self = .channel(m.kind)
        case .webhook(let w): self = .webhook(w.provider)
        default: self = .source(event.sourceKind)
        }
    }

    static func icon(for event: OsaurusEvent) -> String {
        EventSourceTemplate(event).icon
    }
}

// MARK: - Editor

struct EventEditorSheet: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var roster = WorkspaceRosterStore.shared
    @ObservedObject private var workflowStore = InstalledWorkflowStore.shared
    private var taskStore: TaskStore { .shared }

    let request: EventEditorRequest
    let onSave: (OsaurusEvent) -> Void
    let onCancel: () -> Void

    @State private var template: EventSourceTemplate?
    @State private var name = ""
    @State private var isEnabled = true
    @State private var sources = EventSourceDrafts()
    // Filter
    @State private var sendersText = ""
    @State private var keywordsAnyText = ""
    @State private var keywordsAllText = ""
    @State private var pathGlobsText = ""
    @State private var conditionsText = ""
    // Action
    @State private var actionKind: EventActionKind = .agent
    @State private var target: AgentDispatchTarget?
    @State private var instructions = ""
    @State private var workingFolderPath: String?
    @State private var workingFolderBookmark: Data?
    @State private var freshSession = true
    @State private var workflowId: UUID?
    @State private var inputMapping: [String: String] = [:]
    @State private var runAsAgentId: UUID?
    /// "Ask a Model": nil uses the default model.
    @State private var promptModel: String?
    // Queue / reply
    @State private var queueId = TaskQueue.defaultID
    @State private var allowOverlap = false
    @State private var maxConcurrent = 1
    @State private var maxQueued = 0
    @State private var dedupeWindow = 600
    @State private var missedFire: EventMissedFirePolicy = .runOnce
    @State private var steerRunningTurn = true
    @State private var autoReply = false
    @State private var replyWithWorkflowOutput = false

    @State private var validationError: String?
    @State private var hasLoaded = false

    private var isEditing: Bool { request.existing != nil }

    private var isChannelRule: Bool {
        if case .channel = template { return true }
        return false
    }

    private var headerTitle: String {
        if isChannelRule { return isEditing ? L("Edit Routing Rule") : L("Add Routing Rule") }
        return isEditing ? L("Edit Automation") : L("Add Automation")
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header
            if let template {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space.s12) {
                        basicsSection
                        sourceSection(template)
                        if template.sourceKind == .schedule
                            || !template.sourceKind.descriptor.filterClauses.isEmpty
                        {
                            filterSection(template)
                        }
                        actionSection(template)
                        deliverySection(template)
                        if case .channel = template { replySection }
                    }
                    .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            } else {
                sourcePicker
            }
        }
        .fittedSheetFrame(width: 640, height: 720)
        .background(theme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
        .onAppear(perform: load)
        .onChange(of: workflowId) { _, _ in prefillInputsIfEmpty() }
        .onChange(of: sources.webhook.provider) { _, provider in
            if template?.sourceKind == .webhook { template = .webhook(provider) }
        }
        .onDisappear { roster.endObserving() }
    }

    // MARK: Header / footer

    private var header: some View {
        var header = SettingsSheetHeader(
            icon: template?.icon ?? "bolt.fill",
            title: LocalizedStringKey(headerTitle),
            subtitleText: template.map { "\($0.title) — \($0.subtitle)" } ?? L("What should start it?"),
            onClose: onCancel
        )
        header.subtitleLineLimit = 1
        if template != nil, !isEditing, request.template == nil {
            header.accessory = AnyView(SettingsButton(.secondary, "Change Source", size: .compact) { template = nil })
        }
        return header
    }

    private var footer: some View {
        SettingsSheetFooter(
            primary: .init(
                label: isEditing ? "Save Changes" : (isChannelRule ? "Add Rule" : "Add Automation"), handler: save),
            secondary: .init(label: "Cancel", handler: onCancel),
            warning: validationError
        )
    }

    // MARK: Source picker

    /// The registry's triggers, then webhooks from named services. Channel
    /// messages are routed on the channel itself (Channels → the platform →
    /// Routing); a channel template only opens here when that table asks
    /// for the full editor.
    private var sourcePicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                templateGrid(EventSourceTemplate.triggers)

                VStack(alignment: .leading, spacing: theme.space.s8) {
                    Text("App Webhooks", bundle: .module)
                        .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    Text(
                        "A webhook already set up for the service's signature and setup check.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    templateGrid(EventSourceTemplate.providerWebhooks)
                }
                .settingsLandingAnchor("automations.appWebhooks")

                HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .glyphSize(.footnote)
                        .foregroundColor(theme.text.tertiary)
                    Text(
                        "Want an agent to answer messages on Slack, Discord or another channel? Add a routing rule on that channel in Channels.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, theme.settingsPageInset).padding(.vertical, theme.space.s24)
        }
    }

    private func templateGrid(_ options: [EventSourceTemplate]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: theme.space.s12)], spacing: theme.space.s12) {
            ForEach(options) { option in
                Button {
                    choose(option)
                } label: {
                    VStack(alignment: .leading, spacing: theme.space.s8) {
                        Image(systemName: option.icon)
                            .glyphSize(.large, weight: .semibold)
                            .foregroundColor(theme.text.link)
                            // Same box for every symbol, so titles line up.
                            .frame(width: 24, height: 22, alignment: .leading)
                        Text(option.title)
                            .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                            .foregroundColor(theme.text.primary)
                        Text(option.subtitle)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                    .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
                    .settingsChrome(.card)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Basics

    private var basicsSection: some View {
        EventEditorSection(title: isChannelRule ? L("Rule") : L("Automation"), icon: "info.circle.fill") {
            SettingsFieldRow(label: "Name") {
                SettingsTextField(
                    placeholder: isChannelRule ? L("e.g. Support triage") : L("e.g. Morning briefing"),
                    text: $name)
            }
            SettingsToggle(
                title: "Enabled",
                description: isChannelRule
                    ? "Off keeps the rule saved without routing messages."
                    : "Off keeps the automation saved without running it.",
                isOn: $isEnabled
            )
        }
    }

    // MARK: Source

    private func sourceSection(_ template: EventSourceTemplate) -> some View {
        EventEditorSection(title: L("When"), icon: template.icon) {
            EventSourceEditor(template: template, drafts: $sources)
        }
    }

    // MARK: Filter

    @ViewBuilder
    private func filterSection(_ template: EventSourceTemplate) -> some View {
        EventEditorSection(title: L("Only When (optional)"), icon: "line.3.horizontal.decrease.circle.fill") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                let clauses = template.sourceKind.descriptor.filterClauses
                if clauses.isEmpty {
                    Text("Schedules always run on time; no filter applies.", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                }
                if clauses.contains(.pathGlobs) {
                    labeled(L("Changed file matches (globs, comma separated)")) {
                        SettingsTextField(placeholder: "*.pdf, invoices/*", text: $pathGlobsText, icon: "doc")
                    }
                }
                if clauses.contains(.senders) {
                    labeled(L("Senders (ids or handles, comma separated)")) {
                        SettingsTextField(
                            placeholder: senderPlaceholder(template), text: $sendersText, icon: "person")
                    }
                }
                if clauses.contains(.keywords) { keywordFields }
                if clauses.contains(.conditions) {
                    labeled(L("Payload conditions (one per line: path = value)")) {
                        EventMultilineField(
                            text: $conditionsText, placeholder: conditionPlaceholder(template), minHeight: 50,
                            straightQuotes: true)
                    }
                }
            }
        }
    }

    private func senderPlaceholder(_ template: EventSourceTemplate) -> String {
        L("Anyone allowed by the connection")
    }

    private func conditionPlaceholder(_ template: EventSourceTemplate) -> String {
        template.sourceKind == .webhook
            ? "webhook.body.action = opened" : "\(template.sourceKind.descriptor.payloadRoot).field = value"
    }

    private var keywordFields: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            labeled(L("Text contains any of")) {
                SettingsTextField(placeholder: L("e.g. urgent, outage"), text: $keywordsAnyText, icon: "text.magnifyingglass")
            }
            labeled(L("Text contains all of")) {
                SettingsTextField(placeholder: L("e.g. invoice"), text: $keywordsAllText, icon: "text.magnifyingglass")
            }
        }
    }

    // MARK: Action

    @ViewBuilder
    private func actionSection(_ template: EventSourceTemplate) -> some View {
        EventEditorSection(title: L("Do"), icon: "play.circle.fill") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                AssignedBaseSegmentedPicker(
                    selection: $actionKind,
                    options: actionKinds(template).map { .init($0, $0.displayName, verbatim: true) }
                )
                .accessibilityLabel(Text("Do", bundle: .module))
                .settingsLandingAnchor("automations.action")

                switch actionKind {
                case .agent: agentActionFields(template)
                case .workflow: workflowActionFields(template)
                case .prompt: promptActionFields(template)
                }
            }
        }
    }

    /// A channel rule runs an agent or a workflow; it does not ask a model.
    private func actionKinds(_ template: EventSourceTemplate) -> [EventActionKind] {
        template.sourceKind == .channelMessage ? [.agent, .workflow] : EventActionKind.allCases
    }

    @ViewBuilder
    private func promptActionFields(_ template: EventSourceTemplate) -> some View {
        Text("One answer from a model, with no tools and no agent. It is saved as a chat.", bundle: .module)
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        labeled(L("Model")) {
            ModelSearchablePicker(
                items: WorkflowModelChoices.items(), selection: $promptModel, noneTitle: L("Default model"))
        }
        .settingsLandingAnchor("automations.promptModel")
        labeled(L("Instructions")) {
            EventMultilineField(
                text: $instructions,
                placeholder: L("e.g. Write one short motivational quote for today."),
                minHeight: 90)
        }
        EventTriggerValueInsertMenu(values: triggerValues(template)) { inserted in
            let separator = instructions.isEmpty || instructions.hasSuffix(" ") || instructions.hasSuffix("\n") ? "" : " "
            instructions += separator + inserted
        }
    }

    @ViewBuilder
    private func agentActionFields(_ template: EventSourceTemplate) -> some View {
        AgentPicker(
            selectedTarget: $target,
            agents: agentManager.agents.filter { !$0.isBuiltIn },
            workspaceAgents: WorkspaceAgentPickerOption.all(roster: roster)
        )
        labeled(
            template.sourceKind == .channelMessage
                ? L("Context placed ahead of each message (optional)") : L("Instructions")
        ) {
            EventMultilineField(
                text: $instructions,
                placeholder: template.sourceKind == .webhook
                    ? L("e.g. Triage this GitHub issue: {{webhook.body.issue.title}}")
                    : L("What should the agent do when this happens?"),
                minHeight: 90)
        }
        EventTriggerValueInsertMenu(values: triggerValues(template)) { inserted in
            let separator = instructions.isEmpty || instructions.hasSuffix(" ") || instructions.hasSuffix("\n") ? "" : " "
            instructions += separator + inserted
        }
        if template.sourceKind != .folder {
            EventFolderField(
                path: workingFolderPath, placeholder: L("Working folder (optional)"),
                onPick: { path, bookmark in
                    workingFolderPath = path
                    workingFolderBookmark = bookmark
                },
                onClear: {
                    workingFolderPath = nil
                    workingFolderBookmark = nil
                })
        }
        if template.sourceKind != .channelMessage {
            Toggle(L("Start a new chat every time"), isOn: $freshSession).settingsSwitch(showsLabel: true)
                .settingsCheckbox()
        }
    }

    @ViewBuilder
    private func workflowActionFields(_ template: EventSourceTemplate) -> some View {
        if workflowStore.workflows.isEmpty {
            Text("No workflows installed yet. Add one in Workflows.", bundle: .module)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.status.warning.foreground)
        } else {
            labeled(L("Workflow")) {
                SettingsMenuPicker(selection: $workflowId) {
                    Text("Choose a workflow", bundle: .module).tag(UUID?.none)
                    ForEach(workflowStore.workflows) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .fixedSize()
            }
            if let workflow = workflowId.flatMap(workflowStore.workflow(id:)) {
                let fields = WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema)
                if fields.isEmpty {
                    Text("This workflow takes no inputs.", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                } else {
                    WorkflowInputBindingEditor(
                        fields: fields,
                        schema: workflow.definition.inputSchema,
                        triggerValues: triggerValues(template),
                        samplePayload: samplePayload(template),
                        mapping: $inputMapping
                    )
                    .id(workflow.id)
                }
            }
            runAsPicker
        }
    }

    /// The agent whose keys and sessions the run uses; none uses the shared ones.
    private var runAsPicker: some View {
        EventEditorLabeled(
            L("Run as"), hint: L("Uses that agent's keys and sign-ins. No agent uses the shared ones.")
        ) {
            SettingsMenuPicker(selection: $runAsAgentId) {
                Text("No agent (shared keys)", bundle: .module).tag(UUID?.none)
                ForEach(agentManager.agents.filter { !$0.isBuiltIn }) { agent in
                    Text(agent.name).tag(UUID?.some(agent.id))
                }
                if let id = runAsAgentId, !agentManager.agents.contains(where: { $0.id == id }) {
                    Text("Missing agent", bundle: .module).tag(UUID?.some(id))
                }
            }
            .fixedSize()
        }
        .settingsLandingAnchor("automations.runAs")
    }

    private var inputFields: [String] {
        guard let id = workflowId, let workflow = workflowStore.workflow(id: id) else { return [] }
        return (workflow.definition.inputSchema.objectValue?["properties"]?.objectValue?.keys).map {
            $0.sorted()
        } ?? []
    }

    /// The values this trigger exposes, with examples from a sample run.
    private func triggerValues(_ template: EventSourceTemplate) -> [EventTriggerValue] {
        EventTriggerValues.catalog(for: template.sourceKind, sample: samplePayload(template))
    }

    /// One made-up occurrence of the automation as drafted.
    private func samplePayload(_ template: EventSourceTemplate) -> JSONValue {
        let source = sources.sample(template)
        let draft = OsaurusEvent(
            id: request.existing?.id ?? UUID(), name: name.isEmpty ? L("Automation") : name, source: source,
            action: .workflow(WorkflowEventAction(workflowID: workflowId ?? UUID())))
        return EventTriggerValues.samplePayload(for: draft)
    }

    /// A first mapping when a workflow is picked and nothing is bound yet.
    private func prefillInputsIfEmpty() {
        guard let template, let id = workflowId, let workflow = workflowStore.workflow(id: id) else { return }
        let fields = Set(inputFields)
        let current = inputMapping.filter { fields.contains($0.key) && !$0.value.isEmpty }
        guard current.isEmpty else { return }
        inputMapping = WorkflowInputBinding.prefill(
            schema: workflow.definition.inputSchema, sourceKind: template.sourceKind)
    }

    // MARK: Delivery / reply

    @ViewBuilder
    private func deliverySection(_ template: EventSourceTemplate) -> some View {
        EventEditorSection(title: L("Queue"), icon: "tray.full.fill") {
            if taskStore.hasMultipleQueues {
                SettingsRow(title: "Queue", description: L("Where its runs wait for a free slot")) {
                    SettingsMenuPicker(selection: $queueId) {
                        ForEach(taskStore.queues) { Text($0.name).tag($0.id) }
                    }
                }
            }
            if isConversationRelay(template) {
                Text(
                    "One reply at a time per conversation. Different conversations are answered side by side.",
                    bundle: .module
                )
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                SettingsRow(
                    title: "Queued Messages",
                    description: maxQueued == 0
                        ? L("Skip new messages while it's replying")
                        : L("Hold up to \(maxQueued) messages while it's replying"),
                    verbatimDescription: true
                ) {
                    SettingsStepper(value: $maxQueued, range: 0 ... EventDeliveryPolicy.maxQueuedCeiling)
                }
            } else {
                SettingsRow(
                    title: "Allow Overlapping Runs",
                    description: overlapDescription(template),
                    verbatimDescription: true
                ) {
                    Toggle("", isOn: $allowOverlap).settingsSwitch()
                }
            }
            if dedupesDurably(template) {
                SettingsRow(
                    title: "Duplicate Check",
                    description: L("Each item runs once, even after a restart"),
                    verbatimDescription: true
                ) {
                    EmptyView()
                }
            } else if template.sourceKind != .schedule {
                SettingsRow(
                    title: "Duplicate Check",
                    description: dedupeWindow == 0
                        ? L("No duplicate check") : L("Ignore repeats within \(dedupeWindow / 60) min"),
                    verbatimDescription: true
                ) {
                    SettingsStepper(value: dedupeMinutes, range: 0 ... 1440, step: 1, unit: "min")
                }
            }
            if template.sourceKind == .schedule {
                SettingsRow(title: "If the App Was Closed", description: "") {
                    SettingsMenuPicker(selection: $missedFire) {
                        ForEach(EventMissedFirePolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
            if isConversationRelay(template) {
                Toggle(L("Add follow-up messages to a running reply"), isOn: $steerRunningTurn)
                    .settingsSwitch(showsLabel: true)
            }
        }
    }

    private func overlapDescription(_ template: EventSourceTemplate) -> String {
        if !allowOverlap {
            return maxQueued == 0
                ? L("One run at a time; a fire while it runs is skipped")
                : L("One run at a time; later fires wait their turn")
        }
        return template.sourceKind.descriptor.usesConversationSessions
            ? L("Different conversations run side by side, each in order")
            : L("Up to \(max(maxConcurrent, 2)) runs at once")
    }

    private func deliveryMode(for template: EventSourceTemplate) -> EventDeliveryMode {
        if isConversationRelay(template) { return .perConversation }
        guard allowOverlap else { return .serial }
        return template.sourceKind.descriptor.usesConversationSessions ? .perConversation : .parallel
    }

    /// Kinds whose items carry a stable id dedupe on it for good, not in a window.
    private func dedupesDurably(_ template: EventSourceTemplate) -> Bool {
        template.sourceKind.descriptor.dedupeMode == .durable
    }

    private var dedupeMinutes: Binding<Int> {
        Binding(get: { dedupeWindow / 60 }, set: { dedupeWindow = $0 * 60 })
    }

    /// Channel messages that run an agent go through the conversation relay,
    /// which always keeps one turn per conversation.
    private func isConversationRelay(_ template: EventSourceTemplate) -> Bool {
        template.sourceKind == .channelMessage && actionKind == .agent
    }

    private var replySection: some View {
        EventEditorSection(title: L("Reply"), icon: "arrowshape.turn.up.left.fill") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                if actionKind == .agent {
                    Toggle(L("Send the agent's reply without asking"), isOn: $autoReply)
                        .settingsSwitch(showsLabel: true)
                    Text("Off: the reply waits for your approval in the chat.", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                } else {
                    Toggle(L("Send the workflow's output back to the conversation"), isOn: $replyWithWorkflowOutput)
                        .settingsSwitch(showsLabel: true)
                    Text(
                        "Reply steps in the workflow post on their own; when one has posted, the output is not sent again. A failed run still says so.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Helpers

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        EventEditorLabeled(title, content: content)
    }

    private func choose(_ option: EventSourceTemplate) {
        template = option
        let defaults = EventDeliveryPolicy.defaults(for: option.sourceKind)
        applyDelivery(defaults)
        freshSession = AgentEventAction.defaultFreshSession(for: option.sourceKind)
        switch option {
        case .channel(let kind):
            sources.channel.choose(kind)
            if name.isEmpty { name = L("\(kind.displayName) messages") }
        case .providerWebhook(let provider):
            sources.webhook.choose(provider)
            if name.isEmpty { name = L("\(provider.shortName) events") }
        case .source(.webhook):
            sources.webhook.choose(.generic)
        default:
            break
        }
    }

    private func applyDelivery(_ policy: EventDeliveryPolicy) {
        allowOverlap = policy.mode != .serial
        queueId = taskStore.resolvedQueue(policy.queueId).id
        maxConcurrent = policy.maxConcurrent
        maxQueued = policy.maxQueued
        dedupeWindow = Int(policy.dedupeWindowSeconds)
        missedFire = policy.missedFirePolicy
        steerRunningTurn = policy.steerRunningTurn
    }

    private func load() {
        roster.beginObserving()
        guard !hasLoaded else { return }
        hasLoaded = true
        if let initialAgentId = request.initialAgentId { target = .local(initialAgentId) }
        if let preset = request.template { choose(preset) }
        if let initialConnectionId = request.initialConnectionId, !initialConnectionId.isEmpty {
            sources.channel.connectionId = initialConnectionId
        }
        guard let event = request.existing else { return }
        template = EventSourceTemplate(event)
        name = event.name
        isEnabled = event.isEnabled
        sources.load(from: event.source)
        sendersText = event.filter.senderAllowlist.joined(separator: ", ")
        keywordsAnyText = event.filter.keywordsAny.joined(separator: ", ")
        keywordsAllText = event.filter.keywordsAll.joined(separator: ", ")
        pathGlobsText = event.filter.pathGlobs.joined(separator: ", ")
        conditionsText = event.filter.conditions.map { "\($0.path) = \($0.equals)" }.joined(separator: "\n")
        actionKind = event.action.kind
        switch event.action {
        case .agent(let a):
            target = a.target
            instructions = a.instructions
            workingFolderPath = a.folderPath
            workingFolderBookmark = a.folderBookmark
            freshSession = a.freshSessionPerFire
        case .workflow(let w):
            workflowId = w.workflowID
            inputMapping = w.inputMapping
            runAsAgentId = w.runAsAgentId
        case .prompt(let p):
            instructions = p.instructions
            promptModel = p.model
        }
        applyDelivery(event.delivery)
        autoReply = event.reply.autoReply
        replyWithWorkflowOutput = event.reply.replyWithWorkflowOutput
    }

    private func save() {
        switch build() {
        case .success(let event):
            validationError = nil
            onSave(event)
            // After the save: a provider change drops the old secret.
            if let secret = sources.webhook.secretToSave, event.sourceKind == .webhook {
                EventSecretsKeychain.saveSecret(secret, eventID: event.id)
            }
        case .failure(let message):
            withAnimation(theme.motion.quick) { validationError = message.text }
        }
    }

    private struct Message: Error {
        let text: String
    }

    private func build() -> Result<OsaurusEvent, Message> {
        guard let template else { return .failure(Message(text: L("Choose what starts the automation."))) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(Message(text: L("Name is required."))) }

        let source: EventSource
        switch sources.build(template, existing: request.existing?.source) {
        case .success(let built): source = built
        case .failure(let error): return .failure(Message(text: error.message))
        }

        var conditions: [EventCondition] = []
        for line in conditionsText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty else {
                return .failure(Message(text: L("Each condition needs the form path = value.")))
            }
            conditions.append(EventCondition(path: parts[0], equals: parts[1]))
        }
        let clauses = template.sourceKind.descriptor.filterClauses
        let filter = EventFilter(
            senderAllowlist: clauses.contains(.senders) ? Self.list(sendersText) : [],
            keywordsAny: clauses.contains(.keywords) ? Self.list(keywordsAnyText) : [],
            keywordsAll: clauses.contains(.keywords) ? Self.list(keywordsAllText) : [],
            pathGlobs: clauses.contains(.pathGlobs) ? Self.list(pathGlobsText) : [],
            conditions: clauses.contains(.conditions) ? conditions : [])

        let action: EventAction
        switch actionKind {
        case .agent:
            guard let target else { return .failure(Message(text: L("Choose the agent to run."))) }
            let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, template.sourceKind != .channelMessage {
                return .failure(Message(text: L("Instructions are required.")))
            }
            action = .agent(
                AgentEventAction(
                    target: target, instructions: trimmed,
                    folderPath: template.sourceKind == .folder ? nil : workingFolderPath,
                    folderBookmark: template.sourceKind == .folder ? nil : workingFolderBookmark,
                    freshSessionPerFire: template.sourceKind == .channelMessage ? false : freshSession))
        case .workflow:
            guard let workflowId else { return .failure(Message(text: L("Choose the workflow to run."))) }
            if let workflow = workflowStore.workflow(id: workflowId) {
                let declared = WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema)
                if let missing = WorkflowInputBinding.missingRequired(fields: declared, mapping: inputMapping).first {
                    return .failure(Message(text: L("Fill in \(missing.label): the workflow needs it.")))
                }
            }
            let fields = Set(inputFields)
            action = .workflow(
                WorkflowEventAction(
                    workflowID: workflowId,
                    inputMapping: inputMapping.filter { fields.contains($0.key) && !$0.value.isEmpty },
                    runAsAgentId: runAsAgentId))
        case .prompt:
            let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(Message(text: L("Instructions are required."))) }
            guard template.sourceKind != .channelMessage else {
                return .failure(Message(text: L("A routing rule runs an agent or a workflow.")))
            }
            action = .prompt(PromptEventAction(instructions: trimmed, model: promptModel))
        }

        let mode = deliveryMode(for: template)
        let delivery = EventDeliveryPolicy(
            mode: mode,
            maxConcurrent: mode == .parallel ? max(maxConcurrent, 2) : maxConcurrent, maxQueued: maxQueued,
            steerRunningTurn: steerRunningTurn,
            dedupe: dedupesDurably(template) ? .durable : .window(TimeInterval(dedupeWindow)),
            missedFirePolicy: missedFire,
            queueId: queueId == TaskQueue.defaultID ? nil : queueId)
        let reply = EventReplyPolicy(
            autoReply: template.sourceKind == .channelMessage && autoReply,
            replyWithWorkflowOutput: template.sourceKind == .channelMessage && replyWithWorkflowOutput)

        var event =
            request.existing
            ?? OsaurusEvent(name: trimmedName, source: source, action: action)
        event.name = trimmedName
        event.isEnabled = isEnabled
        event.source = source
        event.filter = filter
        event.action = action
        event.delivery = delivery
        event.reply = reply
        return .success(event)
    }

    private static func list(_ text: String) -> [String] {
        EventSourceDrafts.list(text)
    }
}

// MARK: - Small fields

struct EventMultilineField: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 80
    /// JSON or `path = value` text: macOS smart quotes would turn `"` into
    /// `“ ”` as you type, which no parser accepts.
    var straightQuotes = false

    var body: some View {
        SettingsTextEditor(text: $text, placeholder: placeholder, minHeight: minHeight, maxHeight: max(minHeight, 160))
            .onChange(of: text) { _, new in
                guard straightQuotes else { return }
                let straight = Self.straighteningQuotes(new)
                if straight != new { text = straight }
            }
    }

    static func straighteningQuotes(_ text: String) -> String {
        var out = text
        for curly in ["\u{201C}", "\u{201D}", "\u{201E}"] { out = out.replacingOccurrences(of: curly, with: "\"") }
        for curly in ["\u{2018}", "\u{2019}"] { out = out.replacingOccurrences(of: curly, with: "'") }
        return out
    }
}

struct EventFolderField: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let path: String?
    let placeholder: String
    let onPick: (String, Data?) -> Void
    let onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: path == nil ? "folder.badge.questionmark" : "folder.fill")
                .foregroundColor(path == nil ? theme.text.tertiary : theme.text.link)
            if let path {
                Text(path)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(placeholder)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.placeholder)
            }
            Spacer()
            if path != nil, let onClear {
                SettingsIconButton("xmark", help: "Remove", size: .compact, action: onClear)
            }
            Button(L("Browse"), action: pick)
                .buttonStyle(.plain)
                .componentInspectionText(50, role: .caption, fallback: .caption, weight: 500, theme: theme)
                .foregroundColor(theme.text.link)
        }
        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
        .settingsChrome(.control)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Select")
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            let bookmark = try? url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            onPick(url.path, bookmark)
        }
    }
}
