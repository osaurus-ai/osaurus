//
//  ShareWorkflowSheet.swift
//  osaurus
//
//  Sharing a workflow or agent template, start to finish. It opens on a choice: save a
//  `.osaurustemplate` file, or publish to store.osaurus.ai. Either
//  way, before anything leaves the Mac: what this Mac can add so the
//  template sets itself up elsewhere (the models it runs for open slots,
//  how to connect its MCP servers), who signs it, and the template as the
//  receiver will review it. Publishing adds who can see it (Public,
//  Unlisted, Password), then shows the live page with a card worth
//  posting, and hands over to the published workflow's dashboard
//  (`PublishedWorkflowDashboard`), which the sheet also opens straight
//  into for a workflow that is already live.
//
//  Adding suggestions changes the content, so the latest version of a
//  library template is saved as a new version first; an install pinned to
//  it moves along. Older versions export as they are.
//
//  Publishing an agent template also gives the workflows it bundles that
//  are yours their own pages, with the agent's visibility, so its page
//  links to each (`TemplateCascadePlan`); the publish step lists what
//  happens to each one.
//
//  Published templates are always signed with the master key, so
//  publishing needs an Osaurus ID. Built-in templates aren't the user's to
//  sign, so they only take the file path (`publishable: false`).
//

import SwiftUI

struct ShareWorkflowSheet: View {
    /// Where the sheet opens.
    enum Entry: Equatable {
        case choose
        case file
        case publish
        case manage
    }

    @Environment(\.theme) private var theme

    let template: Template
    /// The install's bindings, when sharing an installed workflow.
    var bindings: InstallBindings? = nil
    var entry: Entry = .choose
    /// False for templates that only export as a file.
    let canPublish: Bool
    let onDone: () -> Void

    @AppStorage("templateExport.sign") private var signPreferred = true
    @ObservedObject private var registryRecords = WorkflowRegistryRecordStore.shared
    @ObservedObject private var osaurusID = OsaurusIDService.shared

    /// The version being shared: the one the sheet opened on, or the
    /// library's latest when the dashboard asked to publish it.
    @State private var current: Template
    @State private var phase: Phase
    /// Whether Back from file/publish returns to the chooser or dashboard.
    @State private var origin: Entry
    @State private var confirmTakeDown = false
    @State private var isTakingDown = false
    @State private var suggestModels = true
    @State private var includeServers = true
    @State private var models: [String: String] = [:]
    @State private var hints: [MCPServerHint] = []
    @State private var visibility: WorkflowVisibility = .public
    @State private var password = ""
    @State private var workspaceIDs: Set<String> = []
    @State private var isWriting = false
    @State private var failure: String?
    @State private var hasAppeared = false
    /// The library version a publish saved, so a retry publishes it again
    /// instead of saving another.
    @State private var savedForShare: Template?
    @State private var shareCard: NSImage?
    @State private var retryingVisibility = false
    /// For an agent: also publish the workflows it bundles that are yours.
    @State private var publishWorkflows = true
    /// One of the agent's workflows whose page the user asked to take down.
    @State private var workflowToTakeDown: Template?
    @State private var takingDownWorkflowID: UUID?
    /// What the listing shows, set before publishing and applied right after.
    @State private var listingName = ""
    @State private var listingSummary = ""
    @State private var topics: [ListingTopic] = []
    @State private var examples: [ListingExampleDraft] = []
    @State private var confirmExamples = false
    /// The listing edits sent with the last publish, to retry what failed.
    @State private var sentListing: ListingEdits?
    @State private var retryingListing = false

    private enum Phase: Equatable {
        case choose
        case file
        case publish
        case publishing
        case live(WorkflowShareOutcome)
        case failure(message: String, hint: String?, latestVersion: Int?)
        case manage

        var key: String {
            switch self {
            case .choose: return "choose"
            case .file: return "file"
            case .publish: return "publish"
            case .publishing: return "publishing"
            case .live: return "live"
            case .failure: return "failure"
            case .manage: return "manage"
            }
        }
    }

    init(
        template: Template, bindings: InstallBindings? = nil, entry: Entry = .choose, publishable: Bool = true,
        onDone: @escaping () -> Void
    ) {
        self.template = template
        self.bindings = bindings
        self.entry = entry
        self.canPublish = publishable
        self.onDone = onDone
        let start: Entry = publishable ? entry : .file
        _current = State(initialValue: template)
        _origin = State(initialValue: start)
        switch start {
        case .choose: _phase = State(initialValue: .choose)
        case .file: _phase = State(initialValue: .file)
        case .publish: _phase = State(initialValue: .publish)
        case .manage: _phase = State(initialValue: .manage)
        }
    }

    // MARK: - Derived

    private var canSign: Bool { MasterKey.exists() }
    private var signs: Bool { canSign && signPreferred }
    private var isAgent: Bool { template.kind == .agent }
    private var record: WorkflowRegistryRecord? { registryRecords.record(for: template.id) }
    private var isLive: Bool { record?.isLive == true }

    private var outgoing: Template {
        var t = current
        if suggestModels { t = TemplateShareOptions.withSuggestedModels(t, models) }
        if includeServers { t = TemplateShareOptions.withHints(t, hints) }
        return t
    }

