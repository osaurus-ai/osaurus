//
//  WorkspaceAuditView.swift
//  osaurus
//
//  Audit trail card for one workspace: the host-side, hash-chained record of
//  teammate access grants/denials, runs against this Mac's shared agents,
//  owner Stop actions, and the owner's own administrative actions taken from
//  this app. Reverse-chronological, filterable by category, with Verify
//  (walks the chain) and Export (reveals the JSONL in Finder).
//

import AppKit
import SwiftUI

struct WorkspaceAuditCard: View {
    @Environment(\.theme) private var theme

    let workspaceId: String

    @State private var records: [WorkspaceAuditRecord] = []
    @State private var filter: WorkspaceAuditEventKind.Category?
    @State private var verification: WorkspaceAuditVerification?
    @State private var isVerifying = false
    @State private var isExporting = false
    @State private var exportNote: String?
    @State private var showAll = false
    @State private var observerId: UUID?

    private static let collapsedLimit = 12

    private var filtered: [WorkspaceAuditRecord] {
        let sorted = records.sorted { $0.seq > $1.seq }
        guard let filter else { return sorted }
        return sorted.filter { $0.event.category == filter }
    }

    private var visible: [WorkspaceAuditRecord] {
        showAll ? filtered : Array(filtered.prefix(Self.collapsedLimit))
    }

    var body: some View {
        SettingsSection(
            title: "Audit (this Mac)",
            caption: records.isEmpty ? nil : "\(records.count)",
            anchorId: "workspaces.audit",
            accessory: { headerActions }
        ) {
            if records.isEmpty {
                SettingsEmptyState(
                    inline: "list.bullet.clipboard",
                    title: "No audit events recorded on this Mac yet",
                    hint: "Teammate access, runs on your shared agents, and your own workspace actions are recorded here."
                )
            } else {
                filterRow

                if let verification {
                    verificationRow(verification)
                }

                if let exportNote {
                    Text(exportNote)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { record in
                        WorkspaceAuditRow(record: record)
                        if record.id != visible.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }

                if filtered.count > Self.collapsedLimit {
                    Button {
                        withAnimation(theme.motion.quick) { showAll.toggle() }
                    } label: {
                        Text(
                            showAll
                                ? L("Show fewer")
                                : String(format: L("Show all %d events"), filtered.count)
                        )
                        .textStyle(.footnote, weight: 500)
                        .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(
                "Recorded by this Mac only. Actions other members take on osaurus.ai appear here once their effect reaches this host. The chain is tamper-evident: Verify recomputes every hash.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: workspaceId) {
            await reload()
            let id = await WorkspaceAuditLog.shared.addObserver { changed in
                guard changed == workspaceId else { return }
                Task { @MainActor in await reload() }
            }
            observerId = id
        }
        .onDisappear {
            if let observerId {
                Task { await WorkspaceAuditLog.shared.removeObserver(observerId) }
            }
        }
    }

    // MARK: - Pieces

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await verify() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield")
                        .glyphSize(10.5, weight: .semibold)
                    Text("Verify", bundle: .module)
                }
            }
            .assignedSettingsButtonStyle(.secondary, isLoading: isVerifying, size: .compact)
            .disabled(records.isEmpty || isVerifying)
            .help(L("Recompute every hash in the chain and check the head marker"))

            Button {
                Task { await export() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .glyphSize(10.5, weight: .semibold)
                    Text("Export", bundle: .module)
                }
            }
            .assignedSettingsButtonStyle(.secondary, isLoading: isExporting, size: .compact)
            .disabled(records.isEmpty || isExporting)
            .help(L("Reveal the audit log file (JSON Lines) in Finder"))
        }
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            filterChip(nil, label: L("All"))
            ForEach(WorkspaceAuditEventKind.Category.allCases, id: \.self) { category in
                filterChip(category, label: Self.label(for: category))
            }
            Spacer(minLength: 0)
        }
    }

    private func filterChip(_ category: WorkspaceAuditEventKind.Category?, label: String) -> some View {
        FilterChip(label, isSelected: filter == category) {
            withAnimation(theme.motion.quick) {
                filter = category
                showAll = false
            }
        }
    }

