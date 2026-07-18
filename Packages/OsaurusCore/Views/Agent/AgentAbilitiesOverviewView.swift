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

/// Hero + caller-provided ability cards. The container owns the live
/// context estimate: it recomputes off the `draft` fingerprint (debounced,
/// never inside a view body) and feeds the hero, including a short-lived
/// `+/- tokens` delta after each change so toggling feels causal.
struct AgentAbilitiesOverviewView<Cards: View>: View {
    let agentId: UUID
    let draft: AgentAbilityContextPreview.Draft
    let enabledCount: Int
    let totalCount: Int
    @ViewBuilder let cards: () -> Cards

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var preview: AgentAbilityContextPreview?
    /// Token delta flashed next to the estimate after the last change.
    @State private var lastDelta: Int?
    @State private var deltaDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentAbilitiesHeroCard(
                enabledCount: enabledCount,
                totalCount: totalCount,
                preview: preview,
                delta: lastDelta
            )
            cards()
        }
        // Recompute only when a budget input actually changes — compose
        // reads AgentManager / ToolRegistry and can touch the agent DB, so
        // it must never run per-render.
        .task(id: draft) { await refreshPreview() }
        .onDisappear { deltaDismissTask?.cancel() }
    }

    @MainActor
    private func refreshPreview() async {
        // Debounce so rapid flips coalesce into one compose; `.task(id:)`
        // cancels the previous sleep when the draft changes again.
        try? await Task.sleep(nanoseconds: 140_000_000)
        guard !Task.isCancelled else { return }
        // Composing can open the agent DB; opening parks on the storage
        // gate during a key rotation, which would hang the UI (same guard
        // ChatView's preview path uses). Skip; the next draft change or
        // tab visit retries.
        guard !StorageMutationGate.isRotationInFlight else { return }

        let next = AgentAbilityContextPreview.compute(agentId: agentId, draft: draft)
        if let previous = preview {
            let delta = next.highTokens - previous.highTokens
            if delta != 0 {
                lastDelta = delta
                deltaDismissTask?.cancel()
                deltaDismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        lastDelta = nil
                    }
                }
            }
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9)) {
            preview = next
        }
    }
}

// MARK: - Hero Card

/// Accent-tinted summary card: enabled-ability count, the live startup
/// context estimate (a range when memory can inject), share of the model
/// window when known, the warm-up/TTFT trade-off line, and the composer's
/// small-window auto-disable notice.
struct AgentAbilitiesHeroCard: View {
    let enabledCount: Int
    let totalCount: Int
    let preview: AgentAbilityContextPreview?
    let delta: Int?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        totalCount == 1
                            ? L("\(enabledCount) of 1 ability on")
                            : L("\(enabledCount) of \(totalCount) abilities on")
                    )
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .contentTransition(.numericText())
                    Text(
                        "Every ability this agent carries adds instructions or tool schemas to each new chat.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        if let delta {
                            deltaChip(delta)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                        Text(estimateText)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .contentTransition(.numericText())
                    }
                    Text("Estimated startup context", bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    Text("Estimated startup context: \(estimateText)", bundle: .module)
                )
            }

            if let preview {
                windowBar(preview)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                Text(
                    "A bigger starting context means longer model warm-up and a slower first token.",
                    bundle: .module
                )
                .font(.system(size: 10.5))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = autoDisableNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(theme.warningColor)
                    Text(notice)
                        .font(.system(size: 10.5).italic())
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.10),
                            theme.accentColor.opacity(0.03),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    /// "~2.1K tokens" for a fixed estimate, "~2.1K–2.9K tokens" when memory
    /// can inject up to its budget on a turn. "—" until the first compute.
    private var estimateText: String {
        guard let preview else { return "—" }
        let low = AgentAbilityContextPreview.format(tokens: preview.lowTokens)
        if preview.isRange {
            let high = AgentAbilityContextPreview.format(tokens: preview.highTokens)
            return "~\(low)–\(high) tok"
        }
        return "~\(low) tok"
    }

    private func deltaChip(_ delta: Int) -> some View {
        let magnitude = AgentAbilityContextPreview.format(tokens: abs(delta))
        let text = delta > 0 ? "+~\(magnitude)" : "−~\(magnitude)"
        let color = delta > 0 ? theme.warningColor : theme.accentColor
        return Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    /// Thin usage bar against the model window when the window is known.
    /// Composition (share-of-window), not a budget gauge — headroom is
    /// almost always large, which is exactly the message.
    @ViewBuilder
    private func windowBar(_ preview: AgentAbilityContextPreview) -> some View {
        if let window = preview.contextWindow, let fraction = preview.windowFraction {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.tertiaryBackground.opacity(0.5))
                        Capsule()
                            .fill(theme.accentColor.opacity(0.75))
                            .frame(width: max(3, geo.size.width * CGFloat(fraction)))
                    }
                }
                .frame(height: 5)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.3),
                    value: preview.highTokens
                )

                Text(
                    "of the model's ~\(AgentAbilityContextPreview.format(tokens: window)) token window (\(windowPercent(fraction)))"
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            }
        }
    }

    private func windowPercent(_ fraction: Double) -> String {
        let pct = fraction * 100
        if pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    /// Mirrors the chat popover's auto-disable notice: which knobs the
    /// small-context size class turned off, and why.
    private var autoDisableNotice: String? {
        guard let info = preview?.disable, info.disabledTools || info.disabledMemory else {
            return nil
        }
        let what: String
        switch (info.disabledTools, info.disabledMemory) {
        case (true, true): what = L("Tools and Memory are")
        case (true, false): what = L("Tools are")
        default: what = L("Memory is")
        }
        let model = info.modelId ?? L("this model")
        return String(
            format: L("%@ auto-disabled for %@ — its context window is too small to carry them."),
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
