//
//  AgentRunPowerManager.swift
//  osaurus
//
//  Holds a single process activity while agent work is running so macOS
//  cannot enter idle system sleep before the work finishes.
//

import Foundation

/// Owns Osaurus' idle-system-sleep assertion for active agent work.
///
/// The display remains free to sleep. Explicit Sleep, closing a MacBook lid,
/// shutdown, and low-power system actions are never overridden.
@MainActor
final class AgentRunPowerManager {
    static let shared = AgentRunPowerManager()
    static let keepAwakeDefaultsKey = "agentRunsKeepMacAwake"

    typealias BeginActivity = (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    typealias EndActivity = (NSObjectProtocol) -> Void

    private let defaults: UserDefaults
    private let beginActivity: BeginActivity
    private let endActivity: EndActivity
    private var activityToken: NSObjectProtocol?

    private(set) var isPreventingIdleSystemSleep = false

    init(
        defaults: UserDefaults = .standard,
        beginActivity: @escaping BeginActivity = { options, reason in
            ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        },
        endActivity: @escaping EndActivity = { token in
            ProcessInfo.processInfo.endActivity(token)
        }
    ) {
        self.defaults = defaults
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    /// Refresh the assertion from the current preference and task statuses.
    /// Running and queued work keeps the Mac awake; a task paused for user
    /// input does not hold power indefinitely.
    func update(for statuses: [BackgroundTaskStatus]) {
        let shouldPreventSleep = Self.shouldPreventIdleSystemSleep(
            statuses: statuses,
            preferenceEnabled: Self.isKeepAwakeEnabled(in: defaults)
        )
        setPreventingIdleSystemSleep(shouldPreventSleep)
    }

    static func isKeepAwakeEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepAwakeDefaultsKey) as? Bool ?? true
    }

    static func shouldPreventIdleSystemSleep(
        statuses: [BackgroundTaskStatus],
        preferenceEnabled: Bool
    ) -> Bool {
        guard preferenceEnabled else { return false }
        return statuses.contains { status in
            switch status {
            case .running, .queued:
                return true
            case .waitingForInput, .completed, .failed, .cancelled:
                return false
            }
        }
    }

    private func setPreventingIdleSystemSleep(_ shouldPrevent: Bool) {
        guard shouldPrevent != isPreventingIdleSystemSleep else { return }

        if shouldPrevent {
            activityToken = beginActivity(
                [.userInitiated, .idleSystemSleepDisabled],
                "Running agent sessions"
            )
            isPreventingIdleSystemSleep = true
        } else {
            guard let activityToken else {
                isPreventingIdleSystemSleep = false
                return
            }
            self.activityToken = nil
            endActivity(activityToken)
            isPreventingIdleSystemSleep = false
        }
    }
}
