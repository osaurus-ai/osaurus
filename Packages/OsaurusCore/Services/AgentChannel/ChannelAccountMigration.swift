//
//  ChannelAccountMigration.swift
//  osaurus
//
//  Once, at launch before events load: the extra Slack workspaces and Email
//  accounts that used to share their channel's one connection become
//  connections of their own (`slack-<team>`, `email-<account>`).
//
//  - Each Slack workspace in `slack.json` `workspaceAccounts` gets its own
//    `slack-<team>.json` with its lists and the primary's switches.
//  - `email.json` is saved once more, so every account carries its own
//    copy of the old shared settings and its connection id.
//  - Stored messages, cursors, audit rows, outbound intents and seen events
//    of a moved account follow it to its id.
//  - A channel trigger on `slack` or `email` is split by the rooms it
//    names; one with no rooms ("any room") is copied for each moved account.
//  - Slack bindings to a moved workspace's channels point at its id.
//
//  The files it changes are copied to `backups/channel-accounts-<time>/`
//  first, and a marker keeps it from running twice.
//

import Foundation

enum ChannelAccountMigration {
    static let markerFileName = "channel-accounts-migration.json"

    /// Stored rows still to move: the message store may not open at launch
    /// (its key not resident yet); later launches finish the job.
    struct RowMove: Codable, Equatable {
        var from: String
        var to: String
        var roomIds: [String]
        var roomPrefixes: [String]
        var eventIdPrefixes: [String]
    }

    struct Report: Codable, Equatable {
        var slackWorkspaces: [String] = []
        var emailAccounts: [String] = []
        var movedRows = 0
        var splitTriggers = 0
        var copiedTriggers = 0
        var repointedBindings = 0
        var backupPath: String?
        var pendingRowMoves: [RowMove] = []
        var migratedAt = Date()
    }

    /// A moved account: its new id and how to tell its rooms apart.
    struct MovedAccount: Equatable {
        var kind: AgentChannelKind
        var connectionId: String
        var name: String
        var roomIds: Set<String>
        var roomPrefix: String?
        var eventIdPrefix: String?

        func owns(_ roomId: String) -> Bool {
            roomIds.contains(roomId) || roomPrefix.map { roomId.hasPrefix($0) } == true
        }
    }

    static func markerURL() -> URL {
        OsaurusPaths.config().appendingPathComponent(markerFileName)
    }

