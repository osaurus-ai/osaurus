//
//  SyncLegacyImporter.swift
//  osaurus
//
//  Copies the conversations saved before sync (the SQLCipher chat history)
//  into the sync store, most recent first, in the background. A ledger of
//  imported ids makes it resumable and keeps a chat deleted since from
//  coming back. A chat whose turn rows went missing (#1737) is rebuilt from
//  its Memory transcript. The old database stays where it is, untouched, as
//  a backup.
//

import Combine
import Foundation
import os

@MainActor
final class SyncLegacyImporter: ObservableObject {
    static let shared = SyncLegacyImporter()

    enum State: Equatable {
        case idle
        case importing(done: Int, total: Int)
        case finished(imported: Int, failed: Int)
    }

    @Published private(set) var state: State = .idle

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.import")
    nonisolated private static let batchSize = 20
    nonisolated private static let openAttempts = 10
    nonisolated private static let openRetryInterval: Duration = .seconds(30)

    private var task: Task<Void, Never>?
    private var openObserver: NSObjectProtocol?

    private init() {}

    /// Runs once the sync store opens, unless an earlier launch finished.
    func startIfNeeded() {
        guard task == nil, openObserver == nil else { return }
        guard !Ledger.load().isFinished else { return }
        if SyncService.shared.isOpen {
            run()
            return
        }
        openObserver = NotificationCenter.default.addObserver(
            forName: SyncService.didOpenNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let importer = SyncLegacyImporter.shared
                guard SyncService.shared.isOpen, let observer = importer.openObserver else { return }
                NotificationCenter.default.removeObserver(observer)
                importer.openObserver = nil
                importer.run()
            }
        }
    }

    private func run() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) {
            var outcome: Outcome?
            // Nil while the old database's key isn't available yet.
            for attempt in 0..<Self.openAttempts {
                if attempt > 0 { try? await Task.sleep(for: Self.openRetryInterval) }
                if Task.isCancelled { break }
                outcome = await Self.importAll { done, total in
                    await MainActor.run {
                        SyncLegacyImporter.shared.state = .importing(done: done, total: total)
                        ChatSessionsManager.shared.refresh()
                    }
                }
                if outcome != nil { break }
            }
            await MainActor.run {
                let importer = SyncLegacyImporter.shared
                importer.task = nil
                if let outcome {
                    importer.state = .finished(imported: outcome.imported, failed: outcome.failed)
                    ChatSessionsManager.shared.refresh()
                }
            }
        }
    }

    struct Outcome: Equatable {
        var imported: Int
        var failed: Int
    }

    /// Imports what the ledger doesn't list yet. Nil when there's nothing to
    /// read from (no old database, or its key isn't available yet).
    nonisolated static func importAll(
        legacy: ChatHistoryDatabase = .shared,
        store: SyncConversationStore = .shared,
        memory: MemoryDatabase = .shared,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async -> Outcome? {
        var ledger = Ledger.load()
        guard !ledger.isFinished else { return Outcome(imported: 0, failed: 0) }
        guard FileManager.default.fileExists(atPath: OsaurusPaths.chatHistoryDatabaseFile().path) || legacy.isOpenNonBlocking
        else {
            ledger.finish()
            return Outcome(imported: 0, failed: 0)
        }
        if !legacy.isOpenNonBlocking {
            guard StorageKeyManager.shared.isStorageReadyForWrites else { return nil }
            do {
                try legacy.open()
            } catch {
                log.error("old chat history didn't open: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        // Earlier ledgers skipped empty chats without asking Memory.
        let recheck = ledger.version < Ledger.currentVersion ? legacy.emptySessionIds() : []
        let pending = legacy.loadAllMetadata()
            .filter { !ledger.imported.contains($0.id) || recheck.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
        var outcome = Outcome(imported: 0, failed: 0)
        var transcripts = TranscriptSource(memory: memory)
        var deferred = 0
        var done = 0
        for batch in stride(from: 0, to: pending.count, by: batchSize).map({ pending[$0..<min($0 + batchSize, pending.count)] }) {
            if Task.isCancelled { break }
            for metadata in batch {
                done += 1
                // Already there: an import that stopped before its ledger write.
                if store.scope(forSession: metadata.id) != nil {
                    ledger.imported.insert(metadata.id)
                    continue
                }
                guard var session = legacy.loadSession(id: metadata.id) else {
                    ledger.imported.insert(metadata.id)
                    continue
                }
                if session.turns.isEmpty {
                    guard let turns = transcripts.turns(for: session.id) else {
                        deferred += 1
                        continue
                    }
                    session.turns = turns
                }
                guard !session.turns.isEmpty else {
                    ledger.imported.insert(metadata.id)
                    continue
                }
                do {
                    try store.saveSession(session)
                    ledger.imported.insert(metadata.id)
                    outcome.imported += 1
                } catch {
                    outcome.failed += 1
                    log.error(
                        "import failed for \(metadata.id, privacy: .public): \(error.syncLogDetail, privacy: .public)")
                }
            }
            ledger.save()
            await progress(done, pending.count)
        }
        if outcome.failed == 0, deferred == 0, !Task.isCancelled {
            ledger.finish()
        }
        log.info(
            "imported \(outcome.imported) conversations, \(outcome.failed) failed, \(deferred) waiting on Memory")
        return outcome
    }

    /// Memory transcripts for chats whose turn rows are gone. Opens Memory
    /// on first use, and only when its file exists.
    struct TranscriptSource {
        enum Availability { case unknown, open, absent, failed }

        let memory: MemoryDatabase
        private var availability = Availability.unknown

        init(memory: MemoryDatabase) { self.memory = memory }

        /// The chat's turns from its transcript, empty when it has none. Nil
        /// while Memory exists but can't be opened.
        mutating func turns(for sessionId: UUID) -> [ChatTurnData]? {
            if availability == .unknown { availability = open() }
            switch availability {
            case .absent: return []
            case .failed, .unknown: return nil
            case .open: break
            }
            do {
                return try memory.loadTranscriptForConversation(conversationId: sessionId.uuidString)
                    .compactMap(SyncLegacyImporter.chatTurnData(from:))
            } catch {
                SyncLegacyImporter.log.error(
                    "transcript read failed for \(sessionId, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        private func open() -> Availability {
            if memory.isOpen { return .open }
            guard FileManager.default.fileExists(atPath: OsaurusPaths.memoryDatabaseFile().path) else { return .absent }
            do {
                try memory.open()
                return .open
            } catch {
                SyncLegacyImporter.log.error("memory didn't open: \(String(describing: error), privacy: .public)")
                return .failed
            }
        }
    }

    nonisolated static func chatTurnData(from transcriptTurn: TranscriptTurn) -> ChatTurnData? {
        let trimmedContent = transcriptTurn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return nil }
        guard let role = MessageRole(rawValue: transcriptTurn.role) else { return nil }

        return ChatTurnData(
            role: role,
            content: transcriptTurn.content,
            createdAt: transcriptDate(from: transcriptTurn.createdAt)
        )
    }

    nonisolated private static func transcriptDate(from raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }

        let iso8601Formatter = ISO8601DateFormatter()
        if let date = iso8601Formatter.date(from: raw) {
            return date
        }
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601Formatter.date(from: raw) {
            return date
        }

        let sqliteFormatter = DateFormatter()
        sqliteFormatter.locale = Locale(identifier: "en_US_POSIX")
        sqliteFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        sqliteFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sqliteFormatter.date(from: raw)
    }

    /// Which old conversations are in the sync store already.
    struct Ledger: Codable {
        /// 2: empty chats are rebuilt from their Memory transcript.
        static let currentVersion = 2

        var version = Ledger.currentVersion
        var done = false
        var imported: Set<UUID> = []

        var isFinished: Bool { done && version >= Self.currentVersion }

        static var url: URL { OsaurusPaths.syncLocalState().appendingPathComponent("legacy-import.json") }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            done = try container.decode(Bool.self, forKey: .done)
            imported = try container.decode(Set<UUID>.self, forKey: .imported)
        }

        static func load() -> Ledger {
            guard let data = try? Data(contentsOf: url) else { return Ledger() }
            return (try? JSONDecoder().decode(Ledger.self, from: data)) ?? Ledger()
        }

        mutating func finish() {
            done = true
            version = Self.currentVersion
            save()
        }

        func save() {
            do {
                try FileManager.default.createDirectory(
                    at: OsaurusPaths.syncLocalState(), withIntermediateDirectories: true)
                try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
            } catch {
                SyncLegacyImporter.log.error("ledger write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    #if DEBUG
        func _resetForTesting() {
            task?.cancel()
            task = nil
            if let openObserver { NotificationCenter.default.removeObserver(openObserver) }
            openObserver = nil
            state = .idle
        }
    #endif
}
