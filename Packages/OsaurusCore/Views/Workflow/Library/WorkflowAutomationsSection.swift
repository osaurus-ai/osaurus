//
//  WorkflowAutomationsSection.swift
//  osaurus
//
//  "When It Runs" on a workflow's page: each automation that starts it as
//  a sentence whose words change it in place, with its switch (Remove on
//  hover), then ways to add another. Kinds the words can't say open the
//  Settings editor with the workflow chosen. An automation whose workflow
//  needs an input with no default is saved off and shows the input editor
//  until it is filled.
//

import AppKit
import SwiftUI

/// What a workflow's page opens doing when the automate popover or Home
/// sent the person there.
enum WorkflowAutomationIntent: Equatable {
    /// This automation was just added: its card opens ready to change.
    case highlight(UUID)
    /// A new feed card, waiting for the address.
    case addFeed
    /// The full editor, on this kind, with the workflow picked.
    case openEditor(EventSourceTemplate)
}

extension Notification.Name {
    /// A `WorkflowAutomationIntent` for the workflow page already on screen
    /// (`object` is the workflow id).
    static let workflowAutomationIntent = Notification.Name("WorkflowAutomationIntent")
    /// Home is on screen and a link asked to scroll it.
    static let workflowsHomeScroll = Notification.Name("WorkflowsHomeScroll")
}

struct WorkflowAutomationsSection: View {
    @Environment(\.theme) private var theme

    let workflow: InstalledWorkflow
    /// The page's own answer, so the header and each automation agree.
    let needsSetup: Bool
    /// What the page was opened to do; taken on appear.
    var takeIntent: () -> WorkflowAutomationIntent? = { nil }

    /// An automation just added or asked for, marked for a moment.
    @State private var highlighted: UUID?
    @State private var editorRequest: EventEditorRequest?
    @State private var removing: OsaurusEvent?
    @State private var addingFeed = false

    private var manager: EventManager { .shared }

