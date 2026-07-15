//
//  AgentRunPowerManagerTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentRunPowerManagerTests {
    @Test func policyKeepsRunningAndQueuedWorkAwake() {
        #expect(
            AgentRunPowerManager.shouldPreventIdleSystemSleep(
                statuses: [.running],
                preferenceEnabled: true
            )
        )
        #expect(
            AgentRunPowerManager.shouldPreventIdleSystemSleep(
                statuses: [.queued, .waitingForInput],
                preferenceEnabled: true
            )
        )
    }

    @Test func policyAllowsSleepWhileWaitingOrTerminal() {
        #expect(
            !AgentRunPowerManager.shouldPreventIdleSystemSleep(
                statuses: [.waitingForInput],
                preferenceEnabled: true
            )
        )
        #expect(
            !AgentRunPowerManager.shouldPreventIdleSystemSleep(
                statuses: [
                    .completed(summary: "Done"),
                    .failed(summary: "Failed"),
                    .cancelled,
                ],
                preferenceEnabled: true
            )
        )
        #expect(
            !AgentRunPowerManager.shouldPreventIdleSystemSleep(
                statuses: [.running],
                preferenceEnabled: false
            )
        )
    }

    @Test func preferenceDefaultsOnAndHonorsExplicitOff() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AgentRunPowerManager.isKeepAwakeEnabled(in: defaults))
        defaults.set(false, forKey: AgentRunPowerManager.keepAwakeDefaultsKey)
        #expect(!AgentRunPowerManager.isKeepAwakeEnabled(in: defaults))
    }

    @Test func assertionStartsOnceAndReleasesWhenWorkStops() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var beginCount = 0
        var endCount = 0
        var capturedOptions: ProcessInfo.ActivityOptions = []
        let token = NSObject()
        let manager = AgentRunPowerManager(
            defaults: defaults,
            beginActivity: { options, _ in
                beginCount += 1
                capturedOptions = options
                return token
            },
            endActivity: { _ in endCount += 1 }
        )

        manager.update(for: [.running])
        #expect(manager.isPreventingIdleSystemSleep)
        #expect(beginCount == 1)
        #expect(capturedOptions.contains(.userInitiated))
        #expect(capturedOptions.contains(.idleSystemSleepDisabled))

        manager.update(for: [.running, .queued])
        #expect(beginCount == 1)

        manager.update(for: [.waitingForInput])
        #expect(!manager.isPreventingIdleSystemSleep)
        #expect(endCount == 1)

        manager.update(for: [.completed(summary: "Done")])
        #expect(endCount == 1)
    }

    @Test func disablingPreferenceReleasesActiveAssertion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var endCount = 0
        let manager = AgentRunPowerManager(
            defaults: defaults,
            beginActivity: { _, _ in NSObject() },
            endActivity: { _ in endCount += 1 }
        )

        manager.update(for: [.running])
        #expect(manager.isPreventingIdleSystemSleep)

        defaults.set(false, forKey: AgentRunPowerManager.keepAwakeDefaultsKey)
        manager.update(for: [.running])
        #expect(!manager.isPreventingIdleSystemSleep)
        #expect(endCount == 1)
    }

    @Test func backgroundTaskLifecycleDrivesAssertion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var beginCount = 0
        var endCount = 0
        let powerManager = AgentRunPowerManager(
            defaults: defaults,
            beginActivity: { _, _ in
                beginCount += 1
                return NSObject()
            },
            endActivity: { _ in endCount += 1 }
        )
        let taskManager = BackgroundTaskManager.makeForTesting(powerManager: powerManager)
        let state = BackgroundTaskState(
            retainedId: UUID(),
            taskTitle: "Power lifecycle",
            agentId: UUID(),
            status: .running,
            createdAt: Date(),
            source: .chat,
            sourcePluginId: nil,
            externalSessionKey: nil,
            contextPreview: []
        )

        taskManager.registerTaskForTesting(state)
        #expect(beginCount == 1)
        #expect(taskManager.isPreventingIdleSystemSleep)

        taskManager.cancelTask(state.id)
        #expect(endCount == 1)
        #expect(!taskManager.isPreventingIdleSystemSleep)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AgentRunPowerManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
