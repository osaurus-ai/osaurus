//
//  EventsView.swift
//  osaurus
//
//  The Automations tab: triggers that run a workflow, an agent, or one
//  tool-less model answer on their own (schedules, folder watchers,
//  webhooks), grouped by trigger and read
//  as When → Do → Result. Their runs are tasks (History opens Tasks →
//  History); Channel Messages lists the messages that never became one.
//  Messages that arrive on a channel are routed in Channels, not here.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AutomationsPage: String, CaseIterable, AnimatedTabItem {
    case automations
    case history

    var title: String {
        switch self {
        case .automations: L("Automations")
        case .history: L("Channel Messages")
        }
    }
}

struct EventsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    private var manager = EventManager.shared

    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @State private var page: AutomationsPage = .automations
    @State private var searchText = ""
    @State private var editor: EventEditorRequest?
    @State private var detailEventId: UUID?
    @State private var pendingDelete: OsaurusEvent?
    @State private var hasAppeared = false
    @State private var toast: (message: String, type: SimpleToastType)?

    var body: some View {
        VStack(spacing: 0) {
            if page != .history {
                headerView
                    .settingsHeaderEntrance(hasAppeared: hasAppeared)
            }

            ZStack {
                if page == .history {
                    AutomationHistoryView()
                        .settingsBackDestination(L("Automations"), verbatim: true) { page = .automations }
                        .settingsLandingAnchor("automations.history")
                } else if triggerEvents.isEmpty {
                    emptyState
                } else {
                    list
                        .opacity(hasAppeared ? 1 : 0)
                }

                if let toast {
                    VStack {
                        Spacer()
                        ThemedToastView(toast.message, type: toast.type)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, theme.space.s16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .sheet(item: $editor) { request in
            EventEditorSheet(
                request: request,
                onSave: { event in
                    save(event, isNew: request.existing == nil)
                    editor = nil
                },
                onCancel: { editor = nil }
            )
        }
        .sheet(
            item: Binding(
                get: { detailEventId.map(EventDetailRequest.init) },
                set: { detailEventId = $0?.id }
            )
        ) { request in
            EventDetailView(
                eventId: request.id,
                onEdit: { event in
                    detailEventId = nil
                    editor = EventEditorRequest(existing: event)
                },
                onClose: { detailEventId = nil }
            )
        }
        .themedAlert(
            L("Delete Automation?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            message: pendingDelete.map { L("\"\($0.name)\" and its run history will be removed.") },
            primaryButton: .destructive(L("Delete")) {
                if let event = pendingDelete {
                    manager.delete(id: event.id)
                    showToast(L("Deleted \"\(event.name)\""))
                }
                pendingDelete = nil
            },
            secondaryButton: .cancel(L("Cancel")) { pendingDelete = nil }
        )
        .onAppear {
            withAnimation(theme.motion.standard.delay(0.05)) { hasAppeared = true }
            consumePageRequest()
            consumePendingEditRequest()
            consumePendingDetailRequest()
        }
        .onChange(of: managementState.automationsSubTabRequest) { _, _ in
            consumePageRequest()
        }
        .onChange(of: managementState.pendingEventEditId) { _, _ in
            consumePendingEditRequest()
        }
        .onChange(of: managementState.pendingEventDetailId) { _, _ in
            consumePendingDetailRequest()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Automations",
            subtitle: "Run a workflow, an agent, or one model answer on a schedule, when files change, or when a URL is called",
            count: triggerEvents.count,
            overflowAnchorId: "automations.importExport",
            secondary: {
                SettingsButton(.secondary, "History", icon: "clock.arrow.circlepath") {
                    TaskControl.showHistory(.automations)
                }
                .settingsLandingAnchor("automations.historyButton")
            },
            primary: {
                SettingsButton(.primary, "Add Automation", icon: "plus") { editor = EventEditorRequest() }
                    .settingsLandingAnchor("automations.add")
            },
            overflow: {
                Button(L("Channel Messages")) {
                    withAnimation(theme.motion.quick) { page = .history }
                }
                Divider()
                Button(L("Import Automations…")) { importEvents() }
                Button(L("Export Automations…")) { exportEvents() }
                    .disabled(manager.events.isEmpty)
            },
            toolbar: {
                if !triggerEvents.isEmpty {
                    SettingsHeaderToolbar(searchText: $searchText, searchPlaceholder: "Search automations")
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            SettingsEmptyState(
                icon: "bolt.fill",
                title: "Add Your First Automation",
                subtitle: L(
                    "An automation runs a workflow, an agent, or one model answer on a schedule, when files in a folder change, or when a webhook URL is called."
                ),
                examples: [
                    .init(
                        icon: "calendar.badge.clock", title: L("Morning Briefing"),
                        description: L("Every day at 8:00, summarize the news"),
                        action: { editor = EventEditorRequest(template: .schedule) }),
                    .init(
                        icon: "folder.badge.gearshape", title: L("Inbox Folder"),
                        description: L("When a file lands in ~/Inbox, file it"),
                        action: { editor = EventEditorRequest(template: .folder) }),
                    .init(
                        icon: "link", title: L("Webhook"), description: L("Start a workflow from GitHub, Zapier or n8n"),
                        action: { editor = EventEditorRequest(template: .webhook) }),
                ],
                primaryAction: .init(title: L("Add Automation"), icon: "plus", handler: { editor = EventEditorRequest() }),
                hasAppeared: hasAppeared
            )
            channelRulesNote
                .padding(.horizontal, theme.space.s24)
                .padding(.bottom, theme.space.s24)
        }
    }

    // MARK: - List

    /// Automations that run on their own. Channel automations are routing
    /// rules and live on their channel (Channels → the platform → Routing).
    private var triggerEvents: [OsaurusEvent] {
        manager.events.filter { $0.sourceKind != .channelMessage }
    }

    private var channelRuleCount: Int {
        manager.events.count - triggerEvents.count
    }

    private var filteredEvents: [OsaurusEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return triggerEvents.filter { event in
            guard !query.isEmpty else { return true }
            return event.name.lowercased().contains(query)
                || event.sourceSummary.lowercased().contains(query)
                || EventInspection.actionLabel(event).lowercased().contains(query)
        }
    }

    private var list: some View {
        ScrollView {
            SettingsPageContent {
                ForEach(EventSourceRegistry.listKinds, id: \.self) { kind in
                    let group = EventSourceRegistry.descriptor(for: kind)
                    let events = filteredEvents.filter { $0.sourceKind == kind }
                    if !events.isEmpty {
                        SettingsSection(
                            title: group.listTitle,
                            caption: "\(events.count)",
                            subtitle: group.listSubtitle
                        ) {
                            ForEach(events) { event in
                                row(for: event)
                            }
                        }
                    }
                }
                if filteredEvents.isEmpty {
                    SettingsEmptyState(inline: "line.3.horizontal.decrease.circle", title: "No automations match.")
                        .padding(.vertical, theme.settingsSectionGap)
                }
                channelRulesNote
            }
        }
    }

    /// Where channel messages went: a pointer, not a second list.
    @ViewBuilder
    private var channelRulesNote: some View {
        if channelRuleCount > 0 {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .glyphSize(11)
                    .foregroundColor(theme.text.tertiary)
                Text(
                    channelRuleCount == 1
                        ? L("1 channel routing rule is set on its channel.")
                        : L("\(channelRuleCount) channel routing rules are set on their channels.")
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                Button {
                    AppDelegate.shared?.showManagementWindow(initialTab: .agentChannels)
                } label: {
                    HStack(spacing: theme.space.s4) {
                        Text("Open Channels", bundle: .module)
                        Image(systemName: "arrow.up.right").glyphSize(8, weight: .semibold)
                    }
                    .componentInspectionText(50, role: .caption, fallback: .footnote, weight: 500, theme: theme)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.text.link)
                Spacer(minLength: 0)
            }
            .settingsLandingAnchor("automations.channelRulesNote")
        }
    }

    private func row(for event: OsaurusEvent) -> some View {
        EventRowView(
            event: event,
            isRunning: manager.isRunning(event.id),
            queued: manager.queuedCount(event.id),
            onOpen: { detailEventId = event.id },
            onToggle: { enabled in
                manager.setEnabled(event.id, enabled: enabled)
                showToast(enabled ? L("Turned on \"\(event.name)\"") : L("Turned off \"\(event.name)\""))
            },
            onFireNow: { fireNow(event) },
            onEdit: { editor = EventEditorRequest(existing: event) },
            onDelete: { pendingDelete = event }
        )
    }

    // MARK: - Actions

    private func save(_ event: OsaurusEvent, isNew: Bool) {
        if isNew {
            manager.create(event, telemetryOrigin: "user")
            showToast(L("Created \"\(event.name)\""))
            if event.sourceKind == .webhook { detailEventId = event.id }
        } else {
            manager.update(event)
            showToast(L("Saved \"\(event.name)\""))
        }
    }

    private func fireNow(_ event: OsaurusEvent) {
        Task {
            let result = await manager.fireNow(event.id)
            if result.accepted {
                showToast(L("Started \"\(event.name)\""))
            } else {
                showToast(L("\"\(event.name)\" did not run: \(result.status.displayName)"), type: .warning)
            }
        }
    }

    private func consumePageRequest() {
        guard let requested = managementState.automationsSubTabRequest else { return }
        managementState.automationsSubTabRequest = nil
        if let match = AutomationsPage(rawValue: requested) { page = match }
    }

    private func consumePendingEditRequest() {
        guard let pending = managementState.pendingEventEditId else { return }
        if let match = manager.event(for: pending) {
            editor = EventEditorRequest(existing: match)
        }
        managementState.pendingEventEditId = nil
    }

    private func consumePendingDetailRequest() {
        guard let pending = managementState.pendingEventDetailId else { return }
        if manager.event(for: pending) != nil {
            page = .automations
            detailEventId = pending
        }
        managementState.pendingEventDetailId = nil
    }

    private func exportEvents() {
        let panel = NSSavePanel()
        panel.title = L("Export Automations")
        panel.prompt = L("Export")
        panel.nameFieldStringValue = "osaurus-automations.yaml"
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]
        panel.canCreateDirectories = true
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            do {
                let document = ConfigExporter.export(sections: [.automations])
                let yaml = try ConfigYAML.encode(document)
                try yaml.write(to: url, atomically: true, encoding: .utf8)
                showToast(L("Exported \(manager.events.count) automations"))
            } catch {
                showToast(L("Export failed: \(error.localizedDescription)"), type: .error)
            }
        }
    }

    private func importEvents() {
        let panel = NSOpenPanel()
        panel.title = L("Import Automations")
        panel.prompt = L("Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "yaml") ?? .plainText, UTType(filenameExtension: "yml") ?? .plainText,
            .json, .plainText,
        ]
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let summary = try await EventsImport.apply(yaml: text)
                showToast(summary, type: .success)
            } catch let issues as ConfigPlanIssues {
                showToast(L("Import failed: \(issues.issues.first ?? "")"), type: .error)
            } catch {
                showToast(L("Import failed: \(error.localizedDescription)"), type: .error)
            }
        }
    }

    private func showToast(_ message: String, type: SimpleToastType = .success) {
        withAnimation(theme.motion.springAnimation) { toast = (message, type) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.motion.quick) { toast = nil }
        }
    }
}

