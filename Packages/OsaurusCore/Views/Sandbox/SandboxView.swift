//
//  SandboxView.swift
//  osaurus
//
//  Dedicated management view for the sandbox container and sandbox plugins.
//  Consolidates container lifecycle (provisioning, status, diagnostics, resources)
//  and sandbox plugin management (library, import, install) into a single tab.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SandboxView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var sandboxState = SandboxManager.State.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false

    @State private var config: SandboxConfiguration
    @State private var pendingConfig: SandboxConfiguration
    @State private var provisionError: String?
    @State private var actionError: String?
    @State private var copiedErrorDetails = false
    @State private var showResetConfirm = false
    @State private var showRemoveConfirm = false
    @State private var diagResults: [SandboxManager.DiagnosticResult]?
    @State private var isRunningDiag = false
    @State private var provisioningReport: SandboxProvisioningReport?
    @State private var isRunningProvisioningPreflight = false
    @State private var copiedProvisioningReport = false
    @State private var refreshTask: Task<Void, Never>?

    /// No completed setup yet: starts show the full-page journey. Read
    /// from disk on appear and on each status change, like the banner flag.
    @State private var isFirstRunSetup = false
    /// Set briefly to open (and scroll to) Troubleshooting.
    @State private var troubleshootingRequested = false

    /// Gated mount for the heaviest subviews (currently
    /// `SandboxLogConsoleCard`). Stays `false` until just after first
    /// paint so the user sees the rest of the running-container view
    /// immediately, then flips true to bring the log card in.
    @State private var hasRenderedHeavyCards = false
    @State private var heavyCardMountTask: Task<Void, Never>?

    /// Cached value of `SandboxBridgeMigrationFlag.needsRestart`. The flag
    /// reads `sandbox.json` from disk, so we don't want to hit it from the
    /// body on every state publish — refresh it once on appear and again
    /// whenever the container status changes (which is the only event that
    /// can flip its value during a single visit to this tab).
    @State private var needsBridgeMigrationRestart = false

    init() {
        // Load the persisted sandbox configuration exactly once per view
        // construction and seed both the committed and pending copies from
        // it. The previous double `SandboxConfigurationStore.load()` did
        // two disk reads on the main thread every time the user clicked
        // the Sandbox sidebar tab (since `SidebarNavigation` rebuilds the
        // content via `.id(selection)`).
        let loaded = SandboxConfigurationStore.load()
        _config = State(initialValue: loaded)
        _pendingConfig = State(initialValue: loaded)
        _isFirstRunSetup = State(initialValue: !loaded.setupComplete)
    }

    private var configIsDirty: Bool { pendingConfig != config }

    /// Seatbelt (`sandbox-exec`) backend on pre-Tahoe hosts: no VM, so the
    /// container-specific chrome (CPU/memory resources, boot timings,
    /// agents kept warm, "container" wording) is hidden or reworded.
    private var isSeatbelt: Bool { SandboxBackend.current == .seatbelt }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            headerBar
            containerTabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .onAppear {
            // Previously this tab faded itself in over ~300 ms on every
            // mount (250 ms duration + 50 ms delay). Because
            // `SidebarNavigation` uses `.id(selection)`, the view is
            // destroyed and recreated on every tab switch — so the user
            // paid that latency every time they returned to Sandbox.
            // The header + content now appear immediately on first frame.
            hasAppeared = true
            needsBridgeMigrationRestart = SandboxBridgeMigrationFlag.needsRestart
            isFirstRunSetup = !SandboxConfigurationStore.load().setupComplete
            runProvisioningPreflight()
            // Status starts as `.notProvisioned` until something asks the
            // manager; with no sandbox agent at launch nothing has, so a
            // set-up sandbox would show the first-run page.
            refreshInfo()
        }
        .onChange(of: sandboxState.status) { _, _ in
            needsBridgeMigrationRestart = SandboxBridgeMigrationFlag.needsRestart
            isFirstRunSetup = !SandboxConfigurationStore.load().setupComplete
            runProvisioningPreflight()
        }
        .onDisappear { stopRefreshLoop() }
    }
}

// MARK: - Header

private extension SandboxView {

    static let sandboxDocsURL = URL(string: "https://docs.osaurus.ai/sandbox")!

    var headerBar: some View {
        SettingsPageHeader(
            title: "Sandbox",
            subtitle: sandboxSubtitle
        )
    }

    var sandboxSubtitle: String {
        if !sandboxState.availability.isAvailable {
            return L("Unavailable")
        }
        switch sandboxState.status {
        case .running: return L("Sandbox running")
        case .stopped: return L("Sandbox stopped")
        case .starting: return L("Sandbox starting...")
        case .notProvisioned: return L("Not provisioned")
        case .error: return L("Sandbox stopped with an error")
        }
    }
}

// MARK: - Container Tab

private extension SandboxView {

