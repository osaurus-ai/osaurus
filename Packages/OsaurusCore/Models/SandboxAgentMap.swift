//
//  SandboxAgentMap.swift
//  osaurus
//
//  Persistent bidirectional mapping between Linux usernames and agent UUIDs.
//  Populated when agent users are created in the container, used by the
//  Host API bridge to resolve which agent is making a request.
//

import Foundation

public enum SandboxAgentMap {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    private static var mapURL: URL {
        OsaurusPaths.config().appendingPathComponent("sandbox-agent-map.json")
    }

    // MARK: - Public API

    public static func register(linuxName: String, agentId: String) {
        var map = load()
        map[linuxName] = agentId
        save(map)
    }

    public static func resolve(linuxName: String) -> UUID? {
        let map = load()
        guard let idStr = map[linuxName] else { return nil }
        return UUID(uuidString: idStr)
    }

    public static func linuxName(for agentId: String) -> String? {
        let map = load()
        return map.first(where: { $0.value == agentId })?.key
    }

    public static func all() -> [String: String] {
        return load()
    }

    // MARK: - Persistence

    private static func load() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache { return cached }

        guard let data = try? Data(contentsOf: mapURL),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            cache = [:]
            return [:]
        }
        cache = map
        return map
    }

    private static func save(_ map: [String: String]) {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(map)
            try data.write(to: mapURL, options: .atomic)
            lock.withLock { cache = map }
        } catch {
            NSLog("[SandboxAgentMap] Failed to save: \(error)")
        }
    }
}
