//
//  ConfigApprovalModal.swift
//  OsaurusCore
//
//  The dedicated in-chat approval dialog for `osaurus_config` applies.
//  Presented through the ThemedAlert system (per-window `ThemedAlertHost`)
//  so it gets the standard modal treatment — theme-aware dim, glass card,
//  Esc / Return handling — instead of hand-rolling its own. Driven by
//  `ConfigApprovalQueue`: the custom content renders the structured plan
//  (grouped by section, with per-field change lines, risk callouts, and a
//  prune warning) and resolves the tool's awaiting continuation on Apply /
//  Cancel. Mounted by the main chat; mounting also registers the surface
//  so `ConfigApprovalService` knows a dialog can be shown instead of
//  falling back to the modal panel.
//

import Combine
import SwiftUI

/// Plan-review presenter driven by `ConfigApprovalQueue`. Draws nothing
/// itself: it routes the pending request into `ThemedAlertCenter` as a
/// `customContent` alert, so the per-window `ThemedAlertHost` renders it
/// exactly like every other modal.
struct ConfigApprovalModal: View {
    /// The window's alert scope, passed explicitly by the mounting chat
    /// view. The scope environment doesn't reach this overlay level (see
    /// the note in `ThemedAlertHost`), so it can't be read from there.
    let scope: ThemedAlertScope

    @ObservedObject private var queue = ConfigApprovalQueue.shared

    /// Queue request currently presented as a themed alert; the alert
    /// reuses the request's id.
    @State private var presentedId: UUID?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear {
                queue.surfaceDidMount()
                syncPresentation()
            }
            .onDisappear {
                queue.surfaceDidUnmount()
                if let id = presentedId {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: id)
                    presentedId = nil
                }
            }
            .onChange(of: queue.pending.first?.id) { _, _ in
                syncPresentation()
            }
    }

    /// Keep the themed alert in step with the head of the queue: dismiss a
    /// stale presentation (the request resolved elsewhere — Apply/Cancel in
    /// another window, timeout, turn cancellation) and present the next.
    private func syncPresentation() {
        let request = queue.pending.first
        guard request?.id != presentedId else { return }
        if let stale = presentedId {
            ThemedAlertCenter.shared.dismiss(scope: scope, id: stale)
            presentedId = nil
        }
        guard let request else { return }
        if let review = request.importReview {
            presentImport(request, review: review)
            return
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: request.id,
                title: L("Review configuration changes"),
                message: nil,
                // The plan list under a "?" badge reads as noise; the
                // content dialog convention is title-only.
                showsHeaderIcon: false,
                // The visible buttons live in `customContent` (which
                // replaces the standard row); this cancel entry backs the
                // Esc path — ChatView's window-level Esc monitor resolves
                // it through `cancelActive`.
                buttons: [
                    .cancel(L("Cancel")) {
                        queue.resolve(id: request.id, outcome: .denied)
                    }
                ],
                customContent: AnyView(ConfigApprovalPlanContent(request: request) { outcome in
                    queue.resolve(id: request.id, outcome: outcome)
                }),
                width: 460,
                // Let an unrelated alert landing mid-review stack above the
                // dialog instead of clobbering it — clobbering runs
                // onDismiss, which would silently deny the pending apply.
                hostsNestedAlerts: true,
                onDismiss: {
                    // Every dismissal path that isn't Apply denies the
                    // pending apply. `resolve` is idempotent, so the
                    // buttons resolving first is fine.
                    queue.resolve(id: request.id, outcome: .denied)
                }
            ).promptInspectionScope(),
            scope: scope
        )
        presentedId = request.id
    }

    private func presentImport(_ request: ConfigApprovalRequest, review: ChatImportReview) {
        let id = request.id
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: id,
                title: L("Review what to install"),
                message: nil,
                showsHeaderIcon: false,
                buttons: [
                    .cancel(L("Cancel")) {
                        queue.resolve(id: id, outcome: .denied)
                    }
                ],
                customContent: AnyView(
                    ChatImportReviewView(
                        requestId: id, review: review,
                        onCancel: { queue.resolve(id: id, outcome: .denied) },
                        onInstall: { queue.resolve(id: id, outcome: .approved) }
                    )),
                width: 500,
                hostsNestedAlerts: true,
                onDismiss: {
                    queue.resolve(id: id, outcome: .denied)
                }
            ).promptInspectionScope(),
            scope: scope
        )
        presentedId = id
    }
}

