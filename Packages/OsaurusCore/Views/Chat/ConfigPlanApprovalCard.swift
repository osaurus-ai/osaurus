//
//  ConfigPlanApprovalCard.swift
//  OsaurusCore
//
//  The dedicated in-chat approval card for `osaurus_config` applies.
//  Bottom-pinned like `ComputerUseConfirmOverlay`, driven by
//  `ConfigApprovalQueue`: it renders the structured plan (grouped by
//  section, with per-field change lines, risk callouts, and a prune
//  warning) and resolves the tool's awaiting continuation on Apply /
//  Cancel. Mounted by the main chat; mounting also
//  registers the surface so `ConfigApprovalService` knows a card can be
//  shown instead of falling back to the modal panel.
//

import Combine
import SwiftUI

/// Bottom-pinned plan-review card driven by `ConfigApprovalQueue`.
struct ConfigPlanApprovalCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var queue = ConfigApprovalQueue.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        ZStack {
            if let request = queue.pending.first {
                VStack {
                    Spacer()
                    card(for: request)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: queue.pending.first?.id)
        .onAppear { queue.surfaceDidMount() }
        .onDisappear { queue.surfaceDidUnmount() }
    }

    // MARK: - Card

    private func card(for request: ConfigApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 15))
                    .foregroundColor(theme.accentColor)
                Text("Review configuration changes", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if request.plan.hasHighRiskChanges {
                    badge(L("HIGH RISK"), color: theme.warningColor)
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
                secondaryButton(L("Cancel")) {
                    queue.resolve(id: request.id, outcome: .denied)
                }
                primaryButton(L("Apply Changes")) {
                    queue.resolve(id: request.id, outcome: .approved)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14).stroke(theme.cardBorder, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.2), radius: 16, y: 6)
        )
        .frame(maxWidth: 460)
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
    }
}
