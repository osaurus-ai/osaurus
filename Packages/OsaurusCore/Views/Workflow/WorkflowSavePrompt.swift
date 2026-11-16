//
//  WorkflowSavePrompt.swift
//  osaurus
//
//  The confirm card `workflow_propose_save` raises. The Architect's turn has
//  already ended; Save is the only thing that writes the template. Once
//  saved, the card offers Try It, which opens the workflow's run form in
//  the Workflows window with its example filled in, and Share, which opens
//  Workflows on the share sheet for it.
//

import SwiftUI

@MainActor
public final class WorkflowSavePromptState: ObservableObject {
    public let draftID: UUID
    public let name: String
    public let version: Int
    public let changelog: String
    /// The saved workflow this save makes the next version of.
    public let updates: String?
    /// Test runs since the steps last changed, shown so the user approves
    /// what was actually proven, not only the changelog line.
    public let evidence: WorkflowTestEvidence
    /// Set when saving renames the installed workflow.
    public let renameNotice: String?
    /// What the saved workflow reads and saves on this Mac.
    let access: WorkflowAccessScope?
    /// The automation the Architect proposed with the save.
    let trigger: WorkflowDraftTrigger?
    /// Whether Save also creates `trigger`.
    @Published var includeTrigger = true
    @Published var error: String?
    /// What happened to the trigger after Save, when it did not simply apply.
    @Published private(set) var triggerNote: String?
    @Published private(set) var saved: InstalledWorkflow?
    private var resolved = false

    init(
        draftID: UUID, name: String, version: Int, changelog: String, updates: String? = nil,
        evidence: WorkflowTestEvidence? = nil, trigger: WorkflowDraftTrigger? = nil
    ) {
        self.draftID = draftID
        self.name = name
        self.version = version
        self.changelog = changelog
        self.updates = updates
        self.evidence = evidence ?? WorkflowDraftStore.shared.testEvidence(draftID)
        let draft = WorkflowDraftStore.shared.draft(id: draftID)
        self.renameNotice = draft.flatMap(WorkflowDraftSaver.renameNotice)
        self.access = draft.map { WorkflowAccessScope.derive($0.definition) }
        self.trigger = trigger
    }

    /// "Name · v3", naming the saved workflow when the draft was renamed.
    var title: String {
        guard version > 1 else { return name }
        if let updates, updates != name { return L("\(name) · v\(version) of \(updates)") }
        return "\(name) · v\(version)"
    }

    /// True when saved.
    func save() -> Bool {
        guard !resolved else { return false }
        do {
            let installed = try WorkflowDraftSaver.save(draftID: draftID, changelog: changelog)
            resolved = true
            saved = installed
            WorkflowDraftTrigger.setProposed(nil, for: draftID)
            if let trigger, includeTrigger {
                applyTrigger(trigger, to: installed)
            }
            ToastManager.shared.success(
                L("Workflow saved"),
                message: L("\(installed.name) is saved. Find it under Workflows beside any chat."))
            return true
        } catch {
            self.error = WorkflowErrorText.text(error)
            return false
        }
    }

    private func applyTrigger(_ trigger: WorkflowDraftTrigger, to installed: InstalledWorkflow) {
        let result = trigger.apply(to: installed)
        let outcome: String
        switch result?.status {
        case .done?:
            triggerNote = L("Automation “\(trigger.entry.name)” is set: \(trigger.summary).")
            outcome = "The automation `\(trigger.entry.name)` was created (\(trigger.summary))."
        case .needsUserAction?:
            triggerNote = L("Automation “\(trigger.entry.name)” is set. Finish it in Settings → Automations.")
            outcome =
                "The automation `\(trigger.entry.name)` was created and needs the user in Settings → Automations: "
                + (result?.message ?? "")
        default:
            let message = result?.message ?? L("It could not be created.")
            triggerNote = L("The workflow is saved, but its automation was not: \(message)")
            outcome = "The automation `\(trigger.entry.name)` was NOT created: \(message)"
        }
        WorkflowDraftStore.shared.notePending(draftID, outcome)
    }

    /// Opens the saved workflow's run form in the Workflows window, filled
    /// with the first example.
    func tryIt() {
        guard let saved else { return }
        if let example = saved.definition.examples.first?.input.objectValue {
            WorkflowRunLauncher.stagePrefill(example, for: saved.id)
        }
        WorkflowRunLauncher.openTab(workflowID: saved.id)
    }

