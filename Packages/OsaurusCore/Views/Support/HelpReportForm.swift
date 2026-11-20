//
//  HelpReportForm.swift
//  osaurus
//
//  "Report a Problem" on the Help page, one step after another on the same
//  page:
//
//  1. What it is about: seven kinds of report as cards.
//  2. Details for that kind, picked from this Mac's own agents, workflows,
//     models, Osaurus Cloud connection, paired iPhone and Store listings,
//     plus what went wrong and an
//     opt-in switch for extra metadata about the picked item.
//  3. A description and up to three images.
//  4. A review of everything that is sent, the Terms and Privacy box, Send.
//
//  The draft lives in `SupportService.draft`, so leaving Help to look
//  something up does not lose it.
//

import SwiftUI

struct HelpReportForm: View {
    /// Open a report's conversation (after sending, "View Report").
    let onOpenThread: (String) -> Void

    @ObservedObject private var support = SupportService.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var workflowStore = InstalledWorkflowStore.shared
    @ObservedObject private var registry = WorkflowRegistryRecordStore.shared
    @ObservedObject private var pairing = MobilePairingService.shared
    @ObservedObject private var providers = RemoteProviderManager.shared
    @Environment(\.theme) private var theme

    @State private var draft = SupportReportDraft()
    @State private var didLoadDraft = false
    /// Installed local models, read once per visit: listing them probes the
    /// disk.
    @State private var models: [SupportPick] = []
    /// What is attached to the report. Built when the page appears and sent
    /// as-is, so the preview and the request are the same value.
    @State private var report: SupportReport?
    @State private var hasConsented = false
    @State private var showsIncluded = false
    @State private var isSending = false
    @State private var sendError: String?
    @State private var imageMessage: String?
    @State private var sentThreadId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
            if let sentThreadId {
                sentSection(sentThreadId)
            } else if isAtOpenLimit {
                limitSection
            } else {
                categorySection
                if let category = draft.category {
                    detailsSection(category)
                    describeSection
                    reviewSection(category)
                }
            }
        }
        .task {
            if !didLoadDraft {
                draft = support.draft
                didLoadDraft = true
            }
            models = ModelManager.shared.installedModels().map { SupportPick(id: $0.id, name: $0.name) }
            report = await SupportReportBuilder.buildCurrent()
        }
        .onChange(of: draft) { _, value in
            support.draft = value
            sendError = nil
        }
    }

    // MARK: - State

    /// The router allows three reports that are not closed. Say so before
    /// the user writes a fourth, rather than after they press Send.
    private var isAtOpenLimit: Bool {
        support.openThreadCount >= OsaurusRouterSupportLimits.maxOpenThreads
    }

    private var isTooLong: Bool {
        draft.trimmedDescription.count > OsaurusRouterSupportLimits.maxMessageLength
    }

    private var isLongEnough: Bool {
        draft.trimmedDescription.count >= OsaurusRouterSupportLimits.minDescriptionLength
    }

    private var canSend: Bool {
        hasConsented && draft.category != nil && isLongEnough && !isTooLong && !isSending && report != nil
    }

    // MARK: - 1. Category

    private var categorySection: some View {
        SettingsSection(
            title: "Report a Problem",
            subtitle: "What is it about? Pick the closest one.",
            layout: .plain
        ) {
            Grid(horizontalSpacing: theme.space.s12, verticalSpacing: theme.space.s12) {
                ForEach(Self.categoryRows, id: \.first) { row in
                    GridRow {
                        ForEach(row) { category in
                            categoryCard(category)
                        }
                    }
                }
            }
        }
    }

    /// Two per row: the Help column is narrow, and a `Grid` (unlike
    /// `LazyVGrid`) gives both cards in a row the taller one's height.
    private static let categoryRows: [[SupportCategory]] = stride(
        from: 0,
        to: SupportCategory.allCases.count,
        by: 2
    ).map { Array(SupportCategory.allCases[$0 ..< min($0 + 2, SupportCategory.allCases.count)]) }

    private func categoryCard(_ category: SupportCategory) -> some View {
        LibraryCard(
            title: category.title,
            subtitle: category.subtitle,
            isSelected: draft.category == category,
            minHeight: 0,
            wrapsText: true,
            action: {
                withAnimation(theme.motion.quick) { draft.select(category: category) }
            },
            leading: {
                LibraryIcon(symbol: category.symbol, tint: theme.action.primary.default.background)
            }
        )
        .disabled(isSending)
        .accessibilityAddTraits(draft.category == category ? .isSelected : [])
    }

    // MARK: - 2. Details

    @ViewBuilder
    private func detailsSection(_ category: SupportCategory) -> some View {
        SettingsSection(title: "Details") {
            switch category {
            case .bug:
                SettingsPickerRow(
                    title: "Where",
                    description: "The part of Osaurus with the problem.",
                    style: .menu,
                    selection: $draft.area,
                    options: SupportAppArea.allCases.map { .init($0, $0.title, verbatim: true) }
                )
            case .cloud:
                SettingsValueRow(title: "Connection", value: cloudStatus)
                pickRow(
                    title: "Model",
                    description: "The Osaurus Cloud model, if it is about one.",
                    placeholder: "Choose a model",
                    choices: cloudModels,
                    selection: $draft.cloudModel
                )
            case .agent:
                pickRow(
                    title: "Agent",
                    description: "The agent that is not behaving.",
                    placeholder: "Choose an agent",
                    choices: agentManager.agents.map { SupportPick(id: $0.id.uuidString, name: $0.name) },
                    selection: $draft.agent
                )
            case .workflow:
                pickRow(
                    title: "Workflow",
                    description: "The workflow with the problem.",
                    placeholder: "Choose a workflow",
                    choices: workflowStore.workflows.map { SupportPick(id: $0.id.uuidString, name: $0.name) },
                    selection: $draft.workflow
                )
            case .model:
                pickRow(
                    title: "Model",
                    description: "A model on this Mac.",
                    placeholder: "Choose a model",
                    choices: models,
                    selection: $draft.model
                )
            case .ios:
                SettingsValueRow(
                    title: "Paired iPhone",
                    value: pairing.pairedDevice?.name ?? L("None")
                )
                SettingsFieldRow(label: "iPhone Model") {
                    SettingsTextField(placeholder: L("For example, iPhone 16 Pro"), text: $draft.phoneModel)
                }
                SettingsFieldRow(label: "iOS Version") {
                    SettingsTextField(placeholder: L("For example, 18.2"), text: $draft.phoneOSVersion)
                }
                SettingsFieldRow(label: "App Version", hint: "In the iPhone app under Settings → About.") {
                    SettingsTextField(placeholder: L("For example, 1.4"), text: $draft.phoneAppVersion)
                }
            case .store:
                SettingsPickerRow(
                    title: "Problem With",
                    selection: $draft.storeDirection,
                    options: SupportStoreDirection.allCases.map { .init($0, $0.title, verbatim: true) }
                )
                switch draft.storeDirection {
                case .publishing:
                    pickRow(
                        title: "Listing",
                        description: "Something you published from this Mac.",
                        placeholder: "Choose a listing",
                        choices: storeListings,
                        selection: $draft.storeListing
                    )
                case .installing:
                    SettingsFieldRow(label: "Store Link", hint: "The link to the listing, if you have it.") {
                        SettingsTextField(placeholder: "https://", text: $draft.storeLink)
                    }
                }
            }

            SettingsFieldRow(label: "What Went Wrong") {
                FilterChipRow(
                    category.problems.map(\.id),
                    selection: $draft.problemId,
                    allTitle: nil,
                    title: { id in category.problems.first { $0.id == id }?.title ?? id }
                )
            }

            if let title = category.extrasTitle {
                SettingsToggle(
                    title: title,
                    description: category.extrasDetail ?? "",
                    verbatim: true,
                    isOn: $draft.shareExtras
                )
            }
        }
        .disabled(isSending)
    }

    /// A row with a pop-up of things on this Mac, "Choose …" first.
    private func pickRow(
        title: String,
        description: String,
        placeholder: String,
        choices: [SupportPick],
        selection: Binding<SupportPick?>
    ) -> some View {
        let id = Binding<String?>(
            get: { selection.wrappedValue?.id },
            set: { newValue in
                selection.wrappedValue = newValue.flatMap { value in choices.first { $0.id == value } }
            }
        )
        var options: [SettingsPickerRow<String?>.Option] = [.init(nil, placeholder)]
        options += choices.map { .init($0.id, $0.name, verbatim: true) }
        // A pick that has since been deleted still shows, so the review
        // matches what will be sent.
        if let current = selection.wrappedValue, !choices.contains(current) {
            options.append(.init(current.id, current.name, verbatim: true))
        }
        return SettingsRow(title: title, description: description) {
            SettingsMenuPicker(selection: id, options: options)
                .accessibilityLabel(Text(LocalizedStringKey(title), bundle: .module))
        }
    }

    private var cloudState: RemoteProviderState? {
        providers.providerStates[RemoteProviderManager.osaurusRouterProviderId]
    }

    /// The same states the cloud model browser tells apart.
    private var cloudStatus: String {
        if !providers.isOsaurusRouterEnabled { return L("Off") }
        if providers.isOffline { return L("Offline") }
        if cloudState?.isConnected == true { return L("Connected") }
        if cloudState?.isConnecting == true { return L("Connecting…") }
        return L("Not connected")
    }

    private var cloudModels: [SupportPick] {
        (cloudState?.discoveredModels ?? []).sorted().map { SupportPick(id: $0, name: $0) }
    }

    /// What this Mac has published, newest first.
    private var storeListings: [SupportPick] {
        registry.records
            .sorted { $0.sharedAt > $1.sharedAt }
            .map { SupportPick(id: $0.templateID.uuidString, name: $0.listingName ?? $0.slug) }
            .reduce(into: [SupportPick]()) { picks, pick in
                if !picks.contains(where: { $0.id == pick.id }) { picks.append(pick) }
            }
    }

    // MARK: - 3. Describe

    private var descriptionHint: String {
        if isTooLong {
            return String(
                format: L("%1$lld characters over the %2$lld character limit."),
                draft.trimmedDescription.count - OsaurusRouterSupportLimits.maxMessageLength,
                OsaurusRouterSupportLimits.maxMessageLength
            )
        }
        return L("What you did, what you expected, and what happened instead. Please do not paste passwords or keys.")
    }

    private var describeSection: some View {
        SettingsSection(title: "Describe It") {
            SettingsFieldRow(label: "What Happened", hint: descriptionHint, verbatimHint: true) {
                SettingsTextEditor(
                    text: $draft.description,
                    placeholder: L("Describe the problem"),
                    minHeight: 120,
                    maxHeight: 280,
                    isInvalid: isTooLong
                )
                .disabled(isSending)
                .helpImageIntake(
                    images: $draft.images,
                    limit: OsaurusRouterSupportLimits.maxAttachmentsPerMessage,
                    message: $imageMessage,
                    isEnabled: !isSending
                )
            }
            HelpImageAttachmentsRow(
                images: $draft.images,
                limit: OsaurusRouterSupportLimits.maxAttachmentsPerMessage,
                message: $imageMessage,
                isDisabled: isSending
            )
        }
    }

    // MARK: - 4. Review and Send

    private func reviewSection(_ category: SupportCategory) -> some View {
        SettingsSection(title: "Review and Send") {
            SettingsValueRow(title: "Type", value: category.title)
            ForEach(draft.detailRows) { row in
                SettingsValueRow(title: row.label, value: row.value, verbatimTitle: true)
            }
            if !draft.images.isEmpty {
                SettingsValueRow(title: "Images", value: imagesSummary)
            }
            SettingsRow(
                title: "What's Included",
                description:
                    "Your description and picks, any images, the Osaurus and macOS versions, your Mac model, chip and memory, and diagnostics: the current agent's name and model, tool names, and the timing and status of recent requests. Never your chats, files or keys."
            ) {
                SettingsButton(.tertiary, showsIncluded ? "Hide Details" : "Show Details", size: .compact) {
                    withAnimation(theme.motion.quick) { showsIncluded.toggle() }
                }
            }
            if showsIncluded {
                includedPreview
            }
            consentRow
            sendRow
        }
    }

    private var imagesSummary: String {
        let bytes = draft.images.reduce(0) { $0 + $1.byteSize }
        return String(
            format: L("%1$lld (%2$@)"),
            draft.images.count,
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        )
    }

    @ViewBuilder
    private var includedPreview: some View {
        if let report {
            let extras = SupportReportExtras.current(for: draft)
            VStack(alignment: .leading, spacing: theme.space.s8) {
                ScrollView {
                    Text(verbatim: report.previewJSON(draft: draft, extras: extras))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space.s12)
                }
                .frame(maxHeight: 280)
                .settingsChrome(.code)
                .accessibilityLabel(Text("Details sent with the report", bundle: .module))

                Text(verbatim: includedFootnote(report))
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsRowChrome()
        } else {
            SettingsEmptyState(loading: "Collecting details…")
        }
    }

    private func includedFootnote(_ report: SupportReport) -> String {
        if report.diagnostics == nil {
            return L("Diagnostics were too large to attach, so this report is sent without them.")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(report.diagnosticsBytes), countStyle: .file)
        return String(
            format: L("This is everything sent besides your description and images (%@). Identifiers are one-way fingerprints."),
            size
        )
    }

    /// The box is beside the sentence, not around it, so the Terms and
    /// Privacy links stay clickable.
    private var consentRow: some View {
        HStack(alignment: .center, spacing: theme.space.s10) {
            Toggle(isOn: $hasConsented) { EmptyView() }
                .settingsCheckbox(showsLabel: false)
                .accessibilityLabel(Text("I agree to send this report", bundle: .module))
                .disabled(isSending)
            MarkdownLinkText(
                markdown: Self.consentMarkdown,
                style: .bodySmall,
                textColor: theme.text.primary
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsRowChrome()
    }

    static var consentMarkdown: String {
        String(
            format: L("I agree to send this report and the details listed above to Osaurus, under the [Terms](%1$@) and [Privacy Policy](%2$@)."),
            OsaurusWebLinks.terms.absoluteString,
            OsaurusWebLinks.privacy.absoluteString
        )
    }

    private var sendRow: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            Group {
                if let sendError {
                    Text(verbatim: sendError)
                        .foregroundColor(theme.status[.error].foreground)
                } else if draft.trimmedDescription.isEmpty {
                    Text("Describe the problem above to send.", bundle: .module)
                        .foregroundColor(theme.text.tertiary)
                } else if !isLongEnough {
                    Text("Add a little more detail to send.", bundle: .module)
                        .foregroundColor(theme.text.tertiary)
                } else if !isTooLong, !hasConsented {
                    Text("Tick the box above to send.", bundle: .module)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .font(SettingsFont.caption)
            .fixedSize(horizontal: false, vertical: true)

            // An empty message renders nothing, so the spacer is what keeps
            // the button on the trailing edge.
            Spacer(minLength: 0)

            SettingsButton(.primary, "Send Report", icon: "paperplane.fill", isLoading: isSending) {
                send()
            }
            .disabled(!canSend)
        }
        .settingsRowChrome()
    }

    private func send() {
        guard canSend, let report else { return }
        let draft = draft
        let extras = SupportReportExtras.current(for: draft)
        isSending = true
        sendError = nil
        Task {
            do {
                let thread = try await support.submit(draft: draft, report: report, extras: extras)
                self.draft = SupportReportDraft()
                hasConsented = false
                showsIncluded = false
                imageMessage = nil
                withAnimation(theme.motion.quick) { sentThreadId = thread.id }
                // The next report gets fresh diagnostics, not this one's.
                self.report = await SupportReportBuilder.buildCurrent()
            } catch {
                sendError = SupportService.userMessage(for: error)
            }
            isSending = false
        }
    }

    // MARK: - Other States

    private func sentSection(_ threadId: String) -> some View {
        SettingsSection(title: "Report a Problem", layout: .plain) {
            SettingsCallout(
                icon: "checkmark.circle",
                title: "Report Sent",
                message: "Thanks for telling us. We read every report and reply here. A dot on the Help icon means a reply is waiting.",
                tone: .success
            ) {
                SettingsButton(.secondary, "View Report") { onOpenThread(threadId) }
                SettingsButton(.tertiary, "Send Another") {
                    withAnimation(theme.motion.quick) { sentThreadId = nil }
                }
            }
        }
    }

    private var limitSection: some View {
        SettingsSection(title: "Report a Problem") {
            SettingsEmptyState(
                inline: "tray.full",
                title: "You have 3 open reports",
                hint: "Add to one of them below, or mark one as resolved to send a new report."
            )
        }
    }
}
