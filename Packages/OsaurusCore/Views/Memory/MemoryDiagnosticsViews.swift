//
//  MemoryDiagnosticsViews.swift
//  osaurus
//
//  All view-builders + helpers used by the Memory > Diagnostics card.
//  Moved out of `MemoryView.swift` so the parent file stays focused on
//  identity / agents / configuration / data-loading concerns. The
//  `@State` variables that drive these views still live on `MemoryView`
//  itself — this file is purely presentation + lightweight orchestration.
//
//  Layout:
//   * `diagnosticsSection`           — card + alert wiring
//   * Backfill banners + `runBackfill`
//   * Probe banner + `runBufferProbe`
//   * Pipeline-state group + headline
//   * Per-agent memory list
//   * Recent processing log list
//   * Shared `diagnosticBanner` + `diagnosticRow` chrome
//

import SwiftUI

extension MemoryView {
    // MARK: - Section

    /// Surfaces the actual write-pipeline state. The fastest way to
    /// localise "memory not building" to one of:
    ///   * `bufferTurn` never called      → pending = 0, log empty
    ///   * buffered but never distilled   → pending > 0, log empty
    ///   * distill running but skipping   → log full of "skipped" rows
    ///   * distill calling an unhealthy model → log full of "error" rows
    var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            pipelineCard
            perAgentMemoryCard
            recentProcessingLogCard
        }
        .themedAlert(
            L("Backfill chat history?"),
            isPresented: $showBackfillConfirm,
            message:
                L(
                    "This walks every chat session in your history, buffers their turns into pending_signals, then runs distillation. It can take a while if you have hundreds of sessions — each one is a single LLM call against your core model. Already-distilled sessions are skipped."
                ),
            primaryButton: .primary(L("Start backfill")) { runBackfill() },
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            L("Reset memory store?"),
            isPresented: $showMemoryResetConfirm,
            message:
                L(
                    "The unreadable database is moved to ~/.osaurus/quarantine/ (never deleted) and a fresh, empty memory store is created so memory and search work again. Distilled facts and episodes in the old file stay in quarantine — export a plaintext backup first if you might recover the key."
                ),
            primaryButton: .destructive(L("Reset store")) { runMemoryRecovery(reset: true) },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    /// Top diagnostics card: an at-a-glance health headline, then the
    /// write-pipeline state split into "Status" (config gates that decide
    /// whether the pipeline can run) and "Activity" (throughput counters).
    /// The backfill / probe actions live in the card header and surface
    /// their progress inline.
    private var pipelineCard: some View {
        MemorySectionCard(
            title: L("Pipeline"),
            icon: "waveform.path.ecg"
        ) {
            MemorySectionActionButton(
                backfillButtonTitle,
                icon: "tray.and.arrow.down"
            ) {
                showBackfillConfirm = true
            }
            .disabled(backfillRunning || !config.enabled)

            MemorySectionActionButton(
                probeBufferRunning ? L("Probing...") : L("Test buffer"),
                icon: "syringe"
            ) {
                runBufferProbe()
            }
            .disabled(probeBufferRunning)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                pipelineHeadlineBanner

                if backfillRunning {
                    backfillProgressBanner
                } else if let backfillSummary {
                    backfillSummaryBanner(backfillSummary)
                }
                if let probeBufferResult {
                    bufferProbeResultBanner(probeBufferResult)
                }

                diagnosticSubsection(L("Status")) {
                    statusRows
                }

                Divider().opacity(0.4)

                diagnosticSubsection(L("Activity")) {
                    activityRows
                }
            }
        }
    }

    /// At-a-glance pipeline health derived from `diagnosticHeadline()`.
    /// Replaces the old collapsed one-liner now that diagnostics is its
    /// own always-expanded tab.
    private var pipelineHeadlineBanner: some View {
        let summary = diagnosticHeadline()
        return HStack(spacing: 8) {
            Circle()
                .fill(summary.color)
                .frame(width: 8, height: 8)
            Text(summary.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(summary.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(summary.color.opacity(0.22), lineWidth: 1)
                )
        )
    }

    /// Uppercase sub-header + grouped content, matching the per-agent /
    /// recent-activity section chrome used elsewhere in this tab.
    @ViewBuilder
    private func diagnosticSubsection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.4)
                .textCase(.uppercase)
            content()
        }
    }

    // MARK: - Backfill

    var backfillButtonTitle: String {
        guard backfillRunning else { return L("Backfill history") }
        switch backfillProgress.stage {
        case .buffering: return L("Buffering...")
        case .distilling: return L("Distilling...")
        case .done, .cancelled: return L("Backfilling...")
        }
    }

    var backfillProgressBanner: some View {
        let p = backfillProgress
        let stageText: String
        switch p.stage {
        case .buffering:
            stageText =
                "Buffering session \(p.sessionsProcessed + p.sessionsSkipped)/\(p.sessionsTotal)"
        case .distilling:
            stageText =
                "Distilling \(p.sessionsProcessed) buffered session\(p.sessionsProcessed == 1 ? "" : "s")..."
        case .done, .cancelled:
            stageText = "Wrapping up..."
        }
        return HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(stageText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let title = p.lastSessionTitle, !title.isEmpty {
                    Text(localized: "Last: \(title)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Text(
                    "buffered \(p.turnsBuffered) turn\(p.turnsBuffered == 1 ? "" : "s") · skipped \(p.sessionsSkipped) session\(p.sessionsSkipped == 1 ? "" : "s")"
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Button {
                backfillTask?.cancel()
            } label: {
                Text("Cancel", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.errorColor.opacity(0.12)))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    func backfillSummaryBanner(_ message: String) -> some View {
        diagnosticBanner(
            icon: "checkmark.circle.fill",
            iconColor: .green,
            text: message,
            monospaced: false,
            onDismiss: { backfillSummary = nil }
        )
    }

    func runBackfill() {
        guard !backfillRunning else { return }
        backfillRunning = true
        backfillSummary = nil
        backfillProgress = MemoryBackfillProgress()
        backfillTask = Task.detached {
            let final = await MemoryService.shared.backfillFromChatHistory(
                distillAfterBuffering: true
            ) { snapshot in
                backfillProgress = snapshot
            }
            await MainActor.run {
                backfillSummary = Self.summarize(backfill: final)
                backfillRunning = false
                loadData()
            }
        }
    }

    private static func summarize(backfill final: MemoryBackfillProgress) -> String {
        switch final.stage {
        case .cancelled:
            return
                L(
                    "Backfill cancelled after \(final.sessionsProcessed) session(s) — \(final.turnsBuffered) turns buffered. Run 'Distill pending' to drain them."
                )
        default:
            return
                L(
                    "Backfill complete: \(final.sessionsProcessed) session(s) buffered (\(final.turnsBuffered) turns), \(final.sessionsSkipped) skipped. Distillation finished."
                )
        }
    }

    // MARK: - Probe

    func bufferProbeResultBanner(_ outcome: BufferProbeOutcome) -> some View {
        diagnosticBanner(
            icon: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            iconColor: outcome.isSuccess ? .green : .orange,
            text: outcome.displayText,
            monospaced: true,
            onDismiss: { probeBufferResult = nil }
        )
    }

    func runBufferProbe() {
        guard !probeBufferRunning else { return }
        probeBufferRunning = true
        probeBufferResult = nil
        Task.detached {
            let outcome = await MemoryDiagnostics.runBufferProbe()
            await MainActor.run {
                probeBufferResult = outcome
                probeBufferRunning = false
                loadData()
            }
        }
    }

    // MARK: - Pipeline state

    /// Configuration gates that decide whether the pipeline can run at
    /// all: global enable, DB health, extraction mode, and core model.
    @ViewBuilder
    var statusRows: some View {
        diagnosticRow(
            label: "Memory enabled",
            value: config.enabled ? L("yes") : L("no"),
            statusColor: config.enabled ? .green : .red
        )
        memoryDBStatusRow
        diagnosticRow(
            label: "Extraction mode",
            value: extractionModeDescription(config.extractionMode),
            statusColor: config.extractionMode == .sessionEnd ? .green : .orange,
            detail: config.extractionMode == .manual
                ? L("Manual mode never auto-distills. Use 'Distill pending' or set to sessionEnd.")
                : nil
        )
        diagnosticRow(
            label: "Core model",
            value: coreModelStatusText(coreModelStatus),
            statusColor: coreModelStatusColor(coreModelStatus),
            detail: coreModelStatusDetail(coreModelStatus)
        )
    }

    // MARK: - Memory DB health + recovery

    /// The "Memory DB open" row. When closed, it classifies the *real*
    /// cause (key-locked vs corrupt vs migration, via `PersistenceHealth`)
    /// instead of the old generic string, and offers in-place recovery —
    /// Retry the open, or Reset (quarantine + recreate) the store.
    @ViewBuilder
    var memoryDBStatusRow: some View {
        if memoryDBOpen {
            diagnosticRow(label: "Memory DB open", value: L("yes"), statusColor: .green)
        } else {
            let issue = PersistenceHealth.shared.storeIssue(
                for: StorageRecoveryService.Store.memory.rawValue
            )
            VStack(alignment: .leading, spacing: 8) {
                diagnosticRow(
                    label: "Memory DB open",
                    value: L("no"),
                    statusColor: .red,
                    detail: memoryDBFailureDetail(issue)
                )
                memoryRecoveryControls
            }
        }
    }

    /// Plain-language cause for a closed memory DB, derived from the
    /// classified `StorageStoreIssue` and the database's last open error.
    private func memoryDBFailureDetail(_ issue: StorageStoreIssue?) -> String {
        let cause: String
        switch issue?.kind {
        case .locked:
            cause = L(
                "The storage encryption key is unavailable on this Mac (Keychain reset, app re-sign, or migration without iCloud Keychain). Your encrypted memory can't be unlocked with the current key."
            )
        case .corrupt:
            cause = L(
                "The database file is unreadable — it may be corrupt or was encrypted with a different key."
            )
        case .migration:
            cause = L(
                "A schema migration failed, so the database couldn't be upgraded to this build's format."
            )
        case .unknown:
            cause = L("The memory database failed to open for an unrecognized reason.")
        case .none:
            cause = L(
                "The memory database isn't open. It may still be initializing, or it failed silently — try Retry."
            )
        }
        let underlying = issue?.message ?? MemoryDatabase.shared.lastOpenErrorDescription
        if let underlying, !underlying.isEmpty {
            return cause + "\n\n" + L("Details: \(underlying)")
        }
        return cause
    }

    /// Retry / Reset buttons shown under a closed memory DB row.
    private var memoryRecoveryControls: some View {
        HStack(spacing: 8) {
            recoveryButton(
                title: L("Retry open"),
                icon: "arrow.clockwise",
                tint: theme.accentColor,
                disabled: memoryRecoveryRunning
            ) {
                runMemoryRecovery(reset: false)
            }
            recoveryButton(
                title: L("Reset store…"),
                icon: "trash",
                tint: theme.errorColor,
                disabled: memoryRecoveryRunning
            ) {
                showMemoryResetConfirm = true
            }
            if memoryRecoveryRunning {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 17)
    }

    private func recoveryButton(
        title: String,
        icon: String,
        tint: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }

    /// Run a recovery action against the memory store off the main actor,
    /// then refresh diagnostics so the row reflects the new state.
    func runMemoryRecovery(reset: Bool) {
        guard !memoryRecoveryRunning else { return }
        memoryRecoveryRunning = true
        Task {
            if reset {
                let dest = await StorageRecoveryService.shared.resetStore(.memory)
                await MainActor.run {
                    if let dest {
                        showToast(L("Memory store reset. Old file kept at \(dest.lastPathComponent)."))
                    } else {
                        showToast(L("Memory store reset."))
                    }
                }
            } else {
                let ok = await StorageRecoveryService.shared.retryStore(.memory)
                await MainActor.run {
                    showToast(
                        ok ? L("Memory database reopened.") : L("Still can't open memory — try Reset."),
                        isError: !ok
                    )
                }
            }
            await MainActor.run {
                memoryRecoveryRunning = false
                loadData()
            }
        }
    }

    /// Throughput counters that show whether turns are flowing through the
    /// pipeline: pending signals, episodes, pinned facts, live chat,
    /// distill queue, and buffer telemetry.
    @ViewBuilder
    var activityRows: some View {
        diagnosticRow(
            label: "Pending signals",
            value:
                L("\(pendingSignals.totalSignals) pending · \(pendingSignals.allTimeSignals) all-time"),
            statusColor: pendingSignalsStatusColor,
            detail: pendingSignalsStatusDetail
        )
        diagnosticRow(
            label: "Episodes",
            value: "\(totalEpisodes)",
            statusColor: totalEpisodes == 0 ? .red : .green
        )
        diagnosticRow(
            label: "Pinned facts",
            value: "\(totalPinned)",
            statusColor: totalPinned == 0 ? .gray : .green
        )
        // The two coordinators added in 2026-05 to make
        // distillation safe on heavy MLX core models. "Live chat"
        // shows whether ChatEngine has any in-flight generation;
        // "Distill queue" shows the DistillationCoordinator's
        // single-flight depth + whether a body is executing right
        // now. Together they explain "why is my distillation
        // pausing?" without the user needing to read logs.
        diagnosticRow(
            label: "Live chat",
            value: chatActive ? L("active") : L("idle"),
            statusColor: chatActive ? .orange : .green,
            detail: chatActive
                ? L(
                    """
                    Background distillation is paused while a chat \
                    generation is streaming — they share GPU/unified memory.
                    """
                )
                : nil
        )
        diagnosticRow(
            label: "Distill queue",
            value: distillQueueValueText,
            statusColor: distillQueueStatusColor
        )
        bufferTelemetryRow
    }

    private var distillQueueValueText: String {
        let q = distillSnapshot.queued
        let activeMarker = distillSnapshot.active ? L("running") : L("idle")
        if q == 0 { return L("0 queued · \(activeMarker)") }
        return L("\(q) queued · \(activeMarker)")
    }

    private var distillQueueStatusColor: Color {
        if distillSnapshot.active { return .blue }
        if distillSnapshot.queued > 0 { return .orange }
        return .gray
    }

    private var pendingSignalsStatusColor: Color {
        if pendingSignals.allTimeSignals == 0 { return .red }
        if pendingSignals.totalSignals == 0 { return .green }
        return .orange
    }

    private var pendingSignalsStatusDetail: String? {
        if pendingSignals.allTimeSignals == 0 {
            return
                L(
                    """
                    No turns have ever reached the database. The chat code \
                    never calls bufferTurn for this install — see Buffer Telemetry below.
                    """
                )
        }
        if pendingSignals.totalSignals == 0 {
            return
                L(
                    """
                    All buffered turns have been distilled (or purged). \
                    The pipeline is healthy when episodes are growing.
                    """
                )
        }
        return nil
    }

    private var bufferTelemetryRow: some View {
        let t = bufferTelemetry
        let valueText: String
        let detail: String?
        let color: Color
        if t.attempts == 0 {
            valueText = L("0 attempts since launch")
            detail =
                L(
                    """
                    MemoryService.bufferTurn has not been invoked since the app started. \
                    The chat finalization path isn't reaching it — likely an upstream gate \
                    (per-agent disableMemory, hasContent=false, or a non-default chat path).
                    """
                )
            color = .red
        } else if t.insertSuccesses == 0 {
            let buckets = [
                t.earlyReturnsEmptyMessage > 0 ? "\(t.earlyReturnsEmptyMessage) empty msg" : nil,
                t.earlyReturnsDisabled > 0 ? "\(t.earlyReturnsDisabled) memory off" : nil,
                t.insertFailures > 0 ? "\(t.insertFailures) insert err" : nil,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
            valueText = "\(t.attempts) attempts, 0 successes"
            detail =
                "bufferTurn ran but every call bailed (\(buckets.isEmpty ? "no breakdown" : buckets))."
                + (t.lastError.map { " Last error: \($0)" } ?? "")
            color = .orange
        } else {
            valueText = "\(t.insertSuccesses)/\(t.attempts) successful"
            detail = nil
            color = .green
        }
        return diagnosticRow(
            label: "Buffer telemetry (this run)",
            value: valueText,
            statusColor: color,
            detail: detail
        )
    }

    // MARK: - Per-agent memory

    var perAgentMemoryCard: some View {
        MemorySectionCard(
            title: L("Per-Agent Memory"),
            icon: "person.2",
            count: agentManager.agents.isEmpty ? nil : agentManager.agents.count
        ) {
            if agentManager.agents.isEmpty {
                Text("No agents configured. Create an agent first.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agentManager.agents, id: \.id) { agent in
                        perAgentMemoryRow(agent)
                    }
                }
            }
        }
    }

    private func perAgentMemoryRow(_ agent: Agent) -> some View {
        let globalDisabled = !config.enabled
        let perAgentDisabled = !agent.memoryEnabled
        let isOff = globalDisabled || perAgentDisabled
        let stateText: String
        let stateColor: Color
        if globalDisabled {
            stateText = "off (global)"
            stateColor = .red
        } else if perAgentDisabled {
            stateText = "off (this agent)"
            stateColor = .orange
        } else {
            stateText = "on"
            stateColor = .green
        }
        let canEnableHere = perAgentDisabled && !agent.isBuiltIn
        return HStack(spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text(agent.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Spacer()
            Text(LocalizedStringKey(stateText), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(stateColor)
            if canEnableHere {
                Button {
                    enableMemory(for: agent)
                } label: {
                    Text("Enable", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                }
                .buttonStyle(PlainButtonStyle())
            } else if globalDisabled, isOff {
                Text("toggle below", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(.vertical, 2)
    }

    func enableMemory(for agent: Agent) {
        guard !agent.isBuiltIn else { return }
        var updated = agent
        updated.memoryEnabled = true
        agentManager.update(updated)
        showToast(L("Memory enabled for \(agent.displayName)"))
    }

    // MARK: - Recent processing log

    var recentProcessingLogCard: some View {
        MemorySectionCard(
            title: L("Recent Activity"),
            icon: "list.bullet.rectangle",
            count: recentLogs.isEmpty ? nil : recentLogs.count
        ) {
            if recentLogs.isEmpty {
                Text(
                    "No processing log entries yet. If you've been chatting, the distill pipeline never reached the model.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recentLogs) { row in
                        processingLogRow(row)
                        if row.id != recentLogs.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    private func processingLogRow(_ row: ProcessingLogRow) -> some View {
        HStack(spacing: 8) {
            Text(processingLogStatusBadge(row.status))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(processingLogStatusColor(row.status)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.taskType)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if let model = row.model, !model.isEmpty {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                if let details = row.details, !details.isEmpty {
                    Text(details)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(MemoryView.formatRelativeDate(row.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                if let ms = row.durationMs, ms > 0 {
                    Text("\(ms)ms")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shared chrome

    /// Single shared banner (icon + text + dismiss "x" on a tertiary
    /// background). Used by the buffer-probe outcome AND the backfill
    /// summary; the only knobs are the icon, the icon tint, and whether
    /// to render the body in monospaced text (probe banner attaches a
    /// multi-line schema dump on `SQLITE_CONSTRAINT` failures).
    @ViewBuilder
    func diagnosticBanner(
        icon: String,
        iconColor: Color,
        text: String,
        monospaced: Bool,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(iconColor)
            Text(text)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
        )
    }

    private func diagnosticRow(
        label: String,
        value: String,
        statusColor: Color,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.leading, 17)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Status helpers

    private func extractionModeDescription(_ mode: MemoryExtractionMode) -> String {
        switch mode {
        case .sessionEnd: return L("session-end (default)")
        case .manual: return L("manual")
        }
    }

    private func coreModelStatusText(_ status: CoreModelStatus) -> String {
        switch status {
        case .unset: return L("unset")
        case .available(let modelId, _, _): return "\(modelId) (available)"
        case .unavailable(let modelId, _): return "\(modelId) (unavailable)"
        case .breakerOpen(let modelId, _): return "\(modelId ?? "unset") (breaker open)"
        }
    }

    private func coreModelStatusColor(_ status: CoreModelStatus) -> Color {
        switch status {
        case .available: return .green
        case .unset, .unavailable: return .red
        case .breakerOpen: return .orange
        }
    }

    private func coreModelStatusDetail(_ status: CoreModelStatus) -> String? {
        switch status {
        case .unset:
            return L("Distillation is silently disabled. Pick a model in Settings → General.")
        case .unavailable(_, let reason):
            return reason
        case .breakerOpen(_, let until):
            let secs = max(1, Int(until.timeIntervalSinceNow))
            return "Cooling down for ~\(secs)s after consecutive failures. Next call will probe."
        case .available:
            return nil
        }
    }

    private func processingLogStatusBadge(_ status: String) -> String {
        switch status.lowercased() {
        case "success": return L("OK")
        case "error": return L("ERR")
        case "empty": return L("NIL")
        case "skipped": return L("SKP")
        default: return status.uppercased()
        }
    }

    private func processingLogStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "success": return .green
        case "error": return .red
        case "empty": return .orange
        case "skipped": return .gray
        default: return .blue
        }
    }

    // MARK: - Headline

    struct DiagnosticHeadline {
        let text: String
        let color: Color
    }

    func diagnosticHeadline() -> DiagnosticHeadline {
        if !config.enabled {
            return DiagnosticHeadline(text: L("Memory disabled globally."), color: .red)
        }
        if case .unavailable = coreModelStatus {
            return DiagnosticHeadline(text: L("Core model unavailable."), color: .red)
        }
        if case .unset = coreModelStatus {
            return DiagnosticHeadline(text: L("Core model not configured."), color: .red)
        }
        if pendingSignals.totalSignals == 0 && totalEpisodes == 0 {
            return DiagnosticHeadline(
                text: L("No buffered turns and no episodes — check per-agent memory."),
                color: .orange
            )
        }
        if pendingSignals.totalSignals > 0 && recentLogs.first?.status != "success" {
            return DiagnosticHeadline(
                text: L("\(pendingSignals.totalSignals) buffered turns waiting on distillation."),
                color: .orange
            )
        }
        return DiagnosticHeadline(text: L("Pipeline healthy."), color: .green)
    }
}