/// Imports an events document (YAML or JSON) through the declarative
/// pipeline, so a file imports exactly like `osaurus_config` would apply it.
/// Only the `events` section (and the legacy `schedules` / `watchers`) is
/// read; anything else in the file is ignored.
@MainActor
enum EventsImport {
    struct NothingToImport: LocalizedError {
        var errorDescription: String? { L("The file has no automations.") }
    }

    static func apply(yaml: String) async throws -> String {
        let decoded = try ConfigYAML.decode(yaml)
        let document = decoded.filtered(to: [.automations])
        guard document.automations != nil || document.legacySchedules != nil || document.legacyWatchers != nil else {
            throw NothingToImport()
        }
        _ = try ConfigPlanner.plan(document: document, prune: false)
        let results = await ConfigApplier.apply(document: document, prune: false, caller: .fileImport)
        let failed = results.filter { $0.status == .failed }
        let applied = results.count - failed.count
        if let first = failed.first {
            return L("Imported \(applied) automations; \(failed.count) failed (\(first.target): \(first.message ?? ""))")
        }
        return L("Imported \(applied) automations")
    }
}

struct EventEditorRequest: Identifiable {
    let id = UUID()
    var existing: OsaurusEvent?
    /// Pre-selected source for a new event (Agents → Add Event).
    var template: EventSourceTemplate?
    var initialAgentId: UUID?
    /// The connection a channel template starts on (the sheet it came from).
    var initialConnectionId: String?
}

