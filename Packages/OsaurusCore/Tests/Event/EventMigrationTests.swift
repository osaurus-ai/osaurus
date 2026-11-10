//
//  EventMigrationTests.swift
//  osaurusTests
//
//  First-launch move from schedules, watchers and per-platform inbound
//  routing to events: the conversions, and one end-to-end run in an
//  isolated root (files renamed, history imported, marker written once).
//

import Foundation
import Testing

@testable import OsaurusCore

struct EventMigrationTests {
    // MARK: - Schedules

    @Test func scheduleKeepsItsIdTargetFolderAndTiming() {
        let agent = UUID()
        let session = UUID()
        let fired = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = Schedule(
            name: "Morning brief", instructions: "Summarize my inbox", target: .local(agent),
            parameters: ["pluginId": "brief"], folderPath: "/tmp/brief", frequency: .daily(hour: 8, minute: 30),
            isEnabled: false, lastRunAt: fired.addingTimeInterval(60), lastTriggeredAt: fired,
            lastChatSessionId: session,
            runHistory: [
                ScheduleRunHistoryEntry(scheduleId: UUID(), agentId: agent, status: .failed, startedAt: fired)
            ])
        let event = EventMigration.event(from: schedule)
        #expect(event.id == schedule.id)
        #expect(event.name == "Morning brief")
        #expect(!event.isEnabled)
        #expect(event.source == .schedule(ScheduleSourceConfig(frequency: .daily(hour: 8, minute: 30))))
        #expect(event.action.agent?.target == .local(agent))
        #expect(event.action.agent?.instructions == "Summarize my inbox")
        #expect(event.action.agent?.folderPath == "/tmp/brief")
        #expect(event.action.agent?.freshSessionPerFire == true)
        #expect(event.parameters == ["pluginId": "brief"])
        #expect(event.lastFiredAt == fired)
        #expect(event.lastSessionId == session)
        #expect(event.lastStatus == .failed)
        #expect(event.delivery == .defaults(for: .schedule))
    }

