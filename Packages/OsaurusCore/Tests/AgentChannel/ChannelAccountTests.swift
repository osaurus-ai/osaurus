//
//  ChannelAccountTests.swift
//  osaurusTests
//
//  One channel connection per account: ids, the derived registry, each
//  account's own settings and service, removal, the one-shot migration of
//  Slack workspaces and Email accounts, and `channels.<p>.accounts[]`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Channel accounts", .serialized)
struct ChannelAccountTests {

    // MARK: - Ids

    @Test func thePrimaryKeepsTheChannelIdAndExtrasArePrefixed() {
        let primary = SignInSession(service: .channel(.discord), name: "Main", isPrimary: true)
        let extra = SignInSession(service: .channel(.telegram), name: "Support bot")
        #expect(ChannelAccounts.connectionId(botSession: primary) == "discord")
        #expect(ChannelAccounts.connectionId(botSession: extra) == "telegram-\(extra.id.uuidString.lowercased())")
        #expect(ChannelAccounts.connectionId(botSession: SignInSession(service: .channel(.slack), name: "x")) == nil)
        #expect(ChannelAccounts.connectionId(slackTeamId: "T0ACME") == "slack-t0acme")
        #expect(ChannelAccounts.connectionId(emailAccount: " Work-1 ") == "email-work-1")

        #expect(ChannelAccounts.isPrimary("Discord"))
        #expect(!ChannelAccounts.isPrimary("discord-abc"))
        #expect(ChannelAccounts.isReserved("slack-t0acme"))
        #expect(ChannelAccounts.isReserved("email"))
        #expect(!ChannelAccounts.isReserved("imessage-2"), "single-account kinds reserve only their id")
        #expect(!ChannelAccounts.isReserved("ops-webhook"))
    }

    @Test func accountNamesShowTheChannelThenTheAccount() {
        let extra = ChannelAccount(
            kind: .discord, connectionId: "discord-x", name: "Support bot", isPrimary: false, sessionId: nil,
            reference: nil)
        #expect(extra.displayName == "Discord · Support bot")
        let primary = ChannelAccount(
            kind: .slack, connectionId: "slack", name: "Slack", isPrimary: true, sessionId: nil, reference: nil)
        #expect(primary.displayName == "Slack")
    }

    // MARK: - Email accounts

    @Test func theFirstEmailAccountIsEmailAndOthersGetTheirOwnId() {
        let config = EmailChannelConfiguration(accounts: [
            EmailChannelAccount(connectionId: "Work"),
            EmailChannelAccount(connectionId: "home"),
            EmailChannelAccount(connectionId: "Work"),
        ])
        #expect(config.accounts.map(\.channelConnectionId) == ["email", "email-home"])
        #expect(config.account(channelConnectionId: "EMAIL-HOME")?.connectionId == "home")

        // A kept id stays; a duplicate is reassigned.
        let kept = EmailChannelConfiguration(accounts: [
            EmailChannelAccount(connectionId: "a", channelConnectionId: "email-a"),
            EmailChannelAccount(connectionId: "b", channelConnectionId: "email-a"),
        ])
        #expect(kept.accounts.map(\.channelConnectionId) == ["email-a", "email"])
    }

    @Test func aSharedSettingsFileGivesEveryAccountItsOwnCopy() throws {
        let legacy = """
            {"accounts": [{"connectionId": "c1"}, {"connectionId": "c2", "mailboxes": ["Receipts"]}],
             "senderAllowlist": ["Boss@Home.org"], "receiveEnabled": true, "writeEnabled": true,
             "draftUnsentReplies": false, "defaultReadLimit": 40}
            """
        let config = try JSONDecoder().decode(EmailChannelConfiguration.self, from: Data(legacy.utf8))
        #expect(config.accounts.count == 2)
        for account in config.accounts {
            #expect(account.senderAllowlist == ["boss@home.org"])
            #expect(account.receiveEnabled)
            #expect(account.writeEnabled)
            #expect(!account.draftUnsentReplies)
            #expect(account.defaultReadLimit == 40)
        }
        #expect(config.accounts.map(\.channelConnectionId) == ["email", "email-c2"])

        // Saved per account, the old shared keys are gone.
        let encoded = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? ""
        let reloaded = try JSONDecoder().decode(EmailChannelConfiguration.self, from: Data(encoded.utf8))
        #expect(reloaded == config)
    }