    /// Runs on the event ledger queue at launch, before events load.
    @discardableResult
    static func runIfNeeded(
        messageStore: AgentChannelMessageStore? = .shared, now: Date = Date()
    ) -> Report? {
        let fm = FileManager.default
        if fm.fileExists(atPath: markerURL().path) {
            finishPendingRowMoves(messageStore: messageStore)
            return nil
        }

        let slackPrimary = SlackConnectionConfigurationStore.load(connectionId: AgentChannelConnection.nativeSlackConnectionId)
        let email = EmailChannelConfigurationStore.load()
        let moved = movedAccounts(slack: slackPrimary, email: email)

        var report = Report(migratedAt: now)
        if !moved.isEmpty {
            report.backupPath = backup(now: now)?.path
        }

        // Settings
        if !slackPrimary.workspaceAccounts.isEmpty {
            var primary = slackPrimary
            for workspace in slackPrimary.workspaceAccounts {
                let id = ChannelAccounts.connectionId(slackTeamId: workspace.teamId)
                let config = SlackConnectionConfiguration(
                    configuredTeamIds: [workspace.teamId],
                    readableChannelIds: workspace.readableChannelIds,
                    writableChannelIds: workspace.writableChannelIds,
                    senderAllowlist: workspace.senderAllowlist,
                    writeEnabled: slackPrimary.writeEnabled,
                    defaultReadLimit: slackPrimary.defaultReadLimit,
                    allowBroadcastMentions: slackPrimary.allowBroadcastMentions,
                    botUserId: workspace.botUserId,
                    botId: workspace.botId,
                    apiAppId: workspace.apiAppId,
                    workspaceName: workspace.teamName,
                    acceptAppPostsFromAllowlistedSenders: slackPrimary.acceptAppPostsFromAllowlistedSenders)
                do {
                    try SlackConnectionConfigurationStore.save(config, connectionId: id)
                    report.slackWorkspaces.append(id)
                } catch {
                    print("[Osaurus] Channel account migration could not save \(id): \(error)")
                    return nil
                }
                primary.configuredTeamIds.removeAll { $0 == workspace.teamId }
            }
            primary.workspaceAccounts = []
            do {
                try SlackConnectionConfigurationStore.save(
                    primary, connectionId: AgentChannelConnection.nativeSlackConnectionId)
            } catch {
                print("[Osaurus] Channel account migration could not save slack.json: \(error)")
                return nil
            }
        }
        if fm.fileExists(atPath: EmailChannelConfigurationStore.configurationFileURL().path) {
            try? EmailChannelConfigurationStore.save(email)
        }
        report.emailAccounts = moved.filter { $0.kind == .email }.map(\.connectionId)

        // Stored rows
        let rowMoves: [RowMove] = moved.compactMap { account in
            ChannelAccounts.primaryConnectionId(account.kind).map { from in
                RowMove(
                    from: from, to: account.connectionId, roomIds: account.roomIds.sorted(),
                    roomPrefixes: account.roomPrefix.map { [$0] } ?? [],
                    eventIdPrefixes: account.eventIdPrefix.map { [$0] } ?? [])
            }
        }
        let rows = apply(rowMoves, messageStore: messageStore)
        report.movedRows = rows.moved
        report.pendingRowMoves = rows.pending

        // Triggers
        if !moved.isEmpty {
            let result = splitTriggers(EventStore.loadAll(), moved: moved, now: now)
            for event in result.saved { EventStore.save(event) }
            report.splitTriggers = result.split
            report.copiedTriggers = result.copied
        }

        // Bindings
        let slackMoved = moved.filter { $0.kind == .slack }
        if !slackMoved.isEmpty {
            var configuration = AgentChannelConfigurationStore.load()
            var changed = 0
            configuration.bindings = configuration.bindings.map { binding in
                guard binding.connectionId.lowercased() == AgentChannelConnection.nativeSlackConnectionId,
                    let account = slackMoved.first(where: { $0.owns(binding.roomId) })
                else { return binding }
                var repointed = binding
                repointed.connectionId = account.connectionId
                changed += 1
                return repointed
            }
            if changed > 0, (try? AgentChannelConfigurationStore.save(configuration)) != nil {
                report.repointedBindings = changed
            }
        }

        writeMarker(report)
        if !moved.isEmpty {
            print(
                "[Osaurus] Channel accounts: \(moved.count) account(s) moved to their own connections, \(report.movedRows) stored row(s) reassigned"
            )
        }
        return report
    }

    // MARK: - Rows

    private static func apply(_ moves: [RowMove], messageStore: AgentChannelMessageStore?)
        -> (moved: Int, pending: [RowMove])
    {
        guard !moves.isEmpty else { return (0, []) }
        guard let messageStore, (try? messageStore.openIfNeeded()) != nil else { return (0, moves) }
        var moved = 0
        var pending: [RowMove] = []
        for move in moves {
            do {
                moved += try messageStore.reassign(
                    from: move.from, to: move.to, roomIds: move.roomIds, roomPrefixes: move.roomPrefixes,
                    eventIdPrefixes: move.eventIdPrefixes)
            } catch {
                pending.append(move)
            }
        }
        return (moved, pending)
    }