/// The same plan content is hosted by the alert and the inspector.
private struct ConfigApprovalPlanContent: View {
    @Environment(\.theme) private var environmentTheme
    let request: ConfigApprovalRequest
    var resolve: ((ConfigApprovalOutcome) -> Void)? = nil

    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(36, authoritative: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.planContent.verticalGap", inheriting: PromptInspectionStyle.metric("gap", 12, theme))) {
            if request.plan.hasHighRiskChanges {
                HStack {
                    Spacer(minLength: 0)
                    StatusChip(L("HIGH RISK"), tone: .urgentWarning)
                        .environment(\.theme, PromptInspectionStyle.badgeTheme(environmentTheme))
                    Spacer(minLength: 0)
                }
            }

            if request.prune {
                pruneBanner
            }

            planList(request.plan)

            if let diff = request.plan.diffText, !diff.isEmpty {
                ConfigDiffDisclosure(text: diff)
            }

            if !request.plan.notes.isEmpty {
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.planContent.verticalGap2", inheriting: PromptInspectionStyle.metric("gap", 2, theme))) {
                    ForEach(Array(request.plan.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .promptText(.caption, fallback: .micro, theme: theme)
                            .foregroundColor(theme.text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.planContent.verticalGap2")
            }

            HStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.planContent.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", 10, theme))) {
                Spacer()
                // Resolving pops the request off the queue, which drives
                // `syncPresentation` to dismiss the alert.
                secondaryButton(L("Cancel")) {
                    resolve?(.denied)
                }
                primaryButton(L("Apply Changes")) {
                    resolve?(.approved)
                }
            }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.planContent.horizontalGap")
                .disabled(resolve == nil)
        }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.planContent.verticalGap")
        .environment(\.theme, theme)
    }

    private var pruneBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.pruneBanner.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", 6, theme))) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(11)
                .foregroundColor(theme.status[.urgentWarning].foreground)
            Text(
                "Prune is on: entries not listed in the document will be deleted.",
                bundle: .module
            )
            .promptText(.body, fallback: .footnote, weight: 500, theme: theme)
            .foregroundColor(theme.status[.urgentWarning].foreground)
            .fixedSize(horizontal: false, vertical: true)
        }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.pruneBanner.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.pruneBanner.padding.horizontal", inheriting: PromptInspectionStyle.metric("padding", 8, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.pruneBanner.padding.vertical", inheriting: PromptInspectionStyle.metric("padding", 8, theme))).catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.pruneBanner.padding.horizontal").catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.pruneBanner.padding.vertical")
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium).fill(theme.status[.urgentWarning].background)
        )
    }

    // MARK: - Plan rendering

    private func planList(_ plan: ConfigPlan) -> some View {
        let sections = groupedActions(plan)
        return ScrollView {
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.planList.verticalGap", inheriting: PromptInspectionStyle.metric("gap", 10, theme))) {
                ForEach(sections, id: \.section) { group in
                    VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.planList.verticalGap2", inheriting: PromptInspectionStyle.metric("gap", 5, theme))) {
                        Text(group.section)
                            .promptText(.caption, fallback: .micro, weight: 700, theme: theme)
                            .foregroundColor(theme.text.tertiary)
                            .textCase(.uppercase)
                        ForEach(Array(group.actions.enumerated()), id: \.offset) { _, action in
                            actionRow(action)
                        }
                    }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.planList.verticalGap2")
                }
            }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.planList.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.planList.padding.horizontal", inheriting: PromptInspectionStyle.metric("padding", 10, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.planList.padding.vertical", inheriting: PromptInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.planList.padding.horizontal").catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.planList.padding.vertical")
        }
        .frame(maxHeight: 240)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.surface.hover)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default)
                )
        )
    }

    private func actionRow(_ action: ConfigPlanAction) -> some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.actionRow.verticalGap", inheriting: PromptInspectionStyle.metric("gap", 2, theme))) {
            HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.actionRow.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", 6, theme))) {
                Text(kindSymbol(action.kind))
                    .promptText(.code, fallback: .code, weight: 700, theme: theme)
                    .foregroundColor(kindColor(action.kind))
                    .frame(width: 12, alignment: .center)
                Text(action.target)
                    .promptText(.label, fallback: .caption, weight: 500, theme: theme)
                    .foregroundColor(theme.text.primary)
                if action.longRunning {
                    StatusChip(L("LONG-RUNNING"), tone: .info)
                        .environment(\.theme, PromptInspectionStyle.badgeTheme(environmentTheme))
                }
                Spacer(minLength: 0)
            }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.actionRow.horizontalGap")
            ForEach(Array(action.changes.enumerated()), id: \.offset) { _, change in
                Text(change)
                    .promptText(.code, fallback: .footnote, family: .code, theme: theme)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
            ForEach(Array(action.risks.enumerated()), id: \.offset) { _, risk in
                HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.actionRow.horizontalGap2", inheriting: PromptInspectionStyle.metric("gap", 4, theme))) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .glyphSize(9)
                        .foregroundColor(theme.status.warning.foreground)
                    Text(risk)
                        .promptText(.body, fallback: .footnote, weight: 500, theme: theme)
                        .foregroundColor(theme.status.warning.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.actionRow.horizontalGap2")
                .padding(.leading, 18)
            }
        }.catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.actionRow.verticalGap")
    }

    private struct SectionGroup {
        var section: String
        var actions: [ConfigPlanAction]
    }

    private func groupedActions(_ plan: ConfigPlan) -> [SectionGroup] {
        var out: [SectionGroup] = []
        for action in plan.actions {
            if let last = out.indices.last, out[last].section == action.section {
                out[last].actions.append(action)
            } else {
                out.append(SectionGroup(section: action.section, actions: [action]))
            }
        }
        return out
    }

    private func kindSymbol(_ kind: ConfigPlanAction.Kind) -> String {
        switch kind {
        case .create: return "+"
        case .update: return "~"
        case .delete: return "−"
        case .needsUserInput: return "?"
        }
    }

    private func kindColor(_ kind: ConfigPlanAction.Kind) -> Color {
        switch kind {
        case .create: return theme.status.success.foreground
        case .update: return theme.status.info.foreground
        case .delete: return theme.status.error.foreground
        case .needsUserInput: return theme.status.warning.foreground
        }
    }

    // MARK: - Chrome

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .promptText(.label, fallback: .caption, weight: 500, theme: theme)
                .foregroundColor(theme.text.secondary)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.secondaryButton.paddingX", inheriting: PromptInspectionStyle.metric("padding", 14, theme))).catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.secondaryButton.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.secondaryButton.paddingY", inheriting: PromptInspectionStyle.metric("padding", 7, theme))).catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.secondaryButton.paddingY")
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(theme.surface.hover)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.strong, lineWidth: theme.stroke.default)
                        )
                )
        }
        .buttonStyle(PlainButtonStyle())
        // Themed-alert convention: Esc activates cancel.
        .keyboardShortcut(.cancelAction)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .promptText(.label, fallback: .caption, weight: 600, theme: theme)
                .foregroundColor(theme.action.primary.default.foreground)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.primaryButton.paddingX", inheriting: PromptInspectionStyle.metric("padding", 14, theme))).catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.primaryButton.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.configApprovalModal.primaryButton.paddingY", inheriting: PromptInspectionStyle.metric("padding", 7, theme))).catalogLayoutTarget("component.library.36.elements.layout.configApprovalModal.primaryButton.paddingY")
                .background(RoundedRectangle(cornerRadius: theme.radius.medium).fill(theme.action.primary.default.background))
        }
        .buttonStyle(PlainButtonStyle())
        // Themed-alert convention: Return activates the primary action.
        .keyboardShortcut(.defaultAction)
    }
}

#if OSAURUS_DESIGN_SYSTEM
extension ConfigApprovalModal {
    @MainActor static func inspectionPlan() -> some View {
        let plan = ConfigPlan(actions: [
            .init(section: "Local samples", target: "New sample", kind: .create, changes: ["name: Sample"]),
            .init(section: "Local samples", target: "Existing sample", kind: .update, changes: ["value: Before → After"], longRunning: true),
            .init(section: "Local samples", target: "Removed sample", kind: .delete, risks: ["Display-only risk callout"]),
            .init(section: "Local samples", target: "Review needed", kind: .needsUserInput)
        ], notes: ["Display only. No configuration request is queued or applied."])
        return ConfigApprovalPlanContent(request: .init(plan: plan, prune: true))
    }
}
#endif