    // MARK: - Migration plan

    private static let slackWithWorkspaces = SlackConnectionConfiguration(
        configuredTeamIds: ["TPRIMARY", "TSECOND"],
        readableChannelIds: ["CPRIMARY"],
        writableChannelIds: ["WPRIMARY"],
        senderAllowlist: ["UPRIMARY"],
        writeEnabled: true,
        workspaceAccounts: [
            SlackWorkspaceAccountConfiguration(
                teamId: "TSECOND", teamName: "Second", readableChannelIds: ["CSECOND"],
                writableChannelIds: ["WSECOND"], senderAllowlist: ["USECOND"], botUserId: "UB2", botId: "BB2")
        ])

    private static let twoMailAccounts = EmailChannelConfiguration(accounts: [
        EmailChannelAccount(connectionId: "c1"), EmailChannelAccount(connectionId: "c2", name: "Home"),
    ])

    @Test func movedAccountsAreTheExtraWorkspacesAndEmailAccounts() {
        let moved = ChannelAccountMigration.movedAccounts(slack: Self.slackWithWorkspaces, email: Self.twoMailAccounts)
        #expect(moved.map(\.connectionId) == ["slack-tsecond", "email-c2"])
        let slack = moved[0]
        #expect(slack.name == "Second")
        #expect(slack.owns("CSECOND") && slack.owns("WSECOND"))
        #expect(!slack.owns("CPRIMARY"))
        let email = moved[1]
        #expect(email.name == "Home")
        #expect(email.owns("c2/INBOX") && !email.owns("c1/INBOX"))
        #expect(email.eventIdPrefix == "email:c2:")

        #expect(
            ChannelAccountMigration.movedAccounts(
                slack: SlackConnectionConfiguration(), email: EmailChannelConfiguration(accounts: [
                    EmailChannelAccount(connectionId: "c1")
                ])
            ).isEmpty, "one workspace and one mail account: nothing moves")
    }

    private static func trigger(_ name: String, kind: AgentChannelKind, rooms: [String]) -> OsaurusEvent {
        OsaurusEvent(
            name: name,
            source: .channelMessage(ChannelMessageSourceConfig(kind: kind, connectionId: kind.rawValue, roomIds: rooms)),
            action: .agent(AgentEventAction(target: .local(UUID()), instructions: "")))
    }

    @Test func triggersFollowTheRoomsTheyNameAndAnyRoomIsCopied() throws {
        let moved = ChannelAccountMigration.movedAccounts(slack: Self.slackWithWorkspaces, email: Self.twoMailAccounts)
        let anyRoom = Self.trigger("Helper", kind: .slack, rooms: [])
        let second = Self.trigger("Second only", kind: .slack, rooms: ["CSECOND"])
        let mixed = Self.trigger("Both", kind: .slack, rooms: ["CPRIMARY", "CSECOND"])
        let primaryOnly = Self.trigger("Primary only", kind: .slack, rooms: ["CPRIMARY"])
        let homeMail = Self.trigger("Home mail", kind: .email, rooms: ["c2/INBOX"])
        let workMail = Self.trigger("Work mail", kind: .email, rooms: ["c1/INBOX"])
        let now = Date(timeIntervalSince1970: 1_000)

        let result = ChannelAccountMigration.splitTriggers(
            [anyRoom, second, mixed, primaryOnly, homeMail, workMail], moved: moved, now: now)
        #expect(result.copied == 1)
        #expect(result.split == 3)

        let saved = result.saved
        let copy = try #require(saved.first { $0.name == "Helper (Second)" })
        #expect(copy.id != anyRoom.id)
        #expect(copy.source.channelMessage?.connectionId == "slack-tsecond")
        #expect(copy.source.channelMessage?.roomIds == [])
        #expect(copy.action == anyRoom.action)
        #expect(!saved.contains { $0.id == anyRoom.id }, "the original keeps answering on the primary")

        let movedWhole = try #require(saved.first { $0.id == second.id })
        #expect(movedWhole.source.channelMessage?.connectionId == "slack-tsecond")

        let keptPart = try #require(saved.first { $0.id == mixed.id })
        #expect(keptPart.source.channelMessage?.connectionId == "slack")
        #expect(keptPart.source.channelMessage?.roomIds == ["CPRIMARY"])
        let splitPart = try #require(saved.first { $0.name == "Both (Second)" })
        #expect(splitPart.source.channelMessage?.connectionId == "slack-tsecond")
        #expect(splitPart.source.channelMessage?.roomIds == ["CSECOND"])

        #expect(!saved.contains { $0.id == primaryOnly.id || $0.id == workMail.id })
        #expect(saved.first { $0.id == homeMail.id }?.source.channelMessage?.connectionId == "email-c2")
    }

    @Test func storedRowsOfAMovedAccountFollowIt() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }
        _ = try store.recordMessages([
            AgentChannelStoredMessage(
                connectionId: "slack", roomId: "CPRIMARY", providerMessageId: "1", direction: .inbound, content: "a"),
            AgentChannelStoredMessage(
                connectionId: "slack", roomId: "CSECOND", providerMessageId: "2", direction: .inbound, content: "b"),
            AgentChannelStoredMessage(
                connectionId: "email", roomId: "c2/INBOX", providerMessageId: "3", direction: .inbound, content: "c"),
        ])

        #expect(try store.reassign(from: "slack", to: "slack-tsecond", roomIds: ["CSECOND"]) == 1)
        #expect(try store.reassign(from: "email", to: "email-c2", roomPrefixes: ["c2/"]) == 1)
        #expect(try store.messageCount(connectionId: "slack") == 1)
        #expect(try store.messageCount(connectionId: "slack-tsecond", roomId: "CSECOND") == 1)
        #expect(try store.messageCount(connectionId: "email-c2", roomId: "c2/INBOX") == 1)
        #expect(try store.reassign(from: "slack", to: "slack-tsecond", roomIds: ["CSECOND"]) == 0, "idempotent")
    }

    // MARK: - Bots

    /// Holds the locks every suite that points the channel stores at a temp
    /// directory takes, in the same order.
    private func withIsolatedChannelFiles(_ body: @escaping @MainActor @Sendable (URL) async throws -> Void)
        async throws
    {
        try await StoragePathsTestLock.shared.run {
            try await AgentChannelConfigurationTestLock.shared.run {
                try await Self.inIsolatedChannelFiles(body)
            }
        }
    }

    @MainActor
    private static func inIsolatedChannelFiles(_ body: @MainActor (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-channel-accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousDiscord = DiscordConnectionConfigurationStore.overrideDirectory
        let previousSlack = SlackConnectionConfigurationStore.overrideDirectory
        DiscordConnectionConfigurationStore.overrideDirectory = directory
        SlackConnectionConfigurationStore.overrideDirectory = directory
        defer {
            DiscordConnectionConfigurationStore.overrideDirectory = previousDiscord
            SlackConnectionConfigurationStore.overrideDirectory = previousSlack
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(directory)
    }

    @Test @MainActor func anExtraBotIsItsOwnConnectionUntilRemoved() async throws {
        try await withIsolatedChannelFiles { directory in
            let sessions = SignInSessionStore.shared
            let hadPrimary = sessions.sessions(for: .channel(.discord)).contains(where: \.isPrimary)
            let main = sessions.ensurePrimary(for: .channel(.discord))
            let bot = sessions.add(service: .channel(.discord), name: "Support bot")
            let id = "discord-\(bot.id.uuidString.lowercased())"
            defer {
                if sessions.session(id: bot.id) != nil { sessions.remove(bot.id) }
                if !hadPrimary { sessions.remove(main.id) }
            }

            let accounts = ChannelAccounts.accounts(kind: .discord)
            #expect(accounts.first?.connectionId == "discord")
            #expect(accounts.first?.isPrimary == true)
            let extra = try #require(ChannelAccounts.account(connectionId: id.uppercased()))
            #expect(extra.name == "Support bot")
            #expect(extra.sessionId == bot.id)
            #expect(ChannelAccounts.displayName(connectionId: id) == "Discord · Support bot")

            // Its own service and settings file; the primary is untouched.
            let service = try #require(ChannelAccountServices.discord(id))
            #expect(service.connectionId == id)
            #expect(ChannelAccountServices.discord("discord") === DiscordConnectionService.shared)
            #expect(ChannelAccountServices.discord(id) === service)
            try service.saveConfiguration(
                DiscordConnectionConfiguration(readableChannelIds: ["C2"], senderAllowlist: ["U2"]))
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).json").path))
            #expect(DiscordConnectionConfigurationStore.load().readableChannelIds.isEmpty)
            #expect(DiscordConnectionConfigurationStore.load(connectionId: id).readableChannelIds == ["C2"])

            // Agents see it as a connection of its own.
            let rows = AgentChannelConnectionService(discordService: .shared).listConnections()
            let row = try #require(rows.first { $0["id"] as? String == id })
            #expect(row["kind"] as? String == "discord")
            #expect(row["name"] as? String == "Discord · Support bot")
            #expect(row["read_room_allowlist"] as? [String] == ["C2"])

            ChannelAccountRemoval.removeAccount(connectionId: id)
            #expect(sessions.session(id: bot.id) == nil)
            #expect(ChannelAccounts.account(connectionId: id) == nil)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).json").path))
            #expect(ChannelAccounts.account(connectionId: "discord") != nil, "the primary stays")
            ChannelAccountRemoval.removeAccount(connectionId: "discord")
            #expect(ChannelAccounts.account(connectionId: "discord") != nil, "the primary can't be removed")
        }
    }

    @Test @MainActor func anAgentsBotPostsTheMessagesSentToThePrimary() async throws {
        let sessions = SignInSessionStore.shared
        let hadPrimary = sessions.sessions(for: .channel(.telegram)).contains(where: \.isPrimary)
        let main = sessions.ensurePrimary(for: .channel(.telegram))
        let bot = sessions.add(service: .channel(.telegram), name: "Ops bot")
        let agent = UUID()
        defer {
            sessions.removeAgent(agent)
            sessions.remove(bot.id)
            if !hadPrimary { sessions.remove(main.id) }
        }
        #expect(ChannelSessions.postingConnectionId(for: "telegram", agentId: agent) == nil, "no pick: the primary")
        sessions.assign(agentId: agent, service: .channel(.telegram), sessionId: bot.id)
        let botId = "telegram-\(bot.id.uuidString.lowercased())"
        #expect(ChannelSessions.postingConnectionId(for: "telegram", agentId: agent) == botId)
        #expect(ChannelSessions.postingConnectionId(for: botId, agentId: agent) == nil)
        #expect(ChannelSessions.postingConnectionId(for: "slack", agentId: agent) == nil)
    }

    // MARK: - Slack workspaces

    @Test @MainActor func eachSlackWorkspaceFileIsAnAccount() async throws {
        try await withIsolatedChannelFiles { _ in
            try SlackConnectionConfigurationStore.save(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T0ACME"], readableChannelIds: ["CACME"], workspaceName: "Acme"),
                connectionId: "slack-t0acme")
            #expect(SlackConnectionConfigurationStore.accountConnectionIds() == ["slack-t0acme"])
            let accounts = ChannelAccounts.accounts(kind: .slack)
            #expect(accounts.map(\.connectionId) == ["slack", "slack-t0acme"])
            #expect(accounts[1].name == "Acme")
            #expect(accounts[1].reference == "T0ACME")

            let service = try #require(ChannelAccountServices.slack("slack-t0acme"))
            #expect(service.connectionId == "slack-t0acme")
            #expect(service.configuration().readableChannelIds == ["CACME"])
            #expect(SlackConnectionConfigurationStore.load().readableChannelIds.isEmpty)
            #expect(ChannelAccountServices.slack("slack") === SlackConnectionService.shared)
            ChannelAccountServices.forget("slack-t0acme")

            SlackConnectionConfigurationStore.delete(connectionId: "slack-t0acme")
            #expect(ChannelAccounts.accounts(kind: .slack).map(\.connectionId) == ["slack"])
        }
    }

    // MARK: - Declarative accounts[]

    @Test func accountsEntriesAreTargetsWithTheirOwnPath() {
        var extra = ChannelPlatformSection()
        extra.id = "Slack-T0ACME"
        extra.writeEnabled = true
        var primaryAgain = ChannelPlatformSection()
        primaryAgain.id = "slack"
        var slack = ChannelPlatformSection()
        slack.accounts = [extra, primaryAgain, ChannelPlatformSection()]
        var channels = ChannelsSection()
        channels.slack = slack

        let targets = ConfigChannelPlatform.slack.targets(in: channels)
        #expect(targets.map(\.connectionId) == ["slack", "slack-t0acme"])
        #expect(targets.map(\.path) == ["channels.slack", "channels.slack.accounts[Slack-T0ACME]"])
        #expect(targets.map(\.label) == ["slack", "slack slack-t0acme"])
        #expect(targets[1].section.writeEnabled == true)
        #expect(ConfigChannelPlatform.targets(in: nil).isEmpty)
    }

    @Test @MainActor func accountsEntriesAreValidated() {
        var noId = ChannelPlatformSection()
        noId.writeEnabled = true
        var primary = ChannelPlatformSection()
        primary.id = "discord"
        var twice = ChannelPlatformSection()
        twice.id = "discord-abc"
        var withToken = ChannelPlatformSection()
        withToken.id = "discord-abc"
        withToken.accounts = [ChannelPlatformSection()]
        var discord = ChannelPlatformSection()
        discord.accounts = [noId, primary, twice, withToken]
        var imessage = ChannelPlatformSection()
        imessage.accounts = [twice]
        var channels = ChannelsSection()
        channels.discord = discord
        channels.imessage = imessage

        var issues: [String] = []
        ConfigChannelAccounts.validate(channels, into: &issues)
        #expect(issues.contains { $0.hasPrefix("channels.discord.accounts[0].id") })
        #expect(issues.contains { $0.contains("is the primary account") })
        #expect(issues.contains { $0.contains("listed twice") })
        #expect(issues.contains { $0.contains("accounts don't nest") })
        #expect(issues.contains { $0.hasPrefix("channels.imessage.accounts") })

        let unknown = ConfigChannelPlatform.discord.targets(in: channels).first { !$0.isPrimary }
        #expect(unknown.map(ConfigChannelAccounts.isKnown) == false)
        #expect(unknown.map(ConfigChannelAccounts.unknownAccountIssue)?.contains("Settings → Channels") == true)
    }

    @Test @MainActor func aPlanNamingAMissingAccountIsRefused() {
        var account = ChannelPlatformSection()
        account.id = "telegram-\(UUID().uuidString.lowercased())"
        account.writeEnabled = true
        var telegram = ChannelPlatformSection()
        telegram.accounts = [account]
        var channels = ChannelsSection()
        channels.telegram = telegram
        var document = OsaurusConfigDocument()
        document.channels = channels
        #expect(throws: ConfigPlanIssues.self) {
            _ = try ConfigPlanner.plan(document: document, prune: false)
        }
    }
}
