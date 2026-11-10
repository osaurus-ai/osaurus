//
//  AgentAbilitiesOverviewView.swift
//  osaurus
//
//  The Abilities → Overview tab: one place to see and flip everything a
//  custom agent can do. A hero card shows how many abilities are on and a
//  live "estimated startup context" figure that responds to every toggle,
//  priced by `AgentAbilityContextPreview` through the same composer gates
//  the next real send will use. Capability cards below carry the on/off
//  state; deep configuration stays in the specialist tabs (Tools,
//  Subagents, Sandbox, Memory, Database) that the cards link into.
//
//  Motion: state changes animate with a soft spring and the estimate
//  animates numerically, but every animation collapses to a plain update
//  when Reduce Motion is on.
//

import SwiftUI

// MARK: - Overview Container

/// Ability cards for the Overview tab. Context usage lives in the shared
/// fixed card above every Abilities tab, including this one.
struct AgentAbilitiesOverviewView<Cards: View>: View {
    @ViewBuilder let cards: () -> Cards

    var body: some View {
        cards()
    }
}

// MARK: - Shared Context Card

/// Compact Abilities-navigation status. Details live in a popover instead of
/// expanding inline, preserving the destination's vertical workspace.
struct AgentAbilityContextPreviewBar: View {
    let preview: AgentAbilityContextPreview?
    let delta: Int?
    let enabledCount: Int
    let totalCount: Int

    @Environment(\.theme) private var theme
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .glyphSize(10.5, weight: .semibold)
                    .foregroundColor(statusColor)
                Text("Context", bundle: .module)
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.secondary)

                if let delta {
                    deltaChip(delta)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                Text(compactEstimateText)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .contentTransition(.numericText())

                StatusChip(compactImpactLabel, tint: statusColor)

                Image(systemName: "chevron.down")
                    .glyphSize(7.5, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
        .settingsChrome(.control)
        .localizedHelp("Show how much model context this agent uses")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            contextPopover
        }
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .glyphSize(13, weight: .semibold)
                    .foregroundColor(statusColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.medium)
                            .fill(statusColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Context impact", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                            .fixedSize()
                        StatusChip(abilityCountText, tone: .neutral)
                    }
                    Text(summaryText)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(fullEstimateText)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                    Text(impactLabel)
                        .font(SettingsFont.chip)
                        .foregroundColor(statusColor)
                }
            }

            if let preview {
                AgentAbilityContextDetailsView(preview: preview)
            }
        }
        .padding(theme.space.s12)
        .frame(width: 390)
    }

    private var compactEstimateText: String {
        guard let preview else { return "…" }
        let low = AgentAbilityContextPreview.format(tokens: preview.lowTokens)
        if preview.isRange {
            let high = AgentAbilityContextPreview.format(tokens: preview.highTokens)
            return "~\(low)–\(high)"
        }
        return "~\(low)"
    }

    private var fullEstimateText: String {
        guard preview != nil else { return L("Estimating…") }
        return "\(compactEstimateText) tokens"
    }

    private var abilityCountText: String {
        totalCount == 1
            ? L("\(enabledCount) of 1 ability on")
            : L("\(enabledCount) of \(totalCount) abilities on")
    }

    private var summaryText: String {
        guard let preview else {
            return L("Estimating how much of the model's working space this agent uses.")
        }
        if let fraction = preview.usableWindowFraction {
            return L(
                "This agent uses \(windowPercent(fraction)) of the model's working space before you start chatting."
            )
        }
        return L("This setup is loaded into the model before you start chatting.")
    }

    private var statusColor: Color {
        guard let preview else { return theme.action.primary.default.background }
        switch preview.severity {
        case .normal: return theme.action.primary.default.background
        case .warning: return theme.status.warning.foreground
        case .critical: return theme.status.error.foreground
        }
    }

    private var impactLabel: String {
        guard let preview else { return L("Estimating") }
        switch preview.severity {
        case .warning:
            return L("High impact")
        case .critical:
            return L("At the limit")
        case .normal:
            guard let fraction = preview.usableWindowFraction else {
                return L("Estimated")
            }
            return fraction < 0.10 ? L("Low impact") : L("Moderate impact")
        }
    }

    private var compactImpactLabel: String {
        guard let preview else { return "…" }
        switch preview.severity {
        case .warning: return L("High")
        case .critical: return L("Limit")
        case .normal:
            guard let fraction = preview.usableWindowFraction else { return L("Estimate") }
            return fraction < 0.10 ? L("Low") : L("Moderate")
        }
    }

    private var controlFill: Color {
        guard let preview else { return theme.surface.raised }
        switch preview.severity {
        case .normal: return theme.surface.raised
        case .warning: return theme.status.warning.background
        case .critical: return theme.status.error.background
        }
    }

    private var controlBorder: Color {
        guard let preview else { return theme.border.default }
        switch preview.severity {
        case .normal: return theme.border.default
        case .warning: return theme.status.warning.border
        case .critical: return theme.status.error.border
        }
    }

    private func deltaChip(_ delta: Int) -> some View {
        let magnitude = AgentAbilityContextPreview.format(tokens: abs(delta))
        let text = delta > 0 ? "+\(magnitude)" : "−\(magnitude)"
        let color = delta > 0 ? theme.status.warning.foreground : theme.action.primary.default.background
        return StatusChip(text, tint: color)
    }

    private func windowPercent(_ fraction: Double) -> String {
        let pct = fraction * 100
        return pct < 1 ? "<1%" : "\(Int(pct.rounded()))%"
    }
}

