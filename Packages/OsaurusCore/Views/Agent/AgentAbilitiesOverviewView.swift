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
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(statusColor)
                Text("Context", bundle: .module)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText)

                if let delta {
                    deltaChip(delta)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                Text(compactEstimateText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .contentTransition(.numericText())

                Text(compactImpactLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.11)))

                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(controlFill)
                .overlay(
                    Capsule()
                        .stroke(controlBorder, lineWidth: 1)
                )
        )
        .localizedHelp("Show how much model context this agent uses")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            contextPopover
        }
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(statusColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(statusColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Context impact", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .fixedSize()
                        Text(abilityCountText)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                    Text(summaryText)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(fullEstimateText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Text(impactLabel)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(statusColor)
                }
            }

            if let preview {
                AgentAbilityContextDetailsView(preview: preview)
            }
        }
        .padding(14)
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
        guard let preview else { return theme.accentColor }
        switch preview.severity {
        case .normal: return theme.accentColor
        case .warning: return theme.warningColor
        case .critical: return theme.errorColor
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
        guard let preview else { return theme.cardBackground }
        switch preview.severity {
        case .normal: return theme.cardBackground
        case .warning: return theme.warningColor.opacity(0.055)
        case .critical: return theme.errorColor.opacity(0.055)
        }
    }

    private var controlBorder: Color {
        guard let preview else { return theme.cardBorder }
        switch preview.severity {
        case .normal: return theme.cardBorder
        case .warning: return theme.warningColor.opacity(0.45)
        case .critical: return theme.errorColor.opacity(0.45)
        }
    }

    private func deltaChip(_ delta: Int) -> some View {
        let magnitude = AgentAbilityContextPreview.format(tokens: abs(delta))
        let text = delta > 0 ? "+\(magnitude)" : "−\(magnitude)"
        let color = delta > 0 ? theme.warningColor : theme.accentColor
        return Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
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
            Divider().foregroundColor(theme.cardBorder)

            Text(
                "Context is the model's working space. Agent instructions and tool descriptions use some of it before your first message; memory can add more on each turn. A larger setup can slow the first reply and leave less room for a very long conversation.",
                bundle: .module
            )
            .font(.system(size: 10.5))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(displayRows) { row in
                    HStack(spacing: 8) {
                        Text(row.label, bundle: .module)
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        Text("~\(AgentAbilityContextPreview.format(tokens: row.tokens)) tokens")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }

            Text(toolModeExplanation, bundle: .module)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let notice = autoDisableNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(theme.warningColor)
                    Text(notice)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText)
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

// MARK: - Ability Group Header

/// Small-caps group label + optional one-line description above a run of
/// ability cards, so the overview reads as distinct domains rather than a
/// wall of switches.
struct AgentAbilityGroupHeader: View {
    @Environment(\.theme) private var theme

    let label: LocalizedStringKey
    var description: LocalizedStringKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AgentSheetSectionLabel(label)
            if let description {
                Text(description, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 2)
        .padding(.top, 4)
    }
}

// MARK: - Ability Card

/// The canonical ability card: tinted icon tile, title + subtitle, and an
/// accent switch. The card visibly "lights up" when active (icon tint,
/// border, tile fill), shows a paused chip when a dependency suppresses it
/// (Tools off), and can carry a configure deep link plus arbitrary
/// accessory content (disclaimers, folder pickers, shortcuts).
struct AgentAbilityCard<Accessory: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    /// Switch binding; nil renders a card without a switch (e.g. Host
    /// Files, whose state is a folder grant rather than a toggle).
    var isOn: Binding<Bool>? = nil
    /// Visual active state when there is no switch.
    var isActive: Bool? = nil
    /// False dims the card and disables the switch (e.g. sandbox not
    /// running) while keeping the copy readable.
    var isInteractive: Bool = true
    /// Rendered as a warning chip when the ability is gated off by a
    /// dependency even though its own switch may be on.
    var pausedNote: LocalizedStringKey? = nil
    /// Makes the paused chip tappable — a "take me to the cause"
    /// affordance (e.g. scroll to and highlight the Tools master card).
    var onPausedNoteTap: (() -> Void)? = nil
    var configureLabel: LocalizedStringKey? = nil
    var onConfigure: (() -> Void)? = nil
    @ViewBuilder let accessory: () -> Accessory

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        icon: String,
        isOn: Binding<Bool>? = nil,
        isActive: Bool? = nil,
        isInteractive: Bool = true,
        pausedNote: LocalizedStringKey? = nil,
        onPausedNoteTap: (() -> Void)? = nil,
        configureLabel: LocalizedStringKey? = nil,
        onConfigure: (() -> Void)? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isOn = isOn
        self.isActive = isActive
        self.isInteractive = isInteractive
        self.pausedNote = pausedNote
        self.onPausedNoteTap = onPausedNoteTap
        self.configureLabel = configureLabel
        self.onConfigure = onConfigure
        self.accessory = accessory
    }

    private var active: Bool {
        isOn?.wrappedValue ?? isActive ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                iconTile

                VStack(alignment: .leading, spacing: 2) {
                    Text(title, bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle, bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if let isOn {
                    Toggle(title, isOn: isOn)
                        .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                        .labelsHidden()
                        .disabled(!isInteractive)
                }
            }

            if let pausedNote {
                let chip = HStack(spacing: 4) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(pausedNote, bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(theme.warningColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.warningColor.opacity(0.12)))

                Group {
                    if let onPausedNoteTap {
                        Button(action: onPausedNoteTap) { chip.contentShape(Capsule()) }
                            .buttonStyle(.plain)
                            .help(Text("Show the switch this depends on", bundle: .module))
                    } else {
                        chip
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            accessory()

            if active, let configureLabel, let onConfigure {
                Button(action: onConfigure) {
                    HStack(spacing: 4) {
                        Text(configureLabel, bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            active ? theme.accentColor.opacity(0.5) : theme.cardBorder,
                            lineWidth: 1
                        )
                )
        )
        .opacity(isInteractive ? 1 : 0.55)
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
            value: active
        )
    }

    private var iconTile: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(active ? theme.accentColor : theme.secondaryText)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        active
                            ? theme.accentColor.opacity(0.14)
                            : theme.tertiaryBackground.opacity(0.6)
                    )
            )
    }
}

extension AgentAbilityCard where Accessory == EmptyView {
    /// Convenience for the common accessory-free card.
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        icon: String,
        isOn: Binding<Bool>? = nil,
        isActive: Bool? = nil,
        isInteractive: Bool = true,
        pausedNote: LocalizedStringKey? = nil,
        onPausedNoteTap: (() -> Void)? = nil,
        configureLabel: LocalizedStringKey? = nil,
        onConfigure: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            icon: icon,
            isOn: isOn,
            isActive: isActive,
            isInteractive: isInteractive,
            pausedNote: pausedNote,
            onPausedNoteTap: onPausedNoteTap,
            configureLabel: configureLabel,
            onConfigure: onConfigure,
            accessory: { EmptyView() }
        )
    }
}
