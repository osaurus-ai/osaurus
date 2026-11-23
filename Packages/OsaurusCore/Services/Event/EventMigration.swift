//
//  EventMigration.swift
//  osaurus
//
//  One-shot move from the pre-events trigger configs to events, on the
//  first launch that has events:
//
//   - `schedules/*.json`  → schedule events (same ids, so their chats keep
//                           grouping), run history → the ledger
//   - `watchers/*.json`   → folder events (same ids)
//   - each platform's `inboundDispatch` (Discord, Slack, Telegram,
//     iMessage, WhatsApp, n8n connections) → one channel-message event per
//     default agent and per routing rule
//
//  Legacy schedule/watcher files stay where they are, and platform configs
//  keep their `inboundDispatch` block, so a user who goes back to a build
//  without events still has them. `events/migration.json` records what
//  moved and keeps the move from running twice.
//

import Foundation

enum EventMigration {
    static let markerFileName = "migration.json"
    static let migratedSuffix = ".migrated"

    struct Marker: Codable, Equatable {
        var version: Int
        var migratedAt: Date
        var schedules: Int
        var watchers: Int
        var channelEvents: Int
        var importedRuns: Int
        var notes: [String]
    }

    static var markerURL: URL { OsaurusPaths.events().appendingPathComponent(markerFileName) }

    static func hasMigrated() -> Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Runs the migration unless the marker exists. Safe to call on every
    /// launch; never overwrites an event that already exists.
    @discardableResult
    static func runIfNeeded(ledger: EventRunDatabase) -> Marker? {
        restoreRenamedLegacyFiles()
        guard !hasMigrated() else { return nil }
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.events())
        var notes: [String] = []

        let schedules = loadLegacy(Schedule.self, from: legacySchedulesDirectory)
        let watchers = loadLegacy(Watcher.self, from: legacyWatchersDirectory)
        let channelEvents = legacyChannelEvents(notes: &notes)

        var events: [OsaurusEvent] = []
        events += schedules.map { event(from: $0.1) }
        events += watchers.map { event(from: $0.1) }
        events += channelEvents
        for event in events where EventStore.load(id: event.id) == nil {
            EventStore.save(event)
        }

        var importedRuns = 0
        ledger.ensureOpen()
        for (_, schedule) in schedules {
            for run in runs(from: schedule) {
                if (try? ledger.upsert(run)) != nil { importedRuns += 1 }
            }
        }

        let marker = Marker(
            version: 1,
            migratedAt: Date(),
            schedules: schedules.count,
            watchers: watchers.count,
            channelEvents: channelEvents.count,
            importedRuns: importedRuns,
            notes: notes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(marker).write(to: markerURL, options: [.atomic])
        if !events.isEmpty {
            print(
                "[Osaurus] Migrated \(schedules.count) schedule(s), \(watchers.count) watcher(s), "
                    + "\(channelEvents.count) channel route(s) to events")
        }
        return marker
    }

    // MARK: - Legacy files

