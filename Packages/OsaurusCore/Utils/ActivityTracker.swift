//
//  ActivityTracker.swift
//  osaurus
//
//  Periodic cleanup utility for the memory system.
//  Summary generation is handled by MemoryService's per-conversation debounce.
//

import Foundation

@MainActor
public final class ActivityTracker: ObservableObject {
    public static let shared = ActivityTracker()

    private var timer: Timer?
    private static let pollInterval: TimeInterval = 30
    private var lastPurge: Date = .distantPast
    private static let purgeInterval: TimeInterval = 24 * 60 * 60

    private init() {}

    /// Start the polling timer. Call once at app startup.
    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.periodicCleanup()
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

    private func periodicCleanup() {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }
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
