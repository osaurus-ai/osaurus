//
//  GuestAccessLedger.swift
//  osaurus
//
//  The one list of guests: people who reach an agent through a guest link
//  (and older direct pairings). It merges the issued links that nobody has
//  used yet with the access keys minted when a link was accepted, so a link
//  and its key never show two different states. Each row names the person
//  when they proved their wallet, where the link was accepted from, its
//  usage, and one Revoke. Sharing → Access shows every agent; the agent's
//  Sharing tab and the Share Agent sheet show one.
//

import SwiftUI

// MARK: - Model

/// One person (or one unused link) that can reach an agent.
struct ConnectionRow: Identifiable, Equatable {
    enum Status: Equatable {
        case active
        case expired
        case revoked
        /// Issued guest link that nobody has accepted yet — no key exists.
        case pending
    }

    /// Who the key belongs to, from the label it was minted with.
    enum Kind: Equatable {
        /// A guest link, or a pairing from before guest links.
        case guest
        /// A workspace teammate (listed under Workspaces, not here).
        case teammate
        /// One of the owner's own devices (listed under Devices, not here).
        case ownDevice
    }

    /// `key-<uuid>` for minted keys, `invite-<nonce>` for pending links.
    let id: String
    let title: String
    let status: Status
    let createdAt: Date?
    let expiresAt: Date?
    /// Key nonce used to attribute inbound Insights rows. `nil` for pending
    /// links (no key minted until acceptance).
    let accessKeyNonce: String?
    /// Revoke target — exactly one of these is set per row.
    let keyId: UUID?
    let inviteNonce: String?
    var kind: Kind = .guest
    /// The wallet the guest proved when accepting the link.
    var verifiedWallet: String? = nil
    /// Where the link was accepted from (the relay edge's view of the client).
    var redeemedFrom: String? = nil
    var agentId: UUID? = nil
    var agentName: String? = nil

    var canRevoke: Bool {
        switch status {
        case .active, .pending: return true
        case .expired, .revoked: return false
        }
    }
}

/// Pure assembly for the guest ledger, free of singletons so the merge and
/// status mapping (revoked → `.revoked`, expired → `.expired`, unaccepted
/// links → `.pending`) stay unit-testable.
enum RemoteConnectionsModel {
    static let teammateLabelPrefix = "Workspace – "

    static func kind(forLabel label: String) -> ConnectionRow.Kind {
        if label.hasPrefix(teammateLabelPrefix) { return .teammate }
        if label.hasPrefix(OwnerDeviceAccess.labelPrefix) { return .ownDevice }
        return .guest
    }

    static func rows(
        keys: [AccessKeyInfo],
        invites: [IssuedInviteRecord],
        peerWallet: (String) -> String? = { _ in nil }
    ) -> [ConnectionRow] {
        var result: [ConnectionRow] = []
        let inviteByKey = Dictionary(
            invites.compactMap { invite in invite.accessKeyId.map { ($0, invite) } },
            uniquingKeysWith: { first, _ in first }
        )

        for key in keys.sorted(by: { $0.createdAt > $1.createdAt }) {
            let status: ConnectionRow.Status
            if key.revoked {
                status = .revoked
            } else if key.isExpired {
                status = .expired
            } else {
                status = .active
            }
            let wallet = peerWallet(key.nonce)
            result.append(
                ConnectionRow(
                    id: "key-\(key.id.uuidString)",
                    title: wallet.map(ParticipantFormatter.shortAddress) ?? key.label,
                    status: status,
                    createdAt: key.createdAt,
                    expiresAt: key.expiresAt,
                    accessKeyNonce: key.nonce,
                    keyId: key.id,
                    inviteNonce: nil,
                    kind: kind(forLabel: key.label),
                    verifiedWallet: wallet,
                    redeemedFrom: inviteByKey[key.id]?.redeemedFrom
                )
            )
        }

        // Unaccepted links: issued, no key yet, not past expiry. Accepted links
        // already appear above as their key.
        for invite in invites
        where invite.displayStatus == .active && invite.accessKeyId == nil {
            result.append(
                ConnectionRow(
                    id: "invite-\(invite.nonce)",
                    title: L("Guest link · \(String(invite.nonce.prefix(8)))…"),
                    status: .pending,
                    createdAt: invite.issuedAt,
                    expiresAt: invite.expirationDate,
                    accessKeyNonce: nil,
                    keyId: nil,
                    inviteNonce: invite.nonce
                )
            )
        }

        return result
    }

    /// Guest rows for `agents`, newest first per agent, tagged with the agent
    /// so a page that lists several can name it.
    @MainActor
    static func guestRows(for agents: [Agent]) -> [ConnectionRow] {
        agents.flatMap { agent -> [ConnectionRow] in
            guard let address = agent.agentAddress else { return [] }
            return rows(
                keys: APIKeyManager.shared.listKeys(forAudience: address),
                invites: AgentInviteStore.list(for: agent.id),
                peerWallet: InvitePeerIdentityStore.wallet(forKeyNonce:)
            )
            .filter { $0.kind == .guest }
            .map { row in
                var row = row
                row.agentId = agent.id
                row.agentName = agent.name
                return row
            }
        }
    }

    /// Revokes the row's key, or the unused link and any key it minted.
    @MainActor
    static func revoke(_ row: ConnectionRow) {
        if let keyId = row.keyId {
            APIKeyManager.shared.revoke(id: keyId)
        } else if let nonce = row.inviteNonce, let agentId = row.agentId {
            if let linkedKeyId = AgentInviteStore.revoke(nonce: nonce, for: agentId) {
                APIKeyManager.shared.revoke(id: linkedKeyId)
            }
        }
    }
}