private struct EventDetailRequest: Identifiable {
    let id: UUID
}

// MARK: - Row

private struct EventRowView: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let event: OsaurusEvent
    let isRunning: Bool
    let queued: Int
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void
    let onFireNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        LibraryRow(
            title: event.name,
            subtitle: flow,
            action: onOpen
        ) {
            SettingsIconTile(
                icon: EventSourceTemplate.icon(for: event),
                tint: event.isEnabled ? nil : theme.text.tertiary
            )
        } badges: {
            if SelfScheduleAutomations.isAgentOwned(event) {
                StatusChip(L("Agent-scheduled"), tone: .neutral)
            }
            statusBadge
        } trailing: {
            // Always laid out so revealing it on hover never shifts the row.
            SettingsIconButton("play.fill", help: "Run Now", action: onFireNow)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)

            Toggle("", isOn: Binding(get: { event.isEnabled }, set: onToggle))
                .settingsSwitch()
        } menu: {
            Button(L("Run Now"), action: onFireNow)
            Button(L("Edit"), action: onEdit)
            Divider()
            Button(L("Delete"), role: .destructive, action: onDelete)
        }
        .onHover { isHovering = $0 }
    }

    /// When → Do → Result, in one line.
    private var flow: String {
        [event.sourceSummary, EventInspection.actionLabel(event), EventInspection.resultLabel(event)]
            .joined(separator: " → ")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isRunning {
            StatusChip(queued > 0 ? L("Running · \(queued) queued") : L("Running"), tone: .accent)
        } else if let problem = EventInspection.targetProblem(event) {
            StatusChip(L("Needs attention"), tone: .warning)
                .help(problem.message)
        } else if !event.isEnabled {
            StatusChip(L("Off"), tint: theme.text.tertiary)
        } else if let next = event.nextRunDescription {
            StatusChip(next, tone: .neutral)
        } else if let status = event.lastStatus {
            StatusChip(
                status.displayName,
                tint: status == .failed
                    ? theme.status.error.foreground
                    : status == .succeeded ? theme.status.success.foreground : theme.text.secondary
            )
        }
    }
}

