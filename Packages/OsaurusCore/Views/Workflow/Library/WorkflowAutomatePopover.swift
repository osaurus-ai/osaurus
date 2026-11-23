//
//  WorkflowAutomatePopover.swift
//  osaurus
//
//  The bolt on a sidebar row: one click from running a workflow by hand to
//  running it on its own. Its automations first, each with its switch;
//  then a few schedules (the first marked Suggested when the workflow's
//  name fits one), then the other ways, each finishing on the workflow's
//  page. A schedule that needs nothing more is made at once and can be
//  undone from the toast.
//

import SwiftUI

struct WorkflowAutomatePopover: View {
    @Environment(\.theme) private var theme

    let workflow: InstalledWorkflow
    /// Closes the popover and opens the workflow's page doing this.
    let onOpenPage: (WorkflowAutomationIntent) -> Void
    /// Closes the popover and shows Home's Ways to automate.
    let onSeeAllWays: () -> Void
    let onClose: () -> Void

    static let width: CGFloat = 340

    private var manager: EventManager { .shared }

    /// Dark themes paint `border.subtle` the same as `surface.overlay`.
    private var rule: Color { theme.isDark ? theme.border.default : theme.border.subtle }

    var body: some View {
        let automations = manager.events(forWorkflowID: workflow.id).sorted { $0.createdAt < $1.createdAt }
        VStack(alignment: .leading, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: L("Run \(workflow.name)…"))
                    .font(SettingsFont.sectionTitle)
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(2)
                Text(verbatim: L("One click and it is set."))
                    .font(SettingsFont.footnote)
                    .foregroundStyle(theme.text.secondary)
            }
            if !automations.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    ForEach(automations) { event in existingRow(event) }
                }
                ThemeHairlineDivider(color: rule)
                Text(verbatim: L("Add another"))
                    .font(SettingsFont.compactLabel)
                    .foregroundStyle(theme.text.secondary)
            }
            VStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(AutomationPresets.presets(name: workflow.name, summary: workflow.summary)) { preset in
                    row(icon: icon(preset.kind), title: preset.title, isSuggested: preset.isSuggested) { choose(preset.kind) }
                }
            }
            .padding(.horizontal, -WorkflowAutomateRowLabel.inset(theme))
            ThemeHairlineDivider(color: rule)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                row(icon: "folder.badge.gearshape", title: L("When a file shows up in a folder…")) { pickFolder(startingAt: nil) }
                row(icon: "dot.radiowaves.up.forward", title: L("When a site posts something new…")) { onOpenPage(.addFeed) }
                Menu {
                    ForEach(WebhookProvider.services, id: \.self) { provider in
                        Button(provider.shortName) { onOpenPage(.openEditor(.providerWebhook(provider))) }
                    }
                } label: {
                    rowLabel(icon: "app.badge", title: L("When an app has news…"), isSuggested: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .padding(.horizontal, -WorkflowAutomateRowLabel.inset(theme))
            ThemeHairlineDivider(color: rule)
            WorkflowTextLink(title: L("See all ways to automate"), action: onSeeAllWays)
                .padding(.leading, -theme.assignedMetric(SettingsButtonSize.extraSmall.assignment("paddingX"), fallback: theme.space.s6))
        }
        .padding(theme.space.s16)
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    // MARK: Rows

    private func existingRow(_ event: OsaurusEvent) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: EventSourceTemplate.icon(for: event))
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(theme.text.secondary)
                .frame(width: theme.space.s16)
                .accessibilityHidden(true)
            Text(verbatim: AutomationSentence.short(event))
                .font(SettingsFont.compactLabel)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
            Spacer(minLength: theme.space.s8)
            Toggle(
                L("\(workflow.name) automation"),
                isOn: Binding(get: { event.isEnabled }, set: { manager.setEnabled(event.id, enabled: $0) })
            )
            .settingsMiniSwitch()
        }
        .padding(.vertical, theme.space.s4)
    }

    private func row(icon: String, title: String, isSuggested: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(icon: icon, title: title, isSuggested: isSuggested) }
            .buttonStyle(.plain)
    }

    private func rowLabel(icon: String, title: String, isSuggested: Bool) -> some View {
        WorkflowAutomateRowLabel(icon: icon, title: title, isSuggested: isSuggested)
    }

    private func icon(_ kind: AutomationPresets.Kind) -> String {
        switch kind {
        case .schedule: return "calendar.badge.clock"
        case .folder: return "folder.badge.gearshape"
        case .pickDayAndTime: return "slider.horizontal.3"
        }
    }

    // MARK: Actions

    private func choose(_ kind: AutomationPresets.Kind) {
        WorkflowAutomationPresetAction.perform(kind, for: workflow, onClose: onClose, onOpenPage: onOpenPage)
    }

    private func pickFolder(startingAt path: String?) {
        WorkflowAutomationPresetAction.pickFolder(startingAt: path, for: workflow, onClose: onClose, onOpenPage: onOpenPage)
    }
}

