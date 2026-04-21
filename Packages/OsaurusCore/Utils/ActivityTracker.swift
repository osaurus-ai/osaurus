//
//  ActivityTracker.swift
//  osaurus
//
//  Periodic purge timer for the memory subsystem. Polls every 30s and
//  triggers a daily call to `purgeOldEventData` (processing logs +
//  processed pending signals). Distillation, decay, and eviction all live
//  elsewhere — this is just the housekeeping ticker that survives across
//  rewrites.
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
                self?.purgeIfNeeded()
            }
        }
    }

    /// Stop the polling timer.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func purgeIfNeeded() {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }
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