    /// Content changes are saved as a new version only from the latest one.
    private var savesNewVersion: Bool {
        outgoing.contentHash != current.contentHash
            && TemplateStore.shared.latest(id: current.id)?.version == current.version
    }

    /// The version a publish would make live.
    private var shareVersion: Int {
        if let savedForShare { return savedForShare.version }
        return savesNewVersion ? current.version + 1 : current.version
    }

    /// The author is the claimed Osaurus ID (`@handle`), never a typed name.
    /// Nil until a handle is claimed in Identity settings; the signature
    /// still carries the address.
    private var authorName: String? { osaurusID.claimedHandle.map { "@" + $0 } }

    /// A live page keeps its visibility over a republish; the dashboard changes it.
    private var effectiveVisibility: WorkflowVisibility { isLive ? (record?.visibility ?? visibility) : visibility }

    /// What publishing the agent would do for its workflows. The address is
    /// the one this Mac last signed with; the publish itself recomputes the
    /// plan with the key it reads.
    private var cascadePlan: TemplateCascadePlan {
        TemplateCascadePlan.make(
            template: savedForShare ?? outgoing, visibility: effectiveVisibility,
            ownAddress: OsaurusRouterWalletCache.lastSignedAddress ?? registryRecords.records.first?.address,
            record: { registryRecords.record(for: $0) },
            isBuiltIn: WorkflowShareService.isBuiltInTemplate)
    }

    private var passwordOK: Bool { visibility != .password || WorkflowVisibility.isValidPassword(password) }

    /// A new Workspace listing needs at least one workspace; a live one
    /// keeps its own and changes them from the dashboard.
    private var workspacesOK: Bool {
        effectiveVisibility != .workspace || isLive
            || WorkflowVisibility.isValidWorkspaceSelection(Array(workspaceIDs))
    }

