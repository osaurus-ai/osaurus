//
//  ConfigChannelAccounts.swift
//  osaurus
//
//  `channels.<platform>.accounts[]`: a platform's extra accounts (bots,
//  workspaces, mail accounts). Each entry edits the account whose
//  connection id it names, with the same fields as the platform section.
//  Accounts with tokens are added in Settings → Channels; an Email entry
//  may add an account for a mail account that already exists.
//

import Foundation

@MainActor
enum ConfigChannelAccounts {
    /// Whether the target names an account that exists, or (Email) one
    /// apply can add for an existing mail account.
    static func isKnown(_ target: ConfigChannelTarget) -> Bool {
        if target.isPrimary { return true }
        if ChannelAccounts.account(connectionId: target.connectionId)?.kind == target.platform.kind { return true }
        guard target.platform == .email, let source = mailSourceId(forEmailConnectionId: target.connectionId)
        else { return false }
        return EmailChannelConfigurationStore.load().account(connectionId: source) == nil
    }

    /// The mail account an `email-<mail account id>` connection id names.
    static func mailSourceId(forEmailConnectionId connectionId: String) -> String? {
        let prefix = ChannelAccounts.extraPrefix(.email)
        guard connectionId.hasPrefix(prefix) else { return nil }
        let suffix = String(connectionId.dropFirst(prefix.count))
        return SourceConnectionStore.shared.connections(of: [.mailApp, .imap])
            .first { $0.id.lowercased() == suffix }?.id
    }

    static func unknownAccountIssue(_ target: ConfigChannelTarget) -> String {
        if target.platform == .email {
            return "\(target.path): no Email account with this id. Use `email-<mail account id>` for a Mail app "
                + "or IMAP account added in Settings that no other Email account watches."
        }
        return "\(target.path): no \(target.platform.kind.displayName) account with this id. Add the account in "
            + "Settings → Channels, then use the id agent_channel_list_connections shows."
    }

    /// Issues for every `accounts` list in the document.
    static func validate(_ channels: ChannelsSection, into issues: inout [String]) {
        for platform in ConfigChannelPlatform.allCases {
            guard let accounts = platform.section(in: channels)?.accounts else { continue }
            let base = "channels.\(platform.rawValue).accounts"
            guard platform != .imessage && platform != .whatsapp else {
                issues.append("\(base): \(platform.kind.displayName) has one account.")
                continue
            }
            var seen = Set<String>()
            for (index, account) in accounts.enumerated() {
                guard let raw = account.id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    issues.append("\(base)[\(index)].id: every account needs the connection id it edits.")
                    continue
                }
                let id = AgentChannelConnection.normalizedId(raw).lowercased()
                let label = "\(base)[\(raw)]"
                if id == platform.primaryConnectionId {
                    issues.append("\(label): `\(raw)` is the primary account — set it on `channels.\(platform.rawValue)`.")
                    continue
                }
                if !seen.insert(id).inserted {
                    issues.append("\(label): listed twice.")
                }
                if account.accounts != nil {
                    issues.append("\(label).accounts: accounts don't nest.")
                }
                if account.botTokenRef != nil || account.appTokenRef != nil {
                    issues.append(
                        "\(label): tokens for an extra account are added in Settings → Channels, not from config.")
                }
                if account.hasLegacyInbound {
                    issues.append("\(label): use `routing` to say who answers on this account.")
                }
            }
        }
    }
}