    @Test func runHistoryImportsWithInterruptedRunsClosed() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = Schedule(
            name: "S", instructions: "", frequency: .hourly(minute: 0),
            runHistory: [
                ScheduleRunHistoryEntry(
                    scheduleId: UUID(), agentId: nil, status: .succeeded, startedAt: start,
                    endedAt: start.addingTimeInterval(30), chatSessionId: UUID()),
                ScheduleRunHistoryEntry(scheduleId: UUID(), agentId: nil, status: .running, startedAt: start),
                ScheduleRunHistoryEntry(scheduleId: UUID(), agentId: nil, status: .skipped, startedAt: start),
                ScheduleRunHistoryEntry(
                    scheduleId: UUID(), agentId: nil, status: .failed, startedAt: start, errorMessage: "no model"),
            ])
        let runs = EventMigration.runs(from: schedule)
        #expect(runs.map(\.status) == [.succeeded, .cancelled, .suppressed, .failed])
        #expect(runs.allSatisfy { $0.eventId == schedule.id && $0.sourceKind == .schedule })
        #expect(runs.allSatisfy { $0.summary["imported"] == "schedule_history" })
        #expect(runs[0].finishedAt == start.addingTimeInterval(30))
        #expect(runs[1].reason == "interrupted")
        #expect(runs[1].finishedAt == start)
        #expect(runs[3].error == "no model")
        #expect(runs.map(\.id) == schedule.runHistory.map(\.id))
    }

    // MARK: - Watchers

    @Test func watcherBecomesAFolderEvent() {
        let watcher = Watcher(
            name: "Downloads", instructions: "Sort it", target: .local(UUID()), watchPath: "/tmp/dl",
            isEnabled: true, recursive: true, responsiveness: .patient, settleSeconds: 5)
        let event = EventMigration.event(from: watcher)
        #expect(event.id == watcher.id)
        #expect(
            event.source
                == .folder(
                    FolderSourceConfig(path: "/tmp/dl", recursive: true, responsiveness: .patient, settleSeconds: 5)))
        #expect(event.action.agent?.instructions == "Sort it")
        #expect(event.action.agent?.freshSessionPerFire == false)
        #expect(event.delivery == .defaults(for: .folder))
        #expect(event.delivery.dedupeWindowSeconds == 0)
    }

    // MARK: - Channel routing

    @Test func inboundRoutingBecomesOneEventPerAgentAndRule() throws {
        let fallback = UUID()
        let support = UUID()
        let ops = UUID()
        let supportRoute = AgentChannelDispatchRoute(roomId: "C-SUPPORT", agentId: support)
        let opsRoute = AgentChannelDispatchRoute(agentId: ops, nameAliases: ["Ops", "oncall"])
        let inbound = AgentChannelInboundDispatchConfiguration(
            enabled: true, targetAgentId: fallback, routes: [supportRoute, opsRoute], requireMention: true,
            continueThreads: false, autoReplyEnabled: true)
        let events = EventMigration.events(fromInbound: inbound, kind: .slack, connectionId: "slack", label: "Slack")
        #expect(events.count == 3)
        #expect(events.map(\.target) == [.local(fallback), .local(support), .local(ops)])

        let any = try #require(events[0].source.channelMessage)
        #expect(any.roomIds.isEmpty)
        #expect(any.aliases.isEmpty)
        #expect(any.requireMention)
        #expect(!any.continueThreads)
        #expect(events[0].reply.autoReply)
        #expect(events[0].isEnabled)
        #expect(events[0].delivery == .defaults(for: .channelMessage))

        #expect(events[1].source.channelMessage?.roomIds == ["C-SUPPORT"])
        #expect(events[1].name.contains("C-SUPPORT"))
        #expect(events[2].source.channelMessage?.aliases == ["ops", "oncall"])
        #expect(events[2].name.contains("ops"))

        let again = EventMigration.events(fromInbound: inbound, kind: .slack, connectionId: "slack", label: "Slack")
        #expect(again.map(\.id) == events.map(\.id))
        let elsewhere = EventMigration.events(fromInbound: inbound, kind: .slack, connectionId: "other", label: "Slack")
        #expect(Set(elsewhere.map(\.id)).isDisjoint(with: events.map(\.id)))
    }

    @Test func disabledInboundMigratesDisabledAndMentionsOnlyWhereSupported() {
        let inbound = AgentChannelInboundDispatchConfiguration(
            enabled: false, targetAgentId: UUID(), requireMention: true)
        let imessage = EventMigration.events(fromInbound: inbound, kind: .imessage, connectionId: "imessage", label: "iMessage")
        #expect(imessage.count == 1)
        #expect(!imessage[0].isEnabled)
        #expect(imessage[0].source.channelMessage?.requireMention == false)
        #expect(!imessage[0].reply.autoReply)
        let discord = EventMigration.events(fromInbound: inbound, kind: .discord, connectionId: "discord", label: "Discord")
        #expect(discord[0].source.channelMessage?.requireMention == true)
        #expect(EventMigration.events(fromInbound: AgentChannelInboundDispatchConfiguration(), kind: .slack, connectionId: "s", label: "S").isEmpty)
    }

    @Test func statusMapping() {
        #expect(EventMigration.status(from: .running) == .running)
        #expect(EventMigration.status(from: .succeeded) == .succeeded)
        #expect(EventMigration.status(from: .failed) == .failed)
        #expect(EventMigration.status(from: .cancelled) == .cancelled)
        #expect(EventMigration.status(from: .skipped) == .suppressed)
    }

    // MARK: - End to end

    private struct DiscordFile: Encodable {
        var enabled = true
        var inboundDispatch: AgentChannelInboundDispatchConfiguration
    }

    @Test func runIfNeededMovesEverythingOnce() async throws {
        // The migration reads the platform config stores, whose override
        // directories other suites set under the channel configuration lock.
        try await StoragePathsTestLock.shared.run {
            try await AgentChannelConfigurationTestLock.shared.run {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-event-migration-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let previousRoot = OsaurusPaths.overrideRoot
                OsaurusPaths.overrideRoot = root
                defer {
                    OsaurusPaths.overrideRoot = previousRoot
                    try? FileManager.default.removeItem(at: root)
                }

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let start = Date(timeIntervalSince1970: 1_800_000_000)
                let schedule = Schedule(
                    name: "Nightly", instructions: "Report", target: .local(UUID()),
                    frequency: .daily(hour: 2, minute: 0),
                    runHistory: [
                        ScheduleRunHistoryEntry(scheduleId: UUID(), agentId: nil, status: .succeeded, startedAt: start),
                        ScheduleRunHistoryEntry(scheduleId: UUID(), agentId: nil, status: .failed, startedAt: start),
                    ])
                let watcher = Watcher(
                    name: "Inbox", instructions: "File it", target: .local(UUID()), watchPath: "/tmp/in")
                let schedulesDir = EventMigration.legacySchedulesDirectory
                let watchersDir = EventMigration.legacyWatchersDirectory
                try FileManager.default.createDirectory(at: schedulesDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: watchersDir, withIntermediateDirectories: true)
                let scheduleURL = schedulesDir.appendingPathComponent("\(schedule.id.uuidString).json")
                let watcherURL = watchersDir.appendingPathComponent("\(watcher.id.uuidString).json")
                try encoder.encode(schedule).write(to: scheduleURL)
                try encoder.encode(watcher).write(to: watcherURL)
                try Data("not json".utf8).write(to: schedulesDir.appendingPathComponent("broken.json"))

                let discordURL = DiscordConnectionConfigurationStore.configurationFileURL()
                try FileManager.default.createDirectory(
                    at: discordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(
                    DiscordFile(
                        inboundDispatch: AgentChannelInboundDispatchConfiguration(
                            enabled: true, targetAgentId: UUID()))
                ).write(to: discordURL)

                let ledger = EventRunDatabase()
                try ledger.openInMemory()
                let marker = try #require(EventMigration.runIfNeeded(ledger: ledger))
                #expect(marker.schedules == 1)
                #expect(marker.watchers == 1)
                #expect(marker.channelEvents == 1)
                #expect(marker.importedRuns == 2)
                #expect(!marker.notes.isEmpty)

                let events = EventStore.loadAll()
                #expect(Set(events.map(\.sourceKind)) == [.schedule, .folder, .channelMessage])
                #expect(events.contains { $0.id == schedule.id })
                #expect(events.contains { $0.id == watcher.id })
                #expect(try ledger.runs(eventId: schedule.id).count == 2)

                // Builds without events still read these after a downgrade.
                let fm = FileManager.default
                #expect(fm.fileExists(atPath: scheduleURL.path))
                #expect(fm.fileExists(atPath: watcherURL.path))
                #expect(!fm.fileExists(atPath: scheduleURL.path + EventMigration.migratedSuffix))
                #expect(!fm.fileExists(atPath: watcherURL.path + EventMigration.migratedSuffix))
                #expect(EventMigration.hasMigrated())

                #expect(EventMigration.runIfNeeded(ledger: ledger) == nil)
                #expect(EventStore.loadAll().count == events.count)
            }
        }
    }

    @Test func runIfNeededRestoresFilesEarlierBetasRenamed() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-event-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            let fm = FileManager.default
            let schedulesDir = EventMigration.legacySchedulesDirectory
            let watchersDir = EventMigration.legacyWatchersDirectory
            try fm.createDirectory(at: schedulesDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: watchersDir, withIntermediateDirectories: true)
            let renamedSchedule = schedulesDir.appendingPathComponent("a.json" + EventMigration.migratedSuffix)
            let renamedWatcher = watchersDir.appendingPathComponent("b.json" + EventMigration.migratedSuffix)
            try Data("schedule".utf8).write(to: renamedSchedule)
            try Data("watcher".utf8).write(to: renamedWatcher)
            // A file recreated under the original name since wins.
            let recreated = schedulesDir.appendingPathComponent("c.json")
            let renamedOverRecreated = schedulesDir.appendingPathComponent("c.json" + EventMigration.migratedSuffix)
            try Data("new".utf8).write(to: recreated)
            try Data("old".utf8).write(to: renamedOverRecreated)

            OsaurusPaths.ensureExistsSilent(OsaurusPaths.events())
            try Data("{}".utf8).write(to: EventMigration.markerURL)
            let ledger = EventRunDatabase()
            try ledger.openInMemory()
            #expect(EventMigration.runIfNeeded(ledger: ledger) == nil)

            #expect(try Data(contentsOf: schedulesDir.appendingPathComponent("a.json")) == Data("schedule".utf8))
            #expect(try Data(contentsOf: watchersDir.appendingPathComponent("b.json")) == Data("watcher".utf8))
            #expect(!fm.fileExists(atPath: renamedSchedule.path))
            #expect(!fm.fileExists(atPath: renamedWatcher.path))
            #expect(try Data(contentsOf: recreated) == Data("new".utf8))
            #expect(fm.fileExists(atPath: renamedOverRecreated.path))
        }
    }
}
