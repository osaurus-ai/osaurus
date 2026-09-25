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

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var queue = ConfigApprovalQueue.shared

    /// Queue request currently presented as a themed alert; the alert
    /// reuses the request's id.
    @State private var presentedId: UUID?

    private var theme: ThemeProtocol { themeManager.currentTheme }

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
                customContent: AnyView(planContent(for: request)),
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
            ),
            scope: scope
        )
        presentedId = request.id
    }

    // MARK: - Dialog content

    private func planContent(for request: ConfigApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if request.plan.hasHighRiskChanges {
                HStack {
                    Spacer(minLength: 0)
                    badge(L("HIGH RISK"), color: theme.warningColor)
                    Spacer(minLength: 0)
                }
            }

            if request.prune {
                pruneBanner
            }

            planList(request.plan)

            if !request.plan.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(request.plan.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                // Resolving pops the request off the queue, which drives
                // `syncPresentation` to dismiss the alert.
                secondaryButton(L("Cancel")) {
                    queue.resolve(id: request.id, outcome: .denied)
                }
                primaryButton(L("Apply Changes")) {
                    queue.resolve(id: request.id, outcome: .approved)
                }
            }
        }
    }

    private var pruneBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(theme.warningColor)
            Text(
                "Prune is on: entries not listed in the document will be deleted.",
                bundle: .module
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.warningColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(theme.warningColor.opacity(0.1))
        )
    }

    // MARK: - Plan rendering

    private func planList(_ plan: ConfigPlan) -> some View {
        let sections = groupedActions(plan)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sections, id: \.section) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.section)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .textCase(.uppercase)
                        ForEach(Array(group.actions.enumerated()), id: \.offset) { _, action in
                            actionRow(action)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxHeight: 240)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private func actionRow(_ action: ConfigPlanAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(kindSymbol(action.kind))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(kindColor(action.kind))
                    .frame(width: 12, alignment: .center)
                Text(action.target)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if action.longRunning {
                    badge(L("LONG-RUNNING"), color: theme.accentColor)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(action.changes.enumerated()), id: \.offset) { _, change in
                Text(change)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
            ForEach(Array(action.risks.enumerated()), id: \.offset) { _, risk in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(theme.warningColor)
                    Text(risk)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
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
        case .create: return theme.successColor
        case .update: return theme.accentColor
        case .delete: return theme.errorColor
        case .needsUserInput: return theme.warningColor
        }
    }

    // MARK: - Chrome

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
        }
        .buttonStyle(PlainButtonStyle())
        // Themed-alert convention: Return activates the primary action.
        .keyboardShortcut(.defaultAction)
    }
}