    /// The template's own name and summary, as the listing shows them
    /// until the publisher writes their own.
    private var templateDetails: (name: String, summary: String) {
        let t = savedForShare ?? outgoing
        return (t.name, (t.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A live listing that already has examples keeps them; they change
    /// from its dashboard, where they can be seen and removed one by one.
    private var editsExamplesHere: Bool { !(isLive && (record?.exampleCount ?? 0) > 0) }

    /// What the publish changes on the listing beside the template.
    private var listingEdits: ListingEdits {
        let template = templateDetails
        let shown = (record?.listingName ?? template.name, record?.listingSummary ?? template.summary)
        return ListingEdits(
            details: ListingEdits.details(
                name: listingName, summary: listingSummary, template: template, shown: shown,
                edited: record?.listingName != nil),
            topics: topics == (record?.topics ?? []) ? nil : topics,
            examples: editsExamplesHere && !examples.isEmpty ? examples : nil)
    }

    private var listingOK: Bool { ListingEdits.isValid(name: listingName, summary: listingSummary) }

    /// The chooser is two rows and a taken-down page has no visibility or
    /// link section; the rest of the flow needs the full height.
    private var sheetHeight: CGFloat {
        switch phase {
        case .choose: return 340
        case .file: return 640
        case .manage: return isLive ? 680 : 480
        default: return 680
        }
    }

    /// `@handle` from the registry when known, else the claimed Osaurus ID,
    /// else the short address.
    private func handle(for record: WorkflowRegistryRecord) -> String {
        if let h = record.authorHandle, h.hasPrefix("@") { return h }
        if let claimed = osaurusID.claimedHandle { return "@" + claimed }
        return record.authorHandle ?? SharedAgentIdentity.shortAddress(record.address)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(icon: headerIcon, title: headerTitle, subtitleText: template.name, onClose: onDone)
            Group {
                if case .manage = phase {
                    PublishedWorkflowDashboard(
                        template: template,
                        onPublish: { latest in
                            current = latest
                            savedForShare = nil
                            origin = .manage
                            resetListingFields()
                            go(.publish)
                        },
                        onSaveAsFile: {
                            origin = .manage
                            go(.file)
                        },
                        confirmTakeDown: $confirmTakeDown,
                        isTakingDown: isTakingDown,
                        onTakeDownWorkflow: { workflowToTakeDown = $0 },
                        takingDownWorkflowID: takingDownWorkflowID,
                        onRevise: isAgent
                            ? nil
                            : {
                                onDone()
                                PublishReviewRouter.revise(templateID: template.id, kind: .workflow)
                            }
                    )
                } else {
                    ScrollView {
                        Group {
                            switch phase {
                            case .choose: chooser
                            case .file: fileOptions
                            case .publish: publishOptions
                            case .publishing: publishingView
                            case .live(let outcome): liveView(outcome)
                            case .failure(let message, let hint, _): failureView(message: message, hint: hint)
                            case .manage: EmptyView()
                            }
                        }
                        .padding(theme.space.s16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(phase.key)
            .transition(.opacity.combined(with: .offset(y: 8)))
            footer
        }
        .animation(theme.motion.quick, value: phase.key)
        .fittedSheetFrame(width: 640, height: sheetHeight)
        .animation(theme.motion.standard, value: sheetHeight)
        .settingsSheetSurface()
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
        .opacity(hasAppeared ? 1 : 0)
        .animation(theme.motion.quick, value: hasAppeared)
        // `.contained`: the central alert host sits behind this sheet's window.
        .themedAlert(
            WorkflowShareCopy.takeDownTitle(template.kind),
            isPresented: $confirmTakeDown,
            message: WorkflowShareCopy.unpublishMessage(template.name),
            primaryButton: .destructive(L("Take Down"), action: takeDown),
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
        .themedAlert(
            WorkflowShareCopy.takeDownTitle(.workflow),
            isPresented: Binding(get: { workflowToTakeDown != nil }, set: { if !$0 { workflowToTakeDown = nil } }),
            message: WorkflowShareCopy.unpublishMessage(workflowToTakeDown?.name ?? ""),
            primaryButton: .destructive(L("Take Down"), action: takeDownWorkflow),
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
        .themedAlert(
            ListingCopy.consentTitle(examples.count),
            isPresented: $confirmExamples,
            message: ListingCopy.consentMessage(
                images: examples.reduce(0) { $0 + $1.includedImages.count }, visibility: effectiveVisibility),
            primaryButton: .primary(L("Share and Publish"), action: { publish() }),
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
        .onAppear {
            hasAppeared = true
            models = TemplateShareOptions.suggestableModels(template, bindings: bindings)
            hints = TemplateShareOptions.suggestableHints(
                template, servers: TemplateShareOptions.liveServers(for: template, bindings: bindings),
                directory: MCPProviderTemplate.allTemplates)
            if let record {
                visibility = record.visibility
                workspaceIDs = Set(record.workspaceIDs)
            }
            resetListingFields()
        }
    }

    private var headerIcon: String {
        switch phase {
        case .choose: return "square.and.arrow.up"
        case .file: return "doc.badge.arrow.up"
        case .publish, .publishing, .failure: return "globe"
        case .live: return "checkmark.seal"
        case .manage: return "globe"
        }
    }

    private var headerTitle: LocalizedStringKey {
        switch phase {
        case .choose: return canPublish ? (isAgent ? "Share Template" : "Share Workflow") : "Export Template"
        case .file: return canPublish ? "Save as File" : "Export Template"
        case .publish, .publishing, .failure: return isAgent ? "Publish Template" : "Publish Workflow"
        case .live(let outcome):
            let record = registryRecords.record(for: outcome.record.templateID) ?? outcome.record
            return outcome.published.review != nil && PublishReviewState(record: record).isUnderReview
                ? "Submitted" : "Published"
        case .manage: return "Published"
        }
    }

    private func go(_ next: Phase) {
        failure = nil
        phase = next
    }

    private func back() {
        switch origin {
        case .manage: go(.manage)
        default: go(.choose)
        }
    }

    private var hasBack: Bool {
        guard canPublish else { return false }
        switch phase {
        case .file, .publish: return origin == .choose || origin == .manage
        default: return false
        }
    }

    // MARK: - Choose

    private var chooser: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            ShareOptionRow(
                icon: "doc.badge.arrow.up", title: L("Save as a file"),
                detail: L("A .osaurustemplate anyone can review and install. No account needed."),
                action: {
                    origin = .choose
                    go(.file)
                })
            if let record, record.isLive {
                ShareOptionRow(
                    icon: record.visibility.symbol, title: L("Published on store.osaurus.ai"),
                    detail: liveSummary(record),
                    action: { go(.manage) })
            } else if let record, record.removedByAdmin {
                ShareOptionRow(
                    icon: "exclamationmark.triangle", title: L("Removed from store.osaurus.ai"),
                    detail: L("The Osaurus team took this down. It can't be published again."),
                    isEnabled: false, action: {})
            } else {
                ShareOptionRow(
                    icon: "globe", title: L("Publish to store.osaurus.ai"),
                    detail: canSign
                        ? L("A page with a link, signed with your Osaurus ID. You choose who can see it and can update or take it down.")
                        : L("Needs an Osaurus ID. It signs what you publish so people know who made it."),
                    action: {
                        origin = .choose
                        go(.publish)
                    }
                ) {
                    if !canSign {
                        Button {
                            onDone()
                            AppDelegate.shared?.showManagementWindow(initialTab: .identity)
                        } label: {
                            Text("Open Identity Settings", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.secondary, size: .compact)
                    }
                }
                .settingsLandingAnchor(isAgent ? nil : "workflows.publish")
            }
        }
        .settingsLandingAnchor(isAgent ? "agents.templates.share" : "workflows.share")
    }

    private func liveSummary(_ record: WorkflowRegistryRecord) -> String {
        var parts = [L("Version \(record.registryLatestVersion ?? record.version)"), record.visibility.title]
        if let installs = record.installCount {
            parts.append(installs == 1 ? L("1 install") : L("\(installs) installs"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - File

    private var fileOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            Text("Saves a .osaurustemplate file you can send to someone.", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
            if !models.isEmpty || !hints.isEmpty { suggestions }
            if canSign { signing }
            review(L("What they'll review"))
            failureLine
        }
    }

    // MARK: - Publish

    private var publishOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            if !canSign { needsIdentity }
            listingSection
            if !models.isEmpty || !hints.isEmpty { suggestions }
            whoCanSeeIt
            if isAgent { alsoPublishes }
            if canSign || record != nil { publishAuthor }
            review(L("What everyone will see"))
            failureLine
        }
    }

    private var listingSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s10) {
                SettingsFieldLabel("Listing Details")
                ListingDetailsFields(
                    name: $listingName, summary: $listingSummary, kind: template.kind,
                    templateName: templateDetails.name, templateSummary: templateDetails.summary)
            }
            .settingsLandingAnchor(isAgent ? "agents.templates.listingDetails" : "workflows.listingDetails")
            VStack(alignment: .leading, spacing: theme.space.s10) {
                SettingsFieldLabel("Topics")
                ListingTopicPicker(selection: $topics)
            }
            .settingsLandingAnchor(isAgent ? "agents.templates.topics" : "workflows.topics")
            VStack(alignment: .leading, spacing: theme.space.s10) {
                SettingsFieldLabel("Example Runs")
                if editsExamplesHere {
                    ListingExamplesEditor(
                        template: savedForShare ?? current, examples: $examples, latestVersion: shareVersion)
                } else {
                    let count = record?.exampleCount ?? 0
                    Text(
                        verbatim: count == 1
                            ? L("1 example run is on its page. Change it from its dashboard.")
                            : L("\(count) example runs are on its page. Change them from its dashboard."))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsLandingAnchor(isAgent ? "agents.templates.exampleRuns" : "workflows.exampleRuns")
        }
    }

    private var whoCanSeeIt: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            SettingsFieldLabel("Who can see it")
            ForEach(WorkflowVisibility.allCases, id: \.self) { option in
                ShareOptionRow(
                    icon: option.symbol, title: option.title, detail: option.detail,
                    isSelected: visibility == option,
                    action: { withAnimation(theme.motion.quick) { visibility = option } })
            }
            if visibility == .password {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    SettingsTextField(
                        placeholder: L("Password"), text: $password, icon: "lock", isSecure: true, revealable: true,
                        autofocus: true)
                    Text(
                        L("\(WorkflowVisibility.passwordLength.lowerBound) to \(WorkflowVisibility.passwordLength.upperBound) characters. You can change it later.")
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                }
                .padding(.leading, theme.space.s2)
                .transition(.opacity)
            }
            if visibility == .workspace, !isLive {
                WorkspaceShareChooser(selection: $workspaceIDs)
                    .transition(.opacity)
                    .settingsLandingAnchor(isAgent ? "agents.templates.workspaces" : "workflows.shareWorkspaces")
            }
            if effectiveVisibility == .public { publicReviewNote }
            if let record, record.isLive, record.visibility != visibility {
                Text(
                    L("It's \(record.visibility.title) now. Change who can see it from its dashboard after publishing.")
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsLandingAnchor(isAgent ? "agents.templates.visibility" : "workflows.visibility")
    }

    /// Public goes through store review; say what that means before Submit.
    private var publicReviewNote: some View {
        let listed = record.flatMap { PublishReviewState(record: $0).listedVersion }
        return Label {
            Text(
                verbatim: listed.map {
                    L("The Osaurus team reviews this update before it replaces version \($0) in the store. Your link keeps working meanwhile.")
                } ?? PublishReviewState.publicReviewNote
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
                .glyphSize(.caption)
                .foregroundColor(theme.status.info.foreground)
        }
        .padding(.leading, theme.space.s2)
        .transition(.opacity)
    }

    @ViewBuilder
    private var alsoPublishes: some View {
        let plan = cascadePlan
        if !plan.isEmpty {
            let agentVisibility = effectiveVisibility
            VStack(alignment: .leading, spacing: theme.space.s10) {
                SettingsFieldLabel("Also publishes")
                if plan.mayPublish, let shared = plan.visibility {
                    option(
                        $publishWorkflows, title: L("Give my workflows their own pages"),
                        detail: L("\(shared.title), like the agent, so its page links to each one. Taking the agent down leaves them up."))
                }
                CascadeWorkflowList(items: plan.rows) { row in
                    let shown = !publishWorkflows && row.state == .willPublish ? .bundledOnly(.turnedOff) : row.state
                    CascadeWorkflowRow(
                        name: row.template.name, version: row.template.version,
                        chip: TemplateCascadeCopy.chip(shown, agentVisibility: agentVisibility),
                        detail: TemplateCascadeCopy.detail(
                            TemplateCascadePlan.Row(template: row.template, state: shown, record: row.record),
                            agentVisibility: agentVisibility, visibility: plan.visibility)
                    ) { EmptyView() }
                }
            }
            .settingsLandingAnchor("agents.templates.publishWorkflows")
        }
    }

    private var needsIdentity: some View {
        HStack(alignment: .top, spacing: theme.space.s10) {
            Image(systemName: "person.badge.key")
                .glyphSize(.body)
                .foregroundColor(theme.status.warning.foreground)
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text(
                    "Publishing needs an Osaurus ID. It signs what you publish so people know who made it.",
                    bundle: .module
                )
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    onDone()
                    AppDelegate.shared?.showManagementWindow(initialTab: .identity)
                } label: {
                    Text("Open Identity Settings", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.warning))
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            SettingsFieldLabel("Make it easier to set up")
            if !models.isEmpty {
                option(
                    $suggestModels, title: L("Suggest the models I use"),
                    detail: models.keys.sorted().map { "\($0): \(WorkflowModelChoices.displayName(models[$0] ?? ""))" }
                        .joined(separator: " · "))
            }
            if !hints.isEmpty {
                option(
                    $includeServers, title: L("Include how to connect my MCP servers"),
                    detail: L("\(hints.map(\.name).joined(separator: ", ")). Addresses and commands only; keys, tokens, and passwords stay on this Mac."))
            }
            if savesNewVersion && savedForShare == nil {
                Text(
                    L("Saved as version \(current.version + 1) of \(current.name) so the file and your library match.")
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signing: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            SettingsFieldLabel("Author")
            option(
                $signPreferred, title: L("Sign with my Osaurus ID"),
                detail: authorName.map { L("Named \($0). The receiver sees the file came from you and hasn't been changed since.") }
                    ?? L("The receiver sees the file came from you and hasn't been changed since."))
        }
    }

    private var publishAuthor: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            if canSign {
                SettingsFieldLabel("Author")
                Text(
                    L("Published as \(authorName ?? L("your Osaurus ID")), signed so the page shows it came from you.")
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let record, record.isLive {
                Text(
                    L(
                        "Version \(record.registryLatestVersion ?? record.version) is live. Publishing replaces it with version \(shareVersion) at the same link."
                    )
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else if let record, record.takenDown {
                Text("Publishing again brings the same link back.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
        }
    }

    private func review(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(verbatim: label)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
            TemplateImportReviewView(template: TemplateExportSanitizer.sanitized(outgoing))
        }
    }

    @ViewBuilder
    private var failureLine: some View {
        if let failure {
            Text(verbatim: failure)
                .font(SettingsFont.caption)
                .foregroundColor(theme.status.error.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ isOn: Binding<Bool>, title: String, detail: String) -> some View {
        SettingsToggle(title: title, description: detail, verbatim: true, isOn: isOn)
            .environment(\.settingsInGroup, true)
    }

    // MARK: - Publishing / live / failure

    private var publishingView: some View {
        VStack(spacing: theme.space.s14) {
            Spacer().frame(height: 60)
            Text(effectiveVisibility == .public ? "Submitting…" : "Publishing…", bundle: .module)
                .font(SettingsFont.cardTitle)
                .foregroundColor(theme.text.primary)
            Text("You may be asked to authenticate to sign it.", bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
            SettingsStepTracker(steps: PublishReviewState.publishingSteps(visibility: effectiveVisibility))
                .padding(.top, theme.space.s16)
        }
        .frame(maxWidth: .infinity)
    }

    private func liveView(_ outcome: WorkflowShareOutcome) -> some View {
        let published = outcome.published
        let record = registryRecords.record(for: outcome.record.templateID) ?? outcome.record
        let review = PublishReviewState(record: record)
        // Went to review; stays the review story when the decision lands here.
        let submitted = published.review != nil && record.isLive && record.visibility == .public
        let subline = [
            L("Published by \(handle(for: record))"), L("Version \(published.version)"),
            review.isUnlistedUntilApproved ? L("Unlisted until approved") : record.visibility.title,
        ].joined(separator: " · ")
        return VStack(alignment: .leading, spacing: theme.space.s20) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Image(systemName: submitted ? statusGlyph(review) : "checkmark.seal.fill")
                    .glyphSize(.display)
                    .foregroundColor(submitted ? statusTint(review) : theme.status.success.foreground)
                Text(verbatim: submitted ? submittedTitle(review, name: listedName(record)) : L("\(listedName(record)) is live."))
                    .font(SettingsFont.pageTitle)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: subline)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            }
            .padding(.top, theme.space.s8)

            if submitted {
                VStack(alignment: .leading, spacing: theme.space.s14) {
                    SettingsStepTracker(steps: review.steps(uploadedVersion: published.version))
                    Text(verbatim: review.detail())
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if review.phase == .inReview {
                        Label {
                            Text("Osaurus lets you know as soon as it's decided, even if you close this.", bundle: .module)
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                        } icon: {
                            Image(systemName: "bell.badge")
                                .glyphSize(.footnote)
                                .foregroundColor(theme.text.tertiary)
                        }
                    }
                }
                .padding(theme.space.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.card)
                .settingsLandingAnchor(isAgent ? "agents.templates.review" : "workflows.review")
            }

            if let error = outcome.visibilityError {
                HStack(alignment: .top, spacing: theme.space.s10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .glyphSize(.label)
                        .foregroundColor(theme.status.warning.foreground)
                    VStack(alignment: .leading, spacing: theme.space.s6) {
                        Text(
                            visibility == .workspace
                                ? "Published as Unlisted. Sharing with the workspaces didn't go through."
                                : "Published as Unlisted. The password didn't save.",
                            bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        Text(verbatim: error.localizedDescription)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            retryVisibility(outcome)
                        } label: {
                            Text("Try Again", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.secondary, isLoading: retryingVisibility, size: .compact)
                        .disabled(retryingVisibility)
                    }
                }
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.status(.warning))
            }

            VStack(alignment: .leading, spacing: theme.space.s10) {
                if let shareCard {
                    Image(nsImage: shareCard)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.subtle, lineWidth: theme.stroke.default)
                        )
                } else {
                    Color.clear
                        .aspectRatio(WorkflowShareCardView.size.width / WorkflowShareCardView.size.height, contentMode: .fit)
                        .settingsChrome(.subtle, radius: theme.radius.large)
                        .overlay(SettingsSpinner())
                }
                ShareCardActions(image: shareCard, pageURL: published.url, suggestedName: "\(published.slug)-card.png")
            }
            .onAppear { renderShareCard(record: record) }

            VStack(alignment: .leading, spacing: theme.space.s10) {
                SettingsFieldLabel("Link")
                HStack(alignment: .top, spacing: theme.space.s14) {
                    VStack(alignment: .leading, spacing: theme.space.s10) {
                        ShareCopyRow(label: L("Page"), value: published.url.absoluteString)
                        Button {
                            NSWorkspace.shared.open(published.url)
                        } label: {
                            Label { Text("Open Page", bundle: .module) } icon: { Image(systemName: "safari") }
                        }
                        .assignedSettingsButtonStyle(.secondary, size: .compact)
                    }
                    ShareQRCardView(text: published.url.absoluteString)
                        .frame(width: 96, height: 96)
                }
            }

            if let listing = outcome.listing {
                ListingEditsStatusView(result: listing, isRetrying: retryingListing) { retryListing(outcome) }
            }

            if !outcome.cascade.isEmpty { cascadeResults(outcome) }

            DisclosureGroup {
                VStack(spacing: theme.space.s10) {
                    ShareCopyRow(label: L("Install Link"), value: published.deepLink.absoluteString)
                    ShareCopyRow(label: L("Template File"), value: published.rawURL.absoluteString)
                    ShareCopyRow(label: L("Registry ID"), value: published.id)
                }
                .padding(.top, theme.space.s8)
            } label: {
                Text("Advanced details", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
            }
            .tint(theme.text.secondary)

            Text(liveFootnote(review.isUnlistedUntilApproved ? .hidden : record.visibility))
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cascadeResults(_ outcome: WorkflowShareOutcome) -> some View {
        let agentVisibility = outcome.record.visibility
        return VStack(alignment: .leading, spacing: theme.space.s10) {
            SettingsFieldLabel("Workflows it brings")
            CascadeWorkflowList(items: outcome.cascade) { result in
                let version = result.record.map { $0.registryLatestVersion ?? $0.version }
                    ?? (savedForShare ?? outgoing).bundled.first { $0.id == result.templateID }?.version ?? 1
                CascadeWorkflowRow(
                    name: result.name, version: version,
                    chip: TemplateCascadeCopy.chip(result.status, agentVisibility: agentVisibility),
                    detail: TemplateCascadeCopy.detail(result.status, agentVisibility: agentVisibility)
                ) {
                    if let page = result.record, page.isLive {
                        Button {
                            NSWorkspace.shared.open(page.url)
                        } label: {
                            Text("Open Page", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.secondary, size: .compact)
                    }
                }
            }
        }
    }

    private func statusGlyph(_ review: PublishReviewState) -> String {
        switch review.phase {
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .listed: return "checkmark.seal.fill"
        default: return "paperplane.circle.fill"
        }
    }

    private func statusTint(_ review: PublishReviewState) -> Color {
        switch review.phase {
        case .changesRequested: return theme.status.warning.foreground
        case .listed: return theme.status.success.foreground
        default: return theme.status.info.foreground
        }
    }

    /// The live view follows the decision if it lands while the sheet is up.
    private func submittedTitle(_ review: PublishReviewState, name: String) -> String {
        switch review.phase {
        case .changesRequested: return L("Changes requested on \(name).")
        case .listed: return L("\(name) is in the store.")
        default: return L("\(name) is submitted for review.")
        }
    }

    private func liveFootnote(_ visibility: WorkflowVisibility) -> String {
        if visibility == .workspace {
            return isAgent
                ? L("Members of its workspaces can see its instructions and tools and install it from the workspace's Workflows page. Secret values and local paths were left out.")
                : L("Members of its workspaces can see every step and install it from the workspace's Workflows page. Secret values, saved answers, and local paths were left out.")
        }
        switch (isAgent, visibility == .public) {
        case (true, true):
            return L("Anyone can find it, see its instructions and tools, and install it. Secret values and local paths were left out.")
        case (true, false):
            return L("Anyone with the link can see its instructions and tools and install it. Secret values and local paths were left out.")
        case (false, true):
            return L("Anyone can find it, see every step, and install it. Secret values, saved answers, and local paths were left out.")
        case (false, false):
            return L("Anyone with the link can see every step and install it. Secret values, saved answers, and local paths were left out.")
        }
    }

    private func failureView(message: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .glyphSize(.medium)
                    .foregroundColor(theme.status.error.foreground)
                Text("Publishing didn't finish", bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
            }
            Text(verbatim: message)
                .font(SettingsFont.body)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(verbatim: hint)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .textSelection(.enabled)
                    .padding(.horizontal, theme.space.s8)
                    .padding(.vertical, theme.space.s4)
                    .settingsChrome(.inset)
            }
        }
    }

    // MARK: - Footer

    private var footer: SettingsSheetFooter {
        let cancel = SettingsSheetFooter.Action(label: "Cancel", handler: onDone)
        let backOrCancel = hasBack ? SettingsSheetFooter.Action(label: "Back", handler: back) : cancel
        switch phase {
        case .choose:
            return SettingsSheetFooter(primary: nil, secondary: cancel)
        case .file:
            return SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: "Save…", isEnabled: !isWriting, isLoading: isWriting, handler: export),
                secondary: backOrCancel)
        case .publish:
            return SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: LocalizedStringKey(publishButtonLabel),
                    isEnabled: canSign && passwordOK && workspacesOK && listingOK,
                    handler: requestPublish),
                secondary: backOrCancel)
        case .publishing:
            return SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: LocalizedStringKey(publishButtonLabel), isEnabled: false, isLoading: true, handler: {}),
                secondary: nil)
        case .live:
            return SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(label: "Done", handler: onDone),
                secondary: SettingsSheetFooter.Action(label: "Manage", handler: { go(.manage) }))
        case .failure(_, _, let latest?):
            let next = nextVersion(afterPublished: latest)
            return SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: LocalizedStringKey(L("Publish as Version \(next)")), handler: { publish(asVersion: next) }),
                secondary: cancel)
        case .failure:
            return SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(label: "Try Again", handler: { publish() }),
                secondary: cancel)
        case .manage:
            if let record, record.takenDown, !record.removedByAdmin {
                return SettingsSheetFooter(
                    primary: SettingsSheetFooter.Action(
                        label: "Publish Again",
                        handler: {
                            current = TemplateStore.shared.latest(id: template.id) ?? template
                            savedForShare = nil
                            origin = .manage
                            resetListingFields()
                            go(.publish)
                        }),
                    secondary: SettingsSheetFooter.Action(label: "Done", handler: onDone))
            }
            return SettingsSheetFooter(primary: SettingsSheetFooter.Action(label: "Done", handler: onDone), secondary: nil)
        }
    }

    private var publishButtonLabel: String {
        guard let record, record.isLive else {
            return WorkflowShareCopy.publishLabel(version: nil, record: nil, visibility: effectiveVisibility)
        }
        if (record.registryLatestVersion ?? record.version) == shareVersion { return L("Publish Again") }
        return WorkflowShareCopy.publishLabel(version: shareVersion, record: record, visibility: effectiveVisibility)
    }

    // MARK: - Actions

    /// The name the listing shows: the publisher's own, or the template's.
    private func listedName(_ record: WorkflowRegistryRecord) -> String {
        registryRecords.record(for: record.templateID)?.listingName ?? record.listingName ?? template.name
    }

    private func resetListingFields() {
        let own = templateDetails
        listingName = record?.listingName ?? own.name
        listingSummary = record?.listingSummary ?? own.summary
        topics = record?.topics ?? []
        examples = []
    }

    /// Publishing shares new example runs only after the publisher agrees.
    private func requestPublish() {
        if listingEdits.sharesNewExamples {
            confirmExamples = true
        } else {
            publish()
        }
    }

    private func retryListing(_ outcome: WorkflowShareOutcome) {
        guard let sent = sentListing, let result = outcome.listing else { return }
        let again = sent.failed(in: result)
        guard !again.isEmpty else { return }
        retryingListing = true
        Task { @MainActor in
            defer { retryingListing = false }
            var updated = outcome
            do {
                let retried = try await WorkflowShareService.shared.applyListingEdits(
                    templateID: outcome.record.templateID, again)
                var merged = result
                merged.detailsError = again.details == nil ? result.detailsError : retried.detailsError
                merged.topicsError = again.topics == nil ? result.topicsError : retried.topicsError
                if again.examples != nil {
                    merged.examplesError = retried.examplesError
                    merged.imagesSkipped = retried.imagesSkipped
                    merged.unreadableImages = retried.unreadableImages
                }
                updated.listing = merged
            } catch {
                var failed = result
                let message = error.localizedDescription
                if again.details != nil { failed.detailsError = message }
                if again.topics != nil { failed.topicsError = message }
                if again.examples != nil { failed.examplesError = message }
                updated.listing = failed
            }
            go(.live(updated))
        }
    }

    private func renderShareCard(record: WorkflowRegistryRecord) {
        guard shareCard == nil else { return }
        let listed = registryRecords.record(for: record.templateID) ?? record
        let content = WorkflowShareCardContent(
            name: listed.listingName ?? template.name, summary: listed.listingSummary ?? template.summary ?? "",
            facts: WorkflowCardFacts.template(template).joined(separator: " · "),
            handle: handle(for: record), url: record.url)
        shareCard = WorkflowShareCard.render(content)
    }

    private func export() {
        failure = nil
        // An unsigned file carries no name: without the signature it would be
        // an unverifiable claim.
        let name = signs ? authorName : nil
        isWriting = true
        Task { @MainActor in
            defer { isWriting = false }
            var final = outgoing
            var named = final
            if savesNewVersion { named.version = current.version + 1 }
            guard let url = await TemplateFileExport.chooseDestination(for: named, signing: signs) else { return }
            do {
                if savesNewVersion { final = try saveNewVersion(final) }
                let outcome = try TemplateFileExport.write(final, to: url, sign: signs, authorName: name)
                let message: String? = {
                    if case .signingFailed = outcome { return L("It's unsigned because signing didn't finish.") }
                    return nil
                }()
                ToastManager.shared.action(
                    L("Saved \"\(final.name)\""), message: message, action: .revealInFinder(url),
                    buttonTitle: L("Show in Finder"))
                onDone()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Publishes the outgoing template, saving it as a new library version
    /// first when its content changed (or as `asVersion` when the registry
    /// already has a newer one).
    private func publish(asVersion: Int? = nil) {
        let name = authorName
        let chosenVisibility = effectiveVisibility
        let chosenPassword = visibility == .password ? password : nil
        let chosenWorkspaces = chosenVisibility == .workspace && !isLive ? workspaceIDs.sorted() : []
        let cascade = publishWorkflows
        let listing = listingEdits
        sentListing = listing.isEmpty ? nil : listing
        go(.publishing)
        Task { @MainActor in
            do {
                var final = savedForShare ?? outgoing
                if let asVersion {
                    final = try saveVersion(final, as: asVersion, changelog: L("Published update"))
                    savedForShare = final
                } else if savedForShare == nil && savesNewVersion {
                    final = try saveNewVersion(final)
                    savedForShare = final
                }
                let outcome =
                    isAgent
                    ? try await WorkflowShareService.shared.shareAgent(
                        final, authorName: name, visibility: chosenVisibility, password: chosenPassword,
                        workspaceIDs: chosenWorkspaces, publishWorkflows: cascade, listing: listing)
                    : try await WorkflowShareService.shared.share(
                        final, authorName: name, visibility: chosenVisibility, password: chosenPassword,
                        workspaceIDs: chosenWorkspaces, listing: listing)
                shareCard = nil
                go(.live(outcome))
            } catch let error as WorkflowShareError {
                var latest: Int?
                if case .versionNotNewer(let v) = error { latest = v }
                go(.failure(message: error.localizedDescription, hint: error.diagnosticHint, latestVersion: latest))
            } catch {
                go(.failure(message: error.localizedDescription, hint: nil, latestVersion: nil))
            }
        }
    }

    private func takeDown() {
        isTakingDown = true
        Task { @MainActor in
            defer { isTakingDown = false }
            do {
                try await WorkflowShareService.shared.unpublish(templateID: template.id)
                _ = ToastManager.shared.success(
                    L("Took down \"\(template.name)\""), message: L("Its page no longer works. Publish again to bring it back."))
            } catch {
                _ = ToastManager.shared.error(L("Take Down"), message: error.localizedDescription)
            }
        }
    }

    /// Takes down one of the agent's workflow pages; the agent's stays up.
    private func takeDownWorkflow() {
        guard let workflow = workflowToTakeDown else { return }
        workflowToTakeDown = nil
        takingDownWorkflowID = workflow.id
        Task { @MainActor in
            defer { takingDownWorkflowID = nil }
            do {
                try await WorkflowShareService.shared.unpublish(templateID: workflow.id)
                _ = ToastManager.shared.success(
                    L("Took down \"\(workflow.name)\""),
                    message: L("Its page no longer works. \(template.name) still carries it."))
            } catch {
                _ = ToastManager.shared.error(L("Take Down"), message: error.localizedDescription)
            }
        }
    }

    private func retryVisibility(_ outcome: WorkflowShareOutcome) {
        retryingVisibility = true
        let restricted: WorkflowVisibility = visibility == .workspace ? .workspace : .password
        Task { @MainActor in
            defer { retryingVisibility = false }
            do {
                let record = try await WorkflowShareService.shared.setVisibility(
                    templateID: template.id, visibility: restricted,
                    password: restricted == .password ? password : nil,
                    workspaceIDs: restricted == .workspace ? workspaceIDs.sorted() : [])
                var protected = WorkflowShareOutcome(published: outcome.published, record: record)
                protected.cascade = outcome.cascade
                protected.listing = outcome.listing
                go(.live(protected))
            } catch {
                var failed = outcome
                failed.visibilityError = (error as? WorkflowShareError) ?? .api(.transport(error.localizedDescription))
                go(.live(failed))
            }
        }
    }

    /// The first version above both the registry's and the library's.
    private func nextVersion(afterPublished latest: Int) -> Int {
        let local = TemplateStore.versionNumbers(current.id).last ?? current.version
        return max(latest, local, (savedForShare ?? current).version) + 1
    }

    private func saveNewVersion(_ template: Template) throws -> Template {
        let saved = try TemplateStore.shared.save(template, changelog: L("Added setup suggestions for sharing"))
        try movePinnedInstall(to: saved)
        return saved
    }

    private func saveVersion(_ template: Template, as version: Int, changelog: String) throws -> Template {
        var next = template
        next.version = version
        next.changelog = changelog
        next.createdAt = Date()
        let saved = try TemplateStore.shared.store(exactVersion: next.sealed())
        try movePinnedInstall(to: saved)
        return saved
    }

    /// An install pinned to the version this sheet opened on moves to the
    /// version just saved.
    private func movePinnedInstall(to saved: Template) throws {
        let installs = InstalledWorkflowStore.shared
        guard saved.kind == .workflow, let pinned = installs.workflow(templateID: saved.id),
            pinned.templateVersion == current.version || pinned.templateVersion == savedForShare?.version
        else { return }
        _ = try installs.install(saved, bindings: pinned.bindings)
    }
}
