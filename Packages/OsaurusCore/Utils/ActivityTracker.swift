//
//  ActivityTracker.swift
//  osaurus
//
//  Tracks per-agent activity timestamps and triggers post-activity
//  memory processing after the configured inactivity timeout.
//

import Foundation

@MainActor
public final class ActivityTracker: ObservableObject {
    public static let shared = ActivityTracker()

    private var timer: Timer?
    private static let pollInterval: TimeInterval = 30
    private var lastPurge: Date = .distantPast
    private static let purgeInterval: TimeInterval = 24 * 60 * 60
    private var processingAgentIds: Set<String> = []

    private init() {}

    /// Start the polling timer. Call once at app startup.
    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAgents()
            }
        }
    }

    /// Stop the polling timer.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Record activity for an agent. Called on every message send.
    public func recordActivity(agentId: String) {
        do {
            try MemoryDatabase.shared.updateAgentActivity(agentId: agentId)
        } catch {
            MemoryLogger.service.warning("Failed to record agent activity: \(error)")
        }
    }

    /// Check all agents for inactivity and trigger processing.
    private func checkAgents() {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        do { try MemoryDatabase.shared.resetStuckAgents(staleSeconds: 300) } catch {
            MemoryLogger.service.warning("Failed to reset stuck agents: \(error)")
        }

        let timeout = config.inactivityTimeoutSeconds

        let agentIds: [String]
        do {
            agentIds = try MemoryDatabase.shared.agentsNeedingProcessing(inactivitySeconds: timeout)
        } catch {
            MemoryLogger.service.error("Failed to query agents needing processing: \(error)")
            return
        }

        for agentId in agentIds {
            guard !processingAgentIds.contains(agentId) else { continue }
            processingAgentIds.insert(agentId)
            Task { @MainActor [weak self] in
                await MemoryService.shared.processPostActivity(agentId: agentId)
                self?.processingAgentIds.remove(agentId)
            }
        }

        purgeIfNeeded()
    }

    private func purgeIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPurge) >= Self.purgeInterval else { return }
        lastPurge = now
        Task.detached {
            do {
                try MemoryDatabase.shared.purgeOldEventData()
            } catch {
                MemoryLogger.database.error("Failed to purge old event data: \(error)")
            }
        }
    }
}