    @ViewBuilder
    var containerTabContent: some View {
        if !sandboxState.availability.isAvailable {
            unavailableEmptyState
        } else if showsFullPageJourney {
            provisioningProgressView
        } else if sandboxState.status == .notProvisioned {
            provisionEmptyState
        } else {
            scrollingPage {
                // Only a running guest has the old shim; the next start
                // installs the new one anyway.
                if needsBridgeMigrationRestart, sandboxState.status.isRunning {
                    bridgeMigrationBanner
                }
                overviewSection
                // Surfaced only while the post-start verifyPlugins
                // step is active. Self-hides when verify finishes,
                // so the layout reclaims the space cleanly.
                PostStartTasksCard()
                settingsSection
                if !isSeatbelt {
                    SandboxEnvironmentsSection()
                }
                troubleshootingSection
                dangerZoneCard
            }
            .onAppear {
                refreshInfo()
                startRefreshLoop()
                scheduleHeavyCardMount()
            }
            .onDisappear {
                stopRefreshLoop()
                heavyCardMountTask?.cancel()
                heavyCardMountTask = nil
            }
        }
    }

    /// First-time setup (and its failure) takes the whole page; a warm boot
    /// shows inline in Overview.
    var showsFullPageJourney: Bool {
        if provisionError != nil { return true }
        return isFirstRunSetup && (sandboxState.isProvisioning || sandboxState.status == .starting)
    }

    var isStarting: Bool {
        sandboxState.isProvisioning || sandboxState.status == .starting
    }

    func scrollingPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let page = content()
        return ScrollViewReader { proxy in
            ScrollView {
                SettingsPageContent {
                    page
                }
            }
            .settingsLandingScroll(proxy)
            .onChange(of: troubleshootingRequested) { _, requested in
                guard requested else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(theme.motion.standard) {
                        proxy.scrollTo(Self.troubleshootingAnchor, anchor: .top)
                    }
                }
            }
        }
    }

    /// Non-blocking notice shown until the user restarts the sandbox so the
    /// post-#950 bridge security fix takes effect inside the running guest.
    @ViewBuilder
    var bridgeMigrationBanner: some View {
        SettingsCallout(
            icon: "lock.shield.fill",
            title: "Security update is ready",
            message: "Restart the sandbox to apply per-agent bridge tokens. Plugin calls will return 401 until the running container picks up the new shim.",
            tone: .info
        ) {
            SettingsButton(.primary, "Restart sandbox", size: .compact, action: performRestart)
        }
    }

    var unavailableEmptyState: some View {
        SettingsEmptyState(
            icon: "shippingbox",
            title: "Sandbox Unavailable",
            subtitle: sandboxState.availability.reason ?? L("Sandboxed execution is unavailable on this device."),
            examples: [
                .init(
                    icon: "lock.shield",
                    title: L("Isolated Execution"),
                    description: L("Run code in an isolated sandbox")
                ),
                .init(
                    icon: "puzzlepiece.extension",
                    title: L("Plugin Runtime"),
                    description: "Install and run sandbox plugins"
                ),
                .init(
                    icon: "bolt.fill",
                    title: L("Autonomous Agents"),
                    description: "Agents execute commands safely"
                ),
            ],
            primaryAction: .init(
                title: L("Learn More"),
                icon: "questionmark.circle",
                handler: { NSWorkspace.shared.open(Self.sandboxDocsURL) }
            ),
            hasAppeared: hasAppeared
        )
    }

    /// Setting up ahead of time is optional: the sandbox sets itself up
    /// the first time an agent runs a command.
    var provisionEmptyState: some View {
        scrollingPage {
            SettingsEmptyState(
                icon: "shippingbox",
                title: "Set Up Sandbox",
                subtitle: isSeatbelt
                    ? "Run agent commands confined to a sandbox workspace on this Mac. It sets itself up the first time an agent runs a command; set it up now to have it ready. (macOS 26 or later adds full VM isolation.)"
                    : "Run each agent in its own Linux container. It downloads in the background and starts the first time an agent runs a command; set it up now to have it running.",
                examples: [
                    .init(
                        icon: "puzzlepiece.extension",
                        title: L("Sandbox Plugins"),
                        description: isSeatbelt
                            ? L("Install tools that run in the sandbox")
                            : L("Install tools that run inside the VM")
                    ),
                    .init(
                        icon: "terminal",
                        title: L("Autonomous Exec"),
                        description: L("Agents run shell commands safely")
                    ),
                    .init(
                        icon: "lock.shield",
                        title: isSeatbelt ? L("Confined Writes") : L("Full Isolation"),
                        description: isSeatbelt
                            ? L("Writes limited to the sandbox workspace")
                            : L("Separate filesystem per agent")
                    ),
                ],
                primaryAction: .init(
                    title: L("Set Up Sandbox"),
                    icon: "shippingbox",
                    handler: performProvision
                ),
                hasAppeared: hasAppeared
            )
            .frame(minHeight: 430)

            troubleshootingSection
        }
    }

    var provisioningProgressView: some View {
        let cancel: (() -> Void)? = isStarting ? { performCancel() } : nil
        return ProvisioningJourneyView(
            provisionError: provisionError,
            onRetry: performProvision,
            onCancel: cancel,
            onCopyDetails: { copyErrorDetails(provisionError ?? "") },
            onOpenTroubleshooting: openTroubleshooting
        )
    }
}

// MARK: - Provisioning Preflight

private extension SandboxView {

