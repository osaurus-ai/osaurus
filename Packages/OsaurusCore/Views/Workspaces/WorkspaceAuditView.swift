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
        AgentDetailSection(
            title: L("Audit trail"),
            icon: "list.bullet.clipboard.fill",
            subtitle: records.isEmpty ? nil : "\(records.count)",
            trailing: { headerActions }
        ) {
            if records.isEmpty {
                AgentSectionEmptyState(
                    icon: "list.bullet.clipboard",
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
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
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
                        withAnimation(.easeOut(duration: 0.15)) { showAll.toggle() }
                    } label: {
                        Text(
                            showAll
                                ? L("Show fewer")
                                : String(format: L("Show all %d events"), filtered.count)
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(
                "Recorded by this Mac only. Actions other members take on osaurus.ai appear here once their effect reaches this host. The chain is tamper-evident: Verify recomputes every hash.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
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
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Verify", bundle: .module)
                }
            }
            .buttonStyle(SecondaryButtonStyle(isLoading: isVerifying, size: .compact))
            .disabled(records.isEmpty || isVerifying)
            .help(L("Recompute every hash in the chain and check the head marker"))

            Button {
                Task { await export() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Export", bundle: .module)
                }
            }
            .buttonStyle(SecondaryButtonStyle(isLoading: isExporting, size: .compact))
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
        let selected = filter == category
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                filter = category
                showAll = false
            }
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                .foregroundColor(selected ? theme.accentColor : theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        selected ? theme.accentColor.opacity(0.14) : theme.tertiaryBackground.opacity(0.5)
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func verificationRow(_ verification: WorkspaceAuditVerification) -> some View {
        HStack(spacing: 8) {
            Image(systemName: verification.isIntact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(verification.isIntact ? theme.successColor : theme.errorColor)
            Text(verificationText(verification))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill((verification.isIntact ? theme.successColor : theme.errorColor).opacity(0.08))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(record.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 10.5))
                .foregroundColor(theme.tertiaryText)
                .monospacedDigit()
        }
        .padding(.vertical, 7)
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
            return String(format: L("You changed which pool %@ bills"), agentLabel)
        case .poolTopUp:
            return String(
                format: L("You added %@ to the pool"),
                record.details["amount_micro"].map(OsaurusRouter.formatMicroAsCredits) ?? L("credits")
            )
        case .poolAutoReloadChanged:
            return record.details["enabled"] == "true"
                ? L("You turned on pool auto-reload")
                : L("You turned off pool auto-reload")
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
        case .memberRoleChanged:
            if let previous = record.details["previous_role"] {
                parts.append(String(format: L("was %@"), previous))
            }
        case .billingPreferenceChanged:
            if let bills = record.details["bills_workspace"] {
                parts.append(bills == "none" ? L("now personal credits") : L("now the workspace pool"))
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
            case .runFinished: return record.details["success"] == "true" ? "checkmark.circle.fill" : "xmark.circle"
            default: return "play.circle.fill"
            }
        case .denials:
            return "hand.raised.fill"
        case .administration:
            return "person.badge.key.fill"
        }
    }

    private var tint: Color {
        switch record.event.category {
        case .denials: return theme.errorColor
        case .runs:
            if record.event == .runFinished, record.details["success"] != "true" { return theme.warningColor }
            return theme.accentColor
        case .access: return record.event == .keyRevoked ? theme.warningColor : theme.successColor
        case .administration: return theme.secondaryText
        }
    }
}
