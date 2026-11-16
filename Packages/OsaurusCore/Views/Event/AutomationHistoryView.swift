//
//  AutomationHistoryView.swift
//  osaurus
//
//  Automations → Channel Messages: channel messages that never reached an
//  automation, and those taken as a form's answer, with the reason and a
//  fix. Automation runs are tasks and live in Tasks → History.
//

import AppKit
import Combine
import SwiftUI

struct AutomationHistoryView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private let workbench = AgentChannelAuditWorkbenchService()

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var filter = AutomationHistoryFilter(source: .messages)
    @State private var audit: [AgentChannelAuditRecord] = []
    @State private var summary: AgentChannelAuditWorkbenchSummary?
    @State private var connections: [AgentChannelConnection] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadID = UUID()

    private var items: [AutomationHistoryItem] {
        AutomationHistoryFeed.merge(runs: [], audit: audit, filter: filter)
    }

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Channel Messages",
                subtitle: "Messages that were refused, that no automation claimed, or that answered a workflow's form",
                onRefresh: { reload() },
                isRefreshing: isLoading,
                utilities: {
                    SettingsIconButton("doc.on.doc", help: "Copy redacted export") { copyExport() }
                },
                toolbar: { filterBar }
            )
        } content: {
            messageStats
            if let loadError {
                InlineBanner(kind: .error, title: loadError)
            }
            if items.isEmpty && !isLoading {
                SettingsEmptyState(inline: "tray", title: emptyText)
            } else {
                VStack(alignment: .leading, spacing: theme.settingsControlGap) {
                    ForEach(items) { item in
                        switch item {
                        case .run:
                            EmptyView()
                        case .message(let record):
                            AutomationHistoryMessageRow(record: record, channelName: channelName(record.connectionId))
                        }
                    }
                }
            }
        }
        .onAppear {
            connections = AgentChannelConnectionManager.shared.editableConnections()
            reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentChannelUnreachedMessageRecorded)
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
        ) { _ in reload() }
        .onChange(of: filter.connectionId) { _, _ in reload() }
    }

    // MARK: - Filters

    private var filterBar: some View {
        SettingsHeaderToolbar(showSearch: false) {
            SettingsMenuPicker(selection: $filter.connectionId) {
                Text("All channels", bundle: .module).tag(String?.none)
                ForEach(channelOptions, id: \.self) { id in
                    Text(channelName(id)).tag(String?.some(id))
                }
            }
        } trailing: {
            SettingsMenuPicker(selection: $filter.status) {
                ForEach(AutomationHistoryFilter.Status.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }
        }
    }

    private var messageStats: some View {
        SettingsStatStrip(stats: [
            SettingsStat(label: "Received", value: "\(summary?.acceptedCount ?? 0)", icon: "checkmark.shield.fill"),
            SettingsStat(label: "Denied", value: "\(summary?.deniedCount ?? 0)", icon: "hand.raised.fill"),
            SettingsStat(label: "Duplicates", value: "\(summary?.duplicateCount ?? 0)", icon: "arrow.triangle.2.circlepath"),
        ])
    }

    private var emptyText: String {
        "No channel messages to show. Messages that were refused, that no automation claimed, or that answered a workflow's form appear here; messages that ran an automation show up in Tasks → History."
    }

    /// Every channel account first, then custom connections.
    private var channelOptions: [String] {
        var options = [AgentChannelKind.discord, .slack, .telegram, .imessage, .whatsapp, .email].flatMap {
            ChannelAccounts.accounts(kind: $0).map(\.connectionId)
        }
        for connection in connections where !options.contains(connection.id) {
            options.append(connection.id)
        }
        return options
    }

    private func channelName(_ connectionId: String) -> String {
        if let name = ChannelAccounts.displayName(connectionId: connectionId) { return name }
        if let kind = AgentChannelKind(rawValue: AgentChannelConnection.normalizedId(connectionId)) {
            return kind.displayName
        }
        if let match = connections.first(where: { $0.id == connectionId }), !match.name.isEmpty {
            return match.name
        }
        return connectionId
    }

    // MARK: - Data

    private var auditConnectionScope: String? {
        filter.connectionId
    }

    private func reload() {
        let id = UUID()
        loadID = id
        isLoading = true
        let scope = auditConnectionScope
        let workbench = workbench
        Task {
            let result: Result<(AgentChannelAuditWorkbenchSummary, [AgentChannelAuditRecord]), Error> =
                await Task.detached {
                    Result {
                        let snapshot = try workbench.snapshot(connectionId: scope, messageLimit: 1, auditLimit: 1)
                        let unreached = try AgentChannelMessageStore.shared.recentAuditEvents(
                            connectionId: scope, statuses: [.denied, .failed], limit: 200)
                        let formAnswers = try AgentChannelMessageStore.shared.recentAuditEvents(
                            connectionId: scope, action: EventManager.dialogAnswerAction, limit: 200)
                        return (snapshot.summary, unreached + formAnswers)
                    }
                }.value
            guard loadID == id else { return }
            switch result {
            case .success(let (loadedSummary, loadedAudit)):
                summary = loadedSummary
                audit = loadedAudit
                loadError = nil
            case .failure(let error):
                audit = []
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func copyExport() {
        let scope = auditConnectionScope
        let workbench = workbench
        Task {
            do {
                let export = try await Task.detached {
                    try workbench.exportRedactedJSON(connectionId: scope, messageLimit: 25, auditLimit: 100)
                }.value
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(export, forType: .string)
                _ = ToastManager.shared.success(L("Redacted activity export copied"))
            } catch {
                _ = ToastManager.shared.error(L("Couldn't export activity"), message: error.localizedDescription)
            }
        }
    }
}

// MARK: - Rows

private struct AutomationHistoryMessageRow: View {
    @Environment(\.theme) private var theme
    let record: AgentChannelAuditRecord
    let channelName: String

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s10) {
            Image(systemName: icon)
                .glyphSize(.caption)
                .foregroundColor(
                    record.status == .failed
                        ? theme.status.error.foreground
                        : AutomationHistoryFeed.isFormAnswer(record)
                            ? theme.status.info.foreground : theme.status.warning.foreground
                )
                .frame(width: 18)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(title)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    StatusChip(channelName, tone: .neutral)
                    if let room = record.roomId, !room.isEmpty {
                        Text(room)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                }
                if !record.redactedSummary.isEmpty {
                    Text(record.redactedSummary)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                }
                if let guidance {
                    Text(guidance)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(record.createdAt.formatted(.relative(presentation: .named)))
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            Button {
                ManagementStateManager.shared.pendingChannelConnectionId = record.connectionId
                AppDelegate.shared?.showManagementWindow(initialTab: .agentChannels)
            } label: {
                Image(systemName: "arrow.up.right.square").glyphSize(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.text.link)
            .help(L("Open \(channelName) settings"))
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.surface)
    }

    private var title: String {
        if AutomationHistoryFeed.isFormAnswer(record) { return L("Form answer") }
        if AutomationHistoryFeed.isUnclaimed(record) { return L("No automation ran") }
        return record.status == .failed ? L("Message failed") : L("Message refused")
    }

    private var icon: String {
        if AutomationHistoryFeed.isFormAnswer(record) { return "text.bubble" }
        if AutomationHistoryFeed.isUnclaimed(record) { return "tray" }
        return record.status == .failed ? "xmark.octagon.fill" : "hand.raised.fill"
    }

    private var guidance: String? {
        if AutomationHistoryFeed.isFormAnswer(record) {
            return AutomationHistoryFeed.formAnswerDetail(reason: record.reason)
        }
        let stage: AgentChannelInboundActivityStage =
            record.status == .failed ? .failed : AutomationHistoryFeed.isUnclaimed(record) ? .dispatchSuppressed : .rejected
        let reason = record.reason ?? record.failureCode
        return AgentChannelInboundActivityPresentation.guidance(stage: stage, reason: reason)
            ?? record.failureMessage ?? reason
    }
}
