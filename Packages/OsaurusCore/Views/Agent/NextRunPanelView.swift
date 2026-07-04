//
//  NextRunPanelView.swift
//  osaurus
//
//  Phase 3 — the Next Run panel above the detail-view tab strip (spec
//  §9.4). Shows the agent's upcoming run, paused state, or idle state.
//  The mode picker lives in the Configure tab's Scheduling section; a
//  read-only chip here deep-links to it.
//

import Foundation
import SwiftUI

// MARK: - Panel

/// The Next Run panel. Renders one of three banners — paused,
/// scheduled, or idle — based on the agent's current slot.
public struct NextRunPanelView: View {
    // MARK: Layout constants

    /// Width of the leading status icon (alarm / pause / calendar).
    private static let iconWidth: CGFloat = 18
    /// Inset used on the second-row actions so they line up under the
    /// content column (not the icon). `iconWidth` + the row's HStack
    /// spacing (12).
    private static let iconColumnLeading: CGFloat = 30
    /// `.distantFuture` slots (the "Pause indefinitely" menu option) are
    /// rendered as "Indefinitely paused" instead of a literal year-4001
    /// date. Anything past this offset (≈100 years) is treated as
    /// indefinite — a comfortable buffer over any realistic user input.
    private static let indefinitePauseThreshold: TimeInterval = 100 * 365 * 24 * 3600

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let agentId: UUID
    let onRunNow: () -> Void

    @State private var nextRun: NextRunEntry?
    @State private var pause: AgentPauseRecord?
    @State private var showEditInstructions: Bool = false
    @State private var editedInstructions: String = ""
    @State private var nowTick: Date = Date()
    @State private var refreshTask: Task<Void, Never>?

    // MARK: - Custom pause sheet state (spec §9.4 "Custom…")

    /// Whether the custom-pause sheet is presented. Tied to a flag
    /// (rather than `.sheet(item:)`) because the inputs reset cleanly
    /// when the sheet dismisses; no per-presentation identity needed.
    @State private var showCustomPause: Bool = false
    /// The user-picked pause end-date. Seeded to "+24h" when the sheet
    /// opens so the picker isn't anchored in the past.
    @State private var customPauseUntil: Date = Date().addingTimeInterval(24 * 60 * 60)
    /// Optional free-text reason logged in `agent_pauses.reason`.
    @State private var customPauseReason: String = ""

    public init(agentId: UUID, onRunNow: @escaping () -> Void = {}) {
        self.agentId = agentId
        self.onRunNow = onRunNow
    }

    private var agent: Agent? { agentManager.agent(for: agentId) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pause, pause.pausedUntil > Date() {
                pausedBanner(pause)
            } else if let entry = nextRun {
                scheduledRow(entry)
            } else {
                idleBanner
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.primaryBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .task { await reload() }
        .onAppear { startTicker() }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: agentId) { _, _ in Task { await reload() } }
        .sheet(isPresented: $showEditInstructions) { editInstructionsSheet }
        .sheet(isPresented: $showCustomPause) { customPauseSheet }
    }

    // MARK: Scheduled row