    private func verificationRow(_ verification: WorkspaceAuditVerification) -> some View {
        HStack(spacing: 8) {
            Image(systemName: verification.isIntact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .glyphSize(12, weight: .semibold)
                .foregroundColor(
                    verification.isIntact ? theme.status.success.foreground : theme.status.error.foreground
                )
            Text(verificationText(verification))
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(
                    (verification.isIntact ? theme.status.success.foreground : theme.status.error.foreground).opacity(
                        0.08
                    )
                )
        )
    }

    private func verificationText(_ verification: WorkspaceAuditVerification) -> String {
        if verification.isIntact {
            return String(format: L("Chain intact: %d records verified."), verification.recordCount)
        }
        let first = verification.problems.first.map(Self.describe) ?? ""
        return String(
            format: L("Chain broken: %d problem(s). First: %@"),
            verification.problems.count, first
        )
    }

    // MARK: - Actions

    @MainActor
    private func reload() async {
        records = await WorkspaceAuditLog.shared.records(workspaceId: workspaceId)
        // A stale verdict would be misleading after new rows land.
        verification = nil
    }

    @MainActor
    private func verify() async {
        isVerifying = true
        defer { isVerifying = false }
        verification = await WorkspaceAuditLog.shared.verify(workspaceId: workspaceId)
    }

    @MainActor
    private func export() async {
        isExporting = true
        defer { isExporting = false }
        guard let url = await WorkspaceAuditLog.shared.exportURL(workspaceId: workspaceId) else {
            exportNote = L("Nothing to export yet.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        exportNote = String(format: L("Revealed %@ in Finder."), url.lastPathComponent)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            exportNote = nil
        }
    }

    // MARK: - Labels

    static func label(for category: WorkspaceAuditEventKind.Category) -> String {
        switch category {
        case .access: return L("Access")
        case .runs: return L("Runs")
        case .approvals: return L("Approvals")
        case .denials: return L("Denials")
        case .administration: return L("Admin")
        }
    }

    static func describe(_ problem: WorkspaceAuditVerification.Problem) -> String {
        switch problem {
        case .malformedLine(let line):
            return String(format: L("line %d is not a valid record"), line)
        case .sequenceGap(let seq, let expected):
            return String(format: L("record %d found where %d was expected"), seq, expected)
        case .brokenLink(let seq):
            return String(format: L("record %d does not link to the previous record"), seq)
        case .hashMismatch(let seq):
            return String(format: L("record %d was modified after it was written"), seq)
        case .headMismatch(let expectedSeq, let actualSeq):
            return String(
                format: L("head marker says %d records but the log ends at %d"), expectedSeq, actualSeq
            )
        }
    }
}

// MARK: - Row

struct WorkspaceAuditRow: View {
    @Environment(\.theme) private var theme
    let record: WorkspaceAuditRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .glyphSize(11, weight: .semibold)
                .foregroundColor(tint)
                .frame(width: 16, alignment: .center)
                .padding(.top, theme.space.s2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(record.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, theme.space.s8)
        .help(String(format: L("#%d · %@"), record.seq, record.event.rawValue))
    }

    private var actorLabel: String {
        guard let actor = record.actor else { return L("Someone") }
        if actor.isSelf { return L("You") }
        if let name = actor.name, !name.isEmpty { return name }
        if let wallet = actor.wallet, !wallet.isEmpty {
            return OsaurusRouterWorkspacePerson.shortWallet(wallet)
        }
        return L("A teammate")
    }

    /// The teammate or remote agent an approval or owner message was about.
    private var callerLabel: String {
        if let name = record.details["caller_agent_name"] {
            let address = record.details["caller_agent_address"].map(OsaurusRouterWorkspacePerson.shortWallet)
            return [name, address].compactMap { $0 }.joined(separator: " · ")
        }
        if let handle = record.details["caller_handle"] { return handle }
        if record.event == .approvalRequested { return actorLabel }
        if let wallet = record.details["caller_wallet"] { return OsaurusRouterWorkspacePerson.shortWallet(wallet) }
        return L("a teammate")
    }

    private var agentLabel: String {
        if let name = record.agentName, !name.isEmpty { return name }
        if let address = record.agentAddress, !address.isEmpty {
            return OsaurusRouterWorkspacePerson.shortWallet(address)
        }
        return L("an agent")
    }

    private var title: String {
        switch record.event {
        case .attestationGranted:
            return String(format: L("%@ connected to %@"), actorLabel, agentLabel)
        case .attestationDenied:
            return String(format: L("%@ was refused access to %@"), actorLabel, agentLabel)
        case .keyMinted:
            return String(format: L("Access key issued to %@ for %@"), actorLabel, agentLabel)
        case .keyRevoked:
            return String(format: L("Access key for %@ revoked (%@)"), actorLabel, agentLabel)
        case .runStarted:
            return String(format: L("%@ started a run on %@"), actorLabel, agentLabel)
        case .runFinished:
            let ok = record.details["success"] == "true"
            return String(
                format: ok ? L("%@ finished a run on %@") : L("%@'s run on %@ ended early"),
                actorLabel, agentLabel
            )
        case .runStoppedByOwner:
            return String(format: L("You stopped a teammate's run on %@"), agentLabel)
        case .runRejected:
            return String(format: L("%@'s run on %@ was rejected"), actorLabel, agentLabel)
        case .scopeDenied:
            return String(format: L("%@ was blocked from %@"), actorLabel, record.target ?? "")
        case .taskCancelled:
            return String(format: L("%@ cancelled a background task"), actorLabel)
        case .outboundRunStarted:
            return String(format: L("You started a run on %@"), agentLabel)
        case .outboundRunFinished:
            let ok = record.details["success"] == "true"
            return String(
                format: ok ? L("Your run on %@ finished") : L("Your run on %@ ended early"),
                agentLabel
            )
        case .outboundRunRefused:
            return String(format: L("Your run on %@ was refused"), agentLabel)
        case .approvalRequested:
            return String(
                format: L("%@ asked to use %@ on %@"), callerLabel, record.details["tool"] ?? L("a tool"), agentLabel
            )
        case .approvalGranted:
            return String(
                format: record.details["scope"] == "conversation"
                    ? L("You allowed %@ on %@ for the conversation") : L("You allowed %@ on %@"),
                record.details["tool"] ?? L("a tool"), agentLabel
            )
        case .approvalDenied:
            return String(format: L("You denied %@ on %@"), record.details["tool"] ?? L("a tool"), agentLabel)
        case .approvalTimedOut:
            return String(
                format: L("No answer to %@ on %@ in time"), record.details["tool"] ?? L("a tool"), agentLabel
            )
        case .participantMessage:
            return String(format: L("You wrote in %@'s conversation with %@"), callerLabel, agentLabel)
        case .workflowRunStarted:
            return String(
                format: L("%@ ran the workflow %@ through %@"), actorLabel, record.details["workflow"] ?? "",
                agentLabel)
        case .workflowRunFinished:
            if record.details["status"] == WorkflowRunStatus.awaitingUser.rawValue {
                return String(
                    format: L("%@'s run of %@ is waiting for your answer"), actorLabel,
                    record.details["workflow"] ?? "")
            }
            let ok = record.details["success"] == "true"
            return String(
                format: ok ? L("%@'s run of %@ finished") : L("%@'s run of %@ ended early"),
                actorLabel, record.details["workflow"] ?? "")
        case .workflowRunRefused:
            return String(
                format: L("%@ was refused the workflow %@"), actorLabel, record.details["workflow"] ?? "")
        case .workspaceCreated:
            return L("You created this workspace")
        case .workspaceRenamed:
            return String(format: L("You renamed the workspace to “%@”"), record.details["name"] ?? "")
        case .workspaceDeleted:
            return L("You deleted this workspace")
        case .workspaceReactivated:
            return L("You reactivated this workspace")
        case .workspaceLeft:
            return L("You left this workspace")
        case .inviteCreated:
            return String(format: L("You created a %@ invite link"), record.details["role"] ?? L("member"))
        case .inviteRevoked:
            return L("You revoked an invite link")
        case .memberRemoved:
            return String(
                format: L("You removed %@"),
                record.details["wallet"].map(OsaurusRouterWorkspacePerson.shortWallet) ?? L("a member")
            )
        case .memberRoleChanged:
            return String(format: L("You changed a member's role to %@"), record.details["role"] ?? "")
        case .agentShared:
            return String(format: L("You shared %@ with the workspace"), agentLabel)
        case .agentUnshared:
            return String(format: L("You unshared %@"), agentLabel)
        case .joinRedeemed:
            return L("You joined this workspace")
        case .billingPreferenceChanged:
            return String(format: L("You changed who pays for %@"), agentLabel)
        case .poolTopUp:
            return String(
                format: L("You added %@ to workspace credits"),
                record.details["amount_micro"].map(OsaurusRouter.formatMicroAsCredits) ?? L("credits")
            )
        case .poolAutoReloadChanged:
            return record.details["enabled"] == "true"
                ? L("You turned on auto-reload for workspace credits")
                : L("You turned off auto-reload for workspace credits")
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let role = record.actor?.role, record.actor?.isSelf != true {
            parts.append(role.capitalized)
        }
        switch record.event {
        case .runStarted, .runFinished:
            if let model = record.details["model"], !model.isEmpty { parts.append(model) }
            if let tools = record.details["tools"], !tools.isEmpty {
                parts.append(String(format: L("tools: %@"), tools.replacingOccurrences(of: ",", with: ", ")))
            }
            if record.event == .runFinished, let summary = record.details["summary"] {
                parts.append(summary)
            }
        case .attestationDenied, .runRejected, .keyRevoked:
            if let reason = record.details["reason"] {
                parts.append(reason.replacingOccurrences(of: "_", with: " "))
            }
            if let detail = record.details["detail"] { parts.append(detail) }
        case .scopeDenied:
            parts.append(L("outside this key's allowed routes"))
        case .approvalRequested, .approvalGranted, .approvalDenied, .approvalTimedOut:
            if record.event != .approvalRequested { parts.append(String(format: L("for %@"), callerLabel)) }
            if let surface = record.details["surface"].flatMap(AttentionSurface.init(rawValue:)) {
                parts.append(surface.displayName)
            }
            if let wait = record.details["wait_ms"].flatMap(Int.init) {
                parts.append(String(format: L("after %ds"), wait / 1000))
            }
        case .outboundRunStarted, .outboundRunFinished, .outboundRunRefused:
            if let source = record.details["source"], !source.isEmpty {
                parts.append(source.replacingOccurrences(of: "_", with: " "))
            }
            if let reason = record.details["reason"], !reason.isEmpty { parts.append(reason) }
            if record.event == .outboundRunFinished, let summary = record.details["summary"], !summary.isEmpty {
                parts.append(summary)
            }
        case .workflowRunFinished:
            if let status = record.details["status"] { parts.append(status.replacingOccurrences(of: "_", with: " ")) }
        case .workflowRunRefused:
            if let reason = record.details["reason"] { parts.append(reason.replacingOccurrences(of: "_", with: " ")) }
        case .memberRoleChanged:
            if let previous = record.details["previous_role"] {
                parts.append(String(format: L("was %@"), previous))
            }
        case .billingPreferenceChanged:
            if let bills = record.details["bills_workspace"] {
                parts.append(bills == "none" ? L("now personal credits") : L("now workspace credits"))
            }
        case .poolAutoReloadChanged:
            if record.details["enabled"] == "true",
                let threshold = record.details["threshold_micro"],
                let amount = record.details["amount_micro"]
            {
                parts.append(
                    String(
                        format: L("below %@, reload %@"),
                        OsaurusRouter.formatMicroUSD(threshold), OsaurusRouter.formatMicroUSD(amount)
                    )
                )
            }
        default:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var icon: String {
        switch record.event.category {
        case .access:
            return record.event == .keyRevoked ? "key.slash" : "key.fill"
        case .runs:
            switch record.event {
            case .runStoppedByOwner, .taskCancelled: return "stop.circle.fill"
            case .runFinished, .outboundRunFinished, .workflowRunFinished:
                return record.details["success"] == "true" ? "checkmark.circle.fill" : "xmark.circle"
            case .outboundRunStarted: return "arrow.up.right.circle.fill"
            default: return "play.circle.fill"
            }
        case .denials:
            return "hand.raised.fill"
        case .approvals:
            switch record.event {
            case .approvalGranted: return "checkmark.shield.fill"
            case .approvalDenied: return "xmark.shield.fill"
            case .approvalTimedOut: return "clock.badge.xmark"
            case .participantMessage: return "text.bubble.fill"
            default: return "hand.raised.square.fill"
            }
        case .administration:
            return "person.badge.key.fill"
        }
    }

    private var tint: Color {
        switch record.event.category {
        case .denials: return theme.status.error.foreground
        case .runs:
            if record.event == .runFinished || record.event == .outboundRunFinished
                || record.event == .workflowRunFinished,
                record.details["success"] != "true"
            {
                return theme.status.warning.foreground
            }
            return theme.action.primary.default.background
        case .access:
            return record.event == .keyRevoked ? theme.status.warning.foreground : theme.status.success.foreground
        case .approvals:
            switch record.event {
            case .approvalGranted: return theme.status.success.foreground
            case .approvalDenied, .approvalTimedOut: return theme.status.warning.foreground
            default: return theme.action.primary.default.background
            }
        case .administration: return theme.text.secondary
        }
    }
}