/// A one-click preset: a schedule that needs nothing more is made at once
/// and can be undone from the toast; a folder asks which first; anything
/// else opens the workflow's page on the new automation.
@MainActor
enum WorkflowAutomationPresetAction {
    static func perform(
        _ kind: AutomationPresets.Kind, for workflow: InstalledWorkflow, onClose: () -> Void,
        onOpenPage: @escaping (WorkflowAutomationIntent) -> Void
    ) {
        let manager = EventManager.shared
        switch kind {
        case .schedule(let frequency):
            let event = AutomationDefaults.event(for: workflow, source: .schedule(ScheduleSourceConfig(frequency: frequency)))
            let created = manager.create(event, telemetryOrigin: "user")
            if created.isEnabled {
                onClose()
                WorkflowAutomationUndo.offer(
                    created, message: L("\(workflow.name) will run \(AutomationPresets.schedulePhrase(frequency))."))
            } else {
                onOpenPage(.highlight(created.id))
            }
        case .folder(let path):
            pickFolder(startingAt: path, for: workflow, onClose: onClose, onOpenPage: onOpenPage)
        case .pickDayAndTime:
            let created = manager.create(AutomationDefaults.event(for: workflow, source: AutomationDefaults.schedule), telemetryOrigin: "user")
            onOpenPage(.highlight(created.id))
        }
    }

    /// The folder picker is a sheet of its own, so whatever offered it closes first.
    static func pickFolder(
        startingAt path: String?, for workflow: InstalledWorkflow, onClose: () -> Void,
        onOpenPage: @escaping (WorkflowAutomationIntent) -> Void
    ) {
        onClose()
        Task { @MainActor in
            guard let picked = await WorkflowAutomationFolderPicker.pick(startingAt: path) else { return }
            let event = AutomationDefaults.event(
                for: workflow, source: AutomationDefaults.folder(path: picked.path, bookmark: picked.bookmark))
            let created = EventManager.shared.create(event, telemetryOrigin: "user")
            onOpenPage(.highlight(created.id))
        }
    }
}

private struct WorkflowAutomateRowLabel: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let isSuggested: Bool
    @State private var isHovered = false

    /// How far the icon sits inside the hover fill; the list is pulled out
    /// by as much so icons line up with the card's title.
    static func inset(_ theme: any ThemeProtocol) -> CGFloat { theme.space.s8 }

    var body: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(isSuggested ? theme.action.primary.default.background : theme.text.secondary)
                .frame(width: theme.space.s16)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(SettingsFont.compactLabel)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
            Spacer(minLength: theme.space.s8)
            if isSuggested { StatusChip(L("Suggested"), tone: .accent) }
        }
        .padding(.horizontal, Self.inset(theme))
        .padding(.vertical, theme.space.s6)
        .settingsChrome(isHovered ? .hover : nil)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
    }
}

/// "Morning Brief will run every weekday at 6:00 PM." with Undo, which
/// removes the automation again.
enum WorkflowAutomationUndo {
    @MainActor
    static func offer(_ event: OsaurusEvent, message: String) {
        let actionID = "workflow-automation-undo-\(event.id.uuidString)"
        let toasts = ToastManager.shared
        toasts.registerActionHandler(for: actionID) { _ in
            EventManager.shared.delete(id: event.id)
            toasts.unregisterActionHandler(for: actionID)
        }
        let toastID = toasts.action(message, actionTitle: L("Undo"), actionId: actionID)
        toasts.onDismiss(of: toastID) { _ in toasts.unregisterActionHandler(for: actionID) }
    }
}
