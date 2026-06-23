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
    @State private var showResetConfirm = false
    @State private var showRemoveConfirm = false
    @State private var diagResults: [SandboxManager.DiagnosticResult]?
    @State private var isRunningDiag = false
    @State private var provisioningReport: SandboxProvisioningReport?
    @State private var isRunningProvisioningPreflight = false
    @State private var copiedProvisioningReport = false
    @State private var refreshTask: Task<Void, Never>?

    @State private var showProvisionSheet = false

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
    }

    private var configIsDirty: Bool { pendingConfig != config }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            containerTabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
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
            runProvisioningPreflight()
        }
        .onChange(of: sandboxState.status) { _, _ in
            needsBridgeMigrationRestart = SandboxBridgeMigrationFlag.needsRestart
            runProvisioningPreflight()
        }
        .onDisappear { stopRefreshLoop() }
        .sheet(isPresented: $showProvisionSheet) {
            SandboxProvisionSheet(
                pendingConfig: $pendingConfig,
                onConfirm: performProvision
            )
            .environment(\.theme, theme)
        }
    }
}

// MARK: - Header

private extension SandboxView {

    var headerBar: some View {
        ManagerHeader(
            title: L("Sandbox"),
            subtitle: sandboxSubtitle
        )
    }

    var sandboxSubtitle: String {
        if !sandboxState.availability.isAvailable {
            return L("Unavailable")
        }
        switch sandboxState.status {
        case .running: return L("Container running")
        case .stopped: return L("Container stopped")
        case .starting: return L("Container starting...")
        case .notProvisioned: return L("Not provisioned")
        case .error(let msg): return L("Error: \(msg)")
        }
    }
}

// MARK: - Container Tab

private extension SandboxView {

