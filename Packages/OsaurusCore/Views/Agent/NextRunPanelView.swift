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

    // MARK: Paused

    /// Mirrors `scheduledRow`'s two-row layout: info + mode chip on top,
    /// Resume on a second row.
    @ViewBuilder
    private func pausedBanner(_ p: AgentPauseRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                bannerIcon("pause.circle.fill", color: theme.warningColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paused until \(Self.absolute(p.pausedUntil))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = p.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                modeChip
            }

            actionsRow {
                actionButton("Resume", systemImage: "play.fill") { resume() }
            }
        }
    }

    // MARK: Idle banner

    /// Shown when the agent isn't paused and has no scheduled run. Keeps
    /// the Pause affordance and mode chip discoverable; otherwise the
    /// banner would disappear and the user would lose both entry points.
    @ViewBuilder
    private var idleBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            bannerIcon("calendar.badge.clock", color: theme.tertiaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text("No upcoming run scheduled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("The agent will schedule itself when it has work to do.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            pauseMenu
            modeChip
        }
    }

    // MARK: Shared banner pieces

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
        .help("Mode: \(Self.modeLabel(mode)) — click to change in Configure")
    }

    private static func modeLabel(_ mode: AgentScheduleMode) -> String {
        switch mode {
        case .ambient: return "Ambient"
        case .reactive: return "Reactive"
        case .project: return "Project"
        case .manual: return "Manual"
        }
    }

    @ViewBuilder
    private var pauseMenu: some View {
        if pause?.pausedUntil ?? .distantPast > Date() {
            EmptyView()
        } else {
            Menu {
                Button("1 hour") { pauseFor(.init(hours: 1)) }
                Button("4 hours") { pauseFor(.init(hours: 4)) }
                Button("Until tomorrow") { pauseUntilTomorrow() }
                Button("Custom…") { presentCustomPause() }
                Button("Indefinitely") { pauseFor(nil) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Edit sheet

    private var editInstructionsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit next-run instructions")
                .font(.headline)
            Text(
                "Editing the wake-up brief flags the row as user-scheduled "
                    + "so the agent knows you intervened."
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            TextEditor(text: $editedInstructions)
                .font(.system(size: 12))
                .frame(minHeight: 100)
                .padding(8)
                .background(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.primaryBorder, lineWidth: 0.5)
                )
            HStack {
                Spacer()
                Button("Cancel") { showEditInstructions = false }
                Button("Save") { saveEditedInstructions() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editedInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: Side-effects

    private func runNow() {
        guard let entry = nextRun else { return }
        // Clear the slot synchronously so the scheduler doesn't double-fire,
        // then dispatch with `selfSchedule` so the audit trail still shows
        // the run was triggered by the next-run plumbing.
        try? LocalAgentBridge.shared.cancelNextRun(agentId: agentId)
        let request = DispatchRequest(
            prompt: entry.instructions,
            agentId: agentId,
            title: "Self-scheduled run",
            source: .selfSchedule,
            externalSessionKey: agentId.uuidString
        )
        Task {
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

    private func pauseFor(_ duration: PauseDuration?) {
        let until = duration?.absolute(from: Date()) ?? .distantFuture
        try? LocalAgentBridge.shared.pauseAgent(
            agentId: agentId,
            until: until,
            reason: nil
        )
        Task { await reload() }
    }

    private func pauseUntilTomorrow() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86400)
        try? LocalAgentBridge.shared.pauseAgent(
            agentId: agentId,
            until: tomorrow,
            reason: nil
        )
        Task { await reload() }
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
        try? LocalAgentBridge.shared.pauseAgent(
            agentId: agentId,
            until: until,
            reason: trimmedReason.isEmpty ? nil : trimmedReason
        )
        showCustomPause = false
        Task { await reload() }
    }

    @ViewBuilder
    private var customPauseSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pause agent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Pick when this agent should resume firing scheduled and self-scheduled runs. The optional reason is logged in the audit trail."
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            DatePicker(
                "Resume at",
                selection: $customPauseUntil,
                in: Date().addingTimeInterval(60)...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            VStack(alignment: .leading, spacing: 4) {
                Text("Reason (optional)").font(.system(size: 11, weight: .medium))
                TextField("e.g. cooling off after an error", text: $customPauseReason)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { showCustomPause = false }
                    .controlSize(.small)
                Button("Pause") { applyCustomPause() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func resume() {
        try? LocalAgentBridge.shared.unpauseAgent(agentId: agentId)
        Task { await reload() }
    }

    // MARK: Reload

    @MainActor
    private func reload() async {
        do {
            try SchedulerDatabase.shared.open()
        } catch {
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
                try? await Task.sleep(nanoseconds: 30_000_000_000)
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

    static func absolute(_ when: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: when)
    }
}

// MARK: - PauseDuration

private struct PauseDuration {
    let hours: Int
    func absolute(from base: Date) -> Date {
        base.addingTimeInterval(TimeInterval(hours) * 3600)
    }
}