    /// Opens Workflows with Share up for the saved workflow: save it as a
    /// file, or publish it.
    func share() {
        guard let saved else { return }
        ChatWindowManager.shared.showWorkflowsSurface(tab: .all)
        ManagementStateManager.shared.pendingWorkflowShare = saved.templateID
    }

    /// The published listing this save answers a change request on.
    var awaitingResubmit: WorkflowRegistryRecord? {
        guard let saved,
            let record = WorkflowRegistryRecordStore.shared.record(for: saved.templateID),
            PublishReviewState(record: record).phase == .changesRequested
        else { return nil }
        return record
    }

    /// Opens Share on the publish step, ready to resubmit this version.
    func resubmit() {
        guard let saved else { return }
        ChatWindowManager.shared.showWorkflowsSurface(tab: .published)
        ManagementStateManager.shared.pendingWorkflowShareResubmits = true
        ManagementStateManager.shared.pendingWorkflowShare = saved.templateID
    }

    func cancel() {
        guard !resolved else { return }
        resolved = true
        WorkflowDraftStore.shared.notePending(draftID, "The user chose not to save yet.")
    }
}

struct WorkflowSavePromptOverlay: View {
    @ObservedObject var state: WorkflowSavePromptState
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        PromptOverlayHost(onCancelDismiss: cancel) {
            PromptCard(
                pillIcon: state.saved == nil ? "square.and.arrow.down" : "checkmark.circle",
                pillLabel: state.saved == nil ? "Save workflow?" : "Saved",
                title: state.title,
                descriptionMarkdown: state.saved == nil
                    ? state.changelog
                    : state.awaitingResubmit != nil
                        ? L("It's on this Mac and ready to run. Resubmit it so the Osaurus team can review the fix.")
                        : L("It's on this Mac and ready to run. Try it with the example from testing, or share it."),
                footnote: state.saved == nil
                    ? PromptCardFootnote(
                        icon: "flowchart",
                        text: "Saving installs it on this Mac, set up with the models used in testing.")
                    : nil,
                onCancel: cancel
            ) {
                if state.saved == nil {
                    if let notice = state.renameNotice {
                        WorkflowRenameNotice(text: notice)
                    }
                    WorkflowTestEvidenceView(evidence: state.evidence)
                    if let access = state.access {
                        WorkflowAccessLine(scope: access)
                    }
                    if let trigger = state.trigger {
                        WorkflowSaveTriggerRow(trigger: trigger, isOn: $state.includeTrigger)
                    }
                } else if let note = state.triggerNote {
                    Text(verbatim: note)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = state.error {
                    Text(error)
                        .textStyle(.caption)
                        .foregroundColor(theme.status.error.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } inputRow: {
                if state.saved != nil {
                    savedRow
                } else {
                    confirmRow
                }
            }
        }
    }

    private var savedRow: some View {
        HStack(spacing: theme.space.s8) {
            Spacer()
            Button(action: onDismiss) {
                Text(localized: "Done")
            }
            .buttonStyle(.settings(.tertiary))
            if state.awaitingResubmit != nil {
                Button {
                    state.tryIt()
                    onDismiss()
                } label: {
                    Label {
                        Text(localized: "Try It")
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.settings(.secondary))
                Button {
                    state.resubmit()
                    onDismiss()
                } label: {
                    Label {
                        Text(localized: "Resubmit for Review…")
                    } icon: {
                        Image(systemName: "paperplane")
                    }
                }
                .buttonStyle(.settings(.primary))
                .keyboardShortcut(.defaultAction)
                .help(L("Publish this version for the Osaurus team to review"))
                .settingsLandingAnchor("workflows.shareAfterSave")
            } else {
                Button {
                    state.share()
                    onDismiss()
                } label: {
                    Label {
                        Text(localized: "Share…")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.settings(.secondary))
                .help(L("Save it as a file, or publish a page you control"))
                .settingsLandingAnchor("workflows.shareAfterSave")
                Button {
                    state.tryIt()
                    onDismiss()
                } label: {
                    Label {
                        Text(localized: "Try It")
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.settings(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var confirmRow: some View {
        HStack(spacing: theme.space.s8) {
            Spacer()
            Button(action: cancel) {
                Text(localized: "Not Now")
            }
            .buttonStyle(.settings(.tertiary))
            Button(action: save) {
                Text(localized: "Save")
            }
            .buttonStyle(.settings(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(!state.evidence.satisfied)
            .help(state.evidence.blocker ?? L("Save this workflow on this Mac"))
        }
    }

    private func save() {
        _ = state.save()
    }

    private func cancel() {
        state.cancel()
        onDismiss()
    }
}


// MARK: - Rename notice

/// "Also renames the workflow from …", on both save surfaces when saving
/// changes the name agents and the Orchestrator call.
struct WorkflowRenameNotice: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        Label {
            Text(verbatim: text)
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "character.cursor.ibeam")
                .foregroundColor(theme.text.link)
        }
    }
}

// MARK: - Trigger

/// "Then run it: Schedule · Every day at 8:00 AM", with the checkbox that
/// decides whether Save also creates the automation.
struct WorkflowSaveTriggerRow: View {
    let trigger: WorkflowDraftTrigger
    @Binding var isOn: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Toggle(isOn: $isOn) {
                Text(verbatim: L("Then run it: \(trigger.summary)"))
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsCheckbox()
            .help(L("Save also creates the automation “\(trigger.entry.name)” in Settings → Automations"))
            ForEach(trigger.notes, id: \.self) { note in
                Text(verbatim: note)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Evidence

/// What testing proved since the steps last changed: each run with its
/// example, pass/fail, time, the failed step, and a glimpse of the output.
/// Shown in both save surfaces so approval is of evidence, not a promise.
struct WorkflowTestEvidenceView: View {
    let evidence: WorkflowTestEvidence

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Text(verbatim: headline)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.primary)
            }
            if let blocker = evidence.blocker {
                Text(verbatim: blocker)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(evidence.rows.prefix(4)) { row in
                rowView(row)
            }
            if evidence.rows.count > 4 {
                Text(verbatim: L("and \(evidence.rows.count - 4) more"))
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.tinted(tint))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).strokeBorder(theme.rule(around: tint)))
        .settingsLandingAnchor("workflows.saveEvidence")
    }

    private var tint: Color {
        if evidence.satisfied { return evidence.passed > 0 ? theme.status.success.foreground : theme.text.secondary }
        return evidence.failed > 0 ? theme.status.error.foreground : theme.status.warning.foreground
    }

    private var icon: String {
        if evidence.passed > 0 { return "checkmark.seal.fill" }
        if evidence.failed > 0 { return "xmark.octagon.fill" }
        return evidence.nonTrivial ? "exclamationmark.triangle.fill" : "pencil"
    }

    private var headline: String {
        if evidence.rows.isEmpty {
            return evidence.nonTrivial ? L("Not tested since the steps changed") : L("Only the name or summary changed")
        }
        var parts: [String] = []
        if evidence.passed > 0 { parts.append(evidence.passed == 1 ? L("1 test passed") : L("\(evidence.passed) tests passed")) }
        if evidence.failed > 0 { parts.append(evidence.failed == 1 ? L("1 failed") : L("\(evidence.failed) failed")) }
        return parts.joined(separator: ", ")
    }

    private func rowView(_ row: WorkflowTestEvidence.Row) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: row.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .glyphSize(.micro)
                    .foregroundColor(
                        row.status == .completed ? theme.status.success.foreground : theme.status.error.foreground
                    )
                Text(verbatim: row.label)
                    .textStyle(.footnote, weight: 500)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Spacer()
                if let ms = row.durationMs {
                    Text(verbatim: WorkflowStepRisk.duration(ms))
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            if let step = row.failedStep {
                Text(verbatim: row.error.map { L("Failed at \(step): \($0)") } ?? L("Failed at \(step)"))
                    .textStyle(.footnote)
                    .foregroundColor(theme.status.error.foreground)
                    .lineLimit(2)
            } else if let error = row.error {
                Text(verbatim: error)
                    .textStyle(.footnote)
                    .foregroundColor(theme.status.error.foreground)
                    .lineLimit(2)
            } else if let preview = row.outputPreview, !preview.isEmpty {
                Text(verbatim: preview)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(preview)
            }
        }
    }
}