    var preflightBlock: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            troubleshootingHeading("Provisioning Preflight")
            HStack(alignment: .center, spacing: theme.space.s10) {
                if let report = provisioningReport {
                    readinessPill(report.overallReadiness)
                    Text(preflightSummary(report))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                } else {
                    readinessPill(.unproven)
                    Text(
                        "Run preflight to inspect host paths, permissions, and repair suggestions.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(2)
                }

                Spacer(minLength: 12)

                SettingsButton(
                    .secondary,
                    isRunningProvisioningPreflight ? "Checking" : "Run",
                    icon: "arrow.clockwise",
                    isLoading: isRunningProvisioningPreflight,
                    size: .compact,
                    action: runProvisioningPreflight
                )
                .disabled(isRunningProvisioningPreflight)

                SettingsButton(
                    .secondary,
                    copiedProvisioningReport ? "Copied" : "Copy JSON",
                    icon: "doc.on.doc",
                    size: .compact,
                    help: "Copy support JSON report",
                    action: copyProvisioningReportJSON
                )
                .disabled(provisioningReport == nil)
            }

            if let report = provisioningReport {
                preflightPathList(report)
                preflightFindingsList(report)
            }
        }
        .settingsLandingAnchor("sandbox.preflight")
    }

    func troubleshootingHeading(_ title: String) -> some View {
        Text(LocalizedStringKey(title), bundle: .module)
            .font(SettingsFont.compactLabel)
            .foregroundColor(theme.text.secondary)
    }

    func readinessPill(_ readiness: SandboxProvisioningReadiness) -> some View {
        StatusChip(readiness.label, tint: preflightColor(readiness), showsDot: true)
    }

    func preflightPathList(_ report: SandboxProvisioningReport) -> some View {
        let ids: [SandboxProvisioningLocationID] = [
            .root,
            .containerWorkspace,
            .temporaryDirectory,
            .cacheDirectory,
        ]
        let rows = ids.compactMap { id in report.locations.first { $0.id == id } }

        return VStack(spacing: theme.space.s0) {
            ForEach(rows) { location in
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    Image(systemName: preflightLocationIcon(location.status))
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundColor(preflightLocationColor(location.status))
                        .frame(width: 14)
                    Text(location.title)
                        .font(SettingsFont.chip)
                        .foregroundColor(theme.text.tertiary)
                        .frame(width: 130, alignment: .leading)
                    Text(location.path)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(location.status.rawValue)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(preflightLocationColor(location.status))
                }
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s6)
            }
        }
        .settingsChrome(.control)
    }

    func preflightFindingsList(_ report: SandboxProvisioningReport) -> some View {
        let actionable = report.findings
            .filter { $0.severity == .blocked || $0.severity == .warning || $0.status == .unproven }
        let visible = Array(actionable.prefix(4))
        let hiddenCount = max(0, actionable.count - visible.count)

        return VStack(alignment: .leading, spacing: theme.space.s8) {
            if visible.isEmpty {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "checkmark.circle.fill")
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundColor(theme.status.success.foreground)
                    Text("No blocking host storage issues found.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                }
            } else {
                ForEach(visible) { finding in
                    preflightFindingRow(finding)
                }
                if hiddenCount > 0 {
                    Text(
                        hiddenCount == 1
                            ? L("+1 more finding in copied report")
                            : L("+\(hiddenCount) more findings in copied report")
                    )
                    .textStyle(.micro)
                    .foregroundColor(theme.text.tertiary)
                }
            }
        }
    }

    func preflightFindingRow(_ finding: SandboxProvisioningFinding) -> some View {
        SettingsFindingRow(
            severity: findingSeverity(finding),
            title: finding.title,
            code: finding.code.rawValue,
            detail: finding.detail,
            fix: finding.repairSuggestion
        )
    }

    func findingSeverity(_ finding: SandboxProvisioningFinding) -> SettingsFindingRow.Severity {
        switch finding.severity {
        case .ok: .ok
        case .info: .info
        case .warning: .warning
        case .blocked: .blocked
        }
    }

    func preflightSummary(_ report: SandboxProvisioningReport) -> String {
        switch report.overallReadiness {
        case .ready:
            return L("Host paths and permissions are ready for sandbox tooling.")
        case .needsSetup:
            let count = report.warningFindings.count
            return count == 1
                ? L("1 setup finding needs attention before tools are fully ready.")
                : L("\(count) setup findings need attention before tools are fully ready.")
        case .blocked:
            let count = report.blockingFindings.count
            return count == 1
                ? L("1 blocking finding must be fixed before provisioning.")
                : L("\(count) blocking findings must be fixed before provisioning.")
        case .unproven:
            return L("One or more checks could not be proven; copy the report for support or CI proof.")
        }
    }

    func preflightColor(_ readiness: SandboxProvisioningReadiness) -> Color {
        switch readiness {
        case .ready: theme.status.success.foreground
        case .needsSetup: theme.status.warning.foreground
        case .blocked: theme.status.error.foreground
        case .unproven: theme.status.info.foreground
        }
    }

    func preflightLocationColor(_ status: SandboxProvisioningLocationStatus) -> Color {
        switch status {
        case .ready: theme.status.success.foreground
        case .missing, .unproven: theme.status.warning.foreground
        case .wrongType, .notWritable, .notReadable, .emptyFile: theme.status.error.foreground
        }
    }

    func preflightLocationIcon(_ status: SandboxProvisioningLocationStatus) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .missing, .unproven: "exclamationmark.triangle.fill"
        case .wrongType, .notWritable, .notReadable, .emptyFile: "xmark.octagon.fill"
        }
    }

}

// MARK: - Status Dashboard

private extension SandboxView {

