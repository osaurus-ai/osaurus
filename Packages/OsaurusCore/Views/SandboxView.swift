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
    @ObservedObject private var pluginLibrary = SandboxPluginLibrary.shared

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
                case .plugins:
                    if !sandboxState.availability.isAvailable {
                        unavailableEmptyState
                    } else {
                        SandboxPluginGridView(hasAppeared: hasAppeared)
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
            title: "Sandbox",
            subtitle: sandboxSubtitle
        ) {
            EmptyView()
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .plugins: pluginLibrary.plugins.count
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
            title: "Sandbox Unavailable",
            subtitle: sandboxState.availability.reason ?? "Sandbox requires macOS 26 or later.",
            examples: [
                .init(
                    icon: "lock.shield",
                    title: "Isolated Execution",
                    description: "Run code in a secure Linux container"
                ),
                .init(
                    icon: "puzzlepiece.extension",
                    title: "Plugin Runtime",
                    description: "Install and run sandbox plugins"
                ),
                .init(
                    icon: "bolt.fill",
                    title: "Autonomous Agents",
                    description: "Agents execute commands safely"
                ),
            ],
            primaryAction: .init(
                title: "Learn More",
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
                title: "Set Up Sandbox",
                subtitle: "Run isolated Linux containers for agent plugins and autonomous execution.",
                examples: [
                    .init(
                        icon: "puzzlepiece.extension",
                        title: "Sandbox Plugins",
                        description: "Install tools that run inside the VM"
                    ),
                    .init(
                        icon: "terminal",
                        title: "Autonomous Exec",
                        description: "Agents run shell commands safely"
                    ),
                    .init(
                        icon: "lock.shield",
                        title: "Full Isolation",
                        description: "Separate filesystem per agent"
                    ),
                ],
                primaryAction: .init(
                    title: "Set Up Sandbox",
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

            ProgressView()
                .controlSize(.large)
                .tint(theme.accentColor)

            VStack(spacing: 8) {
                Text("Setting Up Sandbox")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                if let phase = sandboxState.provisioningPhase {
                    Text(phase)
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
                        Label("Retry", systemImage: "arrow.clockwise")
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
                Text("Logs")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button(action: { logLevelFilter = nil }) {
                        Text("ALL")
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
                                    "No log entries yet. Command output and container activity will stream here in real time."
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

                    Text("Tests exec, NAT networking, agent users, apk, and vsock bridge")
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
                    title: "Network Access",
                    description: "Allow outbound network from container",
                    isOn: Binding(
                        get: { pendingConfig.network == "outbound" },
                        set: { pendingConfig.network = $0 ? "outbound" : "none" }
                    )
                )

                toggleRow(
                    title: "Auto-Start",
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
                Text("Resetting destroys all installed sandbox packages. Agent workspace files on the host persist.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                HStack(spacing: 12) {
                    destructiveButton("Reset Container", icon: "arrow.counterclockwise") {
                        showResetConfirm = true
                    }
                    .alert("Reset Container?", isPresented: $showResetConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) { performReset() }
                    } message: {
                        Text(
                            "This will destroy the container and re-provision from scratch. Installed packages and sandbox plugin state will be lost."
                        )
                    }

                    destructiveButton("Remove Container", icon: "trash") {
                        showRemoveConfirm = true
                    }
                    .alert("Remove Container?", isPresented: $showRemoveConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Remove", role: .destructive) { performRemove() }
                    } message: {
                        Text("This will stop and remove the container entirely. You can set it up again later.")
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
            Text("CPUs")
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
            Text("Memory")
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
                Text("Set Up Sandbox")
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
                Text("Configure resources for the Linux container. These can be changed later.")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)

                VStack(alignment: .leading, spacing: 14) {
                    Text("RESOURCES")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .tracking(0.5)

                    HStack {
                        Text("CPUs")
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
                        Text("Memory")
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
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Button(action: {
                    dismiss()
                    onConfirm()
                }) {
                    Label("Set Up Sandbox", systemImage: "shippingbox")
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
            .padding(20)
        }
        .frame(width: 480, height: 360)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Plugin Grid (isolated observation)

private struct SandboxPluginGridView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pluginLibrary = SandboxPluginLibrary.shared
    @ObservedObject private var sandboxPluginManager = SandboxPluginManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    let hasAppeared: Bool

    @State private var showCreatePlugin = false
    @State private var editingPlugin: SandboxPlugin?
    @State private var installingPlugin: SandboxPlugin?
    @State private var managingPlugin: SandboxPlugin?
    @State private var pluginToDelete: SandboxPlugin?
    @State private var showDeleteConfirm = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Plugin Library")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()

                    Button(action: importPluginFile) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11))
                            Text("Import")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(PlainButtonStyle())

                    createPluginButton
                }

                if pluginLibrary.plugins.isEmpty {
                    pluginEmptyState
                } else {
                    let installsMap = buildAgentInstallsMap()
                    let outdatedIds = buildOutdatedPluginIds()

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 300), spacing: 20),
                            GridItem(.flexible(minimum: 300), spacing: 20),
                        ],
                        spacing: 20
                    ) {
                        ForEach(Array(pluginLibrary.plugins.enumerated()), id: \.element.id) { index, plugin in
                            SandboxPluginCard(
                                plugin: plugin,
                                agentInstalls: installsMap[plugin.id] ?? [],
                                hasOutdatedInstalls: outdatedIds.contains(plugin.id),
                                animationDelay: min(Double(index) * 0.05, 0.3),
                                hasAppeared: hasAppeared,
                                onEdit: { editingPlugin = plugin },
                                onInstall: { installingPlugin = plugin },
                                onManage: { managingPlugin = plugin },
                                onDuplicate: { duplicatePlugin(plugin) },
                                onExport: { exportPlugin(plugin) },
                                onDelete: {
                                    pluginToDelete = plugin
                                    showDeleteConfirm = true
                                }
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            sandboxPluginManager.purgeStaleAgents(validAgentIds: validAgentIds)
        }
        .sheet(isPresented: $showCreatePlugin) {
            SandboxPluginEditorView(
                plugin: .blank(),
                isNew: true,
                onSave: { plugin in pluginLibrary.save(plugin) },
                onDismiss: {}
            )
        }
        .sheet(item: $editingPlugin) { plugin in
            SandboxPluginEditorView(
                plugin: plugin,
                isNew: false,
                onSave: { updated in
                    pluginLibrary.update(oldId: plugin.id, plugin: updated)
                    editingPlugin = nil
                },
                onDismiss: { editingPlugin = nil }
            )
        }
        .sheet(item: $installingPlugin) { plugin in
            SandboxInstallSheet(
                plugin: plugin,
                agents: agentManager.agents,
                pluginManager: sandboxPluginManager,
                onInstall: installPluginForAgents
            )
            .environment(\.theme, theme)
        }
        .sheet(item: $managingPlugin) { plugin in
            SandboxManageInstallsSheet(
                plugin: plugin,
                agents: agentManager.agents,
                pluginManager: sandboxPluginManager
            )
            .environment(\.theme, theme)
        }
        .alert("Remove Plugin?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { pluginToDelete = nil }
            Button("Remove", role: .destructive) {
                if let p = pluginToDelete {
                    pluginLibrary.delete(id: p.id)
                    pluginToDelete = nil
                }
            }
        } message: {
            if let p = pluginToDelete {
                Text("Remove \"\(p.name)\" from the library? Existing installations are not affected.")
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            if let error = actionError {
                Text(error)
            }
        }
    }

    // MARK: - Precomputed Data

    private var validAgentIds: Set<String> {
        Set(agentManager.agents.map { $0.id.uuidString })
    }

    private func buildAgentInstallsMap() -> [String: [SandboxPluginCard.AgentInstall]] {
        var map: [String: [SandboxPluginCard.AgentInstall]] = [:]
        for plugin in pluginLibrary.plugins {
            let installs = agentManager.agents.compactMap { agent -> SandboxPluginCard.AgentInstall? in
                let agentId = agent.id.uuidString
                guard let installed = sandboxPluginManager.plugin(id: plugin.id, for: agentId) else { return nil }
                return SandboxPluginCard.AgentInstall(
                    agentName: agent.name,
                    status: installed.status,
                    isOutdated: sandboxPluginManager.isOutdated(pluginId: plugin.id, agentId: agentId)
                )
            }
            if !installs.isEmpty {
                map[plugin.id] = installs
            }
        }
        return map
    }

    private func buildOutdatedPluginIds() -> Set<String> {
        Set(
            pluginLibrary.plugins.compactMap { plugin in
                sandboxPluginManager.hasAnyOutdated(pluginId: plugin.id, validAgentIds: validAgentIds)
                    ? plugin.id : nil
            }
        )
    }

    // MARK: - Actions

    private func installPluginForAgents(plugin: SandboxPlugin, agentIds: Set<UUID>) {
        Task {
            for agentId in agentIds {
                do {
                    try await SandboxPluginManager.shared.install(plugin: plugin, for: agentId.uuidString)
                } catch {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    private func importPluginFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                _ = try pluginLibrary.importFromFile(url)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func duplicatePlugin(_ plugin: SandboxPlugin) {
        var copy = plugin
        copy.name = plugin.name + " Copy"
        copy.version = nil
        pluginLibrary.save(copy)
    }

    private func exportPlugin(_ plugin: SandboxPlugin) {
        guard let data = pluginLibrary.exportData(for: plugin.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(plugin.id).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Empty State

    private var pluginEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text("No plugins in library")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Text("Create a plugin from scratch or import a JSON recipe. Plugins are reusable across all agents.")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(action: importPluginFile) {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())

                createPluginButton
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var createPluginButton: some View {
        Button(action: { showCreatePlugin = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                Text("Create Plugin")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Shared Helpers

private func sandboxAgentColor(for name: String) -> Color {
    let hash = abs(name.hashValue)
    let hue = Double(hash % 360) / 360.0
    return Color(hue: hue, saturation: 0.6, brightness: 0.8)
}

private struct SandboxPluginHeader: View {
    @Environment(\.theme) private var theme
    let plugin: SandboxPlugin
    var iconSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.15), theme.accentColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: iconSize * 0.5))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: iconSize, height: iconSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if let version = plugin.version {
                        Text("v\(version)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                }
                Text(plugin.description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }
        }
    }
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

// MARK: - Sandbox Plugin Card

private struct SandboxPluginCard: View {
    @Environment(\.theme) private var theme

    struct AgentInstall: Identifiable {
        var id: String { agentName }
        let agentName: String
        let status: InstalledSandboxPlugin.InstallStatus
        let isOutdated: Bool
    }

    let plugin: SandboxPlugin
    let agentInstalls: [AgentInstall]
    let hasOutdatedInstalls: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onEdit: () -> Void
    let onInstall: () -> Void
    let onManage: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var pluginColor: Color {
        hasOutdatedInstalls ? .orange : theme.accentColor
    }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [pluginColor.opacity(0.15), pluginColor.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 18))
                            .foregroundColor(pluginColor)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if let version = plugin.version {
                                Text("v\(version)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.tertiaryBackground))
                            }

                            statusBadge
                        }
                    }

                    Spacer(minLength: 8)

                    cardMenu
                }

                Text(plugin.description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        let toolCount = plugin.tools?.count ?? 0
                        if toolCount > 0 {
                            statItem(icon: "wrench.and.screwdriver", text: "\(toolCount)")
                        }
                        if toolCount > 0 && plugin.author != nil {
                            statDot
                        }
                        if let author = plugin.author {
                            statItem(icon: "person", text: author)
                        }
                        Spacer(minLength: 0)
                    }

                    if hasOutdatedInstalls {
                        updateButton
                    } else {
                        agentPillsRow
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(16)
            .background(cardBackground)
            .overlay(hoverGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        if hasOutdatedInstalls {
            SandboxStatusBadge(icon: "arrow.up.circle.fill", text: "Update Available", color: .orange)
        } else if !agentInstalls.isEmpty {
            SandboxStatusBadge(icon: "checkmark.circle.fill", text: "Installed", color: .green)
        }
    }

    // MARK: - Card Menu

    private var cardMenu: some View {
        Menu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(action: onInstall) {
                Label("Install to Agents...", systemImage: "square.and.arrow.down")
            }
            if !agentInstalls.isEmpty {
                Button(action: onManage) {
                    Label("Manage Installations", systemImage: "gearshape")
                }
            }
            Button(action: onDuplicate) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Remove from Library", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    // MARK: - Agent Pills

    @ViewBuilder
    private var agentPillsRow: some View {
        if agentInstalls.isEmpty {
            Text("Not installed")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
        } else {
            HStack(spacing: 6) {
                ForEach(agentInstalls) { install in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(
                                install.isOutdated
                                    ? Color.orange : (install.status == .ready ? Color.green : Color.orange)
                            )
                            .frame(width: 6, height: 6)
                        Text(install.agentName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.tertiaryBackground))
                }
            }
        }
    }

    // MARK: - Update Button

    private var updateButton: some View {
        Button(action: onManage) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text("Update Installations")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Stats

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

    // MARK: - Card Styling

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
    }

    private var cardBorder: some View {
        let hasInstalls = !agentInstalls.isEmpty && !hasOutdatedInstalls
        return RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isHovered
                    ? pluginColor.opacity(0.25)
                    : hasInstalls ? Color.green.opacity(0.2) : theme.cardBorder,
                lineWidth: isHovered ? 1.5 : 1
            )
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        pluginColor.opacity(isHovered ? 0.06 : 0),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Status Badge

private struct SandboxStatusBadge: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundColor(color)
        .fixedSize()
    }
}

// MARK: - Install to Agents Sheet

private struct SandboxInstallSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let plugin: SandboxPlugin
    let agents: [Agent]
    let pluginManager: SandboxPluginManager
    let onInstall: (SandboxPlugin, Set<UUID>) -> Void

    @State private var selectedAgentIds: Set<UUID> = []

    private var installedAgentIds: Set<UUID> {
        Set(agents.filter { pluginManager.plugin(id: plugin.id, for: $0.id.uuidString) != nil }.map(\.id))
    }

    private var newSelectionCount: Int {
        selectedAgentIds.subtracting(installedAgentIds).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Install Plugin")
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
                SandboxPluginHeader(plugin: plugin)

                VStack(alignment: .leading, spacing: 8) {
                    Text("SELECT AGENTS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        ForEach(agents, id: \.id) { agent in
                            agentRow(agent: agent, isInstalled: installedAgentIds.contains(agent.id))
                            if agent.id != agents.last?.id {
                                Divider().foregroundColor(theme.cardBorder)
                            }
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)

            Spacer()

            Divider().foregroundColor(theme.cardBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Button(action: {
                    let newIds = selectedAgentIds.subtracting(installedAgentIds)
                    guard !newIds.isEmpty else { return }
                    onInstall(plugin, newIds)
                    dismiss()
                }) {
                    Label(
                        newSelectionCount > 0
                            ? "Install to \(newSelectionCount) Agent\(newSelectionCount == 1 ? "" : "s")" : "Install",
                        systemImage: "square.and.arrow.down"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(newSelectionCount > 0 ? theme.accentColor : theme.accentColor.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .disabled(newSelectionCount == 0)
            }
            .padding(20)
        }
        .frame(width: 480, height: 480)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func agentRow(agent: Agent, isInstalled: Bool) -> some View {
        Button(action: {
            guard !isInstalled else { return }
            if selectedAgentIds.contains(agent.id) {
                selectedAgentIds.remove(agent.id)
            } else {
                selectedAgentIds.insert(agent.id)
            }
        }) {
            HStack(spacing: 10) {
                SandboxAgentAvatar(name: agent.name)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isInstalled {
                    SandboxStatusBadge(icon: "checkmark.circle.fill", text: "Installed", color: .green)
                } else {
                    Image(systemName: selectedAgentIds.contains(agent.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundColor(selectedAgentIds.contains(agent.id) ? theme.accentColor : theme.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isInstalled)
        .opacity(isInstalled ? 0.6 : 1.0)
    }
}

// MARK: - Manage Installations Sheet

private struct SandboxManageInstallsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let plugin: SandboxPlugin
    let agents: [Agent]
    @ObservedObject var pluginManager: SandboxPluginManager

    @State private var errorMessage: String?

    private var agentInstalls: [(Agent, InstalledSandboxPlugin, Bool)] {
        agents.compactMap { agent in
            guard let installed = pluginManager.plugin(id: plugin.id, for: agent.id.uuidString) else { return nil }
            let outdated = pluginManager.isOutdated(pluginId: plugin.id, agentId: agent.id.uuidString)
            return (agent, installed, outdated)
        }
    }

    private var hasAnyOutdated: Bool {
        agentInstalls.contains { $0.2 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Installations")
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
                SandboxPluginHeader(plugin: plugin)

                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(error)
                            .font(.system(size: 11))
                            .lineLimit(2)
                    }
                    .foregroundColor(theme.warningColor)
                }

                if agentInstalls.isEmpty {
                    VStack(spacing: 8) {
                        Text("Not installed on any agents")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("INSTALLED ON")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.5)

                        VStack(spacing: 0) {
                            ForEach(agentInstalls, id: \.0.id) { agent, installed, outdated in
                                manageRow(agent: agent, installed: installed, isOutdated: outdated)
                                if agent.id != agentInstalls.last?.0.id {
                                    Divider().foregroundColor(theme.cardBorder)
                                }
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
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(20)

            Spacer()

            Divider().foregroundColor(theme.cardBorder)

            HStack {
                if hasAnyOutdated {
                    Button(action: reinstallAll) {
                        Label("Reinstall All", systemImage: "arrow.clockwise")
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

                Spacer()

                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(20)
        }
        .frame(width: 520, height: 480)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func manageRow(agent: Agent, installed: InstalledSandboxPlugin, isOutdated: Bool) -> some View {
        HStack(spacing: 10) {
            SandboxAgentAvatar(name: agent.name)

            Text(agent.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)

            statusBadge(for: installed, isOutdated: isOutdated)

            Spacer()

            if isOutdated {
                Button(action: { reinstallForAgent(agent) }) {
                    Text("Reinstall")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(.plain)
            }

            Button(action: { uninstallForAgent(agent) }) {
                Text("Uninstall")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.errorColor.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBadge(for installed: InstalledSandboxPlugin, isOutdated: Bool) -> some View {
        if isOutdated {
            SandboxStatusBadge(icon: "arrow.up.circle.fill", text: "Update Available", color: .orange)
        } else {
            switch installed.status {
            case .ready:
                SandboxStatusBadge(icon: "checkmark.circle.fill", text: "Ready", color: .green)
            case .failed:
                SandboxStatusBadge(icon: "exclamationmark.triangle.fill", text: "Failed", color: .red)
            case .installing:
                SandboxStatusBadge(icon: "arrow.down.circle", text: "Installing", color: .orange)
            case .uninstalling:
                SandboxStatusBadge(icon: "arrow.up.circle", text: "Uninstalling", color: .orange)
            }
        }
    }

    private func uninstallForAgent(_ agent: Agent) {
        errorMessage = nil
        Task {
            do {
                try await pluginManager.uninstall(pluginId: plugin.id, from: agent.id.uuidString)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reinstallForAgent(_ agent: Agent) {
        errorMessage = nil
        Task {
            do {
                try await pluginManager.reinstall(plugin: plugin, for: agent.id.uuidString)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reinstallAll() {
        errorMessage = nil
        Task {
            for (agent, _, outdated) in agentInstalls where outdated {
                do {
                    try await pluginManager.reinstall(plugin: plugin, for: agent.id.uuidString)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SandboxView()
}