    /// Two-row layout: info + secondary controls (pause / mode chip)
    /// on top, primary actions on a second row. Splitting prevents the
    /// time text and `by …` badge from being squeezed below their
    /// natural width on the narrow settings window.
    @ViewBuilder
    private func scheduledRow(_ entry: NextRunEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                bannerIcon("alarm.fill", color: theme.warningColor)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(Self.relative(entry.scheduledAt, now: nowTick))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .fixedSize()
                        Text("·")
                            .foregroundColor(theme.secondaryText)
                            .fixedSize()
                        Text(Self.absolute(entry.scheduledAt))
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize()
                        scheduledByBadge(entry.scheduledBy)
                            .fixedSize()
                    }
                    Text(entry.instructions)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                    if !entry.contextViews.isEmpty {
                        Text(verbatim: "Prefetching: \(entry.contextViews.joined(separator: ", "))")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText.opacity(0.85))
                            .lineLimit(1)
                    }
                    // A due row with a dead dispatch loop would otherwise
                    // look like a working "Now" state forever (e.g. the
                    // storage key wasn't unlocked at launch). Tell the user
                    // why nothing fired and that Run now is the escape hatch.
                    if entry.scheduledAt <= nowTick, !NextRunScheduler.shared.isRunning {
                        Label(
                            "Scheduler inactive — waiting for storage unlock. Use Run now to start manually.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.warningColor)
                        .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    pauseMenu
                    modeChip
                }
            }

            actionsRow {
                actionButton("Run now", systemImage: "play.fill") { runNow() }
                actionButton("Edit", systemImage: "pencil") {
                    editedInstructions = entry.instructions
                    showEditInstructions = true
                }
                actionButton("Cancel", systemImage: "xmark", destructive: true) { cancelNow() }
            }
        }
    }

    @ViewBuilder
    private func scheduledByBadge(_ by: NextRunScheduledBy) -> some View {
        let label: String = {
            switch by {
            case .agent: return "by agent"
            case .user: return "by you"
            case .system: return "by system"
            }
        }()
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(theme.secondaryText.opacity(0.12))
            )
    }

    // MARK: Paused / Idle banners

    /// Both single-row states share the same anatomy: icon + title +
    /// subtitle on the left, state-toggle action + mode chip on the
    /// right. Routed through `statusBanner` so the two states stay
    /// pixel-identical except for icon, copy, and the toggle slot.
    @ViewBuilder
    private func pausedBanner(_ p: AgentPauseRecord) -> some View {
        statusBanner(
            icon: "pause.circle.fill",
            iconColor: theme.warningColor,
            title: "Paused",
            subtitle: LocalizedStringKey(Self.pausedSubtitle(for: p))
        ) {
            resumeButton
        }
    }

    @ViewBuilder
    private var idleBanner: some View {
        statusBanner(
            icon: "calendar.badge.clock",
            iconColor: theme.tertiaryText,
            title: "No upcoming run scheduled",
            subtitle: "The agent will schedule itself when it has work to do."
        ) {
            pauseMenu
        }
    }

    /// Renders the paused-state subtitle. Combines "Until <date>" with
    /// the optional user-provided reason; "Indefinitely paused" is
    /// substituted when the slot was written with `.distantFuture` so
    /// the user doesn't see a literal year-4001 date.
    private static func pausedSubtitle(for p: AgentPauseRecord) -> String {
        let isIndefinite = p.pausedUntil.timeIntervalSinceNow > Self.indefinitePauseThreshold
        let base =
            isIndefinite
            ? "Indefinitely paused"
            : "Until \(Self.absolute(p.pausedUntil))"
        let reason = p.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? base : "\(base) • \(reason)"
    }

    /// Compact "Resume" button sized to match `pauseMenu`'s visual
    /// weight (same font, same secondary-text color, no chrome) so the
    /// pause/resume toggle reads as one control across the two states.
    /// `pauseMenu` is a menu (multiple presets); `resumeButton` is a
    /// plain button because there's only one resume action.
    @ViewBuilder
    private var resumeButton: some View {
        Button(action: resume) {
            Label(localized: "Resume", systemImage: "play.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: Shared banner pieces

    /// Common chrome for the idle and paused states. Scheduled state
    /// has its own two-row layout (see `scheduledRow`).
    @ViewBuilder
    private func statusBanner<Toggle: View>(
        icon: String,
        iconColor: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder toggle: () -> Toggle
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            bannerIcon(icon, color: iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(subtitle, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            toggle()
            modeChip
        }
    }

    @ViewBuilder
    private func bannerIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(color)
            .frame(width: Self.iconWidth, height: Self.iconWidth)
    }

    /// Renders the bottom row of a two-row banner: primary actions
    /// flushed left under the content column, with trailing slack so
    /// they don't stretch.
    @ViewBuilder
    private func actionsRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.iconColumnLeading)
    }

    // MARK: Mode chip

    /// Read-only at-a-glance indicator of the current schedule mode.
    /// Tapping it deep-links to the Configure tab where the mode
    /// picker lives now (see `AgentDetailView` Scheduling section).
    @ViewBuilder
    private var modeChip: some View {
        let mode = agent?.settings.schedule.mode ?? .ambient
        Button {
            guard let agentId = agent?.id else { return }
            NotificationCenter.default.post(
                name: .agentDetailDeeplink,
                object: nil,
                userInfo: [
                    "agentId": agentId,
                    "tab": "configure",
                ]
            )
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .medium))
                Text(Self.modeLabel(mode))
                    .font(.system(size: 10, weight: .medium))
                    .fixedSize()
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(theme.secondaryText.opacity(0.10))
            )
            .overlay(
                Capsule().stroke(theme.secondaryText.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .localizedHelp("Mode: \(Self.modeLabel(mode)) — click to change in Configure")
    }

    private static func modeLabel(_ mode: AgentScheduleMode) -> String {
        switch mode {
        case .ambient: return "Ambient"
        case .reactive: return "Reactive"
        case .project: return "Project"
        case .manual: return "Manual"
        }
    }

    /// Quick-pause menu surfaced in the idle and scheduled banners.
    /// Never rendered while paused — the body switch routes that case
    /// to `pausedBanner`, which shows `resumeButton` instead.
    @ViewBuilder
    private var pauseMenu: some View {
        Menu {
            Button(localized: "1 hour") { pauseFor(hours: 1) }
            Button(localized: "4 hours") { pauseFor(hours: 4) }
            Button(localized: "Until tomorrow") { pauseUntilTomorrow() }
            Button(localized: "Custom…") { presentCustomPause() }
            Button(localized: "Indefinitely") { applyPause(until: .distantFuture) }
        } label: {
            Label(localized: "Pause", systemImage: "pause.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Edit sheet

    private var editInstructionsSheet: some View {
        let trimmedEmpty =
            editedInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "pencil.and.list.clipboard",
                title: "Edit next-run instructions",
                subtitle:
                    "Editing the wake-up brief flags the row as user-scheduled so the agent knows you intervened.",
                onClose: { showEditInstructions = false }
            )
            VStack(alignment: .leading, spacing: 8) {
                AgentSheetSectionLabel("Wake-up brief")
                StyledTextField(
                    placeholder: "What should the agent do when it wakes up?",
                    text: $editedInstructions,
                    icon: "text.alignleft",
                    axis: .vertical,
                    lineLimit: 5
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            AgentSheetFooter(
                primary: AgentSheetFooter.Action(
                    label: "Save",
                    isEnabled: !trimmedEmpty,
                    handler: { saveEditedInstructions() }
                ),
                secondary: AgentSheetFooter.Action(
                    label: "Cancel",
                    handler: { showEditInstructions = false }
                ),
                hint: "+ Enter to save"
            )
        }
        .frame(width: 480)
        .background(theme.primaryBackground)
    }

    // MARK: Side-effects

    private func runNow() {
        guard let entry = nextRun else { return }
        // Clear the slot synchronously so the scheduler doesn't double-fire,
        // then dispatch with `selfSchedule` so the audit trail still shows
        // the run was triggered by the next-run plumbing.
        try? LocalAgentBridge.shared.cancelNextRun(agentId: agentId)
        Task {
            // Same builder as the automatic path: fresh chat per run,
            // preamble prompt with the previous-run pointer, timestamped
            // session title.
            let request = await NextRunScheduler.makeDispatchRequest(for: entry)
            _ = await TaskDispatcher.shared.dispatch(request)
            await reload()
            onRunNow()
        }
    }

    private func cancelNow() {
        try? LocalAgentBridge.shared.cancelNextRun(agentId: agentId)
        Task { await reload() }
    }

    private func saveEditedInstructions() {
        guard let entry = nextRun else {
            showEditInstructions = false
            return
        }
        let trimmed = editedInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounds = agent?.settings.schedule ?? AgentScheduleSettings.defaults(for: .ambient)
        let request = AgentScheduleRequest(
            scheduledAt: entry.scheduledAt,
            instructions: trimmed,
            contextViews: entry.contextViews,
            priority: entry.priority,
            onMiss: entry.onMiss,
            scheduledBy: .user
        )
        _ = try? LocalAgentBridge.shared.scheduleNextRun(
            agentId: agentId,
            request: request,
            bounds: bounds
        )
        showEditInstructions = false
        Task { await reload() }
    }

    /// Single side-effect for every pause menu entry. Writes to the
    /// scheduler DB and triggers a reload so the banner snaps to the
    /// paused state.
    private func applyPause(until: Date, reason: String? = nil) {
        try? LocalAgentBridge.shared.pauseAgent(
            agentId: agentId,
            until: until,
            reason: reason
        )
        Task { await reload() }
    }

    private func pauseFor(hours: Int) {
        applyPause(until: Date().addingTimeInterval(TimeInterval(hours) * 3600))
    }

    private func pauseUntilTomorrow() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let tomorrow =
            cal.date(byAdding: .day, value: 1, to: start)
            ?? Date().addingTimeInterval(86400)
        applyPause(until: tomorrow)
    }

    /// Seed the custom-pause sheet with a sensible default (+24h)
    /// and present it. Reset on every entry so a previously-typed
    /// reason doesn't bleed through.
    private func presentCustomPause() {
        customPauseUntil = Date().addingTimeInterval(24 * 60 * 60)
        customPauseReason = ""
        showCustomPause = true
    }

    private func applyCustomPause() {
        let trimmedReason =
            customPauseReason
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The picker is constrained to future-only, but guard anyway
        // — a paused-until in the past would no-op the next reload.
        let until = max(customPauseUntil, Date().addingTimeInterval(60))
        applyPause(
            until: until,
            reason: trimmedReason.isEmpty ? nil : trimmedReason
        )
        showCustomPause = false
    }

    @ViewBuilder
    private var customPauseSheet: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "pause.circle",
                title: "Pause agent",
                subtitle:
                    "Pick when this agent should resume firing scheduled and self-scheduled runs. The optional reason is logged in the audit trail.",
                onClose: { showCustomPause = false }
            )
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    AgentSheetSectionLabel("Resume at")
                    DatePicker(
                        "",
                        selection: $customPauseUntil,
                        in: Date().addingTimeInterval(60)...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 8) {
                    AgentSheetSectionLabel("Reason (optional)")
                    StyledTextField(
                        placeholder: "e.g. cooling off after an error",
                        text: $customPauseReason,
                        icon: "text.bubble"
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            AgentSheetFooter(
                primary: AgentSheetFooter.Action(
                    label: "Pause",
                    handler: { applyCustomPause() }
                ),
                secondary: AgentSheetFooter.Action(
                    label: "Cancel",
                    handler: { showCustomPause = false }
                ),
                hint: "+ Enter to pause"
            )
        }
        .frame(width: 400)
        .background(theme.primaryBackground)
    }

    private func resume() {
        try? LocalAgentBridge.shared.unpauseAgent(agentId: agentId)
        Task { await reload() }
    }

    // MARK: Reload

    @MainActor
    private func reload() async {
        guard (try? SchedulerDatabase.shared.open()) != nil else {
            nextRun = nil
            pause = nil
            return
        }
        nextRun = try? LocalAgentBridge.shared.nextRun(agentId: agentId)
        pause = try? LocalAgentBridge.shared.pauseInfo(agentId: agentId)
    }

    private func startTicker() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                nowTick = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(theme.secondaryBackground)
    }

    @ViewBuilder
    private func actionButton(
        _ label: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let tint = destructive ? theme.errorColor : theme.accentColor
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
        .foregroundColor(tint)
        .fixedSize()
    }

    static func relative(_ when: Date, now: Date) -> String {
        let delta = when.timeIntervalSince(now)
        if delta < 0 { return "Now" }
        if delta < 60 { return "in \(Int(delta))s" }
        if delta < 3600 { return "in \(Int(delta / 60))m" }
        if delta < 86400 { return "in \(Int(delta / 3600))h" }
        let days = Int(delta / 86400)
        return "in \(days)d"
    }

    /// Cached formatter: `DateFormatter` allocation is expensive and
    /// `absolute(_:)` is called on every banner render + ticker tick.
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func absolute(_ when: Date) -> String {
        absoluteFormatter.string(from: when)
    }
}