    static var legacySchedulesDirectory: URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.schedules(), legacy: "Schedules")
    }

    static var legacyWatchersDirectory: URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.watchers(), legacy: "Watchers")
    }

    static func loadLegacy<T: Decodable>(_ type: T.Type, from directory: URL) -> [(URL, T)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let value = try? decoder.decode(T.self, from: data) else {
                print("[Osaurus] Event migration skipped unreadable \(url.lastPathComponent)")
                return nil
            }
            return (url, value)
        }
    }

    /// Earlier betas renamed migrated files to `*.json.migrated`, which hid
    /// them from builds without events. Put them back unless a file with the
    /// original name has appeared since.
    @discardableResult
    static func restoreRenamedLegacyFiles() -> Int {
        let fm = FileManager.default
        var restored = 0
        for directory in [legacySchedulesDirectory, legacyWatchersDirectory] {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.lastPathComponent.hasSuffix(".json" + migratedSuffix) {
                let original = url.deletingPathExtension()
                guard !fm.fileExists(atPath: original.path) else { continue }
                if (try? fm.moveItem(at: url, to: original)) != nil { restored += 1 }
            }
        }
        return restored
    }

    // MARK: - Schedules

    static func event(from schedule: Schedule) -> OsaurusEvent {
        OsaurusEvent(
            id: schedule.id,
            name: schedule.name,
            isEnabled: schedule.isEnabled,
            source: .schedule(ScheduleSourceConfig(frequency: schedule.frequency)),
            action: .agent(
                AgentEventAction(
                    target: schedule.target,
                    instructions: schedule.instructions,
                    folderPath: schedule.folderPath,
                    folderBookmark: schedule.folderBookmark,
                    freshSessionPerFire: true
                )),
            delivery: .defaults(for: .schedule),
            parameters: schedule.parameters,
            createdAt: schedule.createdAt,
            updatedAt: schedule.updatedAt,
            lastFiredAt: schedule.lastTriggeredAt,
            lastRunAt: schedule.lastRunAt,
            lastStatus: schedule.runHistory.last.map { status(from: $0.status) },
            lastSessionId: schedule.lastChatSessionId
        )
    }

    static func runs(from schedule: Schedule) -> [EventRun] {
        schedule.runHistory.map { entry in
            var status = status(from: entry.status)
            var reason: String?
            if entry.status == .running {
                status = .cancelled
                reason = "interrupted"
            }
            return EventRun(
                id: entry.id,
                eventId: schedule.id,
                eventName: schedule.name,
                sourceKind: .schedule,
                actionKind: .agent,
                firedAt: entry.startedAt,
                status: status,
                reason: reason,
                sessionId: entry.chatSessionId,
                startedAt: entry.startedAt,
                finishedAt: entry.endedAt ?? (status.isTerminal ? entry.startedAt : nil),
                error: entry.errorMessage,
                summary: ["imported": "schedule_history"]
            )
        }
    }

    static func status(from status: ScheduleRunStatus) -> EventRunStatus {
        switch status {
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        case .skipped: .suppressed
        }
    }

    // MARK: - Watchers

    static func event(from watcher: Watcher) -> OsaurusEvent {
        OsaurusEvent(
            id: watcher.id,
            name: watcher.name,
            isEnabled: watcher.isEnabled,
            source: .folder(
                FolderSourceConfig(
                    path: watcher.watchPath,
                    bookmark: watcher.watchBookmark,
                    recursive: watcher.recursive,
                    responsiveness: watcher.responsiveness,
                    settleSeconds: watcher.settleSeconds
                )),
            action: .agent(
                AgentEventAction(target: watcher.target, instructions: watcher.instructions, freshSessionPerFire: false)),
            delivery: .defaults(for: .folder),
            parameters: watcher.parameters,
            createdAt: watcher.createdAt,
            updatedAt: watcher.updatedAt,
            lastFiredAt: watcher.lastTriggeredAt,
            lastSessionId: watcher.lastChatSessionId
        )
    }

    // MARK: - Channels

    /// The legacy `inboundDispatch` block of a platform config file, read
    /// raw so the platform models no longer carry it.
    private struct LegacyPlatformFile: Decodable {
        var inboundDispatch: AgentChannelInboundDispatchConfiguration?
    }

    private struct LegacyConnectionsFile: Decodable {
        struct Connection: Decodable {
            struct N8n: Decodable {
                var inboundDispatch: AgentChannelInboundDispatchConfiguration?
            }
            var id: String
            var name: String?
            var kind: AgentChannelKind
            var n8n: N8n?
        }
        var connections: [Connection]?
    }

    static func legacyChannelEvents(notes: inout [String]) -> [OsaurusEvent] {
        var out: [OsaurusEvent] = []
        let platforms: [(AgentChannelKind, URL)] = [
            (.discord, DiscordConnectionConfigurationStore.configurationFileURL()),
            (.slack, SlackConnectionConfigurationStore.configurationFileURL()),
            (.telegram, TelegramConnectionConfigurationStore.configurationFileURL()),
            (.imessage, IMessageConnectionConfigurationStore.configurationFileURL()),
            (.whatsapp, WhatsAppConnectionConfigurationStore.configurationFileURL()),
        ]
        for (kind, url) in platforms {
            guard let data = try? Data(contentsOf: url),
                let file = try? JSONDecoder().decode(LegacyPlatformFile.self, from: data),
                let inbound = file.inboundDispatch
            else { continue }
            let connectionId = ChannelMessageSourceConfig.nativeConnectionId(for: kind) ?? kind.rawValue
            out += events(fromInbound: inbound, kind: kind, connectionId: connectionId, label: kind.displayName)
        }
        if let data = try? Data(contentsOf: AgentChannelConfigurationStore.configurationFileURL()),
            let file = try? JSONDecoder().decode(LegacyConnectionsFile.self, from: data)
        {
            for connection in file.connections ?? [] where connection.kind == .n8n {
                guard let inbound = connection.n8n?.inboundDispatch else { continue }
                out += events(
                    fromInbound: inbound, kind: .n8n, connectionId: connection.id,
                    label: connection.name?.isEmpty == false ? connection.name! : AgentChannelKind.n8n.displayName)
            }
        }
        if !out.isEmpty {
            notes.append("Channel routing copied to Automations; the platform files keep the original routing for stable Osaurus.")
        }
        return out
    }

    /// One event for the default agent (any room) and one per routing rule.
    /// A disabled inbound config migrates as disabled events, so the intent
    /// survives without anything starting to answer.
    static func events(
        fromInbound inbound: AgentChannelInboundDispatchConfiguration,
        kind: AgentChannelKind,
        connectionId: String,
        label: String,
        now: Date = Date()
    ) -> [OsaurusEvent] {
        let requireMention = ChannelMessageSourceConfig.supportsMentions(kind) && inbound.requireMention
        func make(name: String, target: AgentDispatchTarget, rooms: [String], aliases: [String], seed: String)
            -> OsaurusEvent
        {
            OsaurusEvent(
                id: AgentChannelAsyncSubstrate.stableUUID(material: "event-migration|\(connectionId)|\(seed)"),
                name: name,
                isEnabled: inbound.enabled,
                source: .channelMessage(
                    ChannelMessageSourceConfig(
                        kind: kind,
                        connectionId: connectionId,
                        roomIds: rooms,
                        aliases: aliases,
                        requireMention: requireMention,
                        continueThreads: inbound.continueThreads
                    )),
                action: .agent(AgentEventAction(target: target, freshSessionPerFire: false)),
                delivery: .defaults(for: .channelMessage),
                reply: EventReplyPolicy(autoReply: inbound.autoReplyEnabled),
                createdAt: now,
                updatedAt: now
            )
        }
        var out: [OsaurusEvent] = []
        if let target = inbound.target {
            out.append(make(name: L("\(label) messages"), target: target, rooms: [], aliases: [], seed: "default"))
        }
        for route in inbound.routes {
            let rooms = route.roomId.map { [$0] } ?? []
            let name: String
            if let alias = route.nameAliases.first {
                name = L("\(label) “\(alias):” messages")
            } else if let room = route.roomId {
                name = L("\(label) room \(room)")
            } else {
                name = L("\(label) messages")
            }
            out.append(
                make(
                    name: name, target: route.target, rooms: rooms, aliases: route.nameAliases,
                    seed: "route|\(route.id.uuidString)"))
        }
        return out
    }
}