    @ViewBuilder
    var containerTabContent: some View {
        if !sandboxState.availability.isAvailable {
            unavailableEmptyState
        } else if sandboxState.status == .notProvisioned {
            provisionEmptyState
        } else if sandboxState.isProvisioning || sandboxState.status == .starting {
            provisioningProgressView
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if needsBridgeMigrationRestart {
                        bridgeMigrationBanner
                    }
                    provisioningPreflightCard
                    statusDashboard
                    // Surfaced only while the post-start verifyPlugins
                    // step is active. Self-hides when verify finishes,
                    // so the layout reclaims the space cleanly.
                    PostStartTasksCard()
                    if sandboxState.status == .running {
                        if hasRenderedHeavyCards {
                            SandboxLogConsoleCard()
                        }
                        diagnosticsCard
                    }
                    workspaceCard
                    resourceConfigCard
                    dangerZoneCard
                }
                .padding(24)
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

    /// Non-blocking notice shown until the user restarts the sandbox so the
    /// post-#950 bridge security fix takes effect inside the running guest.
    @ViewBuilder
    var bridgeMigrationBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Security update is ready", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Restart the sandbox to apply per-agent bridge tokens. Plugin calls will return 401 until the running container picks up the new shim.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: performReset) {
                Text("Restart sandbox", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(theme.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    var unavailableEmptyState: some View {
        SettingsEmptyState(
            icon: "shippingbox",
            title: L("Sandbox Unavailable"),
            subtitle: sandboxState.availability.reason ?? "Sandbox requires macOS 26 or later.",
            examples: [
                .init(
                    icon: "lock.shield",
                    title: L("Isolated Execution"),
                    description: "Run code in a secure Linux container"
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
                handler: {}
            ),
            hasAppeared: hasAppeared
        )
    }

    @ViewBuilder
    var provisionEmptyState: some View {
        if sandboxState.isProvisioning {
            provisioningProgressView
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsEmptyState(
                        icon: "shippingbox",
                        title: L("Set Up Sandbox"),
                        subtitle: L("Run isolated Linux containers for agent plugins and autonomous execution."),
                        examples: [
                            .init(
                                icon: "puzzlepiece.extension",
                                title: L("Sandbox Plugins"),
                                description: L("Install tools that run inside the VM")
                            ),
                            .init(
                                icon: "terminal",
                                title: L("Autonomous Exec"),
                                description: L("Agents run shell commands safely")
                            ),
                            .init(
                                icon: "lock.shield",
                                title: L("Full Isolation"),
                                description: L("Separate filesystem per agent")
                            ),
                        ],
                        primaryAction: .init(
                            title: L("Set Up Sandbox"),
                            icon: "shippingbox",
                            handler: { showProvisionSheet = true }
                        ),
                        hasAppeared: hasAppeared
                    )
                    .frame(minHeight: 430)

                    provisioningPreflightCard
                }
                .padding(24)
            }
        }
    }

    var provisioningProgressView: some View {
        ProvisioningJourneyView(
            provisionError: provisionError,
            onRetry: performProvision
        )
    }
}

// MARK: - Provisioning Preflight

private extension SandboxView {

    var provisioningPreflightCard: some View {
        sectionCard(title: "Provisioning Preflight", icon: "checklist") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    if let report = provisioningReport {
                        readinessPill(report.overallReadiness)
                        Text(preflightSummary(report))
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    } else {
                        readinessPill(.unproven)
                        Text(
                            "Run preflight to inspect host paths, permissions, and repair suggestions.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    Button(action: runProvisioningPreflight) {
                        HStack(spacing: 6) {
                            if isRunningProvisioningPreflight {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(isRunningProvisioningPreflight ? "Checking" : "Run", bundle: .module)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunningProvisioningPreflight)

                    Button(action: copyProvisioningReportJSON) {
                        Label {
                            Text(copiedProvisioningReport ? "Copied" : "Copy JSON", bundle: .module)
                        } icon: {
                            Image(systemName: "doc.on.doc")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(provisioningReport == nil)
                    .localizedHelp("Copy support JSON report")
                }

                if let report = provisioningReport {
                    preflightPathList(report)
                    preflightFindingsList(report)
                }
            }
        }
    }

    func readinessPill(_ readiness: SandboxProvisioningReadiness) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(preflightColor(readiness))
                .frame(width: 7, height: 7)
            Text(readiness.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(preflightColor(readiness))
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            Capsule()
                .fill(preflightColor(readiness).opacity(0.10))
                .overlay(Capsule().stroke(preflightColor(readiness).opacity(0.30), lineWidth: 1))
        )
    }

    func preflightPathList(_ report: SandboxProvisioningReport) -> some View {
        let ids: [SandboxProvisioningLocationID] = [
            .root,
            .containerWorkspace,
            .temporaryDirectory,
            .cacheDirectory,
        ]
        let rows = ids.compactMap { id in report.locations.first { $0.id == id } }

        return VStack(spacing: 0) {
            ForEach(rows) { location in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: preflightLocationIcon(location.status))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(preflightLocationColor(location.status))
                        .frame(width: 14)
                    Text(location.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 130, alignment: .leading)
                    Text(location.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(location.status.rawValue)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(preflightLocationColor(location.status))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    func preflightFindingsList(_ report: SandboxProvisioningReport) -> some View {
        let actionable = report.findings
            .filter { $0.severity == .blocked || $0.severity == .warning || $0.status == .unproven }
        let visible = Array(actionable.prefix(4))
        let hiddenCount = max(0, actionable.count - visible.count)

        return VStack(alignment: .leading, spacing: 8) {
            if visible.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.successColor)
                    Text("No blocking host storage issues found.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            } else {
                ForEach(visible) { finding in
                    preflightFindingRow(finding)
                }
                if hiddenCount > 0 {
                    Text("+\(hiddenCount) more findings in copied report", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    func preflightFindingRow(_ finding: SandboxProvisioningFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: preflightFindingIcon(finding))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(preflightFindingColor(finding))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(finding.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(finding.code.rawValue)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Text(finding.detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.repairSuggestion)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(preflightFindingColor(finding))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(preflightFindingColor(finding).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(preflightFindingColor(finding).opacity(0.18), lineWidth: 1)
                )
        )
    }

    func preflightSummary(_ report: SandboxProvisioningReport) -> String {
        switch report.overallReadiness {
        case .ready:
            return L("Host paths and permissions are ready for sandbox tooling.")
        case .needsSetup:
            return L("\(report.warningFindings.count) setup finding(s) need attention before tools are fully ready.")
        case .blocked:
            return L("\(report.blockingFindings.count) blocking finding(s) must be fixed before provisioning.")
        case .unproven:
            return L("One or more checks could not be proven; copy the report for support or CI proof.")
        }
    }

    func preflightColor(_ readiness: SandboxProvisioningReadiness) -> Color {
        switch readiness {
        case .ready: theme.successColor
        case .needsSetup: theme.warningColor
        case .blocked: theme.errorColor
        case .unproven: theme.infoColor
        }
    }

    func preflightLocationColor(_ status: SandboxProvisioningLocationStatus) -> Color {
        switch status {
        case .ready: theme.successColor
        case .missing, .unproven: theme.warningColor
        case .wrongType, .notWritable, .notReadable, .emptyFile: theme.errorColor
        }
    }

    func preflightLocationIcon(_ status: SandboxProvisioningLocationStatus) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .missing, .unproven: "exclamationmark.triangle.fill"
        case .wrongType, .notWritable, .notReadable, .emptyFile: "xmark.octagon.fill"
        }
    }

    func preflightFindingColor(_ finding: SandboxProvisioningFinding) -> Color {
        switch finding.severity {
        case .ok: theme.successColor
        case .info: theme.infoColor
        case .warning: theme.warningColor
        case .blocked: theme.errorColor
        }
    }

    func preflightFindingIcon(_ finding: SandboxProvisioningFinding) -> String {
        switch finding.severity {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }
}

// MARK: - Status Dashboard

private extension SandboxView {

    var statusDashboard: some View {
        sectionCard(title: "Status", icon: "circle.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(sandboxState.status.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    statusActionButton
                }

                if let info = sandboxState.containerInfo {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 10
                    ) {
                        if let uptime = info.uptime {
                            metricTile(icon: "clock", label: L("Uptime"), value: formatUptime(uptime))
                        }
                        if let cpu = info.cpuLoad {
                            metricTile(icon: "cpu", label: L("CPU Load"), value: cpu)
                        }
                        if let mem = info.memoryUsage {
                            metricTile(icon: "memorychip", label: L("Memory"), value: mem)
                        }
                        if let disk = info.diskUsage {
                            metricTile(icon: "internaldrive", label: L("Disk"), value: disk)
                        }
                        if let procs = info.processCount {
                            metricTile(icon: "list.number", label: L("Processes"), value: "\(procs)")
                        }
                        if !info.agentUsers.isEmpty {
                            metricTile(icon: "person.2", label: L("Agents"), value: "\(info.agentUsers.count)")
                        }
                    }
                }

                if let error = actionError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(theme.warningColor)
                }
            }
        }
    }

    func metricTile(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .textCase(.uppercase)
                    .tracking(0.3)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
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

    var statusColor: Color {
        switch sandboxState.status {
        case .running: .green
        case .stopped: .yellow
        case .notProvisioned: .gray
        case .starting: .orange
        case .error: .red
        }
    }

    @ViewBuilder
    var statusActionButton: some View {
        switch sandboxState.status {
        case .running:
            destructiveButton("Stop", action: performStop)
        case .stopped:
            accentButton("Start", action: performStart)
        case .starting:
            ProgressView()
                .controlSize(.small)
                .tint(theme.accentColor)
        default:
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("Logs", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button(action: { logLevelFilter = nil }) {
                        Text("ALL", bundle: .module)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(logLevelFilter == nil ? .white : theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(logLevelFilter == nil ? theme.accentColor : theme.inputBackground)
                            )
                    }
                    .buttonStyle(.plain)

                    ForEach(SandboxLogBuffer.Entry.Level.allCases, id: \.self) { level in
                        Button(action: { logLevelFilter = level }) {
                            Text(level.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(logLevelFilter == level ? .white : theme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(logLevelFilter == level ? theme.accentColor : theme.inputBackground)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button(action: { showFullHistory.toggle() }) {
                        Text(showFullHistory ? "Tail" : "Full", bundle: .module)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.inputBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(
                        showFullHistory
                            ? "Showing full ring buffer. Click to tail the most recent \(Self.defaultVisibleLimit) lines."
                            : "Tailing the most recent \(Self.defaultVisibleLimit) lines. Click to show the full ring buffer."
                    )

                    Button(action: { logBuffer.clear() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if visibleEntries.isEmpty {
                                Text(
                                    "No log entries yet. Command output and container activity will stream here in real time.",
                                    bundle: .module
                                )
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity)
                            } else {
                                ForEach(visibleEntries) { entry in
                                    logEntryRow(entry)
                                }
                            }
                        }
                    }
                    .frame(height: 320)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.codeBlockBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
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
        HStack(alignment: .top, spacing: 6) {
            Text(Self.logTimestampFormatter.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 65, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(logLevelColor(entry.level))
                .frame(width: 50, alignment: .leading)

            Text(entry.source)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.accentColor.opacity(0.8))
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func logLevelColor(_ level: SandboxLogBuffer.Entry.Level) -> Color {
        switch level {
        case .debug: theme.tertiaryText
        case .info: theme.accentColor
        case .stdout: theme.primaryText
        case .warn: theme.warningColor
        case .error: theme.errorColor
        }
    }

    private static let logTimestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()
}

// MARK: - Diagnostics Card

private extension SandboxView {

    var diagnosticsCard: some View {
        sectionCard(title: "Diagnostics", icon: "stethoscope") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: performDiagnostics) {
                        HStack(spacing: 6) {
                            if isRunningDiag {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "stethoscope")
                                    .font(.system(size: 12))
                            }
                            Text(isRunningDiag ? L("Running...") : L("Run Diagnostics"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isRunningDiag)

                    Text("Tests exec, NAT networking, agent users, apk, and vsock bridge", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }

                if let results = diagResults {
                    diagnosticResultsList(results)
                }
            }
        }
    }

    func diagnosticResultsList(_ results: [SandboxManager.DiagnosticResult]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                // Top-align so the status icon and check name stay anchored to
                // the first line when a failed row's detail wraps to several.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(result.passed ? theme.successColor : theme.warningColor)
                    Text(result.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .frame(width: 100, alignment: .leading)
                    // Passing rows stay on a single truncated line; failures
                    // show the full, selectable detail (with a hover tooltip)
                    // so the actionable hint is never clipped.
                    Text(result.detail)
                        .font(.system(size: 11))
                        .foregroundColor(result.passed ? theme.secondaryText : theme.primaryText)
                        .lineLimit(result.passed ? 1 : nil)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: !result.passed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .help(result.detail)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Workspace Card

private extension SandboxView {

    /// Top-level shortcut into the container's `/workspace` directory,
    /// which is a host bind mount at `~/.osaurus/container/workspace/`.
    /// Lets users browse and edit sandbox files in Finder without
    /// running anything inside the guest.
    var workspaceCard: some View {
        sectionCard(title: "Workspace", icon: "folder") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "The container's /workspace directory is bind-mounted from ~/.osaurus/container/workspace/. Open it in Finder to browse or edit files directly on the host.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

                HStack {
                    Spacer()
                    accentButton("Open in Finder", icon: "folder") {
                        OsaurusPaths.revealInFinder(OsaurusPaths.containerWorkspace())
                    }
                }
            }
        }
    }
}

// MARK: - Resource Config Card

private extension SandboxView {

    var resourceConfigCard: some View {
        sectionCard(title: "Resources", icon: "cpu") {
            VStack(alignment: .leading, spacing: 12) {
                cpuStepper
                memoryStepper

                toggleRow(
                    title: L("Network Access"),
                    description: L("Allow outbound network from container"),
                    isOn: Binding(
                        get: { pendingConfig.network == "outbound" },
                        set: { pendingConfig.network = $0 ? "outbound" : "none" }
                    )
                )

                toggleRow(
                    title: L("Auto-Start"),
                    description: L("Start container when Osaurus launches"),
                    isOn: $pendingConfig.autoStart
                )
                .onChange(of: pendingConfig.autoStart) { _, _ in
                    saveConfigIfClean()
                }

                if configIsDirty {
                    HStack {
                        Spacer()
                        accentButton("Restart to Apply", icon: "arrow.clockwise", action: applyResourceChanges)
                    }
                }
            }
        }
    }
}

// MARK: - Danger Zone Card

private extension SandboxView {

    var dangerZoneCard: some View {
        sectionCard(title: "DANGER ZONE", icon: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Resetting destroys all installed sandbox packages. Agent workspace files on the host persist.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

                HStack(spacing: 12) {
                    destructiveButton("Reset Container", icon: "arrow.counterclockwise") {
                        showResetConfirm = true
                    }
                    .alert(Text("Reset Container?", bundle: .module), isPresented: $showResetConfirm) {
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
                        Text(
                            "This will destroy the container and re-provision from scratch. Installed packages and sandbox plugin state will be lost.",
                            bundle: .module
                        )
                    }

                    destructiveButton("Remove Container", icon: "trash") {
                        showRemoveConfirm = true
                    }
                    .alert(Text("Remove Container?", bundle: .module), isPresented: $showRemoveConfirm) {
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
                        Text(
                            "This will stop and remove the container entirely. You can set it up again later.",
                            bundle: .module
                        )
                    }
                }
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
            } catch {
                provisionError = error.localizedDescription
                runProvisioningPreflight()
            }
        }
    }

    func performStart() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.startContainer()
                refreshInfo()
                runProvisioningPreflight()
            } catch {
                actionError = error.localizedDescription
                runProvisioningPreflight()
            }
        }
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

    func performReset() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.resetContainer()
                refreshInfo()
                runProvisioningPreflight()
            } catch {
                actionError = error.localizedDescription
                runProvisioningPreflight()
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
                actionError = error.localizedDescription
                runProvisioningPreflight()
            }
        }
    }

    func applyResourceChanges() {
        SandboxConfigurationStore.save(pendingConfig)
        config = pendingConfig
        Task {
            try? await SandboxManager.shared.resetContainer()
            refreshInfo()
            runProvisioningPreflight()
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

        withAnimation(.easeInOut(duration: 0.2)) {
            copiedProvisioningReport = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) {
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

// MARK: - Shared Components

private extension SandboxView {

    func sectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    func toggleRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(description), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
        }
    }

    var cpuStepper: some View {
        HStack {
            Text("CPUs", bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Stepper(
                "\(pendingConfig.cpus)",
                value: $pendingConfig.cpus,
                in: 1 ... 8
            )
            .font(.system(size: 12))
        }
    }

    var memoryStepper: some View {
        HStack {
            Text("Memory", bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Stepper(
                "\(pendingConfig.memoryGB) GB",
                value: $pendingConfig.memoryGB,
                in: 1 ... 8
            )
            .font(.system(size: 12))
        }
    }

    func accentButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
        }
        .buttonStyle(PlainButtonStyle())
    }

    func destructiveButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(theme.errorColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.errorColor.opacity(0.1))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Provisioning Sheet

private struct SandboxProvisionSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @Binding var pendingConfig: SandboxConfiguration
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Set Up Sandbox", bundle: .module)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().foregroundColor(theme.cardBorder)

            VStack(alignment: .leading, spacing: 20) {
                Text("Configure resources for the Linux container. These can be changed later.", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)

                VStack(alignment: .leading, spacing: 14) {
                    Text("RESOURCES", bundle: .module)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .tracking(0.5)

                    HStack {
                        Text("CPUs", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Stepper(
                            "\(pendingConfig.cpus)",
                            value: $pendingConfig.cpus,
                            in: 1 ... 8
                        )
                        .font(.system(size: 12))
                    }

                    HStack {
                        Text("Memory", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Stepper(
                            "\(pendingConfig.memoryGB) GB",
                            value: $pendingConfig.memoryGB,
                            in: 1 ... 8
                        )
                        .font(.system(size: 12))
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )
            }
            .padding(20)

            Spacer()

            Divider().foregroundColor(theme.cardBorder)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .font(.system(size: 13, weight: .medium))
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(action: {
                    dismiss()
                    onConfirm()
                }) {
                    Label {
                        Text("Set Up Sandbox", bundle: .module)
                    } icon: {
                        Image(systemName: "shippingbox")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(20)
        }
        .frame(width: 480, height: 360)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        SandboxView()
    }
#endif