    var overviewSection: some View {
        SettingsSection(title: "Overview", anchorId: "sandbox.status") {
            VStack(alignment: .leading, spacing: theme.space.s14) {
                SettingsStatusHero(
                    valueLabel: "Runs on",
                    value: backendSummary,
                    copyable: false,
                    status: { StatusChip(statusTitle, tone: statusTone, showsDot: true) },
                    actions: { statusActions }
                )

                if isStarting {
                    HStack(spacing: theme.space.s8) {
                        SettingsSpinner(size: .mini)
                        Text(verbatim: startingDetail)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(1)
                    }
                }

                if case .error(let message) = sandboxState.status {
                    Text(message)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // A background start (launch, agent switch) that lost the VM
                // lease leaves the status at Stopped; say why. The lease
                // watcher starts the sandbox here once the owner lets go.
                if !sandboxState.status.isRunning, !isStarting,
                    let owner = sandboxState.activeAgentUnavailability?.leaseOwner
                {
                    Text(SandboxLeaseConflictResolver.explanation(for: owner))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.status.warning.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let info = sandboxState.containerInfo {
                    SettingsStatStrip(stats: metricStats(info), style: .tiles(columns: 3))
                }

                // Boot-phase timings are a VM concept; the Seatbelt
                // backend "starts" instantly and records no samples.
                if !isSeatbelt, let boot = SandboxStartupMetricsStore.load().last {
                    Text(lastBootSummary(boot))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = actionError {
                    Text(error)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.status.warning.foreground)
                        .textSelection(.enabled)
                }
            }
        }
    }

    var backendSummary: String {
        if isSeatbelt { return L("This Mac, confined by a sandbox profile") }
        return L("Linux VM · \(config.cpus) CPUs · \(config.memoryGB) GB memory")
    }

    var startingDetail: String {
        if let activity = sandboxState.currentActivity, !activity.isEmpty { return activity }
        if let phase = sandboxState.provisioningPhase, !phase.isEmpty { return phase }
        return L("Starting the sandbox…")
    }

    /// One-line digest of the most recent boot's phase timings (local
    /// metrics file; full samples in startup-metrics.json).
    private func lastBootSummary(_ boot: SandboxBootSample) -> String {
        func fmt(_ v: Double?) -> String {
            guard let v else { return "—" }
            return String(format: "%.1fs", v)
        }
        return
            "Last boot: \(boot.kind.rawValue) · assets \(fmt(boot.assetResolution)) · "
            + "create \(fmt(boot.containerCreate)) · vm \(fmt(boot.vmBoot)) · "
            + "total \(fmt(boot.totalToRunning))"
    }

    func metricStats(_ info: SandboxManager.ContainerInfo) -> [SettingsStat] {
        var stats: [SettingsStat] = []
        if let uptime = info.uptime {
            stats.append(SettingsStat(label: "Uptime", value: formatUptime(uptime), icon: "clock"))
        }
        if let cpu = info.cpuLoad {
            stats.append(SettingsStat(label: "CPU Load", value: cpu, icon: "cpu"))
        }
        if let mem = info.memoryUsage {
            stats.append(SettingsStat(label: "Memory", value: mem, icon: "memorychip"))
        }
        if let disk = info.diskUsage {
            stats.append(SettingsStat(label: "Workspace", value: disk, icon: "internaldrive"))
        }
        if let procs = info.processCount {
            stats.append(SettingsStat(label: "Processes", value: "\(procs)", icon: "list.number"))
        }
        if !info.agentUsers.isEmpty {
            stats.append(SettingsStat(label: "Agents", value: "\(info.agentUsers.count)", icon: "person.2"))
        }
        return stats
    }

    func formatUptime(_ raw: String) -> String {
        guard let seconds = Int(raw.replacingOccurrences(of: " seconds", with: "")) else {
            return raw
        }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(seconds % 60)s"
    }

    var statusTone: StatusChip.Tone {
        switch sandboxState.status {
        case .running: .success
        case .starting: .warning
        case .error: .error
        case .stopped, .notProvisioned: .neutral
        }
    }

    var statusTitle: String {
        if case .error = sandboxState.status { return L("Couldn't start") }
        return sandboxState.status.label
    }

    @ViewBuilder
    var statusActions: some View {
        switch sandboxState.status {
        case .running:
            SettingsButton(.secondary, "Restart", icon: "arrow.clockwise", size: .compact, action: performRestart)
            SettingsButton(.destructive, "Stop", size: .compact, action: performStop)
        case .stopped:
            SettingsButton(.primary, "Start", size: .compact, action: performStart)
        case .starting:
            SettingsButton(.secondary, "Cancel", size: .compact, action: performCancel)
        case .error(let message):
            SettingsButton(.primary, "Try Again", size: .compact, action: performStart)
            SettingsButton(
                .secondary,
                copiedErrorDetails ? "Copied" : "Copy Details",
                icon: "doc.on.doc",
                size: .compact
            ) { copyErrorDetails(message) }
            SettingsButton(.tertiary, "Open Troubleshooting", size: .compact, action: openTroubleshooting)
        case .notProvisioned:
            EmptyView()
        }
    }
}

// MARK: - Log Console (isolated observation)

private struct SandboxLogConsoleCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var logBuffer = SandboxLogBuffer.shared

    @State private var logLevelFilter: SandboxLogBuffer.Entry.Level?
    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var showFullHistory = false

    /// Snapshot of the buffer entries the view actually renders, recomputed
    /// off the body path via `.onReceive(logBuffer.objectWillChange)` so
    /// the (potentially up to 2000-entry) filter/slice does not run inside
    /// every `body` evaluation triggered by the buffer's ~10 Hz publish.
    @State private var visibleEntries: [SandboxLogBuffer.Entry] = []
    @State private var visibleRefreshTask: Task<Void, Never>?

    /// Default soft cap on rendered rows. The buffer holds up to
    /// `SandboxLogBuffer.maxEntries` (2000); displaying all of them on
    /// every flush is the dominant first-paint cost of this card. Users
    /// who actually need older lines can click "Show full history".
    private static let defaultVisibleLimit = 100

    /// Hard cap used when "Show full history" is toggled on. Matches the
    /// ring-buffer ceiling so we still bound the worst case.
    private static let maxVisibleLimit = 2000

    /// Minimum interval between snapshot refreshes. The buffer itself
    /// already coalesces `objectWillChange` to ~10 Hz; this throttles UI
    /// rebuilds to ~5 Hz so layout/diff cost is halved during bursts.
    private static let refreshThrottle: Duration = .milliseconds(200)

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("Logs", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.secondary)

            VStack(alignment: .leading, spacing: theme.space.s10) {
                HStack(spacing: theme.space.s8) {
                    FilterChip(L("All"), isSelected: logLevelFilter == nil) { logLevelFilter = nil }

                    ForEach(SandboxLogBuffer.Entry.Level.allCases, id: \.self) { level in
                        FilterChip(
                            LCached(level.rawValue.capitalized),
                            isSelected: logLevelFilter == level
                        ) { logLevelFilter = level }
                    }

                    Spacer()

                    SettingsButton(
                        .tertiary,
                        showFullHistory ? "Tail" : "Full",
                        size: .compact,
                        help: showFullHistory
                            ? L("Showing full ring buffer. Click to tail the most recent \(Self.defaultVisibleLimit) lines.")
                            : L("Tailing the most recent \(Self.defaultVisibleLimit) lines. Click to show the full ring buffer.")
                    ) { showFullHistory.toggle() }

                    SettingsIconButton("trash", help: "Clear Logs") { logBuffer.clear() }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: theme.space.s0) {
                            if visibleEntries.isEmpty {
                                Text(
                                    "No log entries yet. Command output and sandbox activity will stream here in real time.",
                                    bundle: .module
                                )
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                                .padding(.vertical, theme.space.s16)
                                .frame(maxWidth: .infinity)
                            } else {
                                ForEach(visibleEntries) { entry in
                                    logEntryRow(entry)
                                }
                            }
                        }
                    }
                    .frame(height: 320)
                    .settingsChrome(.subtle)
                    .onChange(of: visibleEntries.last?.id) { _, _ in
                        pendingScrollTask?.cancel()
                        pendingScrollTask = Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            if let last = visibleEntries.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refreshVisibleEntries() }
        .onDisappear {
            visibleRefreshTask?.cancel()
            visibleRefreshTask = nil
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
        }
        .onReceive(logBuffer.objectWillChange) { _ in
            scheduleVisibleRefresh()
        }
        .onChange(of: logLevelFilter) { _, _ in refreshVisibleEntries() }
        .onChange(of: showFullHistory) { _, _ in refreshVisibleEntries() }
    }