    private static func finishPendingRowMoves(messageStore: AgentChannelMessageStore?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: markerURL()),
            var report = try? decoder.decode(Report.self, from: data),
            !report.pendingRowMoves.isEmpty
        else { return }
        let rows = apply(report.pendingRowMoves, messageStore: messageStore)
        guard rows.pending != report.pendingRowMoves else { return }
        report.movedRows += rows.moved
        report.pendingRowMoves = rows.pending
        writeMarker(report)
    }

    // MARK: - Plan

    static func movedAccounts(
        slack: SlackConnectionConfiguration, email: EmailChannelConfiguration
    ) -> [MovedAccount] {
        var moved: [MovedAccount] = slack.workspaceAccounts.map { workspace in
            MovedAccount(
                kind: .slack,
                connectionId: ChannelAccounts.connectionId(slackTeamId: workspace.teamId),
                name: workspace.teamName ?? workspace.teamId,
                roomIds: Set(workspace.readableChannelIds + workspace.writableChannelIds))
        }
        for account in email.accounts where account.channelConnectionId != AgentChannelConnection.nativeEmailConnectionId {
            moved.append(
                MovedAccount(
                    kind: .email,
                    connectionId: account.channelConnectionId,
                    name: account.name.isEmpty ? account.connectionId : account.name,
                    roomIds: [],
                    roomPrefix: account.connectionId + "/",
                    eventIdPrefix: "email:\(account.connectionId):"))
        }
        return moved
    }

    /// Splits each `slack`/`email` channel trigger by the accounts its rooms
    /// belong to; a trigger without rooms is copied to every moved account
    /// of its kind. Returns the events to save.
    static func splitTriggers(_ events: [OsaurusEvent], moved: [MovedAccount], now: Date)
        -> (saved: [OsaurusEvent], split: Int, copied: Int)
    {
        var saved: [OsaurusEvent] = []
        var split = 0
        var copied = 0
        for event in events {
            guard let source = event.source.channelMessage,
                source.connectionId.lowercased() == ChannelAccounts.primaryConnectionId(source.kind)
            else { continue }
            let accounts = moved.filter { $0.kind == source.kind }
            guard !accounts.isEmpty else { continue }

            if source.roomIds.isEmpty {
                for account in accounts {
                    saved.append(copy(event, connectionId: account.connectionId, roomIds: [], account: account, now: now))
                    copied += 1
                }
                continue
            }
            var remaining: [String] = []
            var byAccount: [(MovedAccount, [String])] = []
            for room in source.roomIds {
                if let account = accounts.first(where: { $0.owns(room) }) {
                    if let index = byAccount.firstIndex(where: { $0.0 == account }) {
                        byAccount[index].1.append(room)
                    } else {
                        byAccount.append((account, [room]))
                    }
                } else {
                    remaining.append(room)
                }
            }
            guard !byAccount.isEmpty else { continue }
            if remaining.isEmpty, byAccount.count == 1 {
                // Every room is one moved account's: the trigger moves whole.
                var whole = event
                var moved = source
                moved.connectionId = byAccount[0].0.connectionId
                whole.source = .channelMessage(moved)
                whole.updatedAt = now
                saved.append(whole)
                split += 1
                continue
            }
            var kept = event
            var keptSource = source
            keptSource.roomIds = remaining
            kept.source = .channelMessage(keptSource)
            kept.updatedAt = now
            for (index, part) in byAccount.enumerated() {
                if remaining.isEmpty, index == 0 {
                    // The original keeps its id for the first account.
                    var first = event
                    var firstSource = source
                    firstSource.connectionId = part.0.connectionId
                    firstSource.roomIds = part.1
                    first.source = .channelMessage(firstSource)
                    first.updatedAt = now
                    saved.append(first)
                } else {
                    saved.append(copy(event, connectionId: part.0.connectionId, roomIds: part.1, account: part.0, now: now))
                }
            }
            if !remaining.isEmpty { saved.append(kept) }
            split += 1
        }
        return (saved, split, copied)
    }

    private static func copy(
        _ event: OsaurusEvent, connectionId: String, roomIds: [String], account: MovedAccount, now: Date
    ) -> OsaurusEvent {
        var source = event.source.channelMessage
        source?.connectionId = connectionId
        source?.roomIds = roomIds
        return OsaurusEvent(
            name: "\(event.name) (\(account.name))",
            isEnabled: event.isEnabled,
            source: source.map { .channelMessage($0) } ?? event.source,
            filter: event.filter,
            action: event.action,
            delivery: event.delivery,
            reply: event.reply,
            parameters: event.parameters,
            createdAt: now,
            updatedAt: now)
    }

    // MARK: - Files

    private static func backup(now: Date) -> URL? {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = OsaurusPaths.root()
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("channel-accounts-\(formatter.string(from: now))", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let files = [
                SlackConnectionConfigurationStore.configurationFileURL(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId),
                EmailChannelConfigurationStore.configurationFileURL(),
                AgentChannelConfigurationStore.configurationFileURL(),
            ]
            for file in files where fm.fileExists(atPath: file.path) {
                try? fm.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
            }
            let events = OsaurusPaths.events()
            if fm.fileExists(atPath: events.path) {
                try? fm.copyItem(at: events, to: dir.appendingPathComponent("events", isDirectory: true))
            }
            return dir
        } catch {
            print("[Osaurus] Channel account migration could not write its backup: \(error)")
            return nil
        }
    }

    private static func writeMarker(_ report: Report) {
        let url = markerURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(report).write(to: url, options: [.atomic])
    }
}
