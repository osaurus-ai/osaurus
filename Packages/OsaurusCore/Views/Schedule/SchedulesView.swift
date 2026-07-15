//
//  SchedulesView.swift
//  osaurus
//
//  Management view for creating, editing, and viewing scheduled AI tasks.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Schedules View

struct SchedulesView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    private var scheduleManager = ScheduleManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var isCreating = false
    @State private var editingSchedule: Schedule?
    @State private var historySchedule: Schedule?
    @State private var scheduleSummaries: [UUID: ScheduleAutomationSummary] = [:]
    @State private var summaryLoadTask: Task<Void, Never>?
    @State private var hasAppeared = false
    @State private var successMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            // Content
            ZStack {
                if scheduleManager.schedules.isEmpty {
                    SettingsEmptyState(
                        icon: "calendar.badge.clock",
                        title: L("Create Your First Schedule"),
                        subtitle: L("Set up automated AI tasks that run on your schedule."),
                        examples: [
                            .init(
                                icon: "sun.max",
                                title: L("Morning Briefing"),
                                description: L("Get a daily summary every morning")
                            ),
                            .init(
                                icon: "chart.bar",
                                title: L("Weekly Report"),
                                description: L("Generate insights on a schedule")
                            ),
                            .init(
                                icon: "bell",
                                title: L("Reminders"),
                                description: L("Automated notifications at set times")
                            ),
                        ],
                        primaryAction: .init(title: L("Create Schedule"), icon: "plus", handler: { isCreating = true }),
                        hasAppeared: hasAppeared
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 300), spacing: 20),
                                GridItem(.flexible(minimum: 300), spacing: 20),
                            ],
                            spacing: 20
                        ) {
                            ForEach(Array(scheduleManager.schedules.enumerated()), id: \.element.id) {
                                index,
                                schedule in
                                ScheduleCard(
                                    schedule: schedule,
                                    summary: displaySummary(for: schedule),
                                    isRunning: scheduleManager.isRunning(schedule.id),
                                    animationDelay: Double(index) * 0.05,
                                    hasAppeared: hasAppeared,
                                    onToggle: { enabled in
                                        scheduleManager.setEnabled(schedule.id, enabled: enabled)
                                        scheduleManager.refresh()
                                        reloadHistorySummaries()
                                        showSuccess(
                                            enabled ? "Resumed \"\(schedule.name)\"" : "Paused \"\(schedule.name)\""
                                        )
                                    },
                                    onRunNow: {
                                        scheduleManager.runNow(schedule.id)
                                        scheduleManager.refresh()
                                        reloadHistorySummaries()
                                        showSuccess("Started \"\(schedule.name)\"")
                                    },
                                    onShowHistory: {
                                        historySchedule = schedule
                                    },
                                    onExportSummary: {
                                        exportSummary(for: schedule)
                                    },
                                    onEdit: {
                                        editingSchedule = schedule
                                    },
                                    onDelete: {
                                        scheduleManager.delete(id: schedule.id)
                                        reloadHistorySummaries()
                                        showSuccess("Deleted \"\(schedule.name)\"")
                                    }
                                )
                            }
                        }
                        .padding(24)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

                // Success toast
                if let message = successMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(message, type: .success)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .sheet(isPresented: $isCreating) {
            ScheduleEditorSheet(
                mode: .create,
                onSave: { schedule in
                    scheduleManager.create(
                        name: schedule.name,
                        instructions: schedule.instructions,
                        agentId: schedule.agentId,
                        parameters: schedule.parameters,
                        folderPath: schedule.folderPath,
                        folderBookmark: schedule.folderBookmark,
                        frequency: schedule.frequency,
                        isEnabled: schedule.isEnabled
                    )
                    isCreating = false
                    reloadHistorySummaries()
                    showSuccess("Created \"\(schedule.name)\"")
                },
                onCancel: {
                    isCreating = false
                }
            )
        }
        .sheet(item: $editingSchedule) { schedule in
            ScheduleEditorSheet(
                mode: .edit(schedule),
                onSave: { updated in
                    scheduleManager.update(updated)
                    editingSchedule = nil
                    reloadHistorySummaries()
                    showSuccess("Updated \"\(updated.name)\"")
                },
                onCancel: {
                    editingSchedule = nil
                }
            )
        }
        .sheet(item: $historySchedule) { schedule in
            ScheduleHistorySheet(
                schedule: schedule,
                summary: displaySummary(for: schedule),
                onExport: {
                    exportSummary(for: schedule)
                }
            )
        }
        .onAppear {
            scheduleManager.refresh()
            reloadHistorySummaries()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            consumePendingScheduleEditRequest()
        }
        .onChange(of: managementState.pendingScheduleEditId) { _, _ in
            consumePendingScheduleEditRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scheduleExecutionCompleted)) { _ in
            scheduleManager.refresh()
            reloadHistorySummaries()
        }
        .onDisappear {
            summaryLoadTask?.cancel()
            summaryLoadTask = nil
        }
    }

    /// Handle a deeplink request to open a specific schedule's editor (e.g.
    /// from the Claude plugin import summary). Looks up the schedule by id
    /// against the live `ScheduleManager`, opens the editor, and clears the
    /// pending request so it doesn't replay on the next tab visit.
    private func consumePendingScheduleEditRequest() {
        guard let pending = managementState.pendingScheduleEditId else { return }
        scheduleManager.refresh()
        reloadHistorySummaries()
        if let match = scheduleManager.schedules.first(where: { $0.id == pending }) {
            editingSchedule = match
        }
        managementState.pendingScheduleEditId = nil
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Schedules"),
            subtitle: L("Automate recurring AI tasks with custom schedules"),
            count: scheduleManager.schedules.isEmpty ? nil : scheduleManager.schedules.count
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh schedules") {
                scheduleManager.refresh()
                reloadHistorySummaries()
            }
            HeaderPrimaryButton("Create Schedule", icon: "plus") {
                isCreating = true
            }
        }
    }

    // MARK: - Success Toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                successMessage = nil
            }
        }
    }

    private func reloadHistorySummaries() {
        let schedules = scheduleManager.schedules
        let scheduleIds = Set(schedules.map(\.id))
        let now = Date()
        var summaries = scheduleSummaries.filter { scheduleIds.contains($0.key) }
        for schedule in schedules where summaries[schedule.id] == nil {
            summaries[schedule.id] = placeholderSummary(for: schedule, asOf: now)
        }
        scheduleSummaries = summaries

        summaryLoadTask?.cancel()
        summaryLoadTask = Task { @MainActor in
            let loadedSummaries = await ScheduleHistoryService.shared.summariesOffMain(
                for: schedules,
                runLimit: 8,
                asOf: now
            )
            guard !Task.isCancelled else { return }
            scheduleSummaries = loadedSummaries
        }
    }

    private func displaySummary(for schedule: Schedule) -> ScheduleAutomationSummary {
        scheduleSummaries[schedule.id] ?? placeholderSummary(for: schedule)
    }

    private func placeholderSummary(for schedule: Schedule, asOf now: Date = Date()) -> ScheduleAutomationSummary {
        let runs = Array(schedule.runHistory.prefix(8))
        return ScheduleAutomationSummary(
            scheduleId: schedule.id,
            generatedAt: now,
            nextRun: schedule.nextRunPreview(asOf: now),
            runs: runs,
            lastError: latestLocalError(in: runs)
        )
    }

    private func latestLocalError(in runs: [ScheduleRunHistoryEntry]) -> ScheduleLastErrorDiagnostic? {
        for run in runs {
            guard run.status == .failed || (run.status != .succeeded && run.errorMessage != nil),
                let message = run.errorMessage,
                !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            return ScheduleLastErrorDiagnostic(
                runId: run.id,
                occurredAt: run.endedAt ?? run.startedAt,
                message: message,
                status: run.status
            )
        }
        return nil
    }

    private func exportSummary(for schedule: Schedule) {
        let service = ScheduleHistoryService.shared
        let filenameSummary = displaySummary(for: schedule)

        let panel = NSSavePanel()
        panel.title = L("Export")
        panel.prompt = L("Export")
        panel.nameFieldStringValue = service.suggestedExportFilename(
            for: schedule,
            generatedAt: filenameSummary.generatedAt
        )
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            let summary = await service.summaryOffMain(for: schedule, runLimit: Schedule.maxRunHistoryEntries)
            let markdown = service.markdownSummary(for: schedule, summary: summary)
            do {
                try await Task.detached(priority: .utility) {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                }.value
                scheduleSummaries[schedule.id] = summary
                showSuccess("Exported \"\(schedule.name)\"")
            } catch {
                showSuccess("Export failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Schedule Card

private struct ScheduleCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let schedule: Schedule
    let summary: ScheduleAutomationSummary
    let isRunning: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onRunNow: () -> Void
    let onShowHistory: () -> Void
    let onExportSummary: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var agent: Agent? {
        guard let agentId = schedule.agentId else { return nil }
        return agentManager.agent(for: agentId)
    }

    /// Consistent color derived from the schedule name
    private var scheduleColor: Color {
        let hue = Double(abs(schedule.name.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        if isRunning {
                            Circle()
                                .fill(theme.accentColor.opacity(0.2))
                            ProgressView()
                                .scaleEffect(0.5)
                        } else {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [scheduleColor.opacity(0.15), scheduleColor.opacity(0.05)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            Circle()
                                .strokeBorder(scheduleColor.opacity(0.4), lineWidth: 2)

                            Text(schedule.name.prefix(1).uppercased())
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(scheduleColor)
                        }
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(schedule.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)

                            statusBadge
                        }

                        Text(schedule.frequency.displayDescription)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Menu {
                        Button(action: onEdit) {
                            Label {
                                Text("Edit", bundle: .module)
                            } icon: {
                                Image(systemName: "pencil")
                            }
                        }
                        Button(action: onRunNow) {
                            Label {
                                Text("Run Now", bundle: .module)
                            } icon: {
                                Image(systemName: "play.fill")
                            }
                        }
                        .disabled(isRunning)
                        Button(action: onShowHistory) {
                            Label {
                                Text("History", bundle: .module)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                        }
                        Button(action: onExportSummary) {
                            Label {
                                Text("Export…", bundle: .module)
                            } icon: {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        Divider()
                        Button {
                            onToggle(!schedule.isEnabled)
                        } label: {
                            Label(
                                schedule.isEnabled ? "Pause" : "Resume",
                                systemImage: schedule.isEnabled ? "pause.circle" : "play.circle"
                            )
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label {
                                Text("Delete", bundle: .module)
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                }

                // Instructions excerpt
                if !schedule.instructions.isEmpty {
                    Text(schedule.instructions)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                nextRunPreview

                if let lastError = summary.lastError {
                    lastErrorPreview(lastError)
                }

                Spacer(minLength: 0)

                compactStats
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(cardBackground)
            .overlay(hoverGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .shadow(
                color: isRunning ? theme.accentColor.opacity(0.15) : Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .themedAlert(
            "Delete Schedule",
            isPresented: $showDeleteConfirm,
            message: "Are you sure you want to delete \"\(schedule.name)\"? This action cannot be undone.",
            primaryButton: .destructive("Delete", action: onDelete),
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isHovered
                    ? scheduleColor.opacity(0.25)
                    : (isRunning ? theme.accentColor.opacity(0.3) : theme.cardBorder),
                lineWidth: isRunning || isHovered ? 1.5 : 1
            )
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        scheduleColor.opacity(isHovered ? 0.06 : 0),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        if isRunning {
            badgeLabel("Running", color: theme.accentColor)
        } else if schedule.isEnabled {
            badgeLabel("Enabled", color: theme.successColor)
        } else {
            badgeLabel("Paused", color: .orange)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Compact Stats

    private var nextRunPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: nextRunIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(nextRunColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text("Next run", bundle: .module)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                Text(summary.nextRun.description)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(nextRunColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(nextRunColor.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var nextRunIcon: String {
        switch summary.nextRun.state {
        case .scheduled:
            return "clock"
        case .due:
            return "bell.badge.fill"
        case .paused:
            return "pause.circle"
        case .exhausted:
            return "checkmark.circle"
        }
    }

    private var nextRunColor: Color {
        switch summary.nextRun.state {
        case .scheduled:
            return theme.accentColor
        case .due:
            return .orange
        case .paused:
            return .orange
        case .exhausted:
            return theme.tertiaryText
        }
    }

    private func lastErrorPreview(_ diagnostic: ScheduleLastErrorDiagnostic) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.errorColor)
                .frame(width: 14)
            Text(diagnostic.message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.errorColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.errorColor.opacity(0.18), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var compactStats: some View {
        HStack(spacing: 0) {
            statItem(icon: schedule.frequency.frequencyType.icon, text: schedule.frequency.shortDescription)

            if let latest = summary.latestRun {
                statDot
                statItem(icon: latest.status.iconName, text: latest.status.displayName)
            }

            if let agentName = agent?.name, agent?.isBuiltIn == false {
                statDot
                statItem(icon: "person.fill", text: agentName)
            }

            Spacer(minLength: 0)
        }
    }

    private func statItem(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
    }

    private var statDot: some View {
        Circle()
            .fill(theme.tertiaryText.opacity(0.4))
            .frame(width: 3, height: 3)
            .padding(.horizontal, 8)
    }
}

// MARK: - Schedule History Sheet

private struct ScheduleHistorySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let schedule: Schedule
    let summary: ScheduleAutomationSummary
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overview

                    if let diagnostic = summary.lastError {
                        diagnosticPanel(diagnostic)
                    }

                    runsSection
                }
                .padding(24)
            }

            footer
        }
        .frame(width: 640, height: 560)
        .background(theme.primaryBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text("History", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(schedule.name)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(theme.secondaryBackground)
    }

    private var overview: some View {
        HStack(spacing: 12) {
            ScheduleHistoryMetric(
                icon: schedule.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill",
                title: "State",
                value: schedule.isEnabled ? "Enabled" : "Paused",
                color: schedule.isEnabled ? theme.successColor : .orange
            )
            ScheduleHistoryMetric(
                icon: summary.nextRun.state.iconName,
                title: "Next run",
                value: summary.nextRun.description,
                color: summary.nextRun.state.color(theme: theme)
            )
            ScheduleHistoryMetric(
                icon: "list.bullet.rectangle",
                title: "Runs",
                value: "\(summary.runs.count)",
                color: theme.accentColor
            )
        }
    }

    private func diagnosticPanel(_ diagnostic: ScheduleLastErrorDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(theme.errorColor)
                Text("Diagnostics", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text(formatDate(diagnostic.occurredAt))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            Text(diagnostic.message)
                .font(.system(size: 12))
                .foregroundColor(theme.errorColor)
                .textSelection(.enabled)

            Text("Run ID: \(diagnostic.runId.uuidString)", bundle: .module)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.errorColor.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Runs", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }

            if summary.runs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                    Text("No runs yet.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.secondaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(summary.runs) { run in
                        ScheduleRunHistoryRow(run: run)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(action: { dismiss() }) {
                Text("Close", bundle: .module)
            }
            .buttonStyle(ScheduleSecondaryButtonStyle())

            Button {
                onExport()
            } label: {
                Label {
                    Text("Export…", bundle: .module)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .buttonStyle(SchedulePrimaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(Rectangle().fill(theme.primaryBorder).frame(height: 1), alignment: .top)
        )
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct ScheduleHistoryMetric: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct ScheduleRunHistoryRow: View {
    @Environment(\.theme) private var theme

    let run: ScheduleRunHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.status.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(run.status.color(theme: theme))
                .frame(width: 28, height: 28)
                .background(Circle().fill(run.status.color(theme: theme).opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(run.status.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(formatDate(run.startedAt))
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                    if let duration = run.durationSeconds {
                        Text(formatDuration(duration))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                HStack(spacing: 8) {
                    if let sessionId = run.chatSessionId {
                        Label(String(sessionId.uuidString.prefix(8)), systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }
                    if let error = run.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(theme.errorColor)
                            .lineLimit(1)
                    } else if let preview = run.instructionsPreview {
                        Text(preview)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return "<1s" }
        if duration < 60 { return "\(Int(duration.rounded()))s" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m \(seconds)s"
    }
}

private extension ScheduleRunStatus {
    var displayName: String {
        switch self {
        case .running:
            return L("Running")
        case .succeeded:
            return L("Completed")
        case .failed:
            return L("Failed")
        case .cancelled:
            return L("Cancelled")
        case .skipped:
            return "Skipped"
        }
    }

    var iconName: String {
        switch self {
        case .running:
            return "play.circle.fill"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        case .skipped:
            return "forward.end.circle.fill"
        }
    }

    func color(theme: ThemeProtocol) -> Color {
        switch self {
        case .running:
            return theme.accentColor
        case .succeeded:
            return theme.successColor
        case .failed:
            return theme.errorColor
        case .cancelled, .skipped:
            return .orange
        }
    }
}

private extension ScheduleNextRunPreviewState {
    var iconName: String {
        switch self {
        case .scheduled:
            return "clock"
        case .due:
            return "bell.badge.fill"
        case .paused:
            return "pause.circle.fill"
        case .exhausted:
            return "checkmark.circle.fill"
        }
    }

    func color(theme: ThemeProtocol) -> Color {
        switch self {
        case .scheduled:
            return theme.accentColor
        case .due, .paused:
            return .orange
        case .exhausted:
            return theme.tertiaryText
        }
    }
}

// MARK: - Frequency Dropdown Selector

private struct FrequencySelector: View {
    @Environment(\.theme) private var theme
    @Binding var selection: ScheduleFrequencyType

    @State private var isHovering = false
    @State private var showingPopover = false

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: selection.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)

                Text(selection.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovering || showingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovering || showingPopover ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ScheduleFrequencyType.allCases, id: \.self) { type in
                    FrequencyOptionRow(
                        type: type,
                        isSelected: selection == type,
                        action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selection = type
                            }
                            showingPopover = false
                        }
                    )
                }
            }
            .padding(6)
            .frame(width: 200)
            .background(theme.cardBackground)
        }
    }
}

private struct FrequencyOptionRow: View {
    @Environment(\.theme) private var theme

    let type: ScheduleFrequencyType
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: type.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 16)

                Text(type.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHovering
                            ? theme.tertiaryBackground
                            : (isSelected ? theme.accentColor.opacity(0.08) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Schedule Time Picker

private struct ScheduleTimePicker: View {
    @Environment(\.theme) private var theme

    @Binding var hour: Int
    @Binding var minute: Int

    @State private var hourText: String = ""
    @State private var minuteText: String = ""
    @State private var isFocused = false
    @FocusState private var hourFocused: Bool
    @FocusState private var minuteFocused: Bool

    private var period: String {
        hour >= 12 ? "PM" : "AM"
    }

    private var displayHour: Int {
        let h = hour % 12
        return h == 0 ? 12 : h
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.leading, 10)

            TextField("", text: $hourText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 24)
                .multilineTextAlignment(.center)
                .focused($hourFocused)
                .onAppear {
                    hourText = "\(displayHour)"
                }
                .onChange(of: hour) { _, _ in
                    if !hourFocused {
                        hourText = "\(displayHour)"
                    }
                }
                .onSubmit { validateHour() }
                .onChange(of: hourFocused) { _, focused in
                    isFocused = focused || minuteFocused
                    if !focused { validateHour() }
                }
                .onChange(of: hourText) { _, _ in
                    if hourFocused { commitHourLive() }
                }

            Text(":")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)

            TextField("", text: $minuteText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 24)
                .multilineTextAlignment(.center)
                .focused($minuteFocused)
                .onAppear {
                    minuteText = String(format: "%02d", minute)
                }
                .onChange(of: minute) { _, newValue in
                    if !minuteFocused {
                        minuteText = String(format: "%02d", newValue)
                    }
                }
                .onSubmit { validateMinute() }
                .onChange(of: minuteFocused) { _, focused in
                    isFocused = hourFocused || focused
                    if !focused { validateMinute() }
                }
                .onChange(of: minuteText) { _, _ in
                    if minuteFocused { commitMinuteLive() }
                }

            Button(action: togglePeriod) {
                Text(period)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accentColor.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }

    private func validateHour() {
        if let value = Int(hourText), value >= 1, value <= 12 {
            let isPM = hour >= 12
            if value == 12 {
                hour = isPM ? 12 : 0
            } else {
                hour = isPM ? value + 12 : value
            }
        }
        hourText = "\(displayHour)"
    }

    /// Same clamp/AM-PM math as `validateHour`, but never rewrites
    /// `hourText` — leaves the user's in-progress edit alone.
    private func commitHourLive() {
        guard let value = Int(hourText), value >= 1, value <= 12 else { return }
        let isPM = hour >= 12
        if value == 12 {
            hour = isPM ? 12 : 0
        } else {
            hour = isPM ? value + 12 : value
        }
    }

    private func validateMinute() {
        if let value = Int(minuteText), value >= 0, value <= 59 {
            minute = value
        }
        minuteText = String(format: "%02d", minute)
    }

    private func commitMinuteLive() {
        guard let value = Int(minuteText), value >= 0, value <= 59 else { return }
        minute = value
    }

    private func togglePeriod() {
        if hour >= 12 {
            hour -= 12
        } else {
            hour += 12
        }
    }
}

// MARK: - Hourly Minute Picker

private struct HourlyMinutePicker: View {
    @Environment(\.theme) private var theme
    @Binding var minute: Int

    @State private var minuteText: String = ""
    @State private var isFocused = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.leading, 10)

            Text(":")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)

            TextField("", text: $minuteText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 28)
                .multilineTextAlignment(.center)
                .focused($textFieldFocused)
                .onAppear {
                    minuteText = String(format: "%02d", minute)
                }
                .onChange(of: minute) { _, newValue in
                    if !textFieldFocused {
                        minuteText = String(format: "%02d", newValue)
                    }
                }
                .onSubmit { validateMinute() }
                .onChange(of: textFieldFocused) { _, focused in
                    isFocused = focused
                    if !focused { validateMinute() }
                }
                // See `ScheduleTimePicker` — commit live so previews and
                // an immediate Save reflect the typed value without
                // requiring focus loss first.
                .onChange(of: minuteText) { _, _ in
                    if textFieldFocused { commitMinuteLive() }
                }

            VStack(spacing: 0) {
                Button(action: { incrementMinute() }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)

                Button(action: { decrementMinute() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }

    private func validateMinute() {
        if let value = Int(minuteText), value >= 0, value <= 59 {
            minute = value
        }
        minuteText = String(format: "%02d", minute)
    }

    private func commitMinuteLive() {
        guard let value = Int(minuteText), value >= 0, value <= 59 else { return }
        minute = value
    }

    private func incrementMinute() {
        minute = (minute + 1) % 60
        minuteText = String(format: "%02d", minute)
    }

    private func decrementMinute() {
        minute = (minute + 59) % 60
        minuteText = String(format: "%02d", minute)
    }
}

// MARK: - Weekday Button

private struct WeekdayButton: View {
    @Environment(\.theme) private var theme

    let day: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var dayLetter: String {
        String(Calendar.current.veryShortWeekdaySymbols[day - 1])
    }

    var body: some View {
        Button(action: action) {
            Text(dayLetter)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    isSelected
                        ? .white
                        : (isHovering ? theme.primaryText : theme.secondaryText)
                )
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(
                            isSelected
                                ? theme.accentColor
                                : (isHovering
                                    ? theme.tertiaryBackground
                                    : theme.inputBackground)
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isSelected
                                        ? theme.accentColor
                                        : (isHovering
                                            ? theme.accentColor.opacity(0.3)
                                            : theme.inputBorder),
                                    lineWidth: 1
                                )
                        )
                )
                .scaleEffect(isHovering && !isSelected ? 1.05 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Once Date Picker

private struct OnceDatePicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedDate: Date

    @State private var isHovering = false
    @State private var showingPopover = false

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: selectedDate)
    }

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)

                Text(formattedDate)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovering || showingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovering || showingPopover ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                DatePicker(
                    "",
                    selection: $selectedDate,
                    in: Date()...,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(8)
            }
            .background(theme.cardBackground)
        }
    }
}

// MARK: - Once Time Picker

private struct OnceTimePicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedDate: Date

    @State private var hourText: String = ""
    @State private var minuteText: String = ""
    @State private var isFocused = false
    @FocusState private var hourFocused: Bool
    @FocusState private var minuteFocused: Bool

    private var hour: Int {
        Calendar.current.component(.hour, from: selectedDate)
    }

    private var minute: Int {
        Calendar.current.component(.minute, from: selectedDate)
    }

    private var period: String {
        hour >= 12 ? "PM" : "AM"
    }

    private var displayHour: Int {
        let h = hour % 12
        return h == 0 ? 12 : h
    }

    private func updateHour(_ newHour: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: selectedDate)
        components.hour = newHour
        if let newDate = Calendar.current.date(from: components) {
            selectedDate = newDate
        }
    }

    private func updateMinute(_ newMinute: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: selectedDate)
        components.minute = newMinute
        if let newDate = Calendar.current.date(from: components) {
            selectedDate = newDate
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.leading, 10)

            TextField("", text: $hourText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 24)
                .multilineTextAlignment(.center)
                .focused($hourFocused)
                .onAppear {
                    hourText = "\(displayHour)"
                }
                .onChange(of: hour) { _, _ in
                    if !hourFocused {
                        hourText = "\(displayHour)"
                    }
                }
                .onSubmit { validateHour() }
                .onChange(of: hourFocused) { _, focused in
                    isFocused = focused || minuteFocused
                    if !focused { validateHour() }
                }
                .onChange(of: hourText) { _, _ in
                    if hourFocused { commitHourLive() }
                }

            Text(":")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)

            TextField("", text: $minuteText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 24)
                .multilineTextAlignment(.center)
                .focused($minuteFocused)
                .onAppear {
                    minuteText = String(format: "%02d", minute)
                }
                .onChange(of: minute) { _, newValue in
                    if !minuteFocused {
                        minuteText = String(format: "%02d", newValue)
                    }
                }
                .onSubmit { validateMinute() }
                .onChange(of: minuteFocused) { _, focused in
                    isFocused = hourFocused || focused
                    if !focused { validateMinute() }
                }
                .onChange(of: minuteText) { _, _ in
                    if minuteFocused { commitMinuteLive() }
                }

            Button(action: togglePeriod) {
                Text(period)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accentColor.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }

    private func validateHour() {
        if let value = Int(hourText), value >= 1, value <= 12 {
            let isPM = hour >= 12
            if value == 12 {
                updateHour(isPM ? 12 : 0)
            } else {
                updateHour(isPM ? value + 12 : value)
            }
        }
        hourText = "\(displayHour)"
    }

    private func commitHourLive() {
        guard let value = Int(hourText), value >= 1, value <= 12 else { return }
        let isPM = hour >= 12
        if value == 12 {
            updateHour(isPM ? 12 : 0)
        } else {
            updateHour(isPM ? value + 12 : value)
        }
    }

    private func validateMinute() {
        if let value = Int(minuteText), value >= 0, value <= 59 {
            updateMinute(value)
        }
        minuteText = String(format: "%02d", minute)
    }

    private func commitMinuteLive() {
        guard let value = Int(minuteText), value >= 0, value <= 59 else { return }
        updateMinute(value)
    }

    private func togglePeriod() {
        if hour >= 12 {
            updateHour(hour - 12)
        } else {
            updateHour(hour + 12)
        }
    }
}

// MARK: - Month Picker

private struct MonthPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedMonth: Int

    @State private var isHovering = false
    @State private var showingPopover = false

    private var monthName: String {
        Calendar.current.monthSymbols[selectedMonth - 1]
    }

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 4) {
                Text(monthName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovering || showingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovering || showingPopover ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(1 ... 12, id: \.self) { month in
                    MonthOptionRow(
                        month: month,
                        isSelected: selectedMonth == month,
                        action: {
                            selectedMonth = month
                            showingPopover = false
                        }
                    )
                }
            }
            .padding(6)
            .frame(width: 160)
            .background(theme.cardBackground)
        }
    }
}

// MARK: - Month Option Row

private struct MonthOptionRow: View {
    @Environment(\.theme) private var theme

    let month: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var monthName: String {
        Calendar.current.monthSymbols[month - 1]
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(monthName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isHovering
                            ? theme.tertiaryBackground
                            : (isSelected ? theme.accentColor.opacity(0.1) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Day of Month Input

private struct DayOfMonthPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedDay: Int

    @State private var dayText: String = ""
    @State private var isFocused = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField("", text: $dayText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 32)
                .multilineTextAlignment(.center)
                .focused($textFieldFocused)
                .onAppear {
                    dayText = "\(selectedDay)"
                }
                .onChange(of: selectedDay) { _, newValue in
                    if !textFieldFocused {
                        dayText = "\(newValue)"
                    }
                }
                .onChange(of: dayText) { _, newValue in
                    if let value = Int(newValue), value >= 1, value <= 31 {
                        selectedDay = value
                    }
                }
                .onSubmit {
                    validateAndUpdateDay()
                }
                .onChange(of: textFieldFocused) { _, focused in
                    isFocused = focused
                    if !focused {
                        validateAndUpdateDay()
                    }
                }

            VStack(spacing: 0) {
                Button(action: { incrementDay() }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)

                Button(action: { decrementDay() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }

    private func validateAndUpdateDay() {
        if let value = Int(dayText) {
            selectedDay = min(max(value, 1), 31)
        }
        dayText = "\(selectedDay)"
    }

    private func incrementDay() {
        selectedDay = selectedDay < 31 ? selectedDay + 1 : 1
        dayText = "\(selectedDay)"
    }

    private func decrementDay() {
        selectedDay = selectedDay > 1 ? selectedDay - 1 : 31
        dayText = "\(selectedDay)"
    }
}

// MARK: - Agent Picker

private struct AgentPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedAgentId: UUID?
    let agents: [Agent]

    @State private var isHovering = false
    @State private var showingPopover = false

    private var selectedAgent: Agent? {
        if let id = selectedAgentId {
            return agents.first(where: { $0.id == id })
        }
        return nil
    }

    private var selectedAgentName: String {
        selectedAgent?.name ?? L("Default")
    }

    private var selectedAgentDescription: String? {
        if selectedAgentId == nil {
            return L("Uses the default system behavior")
        }
        let desc = selectedAgent?.description ?? ""
        return desc.isEmpty ? nil : desc
    }

    private var hasDescription: Bool {
        selectedAgentDescription != nil
    }

    private func agentColor(for name: String) -> Color {
        let hue = Double(abs(name.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 12) {
                Circle()
                    .fill(agentColor(for: selectedAgentName).opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(agentColor(for: selectedAgentName))
                    )

                if hasDescription {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedAgentName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)

                        Text(selectedAgentDescription!)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                } else {
                    Text(selectedAgentName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovering || showingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovering || showingPopover ? 1.5 : 1
                            )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                AgentOptionRow(
                    name: "Default",
                    description: "Uses the default system behavior",
                    isSelected: selectedAgentId == nil,
                    action: {
                        selectedAgentId = nil
                        showingPopover = false
                    }
                )

                if !agents.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    ForEach(agents, id: \.id) { agent in
                        AgentOptionRow(
                            name: agent.name,
                            description: agent.description,
                            isSelected: selectedAgentId == agent.id,
                            action: {
                                selectedAgentId = agent.id
                                showingPopover = false
                            }
                        )
                    }
                }
            }
            .padding(8)
            .frame(minWidth: 280)
            .background(theme.cardBackground)
        }
    }
}

// MARK: - Agent Option Row

private struct AgentOptionRow: View {
    @Environment(\.theme) private var theme

    let name: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.tertiaryBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Schedule Editor Sheet

struct ScheduleEditorSheet: View {
    enum Mode {
        case create
        case edit(Schedule)
    }

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let mode: Mode
    let onSave: (Schedule) -> Void
    let onCancel: () -> Void
    var initialAgentId: UUID? = nil

    @State private var name = ""
    @State private var instructions = ""
    @State private var selectedAgentId: UUID?
    @State private var frequencyType: ScheduleFrequencyType = .daily
    @State private var isEnabled = true
    @State private var selectedFolderPath: String?
    @State private var selectedFolderBookmark: Data?
    @State private var selectedIntervalMinutes = 30
    @State private var selectedHour = 9
    @State private var selectedMinute = 0
    @State private var selectedDayOfWeek = 2  // Monday
    @State private var selectedDayOfMonth = 1
    @State private var selectedMonth = 1
    @State private var selectedDay = 1
    @State private var selectedDate = Date()
    @State private var cronExpression = "0 9 * * *"
    @State private var hasAppeared = false
    @State private var attemptedSave = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameInvalid: Bool { attemptedSave && trimmedName.isEmpty }
    private var instructionsInvalid: Bool { attemptedSave && trimmedInstructions.isEmpty }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingId: UUID? {
        if case .edit(let schedule) = mode { return schedule.id }
        return nil
    }

    private var existingCreatedAt: Date? {
        if case .edit(let schedule) = mode { return schedule.createdAt }
        return nil
    }

    private var existingLastRunAt: Date? {
        if case .edit(let schedule) = mode { return schedule.lastRunAt }
        return nil
    }

    private var existingLastTriggeredAt: Date? {
        if case .edit(let schedule) = mode { return schedule.lastTriggeredAt }
        return nil
    }

    private var existingLastChatSessionId: UUID? {
        if case .edit(let schedule) = mode { return schedule.lastChatSessionId }
        return nil
    }

    /// The schedule being edited, if any. Used to detect whether the form
    /// still matches what's stored so "Save Changes" can disable itself.
    private var editingSchedule: Schedule? {
        if case .edit(let schedule) = mode { return schedule }
        return nil
    }

    /// True when an edited schedule differs from its stored version.
    /// Create mode is always "changed" so its button keeps the existing
    /// click-to-reveal-validation behaviour.
    private var hasChanges: Bool {
        guard let original = editingSchedule else { return true }
        return trimmedName != original.name
            || trimmedInstructions != original.instructions
            || selectedAgentId != original.agentId
            || isEnabled != original.isEnabled
            || selectedFolderPath != original.folderPath
            || selectedFolderBookmark != original.folderBookmark
            || buildFrequency() != original.frequency
    }

    private var existingRunHistory: [ScheduleRunHistoryEntry] {
        if case .edit(let schedule) = mode { return schedule.runHistory }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    scheduleInfoSection
                    folderContextSection
                    instructionsSection
                    frequencySection
                    agentSection
                }
                .padding(24)
            }

            footerView
        }
        .frame(width: 580, height: 680)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            if case .edit(let schedule) = mode {
                loadSchedule(schedule)
            } else if let initialAgentId = initialAgentId {
                selectedAgentId = initialAgentId
            }
            withAnimation {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.2),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: isEditing ? "pencil.circle.fill" : "calendar.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? L("Edit Schedule") : L("Create Schedule"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(isEditing ? L("Modify your scheduled task") : L("Set up an automated AI task"))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Schedule Info Section

    private var scheduleInfoSection: some View {
        ScheduleEditorSection(title: L("Schedule Info"), icon: "info.circle.fill") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    ScheduleTextField(
                        placeholder: L("e.g., Daily Summary"),
                        text: $name,
                        icon: "textformat",
                        isInvalid: nameInvalid
                    )

                    if nameInvalid {
                        Text("Name is required", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.errorColor)
                    }
                }

                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(
                                isEnabled
                                    ? theme.successColor : theme.tertiaryText
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enabled", bundle: .module)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(isEnabled ? L("Schedule is active") : L("Schedule is paused"))
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    isEnabled
                                        ? theme.successColor.opacity(0.3)
                                        : theme.inputBorder,
                                    lineWidth: 1
                                )
                        )
                )
            }
        }
    }

    // MARK: - Folder Context Section

    private var hasFolder: Bool { selectedFolderPath != nil }

    private var folderContextSection: some View {
        ScheduleEditorSection(title: L("Working Directory"), icon: "folder.fill") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(hasFolder ? theme.accentColor.opacity(0.1) : theme.tertiaryBackground)
                        Image(systemName: hasFolder ? "folder.fill" : "folder.badge.questionmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(hasFolder ? theme.accentColor : theme.tertiaryText)
                    }
                    .frame(width: 36, height: 36)

                    if let path = selectedFolderPath {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            Text(path)
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text("No folder selected", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                    }

                    Spacer()

                    if hasFolder {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedFolderPath = nil
                                selectedFolderBookmark = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: selectFolder) {
                        Text("Browse", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.accentColor.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                Text("The AI will use this folder as its working directory.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L("Select Working Directory")
        panel.prompt = L("Select")

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }

            do {
                let bookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedFolderPath = url.path
                    selectedFolderBookmark = bookmark
                }
            } catch {
                print("[ScheduleEditor] Failed to create bookmark: \(error)")
            }
        }
    }

    // MARK: - Instructions Section

    private var instructionsSection: some View {
        ScheduleEditorSection(title: L("Instructions"), icon: "text.alignleft") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if instructions.isEmpty {
                        Text("What should the AI do when this runs?", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                            .padding(.top, 12)
                            .padding(.leading, 16)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100, maxHeight: 150)
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    instructionsInvalid ? theme.errorColor : theme.inputBorder,
                                    lineWidth: instructionsInvalid ? 1.5 : 1
                                )
                        )
                )

                if instructionsInvalid {
                    Text("Instructions are required", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                } else {
                    Text("These instructions will be sent to the AI when the schedule runs.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    // MARK: - Frequency Section

    private var frequencySection: some View {
        ScheduleEditorSection(title: L("Frequency"), icon: "clock.fill") {
            VStack(spacing: 16) {
                FrequencySelector(selection: $frequencyType)
                frequencyOptionsView
                    .animation(.easeInOut(duration: 0.2), value: frequencyType)
            }
        }
    }

    @ViewBuilder
    private var frequencyOptionsView: some View {
        switch frequencyType {
        case .once:
            onceOptions
        case .everyNMinutes:
            everyNMinutesOptions
        case .hourly:
            hourlyOptions
        case .daily:
            dailyOptions
        case .weekly:
            weeklyOptions
        case .monthly:
            monthlyOptions
        case .yearly:
            yearlyOptions
        case .cron:
            cronOptions
        }
    }

    private var cronOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cron Expression", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                ScheduleTextField(
                    placeholder: "e.g., 15 0,7 * * 1-5",
                    text: $cronExpression,
                    icon: "terminal"
                )
            }

            Text("Format: minute hour day-of-month month day-of-week", bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Text("Supports standard 5 field format with * , - and / operators", bundle: .module)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)

            if let nextRun = CronParser(cronExpression)?.nextDate(after: Date()) {
                schedulePreview(text: "Next run: \(formattedDate(nextRun))")
            } else {
                schedulePreview(text: "Invalid cron expression", isError: true)
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var onceOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Date", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    OnceDatePicker(selectedDate: $selectedDate)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Time", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    OnceTimePicker(selectedDate: $selectedDate)
                }

                Spacer()
            }

            oncePreview
        }
    }

    private var oncePreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scheduled for", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                Text(formattedOnceDate)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var formattedOnceDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(selectedDate) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInTomorrow(selectedDate) {
            formatter.dateFormat = "'Tomorrow at' h:mm a"
        } else {
            formatter.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
        }

        return formatter.string(from: selectedDate)
    }

    // MARK: - Every N Minutes Options

    private let minuteIntervalChoices = [5, 10, 15, 20, 30, 45]

    private var everyNMinutesOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Interval", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HStack(spacing: 6) {
                    ForEach(minuteIntervalChoices, id: \.self) { interval in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedIntervalMinutes = interval
                            }
                        } label: {
                            Text("\(interval)m", bundle: .module)
                                .font(
                                    .system(size: 12, weight: selectedIntervalMinutes == interval ? .semibold : .medium)
                                )
                                .foregroundColor(
                                    selectedIntervalMinutes == interval
                                        ? .white
                                        : theme.secondaryText
                                )
                                .frame(minWidth: 40, minHeight: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(
                                            selectedIntervalMinutes == interval
                                                ? theme.accentColor
                                                : theme.inputBackground
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .stroke(
                                                    selectedIntervalMinutes == interval
                                                        ? theme.accentColor
                                                        : theme.inputBorder,
                                                    lineWidth: 1
                                                )
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            schedulePreview(text: everyNMinutesPreviewText)
        }
    }

    private var everyNMinutesPreviewText: String {
        "Every \(selectedIntervalMinutes) minutes"
    }

    // MARK: - Hourly Options

    private var hourlyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Minute of Hour", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HourlyMinutePicker(minute: $selectedMinute)
            }

            schedulePreview(text: hourlyPreviewText)
        }
    }

    private var hourlyPreviewText: String {
        "Every hour at :\(String(format: "%02d", selectedMinute))"
    }

    // MARK: - Daily Options

    private var dailyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Time", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                timePicker
            }

            schedulePreview(text: dailyPreviewText)
        }
    }

    private var dailyPreviewText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = selectedHour
        components.minute = selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Every day at \(formatter.string(from: date))"
        }
        return "Every day at \(selectedHour):\(String(format: "%02d", selectedMinute))"
    }

    private var weeklyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Day of Week", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HStack(spacing: 6) {
                    ForEach(1 ... 7, id: \.self) { day in
                        WeekdayButton(
                            day: day,
                            isSelected: selectedDayOfWeek == day,
                            action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedDayOfWeek = day
                                }
                            }
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Time", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                timePicker
            }

            schedulePreview(text: weeklyPreviewText)
        }
    }

    private var weeklyPreviewText: String {
        let dayName = Calendar.current.weekdaySymbols[selectedDayOfWeek - 1]
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = selectedHour
        components.minute = selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Every \(dayName) at \(formatter.string(from: date))"
        }
        return "Every \(dayName)"
    }

    private var monthlyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Day of Month", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    DayOfMonthPicker(selectedDay: $selectedDayOfMonth)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Time", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    timePicker
                }

                Spacer()
            }

            Text("If the day doesn't exist in a month, it will run on the last day.", bundle: .module)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 4)

            schedulePreview(text: monthlyPreviewText)
        }
    }

    private var monthlyPreviewText: String {
        let suffix = daySuffix(selectedDayOfMonth)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = selectedHour
        components.minute = selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Monthly on the \(selectedDayOfMonth)\(suffix) at \(formatter.string(from: date))"
        }
        return "Monthly on the \(selectedDayOfMonth)\(suffix)"
    }

    private func daySuffix(_ day: Int) -> String {
        switch day {
        case 1, 21, 31: return "st"
        case 2, 22: return "nd"
        case 3, 23: return "rd"
        default: return "th"
        }
    }

    private var yearlyOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Month", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    MonthPicker(selectedMonth: $selectedMonth)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Day", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    DayOfMonthPicker(selectedDay: $selectedDay)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Time", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    timePicker
                }

                Spacer()
            }

            schedulePreview(text: yearlyPreviewText)
        }
    }

    private var yearlyPreviewText: String {
        let monthName = Calendar.current.monthSymbols[selectedMonth - 1]
        let suffix = daySuffix(selectedDay)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = selectedHour
        components.minute = selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Yearly on \(monthName) \(selectedDay)\(suffix) at \(formatter.string(from: date))"
        }
        return "Yearly on \(monthName) \(selectedDay)\(suffix)"
    }

    private var timePicker: some View {
        ScheduleTimePicker(hour: $selectedHour, minute: $selectedMinute)
    }

    // Helper view for schedule preview
    private func schedulePreview(text: String, isError: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "repeat")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isError ? theme.errorColor : theme.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(isError ? L("Error") : L("Schedule"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isError ? theme.errorColor : theme.tertiaryText)
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isError ? theme.errorColor : theme.primaryText)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((isError ? theme.errorColor : theme.accentColor).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke((isError ? theme.errorColor : theme.accentColor).opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Agent Section

    private var agentSection: some View {
        ScheduleEditorSection(title: L("Agent"), icon: "person.circle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                AgentPicker(
                    selectedAgentId: $selectedAgentId,
                    agents: agentManager.agents.filter { !$0.isBuiltIn }
                )
                .frame(maxWidth: .infinity)

                Text("The agent determines the AI's behavior and available tools.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(action: onCancel) { Text("Cancel", bundle: .module) }
                .buttonStyle(ScheduleSecondaryButtonStyle())

            Button(isEditing ? L("Save Changes") : L("Create Schedule")) {
                saveSchedule()
            }
            .buttonStyle(SchedulePrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isEditing && !hasChanges)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    // MARK: - Helpers

    private func loadSchedule(_ schedule: Schedule) {
        name = schedule.name
        instructions = schedule.instructions
        selectedAgentId = schedule.agentId
        isEnabled = schedule.isEnabled
        selectedFolderPath = schedule.folderPath
        selectedFolderBookmark = schedule.folderBookmark
        frequencyType = schedule.frequency.frequencyType

        switch schedule.frequency {
        case .once(let date):
            selectedDate = date
        case .everyNMinutes(let minutes):
            selectedIntervalMinutes = minutes
        case .hourly(let minute):
            selectedMinute = minute
        case .daily(let hour, let minute):
            selectedHour = hour
            selectedMinute = minute
        case .weekly(let dayOfWeek, let hour, let minute):
            selectedDayOfWeek = dayOfWeek
            selectedHour = hour
            selectedMinute = minute
        case .monthly(let dayOfMonth, let hour, let minute):
            selectedDayOfMonth = dayOfMonth
            selectedHour = hour
            selectedMinute = minute
        case .yearly(let month, let day, let hour, let minute):
            selectedMonth = month
            selectedDay = day
            selectedHour = hour
            selectedMinute = minute
        case .cron(let expression):
            cronExpression = expression
        }
    }

    private func buildFrequency() -> ScheduleFrequency {
        switch frequencyType {
        case .once:
            return .once(date: selectedDate)
        case .everyNMinutes:
            return .everyNMinutes(minutes: selectedIntervalMinutes)
        case .hourly:
            return .hourly(minute: selectedMinute)
        case .daily:
            return .daily(hour: selectedHour, minute: selectedMinute)
        case .weekly:
            return .weekly(dayOfWeek: selectedDayOfWeek, hour: selectedHour, minute: selectedMinute)
        case .monthly:
            return .monthly(dayOfMonth: selectedDayOfMonth, hour: selectedHour, minute: selectedMinute)
        case .yearly:
            return .yearly(month: selectedMonth, day: selectedDay, hour: selectedHour, minute: selectedMinute)
        case .cron:
            return .cron(expression: cronExpression)
        }
    }

    private func saveSchedule() {
        guard !trimmedName.isEmpty, !trimmedInstructions.isEmpty else {
            // surface the validation errors instead of doing nothing
            withAnimation(.easeOut(duration: 0.15)) {
                attemptedSave = true
            }
            return
        }

        let schedule = Schedule(
            id: existingId ?? UUID(),
            name: trimmedName,
            instructions: trimmedInstructions,
            agentId: selectedAgentId,
            folderPath: selectedFolderPath,
            folderBookmark: selectedFolderBookmark,
            frequency: buildFrequency(),
            isEnabled: isEnabled,
            lastRunAt: existingLastRunAt,
            lastTriggeredAt: existingLastTriggeredAt,
            lastChatSessionId: existingLastChatSessionId,
            runHistory: existingRunHistory,
            createdAt: existingCreatedAt ?? Date(),
            updatedAt: Date()
        )

        onSave(schedule)
    }
}

// MARK: - Editor Section

private struct ScheduleEditorSection<Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Text Field

private struct ScheduleTextField: View {
    @Environment(\.theme) private var theme

    let placeholder: String
    @Binding var text: String
    let icon: String?
    var isInvalid: Bool = false

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        isFocused ? theme.accentColor : theme.tertiaryText
                    )
                    .frame(width: 16)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }

                TextField(
                    "",
                    text: $text,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(borderColor, lineWidth: isFocused || isInvalid ? 1.5 : 1)
                )
        )
    }

    private var borderColor: Color {
        if isInvalid { return theme.errorColor }
        if isFocused { return theme.accentColor.opacity(0.5) }
        return theme.inputBorder
    }
}

// MARK: - Button Styles

private struct SchedulePrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isEnabled ? .white : theme.tertiaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isEnabled ? theme.accentColor : theme.tertiaryBackground)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct ScheduleSecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        SchedulesView()
    }
#endif