    private func scheduleVisibleRefresh() {
        guard visibleRefreshTask == nil else { return }
        visibleRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: Self.refreshThrottle)
            if !Task.isCancelled {
                refreshVisibleEntries()
            }
            visibleRefreshTask = nil
        }
    }

    private func refreshVisibleEntries() {
        let limit = showFullHistory ? Self.maxVisibleLimit : Self.defaultVisibleLimit
        let entries = logBuffer.entries

        let snapshot: [SandboxLogBuffer.Entry]
        if let filter = logLevelFilter {
            let filtered = entries.filter { $0.level == filter }
            snapshot = filtered.count <= limit ? filtered : Array(filtered.suffix(limit))
        } else {
            snapshot = entries.count <= limit ? entries : Array(entries.suffix(limit))
        }
        visibleEntries = snapshot
    }

    private func logEntryRow(_ entry: SandboxLogBuffer.Entry) -> some View {
        HStack(alignment: .top, spacing: theme.space.s6) {
            Text(Self.logTimestampFormatter.string(from: entry.timestamp))
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 65, alignment: .leading)

            Text(verbatim: entry.level.rawValue)
                .font(SettingsFont.monoSmall)
                .foregroundColor(logLevelColor(entry.level))
                .frame(width: 50, alignment: .leading)

            Text(entry.source)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.link)
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(entry.message)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s4)
    }

    private func logLevelColor(_ level: SandboxLogBuffer.Entry.Level) -> Color {
        switch level {
        case .debug: theme.text.tertiary
        case .info: theme.action.primary.default.background
        case .stdout: theme.text.primary
        case .warn: theme.status.warning.foreground
        case .error: theme.status.error.foreground
        }
    }

    private static let logTimestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()
}

// MARK: - Troubleshooting

private extension SandboxView {

    static let troubleshootingAnchor = "sandbox.troubleshooting"

