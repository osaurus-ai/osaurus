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
        try? MemoryDatabase.shared.updateAgentActivity(agentId: agentId)
    }

    /// Check all agents for inactivity and trigger processing.
    private func checkAgents() {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        let timeout = config.inactivityTimeoutSeconds

        guard let agentIds = try? MemoryDatabase.shared.agentsNeedingProcessing(inactivitySeconds: timeout) else {
            return
        }

        for agentId in agentIds {
            Task.detached {
                await MemoryService.shared.processPostActivity(agentId: agentId)
            }
        }
    }
}
