//
//  SandboxAgentUIDs.swift
//  osaurus
//
//  Stable guest UID per sandbox Linux user. Each agent has its own
//  container, so `adduser` alone would give every agent the same first
//  free UID, and the guest kernel counts per-UID limits (`RLIMIT_NPROC`)
//  across all containers.
//

import Foundation

public enum SandboxAgentUIDs {
    static let firstUID: UInt32 = 10_000
    static let lastUID: UInt32 = 59_999

    private static let lock = NSLock()

    private static var fileURL: URL {
        OsaurusPaths.config().appendingPathComponent("sandbox-agent-uids.json")
    }

    /// The UID `linuxName` was given, allocating the next free one on first
    /// use. Nil only when the whole range is taken.
    public static func uid(for linuxName: String) -> UInt32? {
        lock.withLock {
            var map = load()
            if let uid = map[linuxName] { return uid }
            let used = Set(map.values)
            guard let next = nextFree(after: map.values.max(), used: used) else { return nil }
            map[linuxName] = next
            save(map)
            return next
        }
    }

    static func nextFree(after highest: UInt32?, used: Set<UInt32>) -> UInt32? {
        guard let highest else { return firstUID }
        if highest < lastUID { return max(highest + 1, firstUID) }
        return (firstUID ... lastUID).first { !used.contains($0) }
    }

    private static func load() -> [String: UInt32] {
        guard let data = try? Data(contentsOf: fileURL),
            let map = try? JSONDecoder().decode([String: UInt32].self, from: data)
        else { return [:] }
        return map
    }

    private static func save(_ map: [String: UInt32]) {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(map).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[SandboxAgentUIDs] Failed to save: \(error)")
        }
    }
}