    var troubleshootingSection: some View {
        SettingsAdvancedDisclosure(
            title: "Troubleshooting",
            anchorIds: [Self.troubleshootingAnchor, "sandbox.preflight", "sandbox.diagnostics", "sandbox.logs"]
        ) {
            VStack(alignment: .leading, spacing: theme.space.s20) {
                lastFailureBlock
                preflightBlock
                if sandboxState.status == .running {
                    diagnosticsBlock
                }
                if hasRenderedHeavyCards || sandboxState.status == .notProvisioned {
                    SandboxLogConsoleCard()
                        .settingsLandingAnchor("sandbox.logs")
                }
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.bottom, theme.space.s16)
        }
        .transformEnvironment(\.settingsLandingPending) { pending in
            if troubleshootingRequested { pending = Self.troubleshootingAnchor }
        }
        .settingsLandingAnchor(Self.troubleshootingAnchor)
    }

    /// Most recent startup/provisioning failure from the local ring buffer
    /// (`startup-failures.json`), in the same closed tokens the
    /// consent-gated telemetry event carries, so a pasted line matches
    /// what shows up in aggregate.
    @ViewBuilder
    var lastFailureBlock: some View {
        if let failure = SandboxStartupMetricsStore.loadFailures().last {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                troubleshootingHeading("Last Failure")
                Text(SandboxStartupMetricsStore.failureSummary(failure))
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(L("From ~/.osaurus/container/startup-failures.json"))
            }
        }
    }

    var diagnosticsBlock: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            troubleshootingHeading("Diagnostics")
            HStack(spacing: theme.space.s12) {
                SettingsButton(
                    .primary,
                    isRunningDiag ? "Running…" : "Run Diagnostics",
                    icon: "stethoscope",
                    isLoading: isRunningDiag,
                    size: .compact,
                    action: performDiagnostics
                )
                .disabled(isRunningDiag)

                Text(
                    isSeatbelt
                        ? "Tests exec, workspace writes, write confinement, and network policy"
                        : "Tests exec, networking, agent users, apk, and the vsock bridge",
                    bundle: .module
                )
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(2)
            }

            if let results = diagResults {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        SettingsFindingRow(
                            severity: result.passed ? .ok : .warning,
                            title: result.name,
                            detail: result.detail
                        )
                    }
                }
            }
        }
        .settingsLandingAnchor("sandbox.diagnostics")
    }

    /// Expands Troubleshooting and scrolls to it. From the journey it also
    /// leaves the failed setup screen.
    func openTroubleshooting() {
        provisionError = nil
        troubleshootingRequested = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            troubleshootingRequested = false
        }
    }
}

// MARK: - Settings

private extension SandboxView {

    var settingsSection: some View {
        SettingsSection(title: "Settings") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                // CPU/memory budgets and per-agent CoW rootfs clones are
                // VM constructs — the Seatbelt backend runs host processes
                // with no resource caps to configure.
                if !isSeatbelt {
                    SettingsStepperRow(
                        label: "CPUs",
                        help: "Cores the sandbox VM can use.",
                        value: $pendingConfig.cpus,
                        range: 1 ... 8,
                        anchorId: "sandbox.cpus"
                    )
                    if let warning = SandboxHostResourceWarning.cpu(cpus: pendingConfig.cpus, hostCores: ProcessInfo.processInfo.activeProcessorCount) {
                        hostWarning(warning)
                    }
                    SettingsStepperRow(
                        label: "Memory",
                        help: "Memory the sandbox VM can use, shared by every agent's container.",
                        value: $pendingConfig.memoryGB,
                        range: 1 ... 8,
                        unit: "GB",
                        anchorId: "sandbox.memory"
                    )
                    if let warning = SandboxHostResourceWarning.memory(vmGB: pendingConfig.memoryGB, hostBytes: ProcessInfo.processInfo.physicalMemory) {
                        hostWarning(warning)
                    }
                    SettingsStepperRow(
                        label: "Agents Kept Warm",
                        help: "Agents and workflows that each keep their own container running in the sandbox.",
                        value: $pendingConfig.maxAgentEnvironments,
                        range: 1 ... 8,
                        anchorId: "sandbox.agentsKeptWarm"
                    )
                    SettingsStepperRow(
                        label: "Environments Kept on Disk",
                        help: "Agent and workflow environments, with their installed packages, kept between runs. Never fewer than Agents Kept Warm.",
                        value: $pendingConfig.maxRetainedEnvironments,
                        range: SandboxConfiguration.retainedEnvironmentsRange,
                        anchorId: "sandbox.environmentsKeptOnDisk"
                    )
                    SettingsStepperRow(
                        label: "Stop When Idle",
                        help: "Stop the sandbox after this many minutes with nothing running, to free its memory. A connected sandboxed MCP server counts as running. 0 keeps it running.",
                        value: $pendingConfig.idleShutdownMinutes,
                        range: 0 ... 240,
                        unit: "min",
                        anchorId: "sandbox.stopWhenIdle"
                    )
                }

                networkRow

                SettingsToggle(
                    title: "Auto-Start",
                    description: "Start the sandbox when Osaurus launches. When off, it starts the first time an agent runs a command.",
                    anchorId: "sandbox.autoStart",
                    isOn: $pendingConfig.autoStart
                )
                .onChange(of: pendingConfig.autoStart) { _, _ in
                    saveConfigIfClean()
                }

                SettingsRow(
                    title: "Workspace",
                    description: isSeatbelt
                        ? "Sandboxed commands see ~/.osaurus/container/workspace/ as /workspace, the only folder they can write to."
                        : "Every agent's home folder and the shared folder, on this Mac at ~/.osaurus/container/workspace/. Agents see it as /workspace.",
                    anchorId: "sandbox.workspace"
                ) {
                    SettingsButton(.secondary, "Open in Finder", icon: "folder", size: .compact) {
                        OsaurusPaths.revealInFinder(OsaurusPaths.containerWorkspace())
                    }
                }

                if configIsDirty {
                    HStack {
                        Spacer()
                        SettingsButton(
                            .primary,
                            sandboxState.status.isRunning ? "Restart to Apply" : "Save",
                            icon: sandboxState.status.isRunning ? "arrow.clockwise" : nil,
                            size: .compact,
                            action: applyResourceChanges
                        )
                    }
                }
            }
        }
    }

    func hostWarning(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(SettingsFont.rowDescription)
        .foregroundColor(theme.status.warning.foreground)
        .fixedSize(horizontal: false, vertical: true)
    }


    /// Read-only: network is each agent's own setting (Agent → Sandbox).
    var networkRow: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            SettingsValueRow(title: "Network", value: networkValue, anchorId: "sandbox.network")
            Text(networkCaption)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var networkValue: String {
        if isSeatbelt { return L("Per agent") }
        switch sandboxState.podNetwork {
        case .nat?: return L("Open")
        case .filtered?: return L("Filtered per agent")
        case .some(.none): return L("Off")
        case nil: return L("Per agent")
        }
    }

    var networkCaption: String {
        if isSeatbelt {
            return L("Each agent's Sandbox Network setting applies to its own commands. Domain allowlists need the VM sandbox, so an agent with one has no network here.")
        }
        if sandboxState.podNetwork == .filtered {
            return L("Agents in the sandbox have different network settings, so each one's web traffic goes through a filter that applies its own setting. Other connections, such as SSH, are blocked.")
        }
        return L("Set per agent in the agent's Sandbox settings. When agents with different settings share the sandbox, it filters each one's web traffic separately and blocks other connections.")
    }
}