/// Plain-language explanation and grouped costs. Raw manifest labels such as
/// "Platform" and "Enabled Capabilities" are intentionally not user-facing.
private struct AgentAbilityContextDetailsView: View {
    let preview: AgentAbilityContextPreview

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().foregroundColor(theme.border.default)

            Text(
                "Context is the model's working space. Agent instructions and tool descriptions use some of it before your first message; memory can add more on each turn. A larger setup can slow the first reply and leave less room for a very long conversation.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(displayRows) { row in
                    HStack(spacing: 8) {
                        Text(row.label, bundle: .module)
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.secondary)
                        Spacer()
                        Text("~\(AgentAbilityContextPreview.format(tokens: row.tokens)) tokens")
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
            }

            Text(toolModeExplanation, bundle: .module)
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let notice = autoDisableNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .glyphSize(9)
                        .foregroundColor(theme.status.warning.foreground)
                    Text(notice)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct DisplayRow: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let tokens: Int
    }

    private var displayRows: [DisplayRow] {
        let entries = preview.breakdown.context
        let instructions = entries
            .filter { $0.id == "platform" || $0.id == "persona" }
            .reduce(0) { $0 + $1.tokens }
        let tools = entries
            .filter { $0.id == "tools" }
            .reduce(0) { $0 + $1.tokens }
        let abilities = entries
            .filter {
                $0.id != "platform"
                    && $0.id != "persona"
                    && $0.id != "tools"
                    && $0.id != "memory"
            }
            .reduce(0) { $0 + $1.tokens }

        var rows: [DisplayRow] = []
        if instructions > 0 {
            rows.append(DisplayRow(id: "instructions", label: "Agent instructions", tokens: instructions))
        }
        if abilities > 0 {
            rows.append(DisplayRow(id: "abilities", label: "Enabled abilities", tokens: abilities))
        }
        if tools > 0 {
            rows.append(DisplayRow(id: "tools", label: "Tool descriptions", tokens: tools))
        }
        if preview.memoryUpperTokens > 0 {
            rows.append(
                DisplayRow(
                    id: "memory",
                    label: "Memory added per message (up to)",
                    tokens: preview.memoryUpperTokens
                )
            )
        }
        return rows
    }

    private var toolModeExplanation: LocalizedStringKey {
        switch preview.toolMode {
        case .auto:
            return "Auto-discover keeps this smaller by loading other assigned tools only when they are needed."
        case .manual:
            return "Manual mode includes every assigned tool, so assigning more tools increases context use."
        }
    }

    private var autoDisableNotice: String? {
        guard let info = preview.disable, info.disabledTools || info.disabledMemory else {
            return nil
        }
        let what: String
        switch (info.disabledTools, info.disabledMemory) {
        case (true, true): what = L("Tools and Memory were")
        case (true, false): what = L("Tools were")
        default: what = L("Memory was")
        }
        let model = info.modelId ?? L("this model")
        return String(
            format: L("%@ turned off for %@ because its working space is too small."),
            what,
            model
        )
    }
}