    private var automations: [OsaurusEvent] {
        manager.events(forWorkflowID: workflow.id).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let automations = automations
        SettingsSection(title: "When It Runs", layout: .plain) {
            if automations.isEmpty && !addingFeed {
                emptyState
            } else {
                VStack(spacing: theme.space.s0) {
                    ForEach(Array(automations.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { ThemeHairlineDivider(color: theme.border.subtle) }
                        WorkflowAutomationCard(
                            event: event, workflow: workflow,
                            isHighlighted: highlighted == event.id, needsSetup: needsSetup,
                            onChange: { editorRequest = EventEditorRequest(existing: $0) },
                            onRemove: { removing = $0 })
                    }
                    if addingFeed {
                        if !automations.isEmpty { ThemeHairlineDivider(color: theme.border.subtle) }
                        WorkflowFeedDraftCard(
                            onSave: { url in
                                addingFeed = false
                                add(AutomationDefaults.feed(url: url))
                            },
                            onCancel: { addingFeed = false })
                        .padding(.horizontal, theme.space.s16)
                        .padding(.vertical, theme.space.s12)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
                .settingsChrome(.card)
                alsoRunIt(automations)
            }
        }
        .settingsLandingAnchor("workflows.automate.schedule")
        .onAppear { apply(takeIntent()) }
        .onReceive(NotificationCenter.default.publisher(for: .workflowAutomationIntent)) { note in
            guard note.object as? UUID == workflow.id else { return }
            apply(takeIntent())
        }
        .sheet(item: $editorRequest) { request in
            EventEditorSheet(
                request: request,
                onSave: { event in
                    save(event, isNew: request.existing == nil)
                    editorRequest = nil
                },
                onCancel: { editorRequest = nil })
        }
        .themedAlert(
            L("Remove this automation?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            message: removing.map { L("\(workflow.name) will stop running \(AutomationSentence.short($0).lowercasedFirst).") },
            primaryButton: .destructive(L("Remove")) {
                if let event = removing {
                    manager.delete(id: event.id)
                    if highlighted == event.id { highlighted = nil }
                }
                removing = nil
            },
            secondaryButton: .cancel(L("Cancel")) { removing = nil })
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("Want this to run on its own?", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundStyle(theme.text.secondary)
            HStack(alignment: .top, spacing: theme.space.s8) {
                if let suggested = AutomationPresets.presets(name: workflow.name, summary: workflow.summary)
                    .first(where: \.isSuggested)
                {
                    choice(icon: "sparkles", title: suggested.title, detail: L("Suggested for this workflow")) {
                        apply(suggested.kind)
                    }
                }
                choice(icon: "calendar.badge.clock", title: L("At a time I choose"), detail: L("Pick the days and the time")) {
                    add(AutomationDefaults.schedule)
                }
                Menu {
                    happeningsMenu
                } label: {
                    choiceLabel(icon: "bolt", title: L("When something happens"), detail: L("A new file, a new post, and more"))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choice(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { choiceLabel(icon: icon, title: title, detail: detail) }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choiceLabel(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Image(systemName: icon)
                .glyphSize(.body, weight: .semibold)
                .foregroundStyle(theme.action.primary.default.background)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(SettingsFont.rowTitle)
                .foregroundStyle(theme.text.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            Text(verbatim: detail)
                .font(SettingsFont.footnote)
                .foregroundStyle(theme.text.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsChrome(.card)
        .contentShape(Rectangle())
        .pointingHandCursor()
    }

    // MARK: Also run it

    private func alsoRunIt(_ automations: [OsaurusEvent]) -> some View {
        SettingsMenuButton(.tertiary, "Add Another Way", icon: "plus", size: .small) {
            Button {
                add(AutomationDefaults.schedule)
            } label: {
                Label(L("At another time"), systemImage: "calendar.badge.clock")
            }
            Divider()
            happeningsMenu
        }
    }

    /// Every way the catalog offers but a schedule.
    @ViewBuilder
    private var happeningsMenu: some View {
        ForEach(AutomationCatalog.items.filter { $0.entry != .kind(.schedule) }) { item in
            if item.entry == .appNews {
                Menu {
                    ForEach(WebhookProvider.services, id: \.self) { provider in
                        Button(provider.shortName) { openEditor(.providerWebhook(provider)) }
                    }
                } label: {
                    Label(item.title, systemImage: item.icon)
                }
            } else {
                Button {
                    addCatalogEntry(item.entry)
                } label: {
                    Label(item.title, systemImage: item.icon)
                }
            }
        }
    }

    // MARK: Actions

    private func apply(_ intent: WorkflowAutomationIntent?) {
        switch intent {
        case .highlight(let id)?: highlight(id)
        case .addFeed?: addingFeed = true
        case .openEditor(let template)?: openEditor(template)
        case nil: break
        }
    }

    private func apply(_ kind: AutomationPresets.Kind) {
        switch kind {
        case .schedule(let frequency): add(.schedule(ScheduleSourceConfig(frequency: frequency)))
        case .folder(let path): addFolder(startingAt: path)
        case .pickDayAndTime: add(AutomationDefaults.schedule)
        }
    }

    private func addCatalogEntry(_ entry: AutomationCatalog.Entry) {
        switch entry {
        case .kind(.schedule): add(AutomationDefaults.schedule)
        case .kind(.folder): addFolder()
        case .kind(.rss): addingFeed = true
        case .kind(.runFailed): add(AutomationDefaults.runFailed)
        case .kind(.app): add(AutomationDefaults.appLaunch)
        case .kind(let kind): openEditor(.source(kind))
        case .appNews: openEditor(.providerWebhook(WebhookProvider.services.first ?? .generic))
        }
    }

    private func addFolder(startingAt suggested: String? = nil) {
        Task { @MainActor in
            guard let picked = await WorkflowAutomationFolderPicker.pick(startingAt: suggested) else { return }
            add(AutomationDefaults.folder(path: picked.path, bookmark: picked.bookmark))
        }
    }

    private func add(_ source: EventSource) {
        let event = AutomationDefaults.event(for: workflow, source: source)
        let created = manager.create(event, telemetryOrigin: "user")
        highlight(created.id)
    }

    /// Marks the automation just added or opened, then lets it settle.
    private func highlight(_ id: UUID) {
        withAnimation(theme.motion.standard) { highlighted = id }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard highlighted == id else { return }
            withAnimation(theme.motion.standard) { highlighted = nil }
        }
    }

    private func openEditor(_ template: EventSourceTemplate) {
        editorRequest = EventEditorRequest(template: template, initialWorkflowId: workflow.id)
    }

    private func save(_ event: OsaurusEvent, isNew: Bool) {
        if isNew {
            let created = manager.create(event, telemetryOrigin: "user")
            highlight(created.id)
            if created.sourceKind == .webhook { WorkflowAutomationLinks.openInSettings(created.id) }
        } else {
            manager.update(event)
        }
    }
}

// MARK: - Card

/// One automation as a sentence: "[Every weekday] at [9:00 AM]", "When a
/// file shows up in [Downloads]", "When [example.com] posts something new".
struct WorkflowAutomationCard: View {
    @Environment(\.theme) private var theme

    let event: OsaurusEvent
    let workflow: InstalledWorkflow
    let isHighlighted: Bool
    var needsSetup = false
    let onChange: (OsaurusEvent) -> Void
    let onRemove: (OsaurusEvent) -> Void

    @State private var showsInputs = false
    @State private var editingFeed = false
    @State private var isHovered = false

    private var manager: EventManager { .shared }
    private var schema: JSONValue { workflow.definition.inputSchema }
    private var inputFields: [DialogField] { WorkflowFormFields.fields(fromInputSchema: schema) }
    private var mapping: [String: String] { event.action.workflow?.inputMapping ?? [:] }
    private var missingInputs: [DialogField] { AutomationDefaults.missingInputs(schema: schema, mapping: mapping) }

    var body: some View {
        let missing = missingInputs
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(alignment: .center, spacing: theme.space.s10) {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    HStack(spacing: theme.space.s10) {
                        Image(systemName: EventSourceTemplate.icon(for: event))
                            .glyphSize(.body, weight: .medium)
                            .foregroundStyle(event.isEnabled ? theme.text.secondary : theme.text.tertiary)
                            .frame(width: theme.space.s20)
                            .accessibilityHidden(true)
                        sentence
                            .help(L("Click a word to change it."))
                    }
                    let state = WorkflowAutomationState.line(
                        event, needsSetup: needsSetup, inputsMissing: !missing.isEmpty,
                        hasTargetProblem: EventInspection.targetProblem(event) != nil)
                    Text(verbatim: state.text)
                        .font(SettingsFont.footnote)
                        .foregroundStyle(state.tone.map(theme.statusInk) ?? theme.text.secondary)
                        .padding(.leading, theme.space.s20 + theme.space.s10)
                }
                Spacer(minLength: theme.space.s8)
                SettingsIconButton("trash", help: L("Remove"), size: .small, isDestructive: true) { onRemove(event) }
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(!isHovered)
                if !inputFields.isEmpty {
                    SettingsIconButton(
                        "slider.horizontal.3", help: L("What it uses each time"), size: .small,
                        isActive: showsInputs || !missing.isEmpty
                    ) { showsInputs.toggle() }
                }
                Toggle(
                    L("On"),
                    isOn: Binding(get: { event.isEnabled }, set: { manager.setEnabled(event.id, enabled: $0) })
                )
                .settingsSwitch()
                .disabled(!missing.isEmpty)
                .help(missing.isEmpty ? L("Turn this automation on or off") : L("Fill in what it uses first"))
            }
            if editingFeed, case .rss(let rss) = event.source {
                WorkflowFeedDraftCard(
                    initialURL: rss.url,
                    onSave: { url in
                        editingFeed = false
                        var updated = event
                        updated.source = .rss(RSSSourceConfig(url: url))
                        manager.update(updated)
                    },
                    onCancel: { editingFeed = false })
            }
            if showsInputs || !missing.isEmpty {
                WorkflowAutomationInputs(event: event, workflow: workflow)
            }
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if isHighlighted { theme.surface.selected } }
        .animation(theme.motion.standard, value: isHighlighted)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: AutomationSentence.sentence(event)))
        .accessibilityAction(named: Text("Remove", bundle: .module)) { onRemove(event) }
    }

    // MARK: Sentence

    @ViewBuilder
    private var sentence: some View {
        switch AutomationSentence.parts(event) {
        case .schedule(let parts):
            HStack(spacing: theme.space.s6) {
                if parts.day == .custom {
                    sentenceText(AutomationSentence.sentence(event))
                    SettingsButton(.tertiary, "Change…", size: .small) { onChange(event) }
                } else {
                    SettingsMenuButton(.secondary, AutomationSentence.dayLabel(parts.day), size: .standard, verbatim: true) {
                        ForEach(AutomationSentence.dayMenu(), id: \.self) { choice in
                            Button(AutomationSentence.dayLabel(choice)) { setDay(choice, parts: parts) }
                        }
                        Divider()
                        Button(L("Custom…")) { onChange(event) }
                    }
                    if parts.day.hasTime {
                        sentenceText(L("at"))
                        SettingsDatePicker(
                            label: "Time", selection: timeBinding(parts), components: [.hourAndMinute])
                            .fixedSize()
                    }
                }
            }
        case .folder(let name):
            HStack(spacing: theme.space.s6) {
                sentenceText(L("When a file shows up in"))
                SettingsButton(.secondary, name, icon: "folder", size: .small, verbatim: true) { changeFolder() }
            }
        case .feed(let site):
            HStack(spacing: theme.space.s6) {
                sentenceText(L("When"))
                SettingsButton(.secondary, site, size: .small, verbatim: true) { editingFeed = true }
                sentenceText(L("posts something new"))
            }
        case .fixed(let text):
            HStack(spacing: theme.space.s6) {
                sentenceText(text)
                SettingsButton(.tertiary, "Change…", size: .small) { onChange(event) }
            }
        }
    }

    private func sentenceText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.rowTitle)
            .foregroundStyle(theme.text.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Changes

    private func setDay(_ choice: AutomationSentence.DayChoice, parts: AutomationSentence.ScheduleParts) {
        var next = parts
        next.day = choice
        setSchedule(next)
    }

    private func timeBinding(_ parts: AutomationSentence.ScheduleParts) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: parts.hour, minute: parts.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                var next = parts
                next.hour = components.hour ?? parts.hour
                next.minute = components.minute ?? parts.minute
                if next != parts { setSchedule(next) }
            })
    }

    private func setSchedule(_ parts: AutomationSentence.ScheduleParts) {
        guard let frequency = AutomationSentence.frequency(parts) else { return }
        var updated = event
        updated.source = .schedule(ScheduleSourceConfig(frequency: frequency))
        manager.update(updated)
    }

    private func changeFolder() {
        let current: String? = if case .folder(let folder) = event.source { folder.path } else { nil }
        Task { @MainActor in
            guard let picked = await WorkflowAutomationFolderPicker.pick(startingAt: current) else { return }
            guard case .folder(var folder) = event.source else { return }
            folder.path = picked.path
            folder.bookmark = picked.bookmark
            var updated = event
            updated.source = .folder(folder)
            manager.update(updated)
        }
    }
}

// MARK: - Inputs

/// "What should it use each time?": the workflow's inputs bound to what
/// the automation hands it. Saved as it changes; the automation turns on
/// once nothing required is left empty.
private struct WorkflowAutomationInputs: View {
    @Environment(\.theme) private var theme

    let event: OsaurusEvent
    let workflow: InstalledWorkflow

    @State private var mapping: [String: String] = [:]
    @State private var loaded = false

    private var schema: JSONValue { workflow.definition.inputSchema }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(verbatim: L("What should it use each time?"))
                .font(SettingsFont.rowTitle)
                .foregroundStyle(theme.text.primary)
            WorkflowInputBindingEditor(
                fields: WorkflowFormFields.fields(fromInputSchema: schema),
                schema: schema,
                triggerValues: EventTriggerValues.catalog(for: event.sourceKind, sample: EventTriggerValues.samplePayload(for: event)),
                samplePayload: EventTriggerValues.samplePayload(for: event),
                mapping: $mapping)
        }
        .padding(.top, theme.space.s4)
        .onAppear {
            mapping = event.action.workflow?.inputMapping ?? [:]
            loaded = true
        }
        .task(id: mapping) {
            guard loaded else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        guard var action = event.action.workflow, action.inputMapping != mapping else { return }
        let manager = EventManager.shared
        guard var updated = manager.event(for: event.id) else { return }
        let wasMissing = !AutomationDefaults.missingInputs(schema: schema, mapping: action.inputMapping).isEmpty
        action.inputMapping = mapping
        updated.action = .workflow(action)
        if wasMissing, AutomationDefaults.missingInputs(schema: schema, mapping: mapping).isEmpty {
            updated.isEnabled = true
        }
        manager.update(updated)
    }
}

// MARK: - Feed

/// The feed's address, typed in place.
struct WorkflowFeedDraftCard: View {
    @Environment(\.theme) private var theme

    var initialURL: String = ""
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var url = ""

    private var trimmed: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { TriggerSourceURL.parse(trimmed) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(verbatim: L("When a site posts something new"))
                .font(SettingsFont.rowTitle)
                .foregroundStyle(theme.text.primary)
            HStack(spacing: theme.space.s8) {
                SettingsTextField(
                    placeholder: L("The site's feed address, like https://example.com/feed"),
                    text: $url, icon: "dot.radiowaves.up.forward",
                    isInvalid: !trimmed.isEmpty && !isValid, autofocus: true)
                    .onSubmit { if isValid { onSave(trimmed) } }
                SettingsButton(.secondary, "Cancel", size: .small, action: onCancel)
                SettingsButton(.primary, "Save", size: .small) { onSave(trimmed) }
                    .disabled(!isValid)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { url = initialURL }
    }
}

// MARK: - Helpers

enum WorkflowAutomationFolderPicker {
    /// A folder and its security-scoped bookmark; nil when cancelled.
    @MainActor
    static func pick(startingAt path: String?) async -> (path: String, bookmark: Data?)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch This Folder")
        if let path {
            panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard await panel.beginModal() == .OK, let url = panel.url else { return nil }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        return (url.path, bookmark)
    }
}

enum WorkflowAutomationLinks {
    /// The automation's page in Settings → Automations (a webhook's address
    /// and signing live there).
    @MainActor
    static func openInSettings(_ eventID: UUID) {
        let state = ManagementStateManager.shared
        state.pendingEventDetailId = eventID
        state.selectedTab = .automations
        AppDelegate.shared?.showManagementWindow(initialTab: .automations)
    }

    /// Settings → Automations, with "Add Automation" open.
    @MainActor
    static func openAddAutomation() {
        let state = ManagementStateManager.shared
        state.pendingNewAutomation = true
        state.selectedTab = .automations
        AppDelegate.shared?.showManagementWindow(initialTab: .automations)
    }
}

extension String {
    /// "When Downloads changes" → "when Downloads changes".
    var lowercasedFirst: String {
        guard let first else { return self }
        return String(first).lowercased() + dropFirst()
    }
}