// MARK: - Danger Zone Card

private extension SandboxView {

    var resetDescription: String {
        isSeatbelt
            ? L("Clears sandbox plugin state and sets the sandbox up again. Kept: every agent's files in the workspace. Workflows with dependencies will ask to install them again.")
            : L("Deletes the Linux system and every agent's environment, including apk packages, then downloads the runtime and sets the sandbox up again. Kept: every agent's home folder (its files, SOUL.md, and pip and npm packages) and the shared folder. Workflows with dependencies will ask to install them again.")
    }

    var removeDescription: String {
        isSeatbelt
            ? L("Stops the sandbox and clears its state. Kept: every agent's files in the workspace. Agents can't run commands until you set it up again here.")
            : L("Stops the sandbox and deletes the Linux system, every agent's environment, and the downloaded runtime to free disk space. Kept: every agent's home folder and the shared folder. Agents can't run commands until you set it up again here.")
    }

    var dangerZoneCard: some View {
        SettingsDestructiveZone {
            SettingsDestructiveRow(
                title: "Reset Sandbox",
                description: resetDescription,
                actionTitle: "Reset…",
                anchorId: "sandbox.reset"
            ) {
                showResetConfirm = true
            }
            .alert(Text("Reset Sandbox?", bundle: .module), isPresented: $showResetConfirm) {
                Button(role: .cancel) {
                } label: {
                    Text("Cancel", bundle: .module)
                }
                Button(role: .destructive) {
                    performReset()
                } label: {
                    Text("Reset", bundle: .module)
                }
            } message: {
                Text(verbatim: resetDescription)
            }

            SettingsDestructiveRow(
                title: "Remove Sandbox",
                description: removeDescription,
                actionTitle: "Remove…",
                anchorId: "sandbox.remove"
            ) {
                showRemoveConfirm = true
            }
            .alert(Text("Remove Sandbox?", bundle: .module), isPresented: $showRemoveConfirm) {
                Button(role: .cancel) {
                } label: {
                    Text("Cancel", bundle: .module)
                }
                Button(role: .destructive) {
                    performRemove()
                } label: {
                    Text("Remove", bundle: .module)
                }
            } message: {
                Text(verbatim: removeDescription)
            }
        }
    }
}

// MARK: - Actions

private extension SandboxView {

    func performDiagnostics() {
        isRunningDiag = true
        diagResults = nil
        Task {
            let results = await SandboxManager.shared.runDiagnostics()
            await MainActor.run {
                diagResults = results
                isRunningDiag = false
            }
        }
    }

    func performProvision() {
        provisionError = nil
        SandboxConfigurationStore.save(pendingConfig)
        config = pendingConfig
        Task {
            do {
                try await SandboxManager.shared.provision()
                refreshInfo()
                runProvisioningPreflight()
            } catch is CancellationError {
                runProvisioningPreflight()
            } catch {
                if case SandboxError.ownershipConflict = error {
                    handleActionError(error, retry: performProvision)
                    return
                }
                provisionError = error.localizedDescription
                runProvisioningPreflight()
            }
        }
    }

    func performCancel() {
        Task { await SandboxManager.shared.cancelStart() }
    }