// MARK: - View

/// The Guests section. `agents` with one element is the per-agent view, which
/// leaves out the agent name on each row.
@MainActor
struct GuestAccessLedger: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var insights = InsightsService.shared

    let agents: [Agent]
    var title: String = "Guests"
    /// Hide revoked and expired rows (the Share Agent sheet only wants live ones).
    var activeOnly: Bool = false
    /// Bumped by a parent that just issued a link, so the list reloads.
    var reloadToken: Int = 0
    /// Called after a revoke, so a parent can drop a link it is showing.
    var onRevoke: ((ConnectionRow) -> Void)? = nil

    @State private var rows: [ConnectionRow] = []
    @State private var revokeConfirm: ConnectionRow?

    private var showsAgentName: Bool { agents.count > 1 }

    private var visibleRows: [ConnectionRow] {
        activeOnly ? rows.filter(\.canRevoke) : rows
    }

    var body: some View {
        SettingsSection(
            title: title,
            caption: visibleRows.isEmpty ? nil : "\(visibleRows.count)"
        ) {
            if visibleRows.isEmpty {
                SettingsEmptyState(
                    inline: "person.crop.circle.badge.questionmark",
                    title: "No guests yet",
                    hint: "Share an agent with a guest link from its Share menu. People who accept one appear here, with their usage and a way to revoke access."
                )
            } else {
                ForEach(visibleRows) { row in
                    guestRow(row)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: insights.totalRequestCount) { _, _ in reload() }
        .onChange(of: agents.map(\.id)) { _, _ in reload() }
        .onChange(of: reloadToken) { _, _ in reload() }
        .themedAlert(
            L("Revoke access?"),
            isPresented: Binding(
                get: { revokeConfirm != nil },
                set: { if !$0 { revokeConfirm = nil } }
            ),
            message: revokeConfirm.map(revokeMessage(for:)) ?? "",
            primaryButton: .destructive(L("Revoke")) {
                if let target = revokeConfirm {
                    RemoteConnectionsModel.revoke(target)
                    onRevoke?(target)
                    reload()
                }
                revokeConfirm = nil
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    private func guestRow(_ row: ConnectionRow) -> some View {
        SettingsRow(
            title: row.title,
            verbatimTitle: true,
            leading: {
                ParticipantAvatar(name: row.title, seed: row.verifiedWallet ?? row.id, diameter: 26)
            },
            description: {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: detailLine(row))
                    if let usage = usageLine(row) {
                        Text(verbatim: usage)
                    }
                }
            },
            trailing: {
                HStack(spacing: theme.space.s8) {
                    statusChip(row.status)
                    if row.accessKeyNonce.map({ !insights.activity(forAccessKeyId: $0).isEmpty }) == true {
                        SettingsIconButton("chart.bar", help: "View this guest's requests in Insights", size: .compact) {
                            viewInInsights(row)
                        }
                    }
                    if row.canRevoke {
                        SettingsButton(.destructive, "Revoke", size: .compact) { revokeConfirm = row }
                    }
                }
            }
        )
    }

    private func detailLine(_ row: ConnectionRow) -> String {
        var parts: [String] = []
        if showsAgentName, let name = row.agentName { parts.append(name) }
        if row.status == .pending {
            parts.append(L("Not accepted yet"))
        } else if row.verifiedWallet != nil {
            parts.append(L("Wallet verified"))
        } else {
            parts.append(L("Identity not verified"))
        }
        if let from = row.redeemedFrom { parts.append(String(format: L("Accepted from %@"), from)) }
        if let created = row.createdAt {
            parts.append(String(format: L("Added %@"), created.formatted(date: .abbreviated, time: .omitted)))
        }
        if let expires = row.expiresAt {
            parts.append(String(format: L("Expires %@"), expires.formatted(date: .abbreviated, time: .omitted)))
        }
        return parts.joined(separator: " · ")
    }

    private func usageLine(_ row: ConnectionRow) -> String? {
        guard let nonce = row.accessKeyNonce else { return nil }
        let activity = insights.activity(forAccessKeyId: nonce)
        guard !activity.isEmpty else { return row.status == .active ? L("No requests yet") : nil }
        var parts = [activity.requestCount == 1 ? L("1 request") : L("\(activity.requestCount) requests")]
        if let last = activity.lastUsed {
            parts.append(String(format: L("Last %@"), last.formatted(.relative(presentation: .named))))
        }
        return parts.joined(separator: " · ")
    }

    private func statusChip(_ status: ConnectionRow.Status) -> some View {
        switch status {
        case .active: StatusChip(L("Active"), tone: .success)
        case .pending: StatusChip(L("Not accepted"), tone: .warning)
        case .expired: StatusChip(L("Expired"), tone: .neutral)
        case .revoked: StatusChip(L("Revoked"), tone: .error)
        }
    }

    private func reload() {
        rows = RemoteConnectionsModel.guestRows(for: agents)
    }

    private func revokeMessage(for row: ConnectionRow) -> String {
        switch row.status {
        case .pending:
            return L("The guest link will stop working. Anyone trying to use it will be turned away.")
        default:
            return L("This guest loses access immediately. Their open chats show “Access revoked”.")
        }
    }

    private func viewInInsights(_ row: ConnectionRow) {
        if let nonce = row.accessKeyNonce {
            _ = InsightsService.shared.focus(accessKeyId: nonce)
        }
        ManagementStateManager.shared.selectedTab = .insights
    }
}
