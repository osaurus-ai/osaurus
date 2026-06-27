//
//  MCPOperationsHubView.swift
//  osaurus
//
//  Self-contained operations surface for local stdio and HTTP MCP providers.
//

import AppKit
import SwiftUI

struct MCPOperationsHubView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var manager = MCPProviderManager.shared

    @State private var filter: MCPServerHubFilter = .all
    @State private var operationsSnapshot: MCPProviderOperationsSnapshot = MCPProviderOperationsHub.emptySnapshot()
    @State private var snapshotRefreshTask: Task<Void, Never>?
    @State private var selectedProviderId: UUID?
    @State private var editingProvider: MCPProvider?
    @State private var showingAddSheet = false
    @State private var probingProviderIds: Set<UUID> = []
    @State private var reconnectingProviderIds: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            if operationsSnapshot.reports.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    providerList
                        .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
                    Divider()
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(theme.primaryBackground)
        .onAppear {
            refreshAll(selectFirstIfNeeded: true)
        }
        .onDisappear {
            snapshotRefreshTask?.cancel()
            snapshotRefreshTask = nil
        }
        .onReceive(manager.$configuration) { _ in
            refreshAll(reconcileSelection: true)
        }
        .onReceive(manager.$providerStates) { _ in
            refreshAll(reconcileSelection: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: Foundation.Notification.Name.mcpProviderHealthSnapshotChanged)
        ) { _ in
            Task { @MainActor in
                refreshAll(reconcileSelection: true)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: Foundation.Notification.Name.mcpProviderCallHistoryChanged)
        ) { _ in
            Task { @MainActor in
                refreshAll(reconcileSelection: true)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            MCPOperationsProviderEditor(provider: nil) { provider, tokenEdit in
                manager.addProvider(provider, token: tokenEdit.tokenForNewProvider)
                refreshAll()
            }
            .environment(\.theme, theme)
        }
        .sheet(item: $editingProvider) { provider in
            MCPOperationsProviderEditor(provider: provider) { updatedProvider, tokenEdit in
                manager.updateProvider(updatedProvider, tokenEdit: tokenEdit)
                refreshAll()
            }
            .environment(\.theme, theme)
        }
    }

    private var visibleReports: [MCPProviderOperationsReport] {
        operationsSnapshot.filtered(by: filter)
    }

    private var selectedReport: MCPProviderOperationsReport? {
        let reports = visibleReports
        if let selectedProviderId, let match = reports.first(where: { $0.id == selectedProviderId }) {
            return match
        }
        return reports.first
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Operations", bundle: .module)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Picker("", selection: $filter) {
                ForEach(MCPServerHubFilter.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 420)

            iconButton("doc.on.doc", help: "Copy diagnostics") {
                copyToPasteboard(operationsSnapshot.pasteboardText)
            }

            Button {
                showingAddSheet = true
            } label: {
                Label {
                    Text("Add", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
        .overlay(Rectangle().fill(theme.primaryBorder).frame(height: 1), alignment: .bottom)
    }

    private var headerSubtitle: String {
        let hub = operationsSnapshot.hubSnapshot
        if hub.totalCount == 0 {
            return L("Add HTTP/SSE or stdio MCP providers")
        }
        return L("\(hub.connectedCount)/\(hub.totalCount) connected - \(hub.attentionCount) attention - \(hub.toolCount) tools")
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            metrics
                .padding(14)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleReports) { report in
                        providerRow(report)
                    }
                }
                .padding(12)
            }
        }
        .background(theme.primaryBackground)
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            metric("Connected", "\(operationsSnapshot.hubSnapshot.connectedCount)", theme.successColor)
            metric("Attention", "\(operationsSnapshot.hubSnapshot.attentionCount)", theme.warningColor)
            metric("Tools", "\(operationsSnapshot.hubSnapshot.toolCount)", theme.accentColor)
            metric("Stdio", "\(operationsSnapshot.hubSnapshot.stdioCount)", theme.infoColor)
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }

    private func providerRow(_ report: MCPProviderOperationsReport) -> some View {
        let isSelected = selectedReport?.id == report.id
        return Button {
            selectedProviderId = report.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: report))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(statusColor(for: report))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(statusColor(for: report).opacity(0.12)))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(report.provider.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        transportBadge(report.provider)
                    }
                    Text(rowSubtitle(report))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if report.hubReport.hasAttention {
                        Text(report.hubReport.summary)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? theme.accentColor.opacity(0.10) : theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? theme.accentColor.opacity(0.35) : theme.cardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let report = selectedReport {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(report)
                    launchPlanCard(report.launchPlan)
                    authCard(report.authStatus)
                    healthCard(report)
                    diagnosticsCard(report)
                    callHistoryCard(report)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            emptyState
        }
    }

    private func detailHeader(_ report: MCPProviderOperationsReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: iconName(for: report))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(statusColor(for: report))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(statusColor(for: report).opacity(0.12)))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(report.provider.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        statusBadge(report.status)
                        transportBadge(report.provider)
                    }
                    Text(rowSubtitle(report))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                iconButton("doc.on.doc", help: "Copy provider diagnostics") {
                    copyToPasteboard(report.pasteboardText)
                }
            }

            HStack(spacing: 8) {
                actionButton("antenna.radiowaves.left.and.right", title: "Test", busy: probingProviderIds.contains(report.id)) {
                    probe(report.provider)
                }
                actionButton("arrow.clockwise", title: "Reconnect", busy: reconnectingProviderIds.contains(report.id)) {
                    reconnect(report.provider)
                }
                actionButton("pencil", title: "Edit", busy: false) {
                    editingProvider = report.provider
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder, lineWidth: 1))
    }

    private func launchPlanCard(_ plan: MCPProviderLaunchPlan) -> some View {
        operationsCard(title: "Launch Resolution", icon: "terminal") {
            VStack(alignment: .leading, spacing: 10) {
                keyValueRow("Status", plan.status.rawValue)
                keyValueRow("Plan", plan.title)
                keyValueRow("Detail", plan.detail)
                if let command = plan.redactedCommandLine {
                    keyValueRow("Command", command, monospaced: true)
                }
                if let resolved = plan.resolvedExecutablePath {
                    keyValueRow("Executable", resolved, monospaced: true)
                }
                if let cwd = plan.workingDirectory {
                    keyValueRow("Working directory", cwd, monospaced: true)
                }
                if !plan.configuredEnvironmentKeys.isEmpty {
                    keyValueRow("Environment", plan.configuredEnvironmentKeys.joined(separator: ", "))
                }
                if !plan.missingSecretEnvironmentKeys.isEmpty {
                    keyValueRow("Missing secrets", plan.missingSecretEnvironmentKeys.joined(separator: ", "))
                }
                ForEach(plan.warnings, id: \.self) { warning in
                    warningRow(warning)
                }
            }
        }
    }

    private func authCard(_ status: MCPProviderAuthStatus) -> some View {
        operationsCard(title: "Authentication", icon: "person.badge.key") {
            VStack(alignment: .leading, spacing: 10) {
                keyValueRow("State", status.title)
                keyValueRow("Detail", status.detail)
                if let action = status.action {
                    warningRow(action)
                }
            }
        }
    }

    private func healthCard(_ report: MCPProviderOperationsReport) -> some View {
        operationsCard(title: "Health Snapshot", icon: "waveform.path.ecg") {
            if let snapshot = report.hubReport.healthSnapshot {
                VStack(alignment: .leading, spacing: 10) {
                    keyValueRow("Reason", snapshot.lastProbe.reasonCode.rawValue)
                    keyValueRow("Stage", snapshot.lastProbe.stage.rawValue)
                    keyValueRow("Tools", "\(snapshot.lastProbe.toolCount)")
                    keyValueRow("Message", snapshot.lastProbe.redactedMessage)
                    if let action = snapshot.lastProbe.redactedAction {
                        warningRow(action)
                    }
                }
            } else {
                Text("No probe has been recorded for this provider.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private func diagnosticsCard(_ report: MCPProviderOperationsReport) -> some View {
        operationsCard(title: "Redacted Diagnostics", icon: "stethoscope") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.diagnostics.rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(color(for: row.severity))
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.title): \(row.value)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            if let detail = row.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let action = row.action, !action.isEmpty {
                                Text(action)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.accentColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func callHistoryCard(_ report: MCPProviderOperationsReport) -> some View {
        operationsCard(title: "Call History", icon: "clock.arrow.circlepath") {
            if report.callHistory.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No MCP tool calls have been recorded for this provider.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.callHistory.prefix(20)) { call in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(call.toolName)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                statusBadge(call.succeeded ? .connected : .needsAttention)
                                Text("\(call.durationMilliseconds)ms")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.tertiaryText)
                                Spacer()
                                Text(call.startedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            Text(call.argumentSummary)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                            if let error = call.errorMessage, !error.isEmpty {
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.errorColor)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.tertiaryBackground))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text("No MCP providers", bundle: .module)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("Add an HTTP/SSE endpoint or a local stdio command to start managing MCP operations.", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                showingAddSheet = true
            } label: {
                Label {
                    Text("Add Provider", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func operationsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder, lineWidth: 1))
    }

    private func keyValueRow(_ key: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(LocalizedStringKey(key), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(theme.warningColor)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.warningColor.opacity(0.10)))
    }

    private func actionButton(
        _ systemName: String,
        title: String,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().scaleEffect(0.6).frame(width: 13, height: 13)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.secondaryText)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.tertiaryBackground))
        .disabled(busy)
        .localizedHelp(LocalizedStringKey(title))
    }

    private func iconButton(_ systemName: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.secondaryText)
        .background(Circle().fill(theme.tertiaryBackground))
        .localizedHelp(help)
    }

    private func statusBadge(_ status: MCPServerHubStatus) -> some View {
        Text(status.displayName)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(statusColor(for: status))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor(for: status).opacity(0.12)))
    }

    private func transportBadge(_ provider: MCPProvider) -> some View {
        Text(provider.transport == .stdio ? provider.executionHost.rawValue : "http")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(provider.transport == .stdio ? theme.infoColor : theme.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((provider.transport == .stdio ? theme.infoColor : theme.accentColor).opacity(0.12))
            )
    }

    private func rowSubtitle(_ report: MCPProviderOperationsReport) -> String {
        switch report.provider.transport {
        case .http:
            return report.provider.url
        case .stdio:
            return report.launchPlan.redactedCommandLine ?? L("stdio command not set")
        }
    }

    private func iconName(for report: MCPProviderOperationsReport) -> String {
        switch report.status {
        case .connected:
            return "checkmark.seal.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .disabled:
            return "pause.circle.fill"
        case .idle:
            return "server.rack"
        }
    }

    private func statusColor(for report: MCPProviderOperationsReport) -> Color {
        statusColor(for: report.status)
    }

    private func statusColor(for status: MCPServerHubStatus) -> Color {
        switch status {
        case .connected:
            return theme.successColor
        case .connecting:
            return theme.accentColor
        case .needsAttention:
            return theme.warningColor
        case .disabled:
            return theme.tertiaryText
        case .idle:
            return theme.infoColor
        }
    }

    private func color(for severity: ProviderDiagnosticSeverity) -> Color {
        switch severity {
        case .ok:
            return theme.successColor
        case .info:
            return theme.infoColor
        case .warning:
            return theme.warningColor
        case .blocked:
            return theme.errorColor
        }
    }

    private func refreshAll(
        selectFirstIfNeeded: Bool = false,
        reconcileSelection: Bool = false
    ) {
        let providers = manager.configuration.providers
        let states = manager.providerStates

        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                let proxy = GlobalProxySettings.currentDiagnostic()
                let healthSnapshots = MCPProviderHealthSnapshotStore.load()
                let callHistory = MCPProviderCallHistoryStore.load()
                let credentials = MCPProviderOperationsHub.credentialPresence(for: providers)
                return MCPProviderOperationsHub.snapshot(
                    providers: providers,
                    states: states,
                    proxy: proxy,
                    credentialsByProvider: credentials,
                    healthSnapshots: healthSnapshots,
                    callHistoryByProvider: callHistory
                )
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                operationsSnapshot = snapshot
                if selectFirstIfNeeded || reconcileSelection, selectedProviderId == nil {
                    selectedProviderId = snapshot.reports.first?.id
                }
                if reconcileSelection,
                    let selectedProviderId,
                    !snapshot.reports.contains(where: { $0.id == selectedProviderId }) {
                    self.selectedProviderId = snapshot.reports.first?.id
                }
            }
        }
    }

    private func probe(_ provider: MCPProvider) {
        guard !probingProviderIds.contains(provider.id) else { return }
        probingProviderIds.insert(provider.id)
        Task {
            let result: MCPProviderProbeResult
            switch provider.transport {
            case .http:
                let credentials = await Task.detached(priority: .utility) {
                    let token: String? =
                        switch provider.authType {
                        case .bearerToken:
                            MCPProviderKeychain.getToken(for: provider.id)
                        case .oauth:
                            MCPProviderKeychain.getOAuthTokens(for: provider.id)?.accessToken
                        case .none:
                            nil
                        }
                    return (token, provider.resolvedHeaders())
                }.value
                result = await MCPProviderProbeService.probeHTTP(
                    providerId: provider.id,
                    name: provider.name,
                    url: provider.url,
                    token: credentials.0,
                    headers: credentials.1,
                    streamingEnabled: provider.streamingEnabled,
                    discoveryTimeout: provider.discoveryTimeout
                )
            case .stdio:
                result = await MCPProviderProbeService.probeStdio(provider: provider)
            }
            MCPProviderHealthSnapshotStore.record(result, for: provider)
            await MainActor.run {
                probingProviderIds.remove(provider.id)
                refreshAll(reconcileSelection: true)
            }
        }
    }

    private func reconnect(_ provider: MCPProvider) {
        guard provider.enabled, !reconnectingProviderIds.contains(provider.id) else { return }
        reconnectingProviderIds.insert(provider.id)
        Task {
            do {
                try await manager.reconnect(providerId: provider.id)
            } catch {
                // The provider state carries the row error.
            }
            await MainActor.run {
                reconnectingProviderIds.remove(provider.id)
                refreshAll()
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private struct MCPOperationsProviderEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let provider: MCPProvider?
    let onSave: (MCPProvider, MCPProviderBearerTokenEdit) -> Void

    @State private var draftId = UUID()
    @State private var name = ""
    @State private var transport: MCPProviderTransport = .http
    @State private var url = ""
    @State private var authType: MCPProviderAuthType = .bearerToken
    @State private var token = ""
    @State private var clearBearerToken = false
    @State private var enabled = true
    @State private var autoConnect = true
    @State private var streamingEnabled = false
    @State private var discoveryTimeout = 20.0
    @State private var toolCallTimeout = 45.0
    @State private var executionHost: MCPProviderExecutionHost = .sandbox
    @State private var command = ""
    @State private var argsString = ""
    @State private var workingDirectory = ""
    @State private var headerEntries: [KeyValueEntry] = []
    @State private var envEntries: [KeyValueEntry] = []
    @State private var isTesting = false
    @State private var probeResult: MCPProviderProbeResult?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: provider == nil ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider == nil ? "Add MCP Provider" : "Edit MCP Provider", bundle: .module)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Configure HTTP/SSE or local stdio MCP operations", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .background(Circle().fill(theme.tertiaryBackground))
            }
            .padding(18)
            .background(theme.secondaryBackground)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editorCard("Connection", icon: "link") {
                        VStack(alignment: .leading, spacing: 12) {
                            labeledTextField("Name", text: $name, placeholder: "Filesystem MCP")

                            Picker("", selection: $transport) {
                                Text("HTTP/SSE", bundle: .module).tag(MCPProviderTransport.http)
                                Text("Stdio", bundle: .module).tag(MCPProviderTransport.stdio)
                            }
                            .pickerStyle(.segmented)

                            Toggle("Enabled", isOn: $enabled)
                                .toggleStyle(.switch)
                            Toggle("Auto-connect", isOn: $autoConnect)
                                .toggleStyle(.switch)
                        }
                    }

                    if transport == .http {
                        httpFields
                    } else {
                        stdioFields
                    }

                    advancedFields

                    if let probeResult {
                        probeCard(probeResult)
                    }
                }
                .padding(18)
            }

            HStack(spacing: 10) {
                Button { testProvider() } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text("Test", bundle: .module)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                .disabled(isTesting || !canTest)

                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                Button {
                    save()
                } label: {
                    Text(provider == nil ? "Add Provider" : "Save", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(18)
            .background(theme.secondaryBackground)
        }
        .frame(width: 560, height: 680)
        .background(theme.primaryBackground)
        .onAppear(perform: load)
    }

    private var httpFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            editorCard("HTTP", icon: "network") {
                VStack(alignment: .leading, spacing: 12) {
                    labeledTextField("URL", text: $url, placeholder: "https://mcp.example.com/mcp", monospaced: true)
                    Picker("", selection: $authType) {
                        Text("None", bundle: .module).tag(MCPProviderAuthType.none)
                        Text("Bearer", bundle: .module).tag(MCPProviderAuthType.bearerToken)
                        Text("OAuth", bundle: .module).tag(MCPProviderAuthType.oauth)
                    }
                    .pickerStyle(.segmented)
                    if authType == .bearerToken {
                        secureTextField("Bearer Token", text: $token, placeholder: "Stored in Keychain")
                        if provider != nil {
                            Toggle("Clear saved token", isOn: $clearBearerToken)
                                .font(.system(size: 11))
                                .toggleStyle(.checkbox)
                                .foregroundColor(theme.secondaryText)
                                .disabled(!token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Toggle("Streaming/SSE", isOn: $streamingEnabled)
                        .toggleStyle(.switch)
                }
            }
            keyValueEditor(
                title: "Custom Headers",
                icon: "list.bullet.rectangle",
                addLabel: "Add Header",
                entries: $headerEntries
            )
        }
    }

    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            editorCard("Stdio", icon: "terminal") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $executionHost) {
                        Text("Sandbox", bundle: .module).tag(MCPProviderExecutionHost.sandbox)
                        Text("Host", bundle: .module).tag(MCPProviderExecutionHost.host)
                    }
                    .pickerStyle(.segmented)
                    labeledTextField("Command", text: $command, placeholder: "npx", monospaced: true)
                    labeledTextField("Arguments", text: $argsString, placeholder: "-y @modelcontextprotocol/server-filesystem", monospaced: true)
                    labeledTextField("Working directory", text: $workingDirectory, placeholder: "Optional", monospaced: true)
                }
            }
            keyValueEditor(
                title: "Environment",
                icon: "wand.and.stars",
                addLabel: "Add Variable",
                entries: $envEntries
            )
        }
    }

    private var advancedFields: some View {
        editorCard("Timeouts", icon: "clock") {
            VStack(alignment: .leading, spacing: 12) {
                timeoutSlider("Discovery", value: $discoveryTimeout, range: 5...120)
                timeoutSlider("Tool call", value: $toolCallTimeout, range: 5...300)
            }
        }
    }

    private func timeoutSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))s")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func editorCard<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder, lineWidth: 1))
    }

    private func labeledTextField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.inputBackground)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.inputBorder, lineWidth: 1))
                )
        }
    }

    private func secureTextField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.inputBackground)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.inputBorder, lineWidth: 1))
                )
        }
    }

    private func keyValueEditor(
        title: String,
        icon: String,
        addLabel: String,
        entries: Binding<[KeyValueEntry]>
    ) -> some View {
        editorCard(title, icon: icon) {
            VStack(spacing: 10) {
                ForEach(entries.wrappedValue) { entry in
                    if let index = entries.wrappedValue.firstIndex(where: { $0.id == entry.id }) {
                        HStack(spacing: 8) {
                            TextField("KEY", text: entries[index].key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                            if entries[index].isSecret.wrappedValue {
                                SecureField("Value", text: entries[index].value)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                            } else {
                                TextField("Value", text: entries[index].value)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            Toggle("Secret", isOn: entries[index].isSecret)
                                .font(.system(size: 11))
                                .toggleStyle(.checkbox)
                            Button {
                                entries.wrappedValue.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(theme.errorColor)
                        }
                    }
                }
                Button {
                    entries.wrappedValue.append(KeyValueEntry(key: "", value: "", isSecret: false))
                } label: {
                    Label(LocalizedStringKey(addLabel), systemImage: "plus.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func probeCard(_ result: MCPProviderProbeResult) -> some View {
        editorCard(result.succeeded ? "Probe Passed" : "Probe Failed", icon: result.succeeded ? "checkmark.seal" : "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(result.reasonCode.rawValue) / \(result.stage.rawValue)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(result.succeeded ? theme.successColor : theme.errorColor)
                Text(result.redactedMessage)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                if let action = result.redactedAction {
                    Text(action)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
            }
        }
    }

    private var canTest: Bool {
        switch transport {
        case .http:
            return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .stdio:
            return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && canTest
    }

    private func load() {
        guard let provider else { return }
        draftId = provider.id
        name = provider.name
        transport = provider.transport
        url = provider.url
        authType = provider.authType
        clearBearerToken = false
        enabled = provider.enabled
        autoConnect = provider.autoConnect
        streamingEnabled = provider.streamingEnabled
        discoveryTimeout = provider.discoveryTimeout
        toolCallTimeout = provider.toolCallTimeout
        executionHost = provider.executionHost
        command = provider.command
        argsString = ShellArgs.join(provider.args)
        workingDirectory = provider.workingDirectory ?? ""
        headerEntries = provider.customHeaders.map { KeyValueEntry(key: $0.key, value: $0.value, isSecret: false) }
            + provider.secretHeaderKeys.map { KeyValueEntry(key: $0, value: "", isSecret: true) }
        envEntries = provider.env.map { KeyValueEntry(key: $0.key, value: $0.value, isSecret: false) }
            + provider.secretEnvKeys.map { KeyValueEntry(key: $0, value: "", isSecret: true) }
    }

    private func save() {
        let provider = makeProvider()
        saveSecrets(for: provider)
        onSave(
            provider,
            MCPProviderBearerTokenEdit.fromBearerField(
                token,
                authType: provider.authType,
                clearRequested: clearBearerToken
            )
        )
        dismiss()
    }

    private func testProvider() {
        guard canTest else { return }
        isTesting = true
        let provider = makeProvider()
        Task {
            let result: MCPProviderProbeResult
            switch provider.transport {
            case .http:
                result = await MCPProviderProbeService.probeHTTP(
                    providerId: provider.id,
                    name: provider.name,
                    url: provider.url,
                    token: bearerTokenForProbe(provider: provider),
                    headers: headersForProbe(provider: provider),
                    streamingEnabled: provider.streamingEnabled,
                    discoveryTimeout: provider.discoveryTimeout
                )
            case .stdio:
                result = await MCPProviderProbeService.probeStdio(provider: providerForStdioProbe(provider))
            }
            await MainActor.run {
                probeResult = result
                isTesting = false
            }
        }
    }

    private func makeProvider() -> MCPProvider {
        let headers = normalizedEntries(headerEntries)
        let envFields = normalizedEntries(envEntries)
        return MCPProvider(
            id: draftId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: transport == .http ? url.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            enabled: enabled,
            customHeaders: headers.regular,
            streamingEnabled: transport == .http && streamingEnabled,
            discoveryTimeout: discoveryTimeout,
            toolCallTimeout: toolCallTimeout,
            autoConnect: autoConnect,
            secretHeaderKeys: headers.secretKeys,
            authType: transport == .http ? authType : .none,
            oauth: provider?.oauth,
            pluginId: provider?.pluginId,
            transport: transport,
            executionHost: executionHost,
            command: transport == .stdio ? command.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            args: transport == .stdio ? ShellArgs.split(argsString) : [],
            env: transport == .stdio ? envFields.regular : [:],
            secretEnvKeys: transport == .stdio ? envFields.secretKeys : [],
            workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func normalizedEntries(_ entries: [KeyValueEntry]) -> (regular: [String: String], secretKeys: [String]) {
        MCPProviderOperationsFieldNormalizer.normalize(
            entries.map { (key: $0.key, value: $0.value, isSecret: $0.isSecret) }
        )
    }

    private func saveSecrets(for provider: MCPProvider) {
        for entry in headerEntries where entry.isSecret {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !entry.value.isEmpty else { continue }
            MCPProviderKeychain.saveHeaderSecret(entry.value, key: key, for: provider.id)
        }
        saveEnvSecrets(for: provider)
    }

    private func saveEnvSecrets(for provider: MCPProvider) {
        for entry in envEntries where entry.isSecret {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !entry.value.isEmpty else { continue }
            MCPProviderKeychain.saveEnvSecret(entry.value, key: key, for: provider.id)
        }
    }

    private func bearerTokenForProbe(provider: MCPProvider) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if clearBearerToken { return nil }

        switch provider.authType {
        case .bearerToken:
            return self.provider?.getToken()
        case .oauth:
            return self.provider?.getOAuthTokens()?.accessToken
        case .none:
            return nil
        }
    }

    private func headersForProbe(provider: MCPProvider) -> [String: String] {
        var headers = provider.customHeaders
        for entry in headerEntries where entry.isSecret {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if !entry.value.isEmpty {
                headers[key] = entry.value
            } else if let value = MCPProviderKeychain.getHeaderSecret(key: key, for: provider.id),
                !value.isEmpty {
                headers[key] = value
            }
        }
        return headers
    }

    private func providerForStdioProbe(_ provider: MCPProvider) -> MCPProvider {
        MCPProvider(
            id: provider.id,
            name: provider.name,
            url: provider.url,
            enabled: provider.enabled,
            customHeaders: provider.customHeaders,
            streamingEnabled: provider.streamingEnabled,
            discoveryTimeout: provider.discoveryTimeout,
            toolCallTimeout: provider.toolCallTimeout,
            autoConnect: provider.autoConnect,
            secretHeaderKeys: provider.secretHeaderKeys,
            authType: provider.authType,
            oauth: provider.oauth,
            pluginId: provider.pluginId,
            transport: provider.transport,
            executionHost: provider.executionHost,
            command: provider.command,
            args: provider.args,
            env: envForProbe(provider: provider),
            secretEnvKeys: [],
            workingDirectory: provider.workingDirectory
        )
    }

    private func envForProbe(provider: MCPProvider) -> [String: String] {
        var env = provider.env
        for entry in envEntries where entry.isSecret {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if !entry.value.isEmpty {
                env[key] = entry.value
            } else if let value = MCPProviderKeychain.getEnvSecret(key: key, for: provider.id),
                !value.isEmpty {
                env[key] = value
            }
        }
        return env
    }
}

private struct KeyValueEntry: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
    var isSecret: Bool
}