    func performStart() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.startContainer()
                refreshInfo()
                runProvisioningPreflight()
            } catch {
                handleActionError(error, retry: performStart)
            }
        }
    }

    /// A lease conflict opens the fix-it dialog; any other failure shows
    /// under Status.
    func handleActionError(_ error: Error, retry: @escaping () -> Void) {
        runProvisioningPreflight()
        if error is CancellationError { return }
        if case SandboxError.ownershipConflict = error {
            SandboxLeaseConflictResolver.present(SandboxLeaseConflictResolver.currentOwner()) { retry() }
            return
        }
        actionError = error.localizedDescription
    }

    func performStop() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.stopContainer()
                // `stopContainer` itself clears `State.shared.containerInfo`
                // so the dashboard tiles go blank on stop without needing
                // a manual assignment here.
                runProvisioningPreflight()
            } catch {
                actionError = error.localizedDescription
                runProvisioningPreflight()
            }
        }
    }

    func performRestart() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.restartContainer()
                refreshInfo()
                runProvisioningPreflight()
            } catch {
                handleActionError(error, retry: performRestart)
            }
        }
    }

    /// Error, app version, last boot and preflight in one paste for a bug report.
    func copyErrorDetails(_ message: String) {
        var lines = [
            "Sandbox error: \(message)",
            "Osaurus \(SandboxBridgeMigrationFlag.currentAppVersion), backend \(SandboxBackend.current)",
        ]
        if !isSeatbelt, let boot = SandboxStartupMetricsStore.load().last {
            lines.append(lastBootSummary(boot))
        }
        if let report = provisioningReport {
            lines.append(report.plainTextReport)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copiedErrorDetails = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedErrorDetails = false
        }
    }

    func performReset() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.resetContainer()
                refreshInfo()
                runProvisioningPreflight()
            } catch {
                handleActionError(error, retry: performReset)
            }
        }
    }

    func performRemove() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.removeContainer()
                // `removeContainer` → `stopContainer` clears the published
                // metrics, so no manual reset needed here.
                runProvisioningPreflight()
            } catch {
                handleActionError(error, retry: performRemove)
            }
        }
    }

    func applyResourceChanges() {
        SandboxConfigurationStore.save(pendingConfig)
        config = pendingConfig
        actionError = nil
        guard sandboxState.status.isRunning else { return }
        Task {
            do {
                try await SandboxManager.shared.restartContainer()
                refreshInfo()
                runProvisioningPreflight()
            } catch {
                actionError = error.localizedDescription
                runProvisioningPreflight()
            }
        }
    }

    func saveConfigIfClean() {
        var saving = config
        saving.autoStart = pendingConfig.autoStart
        SandboxConfigurationStore.save(saving)
        config = saving
        runProvisioningPreflight()
    }

    func runProvisioningPreflight() {
        guard !isRunningProvisioningPreflight else { return }
        isRunningProvisioningPreflight = true
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                SandboxProvisioningDiagnostics.makeReport()
            }.value
            await MainActor.run {
                provisioningReport = report
                isRunningProvisioningPreflight = false
                copiedProvisioningReport = false
            }
        }
    }

    func copyProvisioningReportJSON() {
        guard let report = provisioningReport else { return }
        let reportText = (try? report.jsonString()) ?? report.plainTextReport
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)

        withAnimation(theme.motion.quick) {
            copiedProvisioningReport = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                withAnimation(theme.motion.quick) {
                    copiedProvisioningReport = false
                }
            }
        }
    }

    func refreshInfo() {
        // `info()` writes the result into `SandboxManager.State.shared`,
        // which `sandboxState.containerInfo` reads. We don't need to
        // capture the return value here.
        Task { _ = await SandboxManager.shared.info() }
    }

    /// Structured replacement for the prior `Timer.scheduledTimer`.
    /// `Task.sleep` is cancellable, the loop awaits each `info()` call so
    /// ticks can never overlap, and the task is torn down with the view.
    func startRefreshLoop() {
        stopRefreshLoop()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                if sandboxState.status == .running {
                    _ = await SandboxManager.shared.info()
                }
            }
        }
    }

    func stopRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Defer mount of `SandboxLogConsoleCard` so the first paint of the
    /// running-container scroll view doesn't have to lay out + diff the
    /// log buffer's contents synchronously. The card itself already uses
    /// a `LazyVStack` + throttled snapshot refresh, so 50 ms is plenty
    /// for AppKit to commit the first frame on a fresh tab visit and
    /// significantly cuts the perceived "blank then logs appear" lag.
    func scheduleHeavyCardMount() {
        if hasRenderedHeavyCards { return }
        heavyCardMountTask?.cancel()
        heavyCardMountTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            if !Task.isCancelled {
                hasRenderedHeavyCards = true
            }
            heavyCardMountTask = nil
        }
    }
}

/// Steppers warn when the sandbox could crowd out the rest of the Mac.
/// Warnings only; the chosen value is kept.
enum SandboxHostResourceWarning {
    /// More than half the Mac's memory.
    static func memory(vmGB: Int, hostBytes: UInt64) -> String? {
        let hostGB = Int((Double(hostBytes) / 1_073_741_824).rounded())
        guard hostGB > 0, vmGB * 2 > hostGB else { return nil }
        return L(
            "This Mac has \(hostGB) GB of memory. While the sandbox is busy, \(vmGB) GB can leave too little for apps and local models."
        )
    }

    static func cpu(cpus: Int, hostCores: Int) -> String? {
        guard hostCores > 0, cpus >= hostCores else { return nil }
        return L("This Mac has \(hostCores) cores; the sandbox can keep all of them busy.")
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        SandboxView()
    }
#endif
