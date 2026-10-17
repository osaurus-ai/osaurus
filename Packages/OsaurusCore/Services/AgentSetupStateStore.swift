//
//  AgentSetupStateStore.swift
//  osaurus
//
//  Persisted "this agent still needs setup" markers. Every agent creation
//  path (create, duplicate, config apply, bundle import, backup restore,
//  template use) sets the marker through `AgentManager.
//  registerInDefaultSpawnPool`, the one hook all of them already call. The
//  marker is cleared the first time a readiness check finds nothing to fix,
//  or when the user finishes (or dismisses) the setup checklist.
//
//  Unlike `NewAgentHighlightStore` this survives relaunch: an agent the
//  orchestrator created with a folder path it cannot read must keep asking
//  for that folder until a human grants it, however many launches later.
//

import Combine
import Foundation

@MainActor
public final class AgentSetupStateStore: ObservableObject {
    public static let shared = AgentSetupStateStore()

    /// Agents whose first-run setup has not been confirmed yet.
    @Published public private(set) var pending: Set<UUID> = []

    private struct File: Codable {
        var version: Int = 1
        var pending: [UUID] = []
    }

    private init() {
        pending = Set(Self.read().pending)
    }

    // MARK: - Paths

    nonisolated static var fileURL: URL {
        OsaurusPaths.agents().appendingPathComponent("setup-pending.json")
    }

    private nonisolated static func read() -> File {
        guard let data = try? Data(contentsOf: fileURL),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return File() }
        return file
    }

    private func write() {
        let file = File(pending: pending.sorted { $0.uuidString < $1.uuidString })
        guard let data = try? JSONEncoder().encode(file) else { return }
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.agents())
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - API

    public func needsSetup(_ agentId: UUID) -> Bool {
        pending.contains(agentId)
    }

    /// Flag a freshly created agent. Idempotent.
    public func markNeedsSetup(_ agentId: UUID) {
        guard pending.insert(agentId).inserted else { return }
        write()
    }

    /// The agent has been checked (or set up) and nothing blocks it.
    public func clear(_ agentId: UUID) {
        guard pending.remove(agentId) != nil else { return }
        write()
    }

    /// Drop markers for agents that no longer exist.
    public func prune(existing: Set<UUID>) {
        let stale = pending.subtracting(existing)
        guard !stale.isEmpty else { return }
        pending.subtract(stale)
        write()
    }

    /// Test seam: forget everything in memory and on disk.
    func resetForTesting() {
        pending = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }
}
