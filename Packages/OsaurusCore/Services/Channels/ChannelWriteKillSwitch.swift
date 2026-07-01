//
//  ChannelWriteKillSwitch.swift
//  osaurus
//
//  Persistent global write gate for remote/channel actions.
//

import Foundation

struct ChannelWriteKillSwitchSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var writeEnabled: Bool
    var generation: Int
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        writeEnabled: Bool = true,
        generation: Int = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.schemaVersion = schemaVersion
        self.writeEnabled = writeEnabled
        self.generation = generation
        self.updatedAt = updatedAt
    }
}

final class ChannelWriteKillSwitch: @unchecked Sendable {
    static let shared = ChannelWriteKillSwitch()
    private static let corruptionRecoveryBaseGeneration = Int.max / 2

    private let fileURL: URL
    private let queue = DispatchQueue(label: "ai.osaurus.channels.write-kill-switch")

    init(fileURL: URL? = nil) {
        self.fileURL =
            fileURL
            ?? OsaurusPaths.config().appendingPathComponent("channel-write-kill-switch.json")
    }

    func snapshot() -> ChannelWriteKillSwitchSnapshot {
        queue.sync {
            switch loadStateUnlocked() {
            case .loaded(let snapshot):
                return snapshot
            case .missing:
                return ChannelWriteKillSwitchSnapshot()
            case .corrupt:
                return failClosedSnapshot(now: Date())
            }
        }
    }

    @discardableResult
    func disableWrites(now: Date = Date()) throws -> ChannelWriteKillSwitchSnapshot {
        try setWriteEnabled(false, now: now)
    }

    @discardableResult
    func enableWrites(now: Date = Date()) throws -> ChannelWriteKillSwitchSnapshot {
        try setWriteEnabled(true, now: now)
    }

    @discardableResult
    func setWriteEnabled(_ enabled: Bool, now: Date = Date()) throws -> ChannelWriteKillSwitchSnapshot {
        try queue.sync {
            let loaded = loadForMutationUnlocked(now: now)
            var current = loaded.snapshot
            var shouldSave = loaded.recoveredFromCorruption
            if current.writeEnabled != enabled {
                current.writeEnabled = enabled
                if !enabled {
                    current.generation += 1
                }
                current.updatedAt = now
                shouldSave = true
            } else if loaded.recoveredFromCorruption {
                current.updatedAt = now
            }
            if shouldSave {
                try saveUnlocked(current)
            }
            return current
        }
    }

    private enum LoadState {
        case loaded(ChannelWriteKillSwitchSnapshot)
        case missing
        case corrupt
    }

    private func loadStateUnlocked() -> LoadState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        do {
            return .loaded(
                try JSONDecoder().decode(
                    ChannelWriteKillSwitchSnapshot.self,
                    from: Data(contentsOf: fileURL)
                )
            )
        } catch {
            return .corrupt
        }
    }

    private func loadForMutationUnlocked(now: Date) -> (
        snapshot: ChannelWriteKillSwitchSnapshot,
        recoveredFromCorruption: Bool
    ) {
        switch loadStateUnlocked() {
        case .loaded(let snapshot):
            return (snapshot, false)
        case .missing:
            return (ChannelWriteKillSwitchSnapshot(), false)
        case .corrupt:
            return (failClosedSnapshot(now: now), true)
        }
    }

    private func failClosedSnapshot(now: Date = Date()) -> ChannelWriteKillSwitchSnapshot {
        ChannelWriteKillSwitchSnapshot(
            writeEnabled: false,
            generation: Self.corruptionRecoveryGeneration(now: now),
            updatedAt: now
        )
    }

    private static func corruptionRecoveryGeneration(now: Date) -> Int {
        let maxOffset = Int.max - corruptionRecoveryBaseGeneration - 1
        let rawOffset = max(0, now.timeIntervalSince1970 * 1_000_000)
        let boundedOffset = min(rawOffset, Double(maxOffset))
        return corruptionRecoveryBaseGeneration + Int(boundedOffset)
    }

    private func saveUnlocked(_ snapshot: ChannelWriteKillSwitchSnapshot) throws {
        OsaurusPaths.ensureExistsSilent(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
    }
}
