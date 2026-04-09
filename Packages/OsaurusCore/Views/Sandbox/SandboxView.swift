//
//  SandboxView.swift
//  osaurus
//
//  Dedicated management view for the sandbox container and sandbox plugins.
//  Consolidates container lifecycle (provisioning, status, diagnostics, resources)
//  and sandbox plugin management (library, import, install) into a single tab.
//

import SwiftUI
import UniformTypeIdentifiers

struct SandboxView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var sandboxState = SandboxManager.State.shared
    @ObservedObject private var agentManager = AgentManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: SandboxTab = .container
    @State private var hasAppeared = false

    @State private var config = SandboxConfigurationStore.load()
    @State private var pendingConfig = SandboxConfigurationStore.load()
    @State private var provisionError: String?
    @State private var actionError: String?
    @State private var containerInfo: SandboxManager.ContainerInfo?
    @State private var showResetConfirm = false
    @State private var showRemoveConfirm = false
    @State private var diagResults: [SandboxManager.DiagnosticResult]?
    @State private var isRunningDiag = false
    @State private var refreshTimer: Timer?

    @State private var showProvisionSheet = false

    private var configIsDirty: Bool { pendingConfig != config }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            Group {
                switch selectedTab {
                case .container:
                    containerTabContent
                case .agents:
                    if !sandboxState.availability.isAvailable {
                        unavailableEmptyState
                    } else {
                        SandboxAgentsView(hasAppeared: hasAppeared)
                    }
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                hasAppeared = true
            }
        }
        .onDisappear { stopRefreshTimer() }
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
        ManagerHeaderWithTabs(
            title: L("Sandbox"),
            subtitle: sandboxSubtitle
        ) {
            EmptyView()
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .agents: agentManager.agents.count
                ],
                showSearch: false
            )
        }
    }

    var sandboxSubtitle: String {
        if !sandboxState.availability.isAvailable {
            return "Unavailable"
        }
        switch sandboxState.status {
        case .running: return "Container running"
        case .stopped: return "Container stopped"
        case .starting: return "Container starting..."
        case .notProvisioned: return "Not provisioned"
        case .error(let msg): return "Error: \(msg)"
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
                    statusDashboard
                    if sandboxState.status == .running {
                        SandboxLogConsoleCard()
                        diagnosticsCard
                    }
                    resourceConfigCard
                    dangerZoneCard
                }
                .padding(24)
            }
            .onAppear {
                refreshInfo()
                startRefreshTimer()
            }
            .onDisappear { stopRefreshTimer() }
        }
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
            SettingsEmptyState(
                icon: "shippingbox",
                title: L("Set Up Sandbox"),
                subtitle: L("Run isolated Linux containers for agent plugins and autonomous execution."),
                examples: [
                    .init(
                        icon: "puzzlepiece.extension",
                        title: L("Sandbox Plugins"),
                        description: "Install tools that run inside the VM"
                    ),
                    .init(
                        icon: "terminal",
                        title: L("Autonomous Exec"),
                        description: "Agents run shell commands safely"
                    ),
                    .init(
                        icon: "lock.shield",
                        title: L("Full Isolation"),
                        description: "Separate filesystem per agent"
                    ),
                ],
                primaryAction: .init(
                    title: L("Set Up Sandbox"),
                    icon: "shippingbox",
                    handler: { showProvisionSheet = true }
                ),
                hasAppeared: hasAppeared
            )
        }
    }

    var provisioningProgressView: some View {
        VStack(spacing: 24) {
            Spacer()

            if let progress = sandboxState.provisioningProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                    .tint(theme.accentColor)
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.accentColor)
            }

            VStack(spacing: 8) {
                Text("Setting Up Sandbox", bundle: .module)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                if let phase = sandboxState.provisioningPhase {
                    HStack(spacing: 6) {
                        Text(phase)
                        if let progress = sandboxState.provisioningProgress {
                            Text("\(Int(progress * 100))%", bundle: .module)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.2), value: phase)
                }
            }

            if let error = provisionError {
                VStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text(error)
                            .font(.system(size: 12))
                            .lineLimit(3)
                    }
                    .foregroundColor(theme.warningColor)

                    Button(action: performProvision) {
                        Label { Text("Retry", bundle: .module) } icon: { Image(systemName: "arrow.clockwise") }
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
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                if let info = containerInfo {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 10
                    ) {
                        if let uptime = info.uptime {
                            metricTile(icon: "clock", label: "Uptime", value: formatUptime(uptime))
                        }
                        if let cpu = info.cpuLoad {
                            metricTile(icon: "cpu", label: "CPU Load", value: cpu)
                        }
                        if let mem = info.memoryUsage {
                            metricTile(icon: "memorychip", label: "Memory", value: mem)
                        }
                        if let disk = info.diskUsage {
                            metricTile(icon: "internaldrive", label: "Disk", value: disk)
                        }
                        if let procs = info.processCount {
                            metricTile(icon: "list.number", label: "Processes", value: "\(procs)")
                        }
                        if !info.agentUsers.isEmpty {
                            metricTile(icon: "person.2", label: "Agents", value: "\(info.agentUsers.count)")
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

    private var filteredLogEntries: [SandboxLogBuffer.Entry] {
        guard let filter = logLevelFilter else { return logBuffer.entries }
        return logBuffer.entries.filter { $0.level == filter }
    }

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
                            let filtered = filteredLogEntries
                            if filtered.isEmpty {
                                Text(
                                    "No log entries yet. Command output and container activity will stream here in real time.", bundle: .module
                                )
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity)
                            } else {
                                ForEach(filtered) { entry in
                                    logEntryRow(entry)
                                        .id(entry.id)
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
                    .onChange(of: logBuffer.entries.count) { _, _ in
                        pendingScrollTask?.cancel()
                        pendingScrollTask = Task {
                            try? await Task.sleep(for: .milliseconds(200))
                            guard !Task.isCancelled else { return }
                            if let last = filteredLogEntries.last {
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
                            Text(isRunningDiag ? "Running..." : "Run Diagnostics")
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
                HStack(spacing: 8) {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(result.passed ? theme.successColor : theme.warningColor)
                    Text(result.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .frame(width: 100, alignment: .leading)
                    Text(result.detail)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
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

// MARK: - Resource Config Card

private extension SandboxView {

    var resourceConfigCard: some View {
        sectionCard(title: "Resources", icon: "cpu") {
            VStack(alignment: .leading, spacing: 12) {
                cpuStepper
                memoryStepper

                toggleRow(
                    title: L("Network Access"),
                    description: "Allow outbound network from container",
                    isOn: Binding(
                        get: { pendingConfig.network == "outbound" },
                        set: { pendingConfig.network = $0 ? "outbound" : "none" }
                    )
                )

                toggleRow(
                    title: L("Auto-Start"),
                    description: "Start container when Osaurus launches",
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
        sectionCard(title: "Danger Zone", icon: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Resetting destroys all installed sandbox packages. Agent workspace files on the host persist.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                HStack(spacing: 12) {
                    destructiveButton("Reset Container", icon: "arrow.counterclockwise") {
                        showResetConfirm = true
                    }
                    .alert(Text("Reset Container?", bundle: .module), isPresented: $showResetConfirm) {
                        Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
                        Button(role: .destructive) { performReset() } label: { Text("Reset", bundle: .module) }
                    } message: {
                        Text(
                            "This will destroy the container and re-provision from scratch. Installed packages and sandbox plugin state will be lost.", bundle: .module
                        )
                    }

                    destructiveButton("Remove Container", icon: "trash") {
                        showRemoveConfirm = true
                    }
                    .alert(Text("Remove Container?", bundle: .module), isPresented: $showRemoveConfirm) {
                        Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
                        Button(role: .destructive) { performRemove() } label: { Text("Remove", bundle: .module) }
                    } message: {
                        Text("This will stop and remove the container entirely. You can set it up again later.", bundle: .module)
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
            } catch {
                provisionError = error.localizedDescription
            }
        }
    }

    func performStart() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.startContainer()
                refreshInfo()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func performStop() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.stopContainer()
                containerInfo = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func performReset() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.resetContainer()
                refreshInfo()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func performRemove() {
        actionError = nil
        Task {
            do {
                try await SandboxManager.shared.removeContainer()
                containerInfo = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func applyResourceChanges() {
        SandboxConfigurationStore.save(pendingConfig)
        config = pendingConfig
        Task {
            try? await SandboxManager.shared.resetContainer()
            refreshInfo()
        }
    }

    func saveConfigIfClean() {
        var saving = config
        saving.autoStart = pendingConfig.autoStart
        SandboxConfigurationStore.save(saving)
        config = saving
    }

    func refreshInfo() {
        Task {
            containerInfo = await SandboxManager.shared.info()
        }
    }

    func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                if sandboxState.status == .running {
                    refreshInfo()
                }
            }
        }
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
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
                Text(title)
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
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(description)
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
                Text(title)
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
                Text(title)
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
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                    .font(.system(size: 13, weight: .medium))
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(action: {
                    dismiss()
                    onConfirm()
                }) {
                    Label { Text("Set Up Sandbox", bundle: .module) } icon: { Image(systemName: "shippingbox") }
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

// MARK: - Shared Helpers

private func sandboxAgentColor(for name: String) -> Color {
    let hue = Double(abs(name.hashValue % 360)) / 360.0
    return Color(hue: hue, saturation: 0.6, brightness: 0.8)
}

private struct SandboxAgentAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let color = sandboxAgentColor(for: name)
        Circle()
            .fill(color.opacity(0.2))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundColor(color)
            )
    }
}

// MARK: - Agents Tab

private struct SandboxAgentsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var sandboxState = SandboxManager.State.shared

    let hasAppeared: Bool

    private var theme: ThemeProtocol { themeManager.currentTheme }
    private var sandboxRunning: Bool { sandboxState.status == .running }

    @State private var expandedAgents: Set<UUID> = []
    @State private var agentSecrets: [UUID: [SecretEntry]] = [:]
    @State private var editingEntry: SecretEntry.ID?
    @State private var provisioningAgents: Set<UUID> = []

    struct SecretEntry: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
        var isNew: Bool
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if agentManager.agents.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(agentManager.agents.enumerated()), id: \.element.id) { index, agent in
                        agentCard(agent)
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 12)
                            .animation(
                                .spring(response: 0.45, dampingFraction: 0.8).delay(Double(index) * 0.06),
                                value: hasAppeared
                            )
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            loadAllSecrets()
            expandedAgents = Set(agentManager.agents.map(\.id))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.tertiaryText)
            VStack(spacing: 6) {
                Text("No Agents", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Text("Create an agent to configure sandbox access, plugins, and secrets.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.15), value: hasAppeared)
    }

    // MARK: - Agent Card

    private func agentCard(_ agent: Agent) -> some View {
        let isExpanded = expandedAgents.contains(agent.id)
        let execConfig = agentManager.effectiveAutonomousExec(for: agent.id)
        let secrets = agentSecrets[agent.id] ?? []

        return VStack(alignment: .leading, spacing: 0) {
            agentCardHeader(
                agent,
                isExpanded: isExpanded,
                execEnabled: execConfig?.enabled ?? false,
                secretCount: secrets.filter { !$0.isNew }.count
            )

            if isExpanded {
                Rectangle().fill(theme.cardBorder).frame(height: 1)

                VStack(alignment: .leading, spacing: 16) {
                    executionToggles(agent: agent, execConfig: execConfig)
                    secretsSection(agent: agent, entries: secrets)
                }
                .padding(16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private func agentCardHeader(
        _ agent: Agent,
        isExpanded: Bool,
        execEnabled: Bool,
        secretCount: Int
    ) -> some View {
        Button(action: { toggleAgent(agent.id) }) {
            HStack(spacing: 12) {
                SandboxAgentAvatar(name: agent.name, size: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    HStack(spacing: 8) {
                        pill(execEnabled ? "Autonomous" : "Manual", color: execEnabled ? .green : theme.tertiaryText)
                        if secretCount > 0 { pill("\(secretCount) secret\(secretCount == 1 ? "" : "s")") }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Execution Toggles

    private func executionToggles(agent: Agent, execConfig: AutonomousExecConfig?) -> some View {
        let isProvisioning = provisioningAgents.contains(agent.id)

        return VStack(alignment: .leading, spacing: 0) {
            if !sandboxRunning {
                inlineBanner(
                    icon: "exclamationmark.circle",
                    text: "Start the sandbox container to configure execution settings.",
                    color: theme.warningColor
                )
            } else {
                VStack(spacing: 0) {
                    execToggleRow(
                        title: L("Autonomous Execution"),
                        subtitle: L("Allow agent to run commands in the sandbox"),
                        isLoading: isProvisioning,
                        loadingLabel: execConfig?.enabled == true ? "Disabling\u{2026}" : "Setting up\u{2026}",
                        isOn: Binding(
                            get: { execConfig?.enabled ?? false },
                            set: { enabled in
                                self.updateExecConfig(for: agent.id, current: execConfig) { $0.enabled = enabled }
                            }
                        )
                    )

                    if execConfig?.enabled == true && !isProvisioning {
                        insetDivider

                        execToggleRow(
                            title: L("Plugin Creation"),
                            subtitle: L("Agent can create its own tools as plugins"),
                            isOn: Binding(
                                get: { execConfig?.pluginCreate ?? false },
                                set: { create in
                                    self.updateExecConfig(for: agent.id, current: execConfig) {
                                        $0.pluginCreate = create
                                    }
                                }
                            )
                        )
                    }
                }
                .insetPanel(theme: theme)
            }
        }
    }

    private func execToggleRow(
        title: String,
        subtitle: String,
        isLoading: Bool = false,
        loadingLabel: String = "Updating\u{2026}",
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if isLoading {
                        Text(loadingLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .transition(.opacity)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accentColor)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                Toggle("", isOn: isOn)
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Secrets Section

    private func secretsSection(agent: Agent, entries: [SecretEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Secrets", icon: "key", count: entries.filter { !$0.isNew }.count)
                Spacer()
                addButton { addSecret(for: agent.id) }
            }

            if entries.isEmpty {
                inlineHint("No secrets configured")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { insetDivider }
                        SecretEntryRow(
                            entry: entry,
                            isEditing: editingEntry == entry.id,
                            theme: theme,
                            onCommit: { commitSecret(entryId: entry.id, agentId: agent.id, key: $0, value: $1) },
                            onDelete: { deleteSecretEntry(entryId: entry.id, agentId: agent.id, key: entry.key) },
                            onStartEditing: { editingEntry = entry.id }
                        )
                    }
                }
                .insetPanel(theme: theme)
            }
        }
    }

    // MARK: - Shared Components

    private func pill(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.1)))
    }

    private func sectionLabel(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.5)
            if count > 0 {
                Text("\(count)", bundle: .module)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.tertiaryBackground))
            }
        }
    }

    private func addButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("Add", bundle: .module).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.accentColor.opacity(0.2), lineWidth: 1))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func inlineHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(theme.tertiaryText)
            .padding(.vertical, 4)
    }

    private func inlineBanner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color.opacity(0.8))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.15), lineWidth: 1))
        )
    }

    private var insetDivider: some View {
        Rectangle().fill(theme.cardBorder.opacity(0.4)).frame(height: 1).padding(.horizontal, 12)
    }

    // MARK: - Actions

    private func toggleAgent(_ agentId: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedAgents.contains(agentId) {
                expandedAgents.remove(agentId)
            } else {
                expandedAgents.insert(agentId)
            }
        }
    }

    private func updateExecConfig(
        for agentId: UUID,
        current: AutonomousExecConfig?,
        _ mutate: (inout AutonomousExecConfig) -> Void
    ) {
        var config = current ?? .default
        mutate(&config)

        let enabledChanged = config.enabled != (current?.enabled ?? false)
        if enabledChanged {
            provisioningAgents.insert(agentId)
        }

        Task { @MainActor in
            do {
                try await agentManager.updateAutonomousExec(config, for: agentId)
            } catch {
                ToastManager.shared.error("Failed to update sandbox access", message: error.localizedDescription)
            }
            provisioningAgents.remove(agentId)
        }
    }

    private func loadAllSecrets() {
        for agent in agentManager.agents {
            let stored = AgentSecretsKeychain.getAllSecrets(agentId: agent.id)
            agentSecrets[agent.id] = stored.map { SecretEntry(key: $0.key, value: $0.value, isNew: false) }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        }
    }

    private func addSecret(for agentId: UUID) {
        if !expandedAgents.contains(agentId) {
            _ = withAnimation(.easeInOut(duration: 0.2)) { expandedAgents.insert(agentId) }
        }
        let entry = SecretEntry(key: "", value: "", isNew: true)
        agentSecrets[agentId, default: []].append(entry)
        editingEntry = entry.id
    }

    private func commitSecret(entryId: SecretEntry.ID, agentId: UUID, key: String, value: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else {
            withAnimation(.easeInOut(duration: 0.15)) { agentSecrets[agentId]?.removeAll { $0.id == entryId } }
            return
        }

        if let existing = agentSecrets[agentId]?.first(where: { $0.id == entryId }),
            !existing.isNew, existing.key != trimmedKey
        {
            AgentSecretsKeychain.deleteSecret(id: existing.key, agentId: agentId)
        }

        AgentSecretsKeychain.saveSecret(trimmedValue, id: trimmedKey, agentId: agentId)

        if let idx = agentSecrets[agentId]?.firstIndex(where: { $0.id == entryId }) {
            agentSecrets[agentId]?[idx] = SecretEntry(key: trimmedKey, value: trimmedValue, isNew: false)
        }
        editingEntry = nil
    }

    private func deleteSecretEntry(entryId: SecretEntry.ID, agentId: UUID, key: String) {
        if !key.isEmpty { AgentSecretsKeychain.deleteSecret(id: key, agentId: agentId) }
        withAnimation(.easeInOut(duration: 0.2)) { agentSecrets[agentId]?.removeAll { $0.id == entryId } }
    }
}

// MARK: - Inset Panel Modifier

private extension View {
    func insetPanel(theme: ThemeProtocol) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.secondaryBackground.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder.opacity(0.6), lineWidth: 1))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Secret Entry Row

private struct SecretEntryRow: View {
    let entry: SandboxAgentsView.SecretEntry
    let isEditing: Bool
    let theme: ThemeProtocol
    let onCommit: (_ key: String, _ value: String) -> Void
    let onDelete: () -> Void
    let onStartEditing: () -> Void

    @State private var editKey: String = ""
    @State private var editValue: String = ""
    @State private var showValue = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if isEditing || entry.isNew {
                editableContent
            } else {
                readOnlyContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHovering ? theme.primaryBackground.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onAppear {
            editKey = entry.key; editValue = entry.value
        }
    }

    private var editableContent: some View {
        HStack(spacing: 10) {
            monoField("SECRET_NAME", text: $editKey, weight: .medium).frame(maxWidth: 200)
            secretValueField(text: $editValue, secure: !showValue)
            visibilityButton
            iconButton("checkmark", color: .white, bg: theme.accentColor) { onCommit(editKey, editValue) }
            iconButton("trash", color: theme.errorColor, bg: theme.errorColor.opacity(0.1), action: onDelete)
                .help(Text("Delete secret", bundle: .module))
        }
    }

    private var readOnlyContent: some View {
        HStack(spacing: 10) {
            Text(entry.key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: 200, alignment: .leading)

            Group {
                if showValue {
                    Text(entry.value).foregroundColor(theme.secondaryText)
                } else {
                    Text(String(repeating: "\u{2022}", count: min(entry.value.count, 24))).foregroundColor(
                        theme.tertiaryText
                    )
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)

            Spacer()
            visibilityButton

            if isHovering {
                iconButton("pencil", color: theme.secondaryText, bg: theme.tertiaryBackground, action: onStartEditing)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                iconButton("trash", color: theme.errorColor, bg: theme.errorColor.opacity(0.1), action: onDelete)
                    .help(Text("Delete secret", bundle: .module))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    // MARK: - Field Helpers

    private func monoField(_ placeholder: String, text: Binding<String>, weight: Font.Weight = .regular) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: weight, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.inputBackground)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.accentColor.opacity(0.4), lineWidth: 1))
            )
    }

    @ViewBuilder
    private func secretValueField(text: Binding<String>, secure: Bool) -> some View {
        if secure {
            SecureField("value", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.inputBackground)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.accentColor.opacity(0.4), lineWidth: 1))
                )
        } else {
            monoField("value", text: text)
        }
    }

    private var visibilityButton: some View {
        iconButton(
            showValue ? "eye.slash.fill" : "eye.fill",
            color: theme.tertiaryText,
            bg: theme.tertiaryBackground
        ) { showValue.toggle() }
        .help(showValue ? "Hide value" : "Show value")
    }

    private func iconButton(_ icon: String, color: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(bg))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview

#Preview {
    SandboxView()
}
