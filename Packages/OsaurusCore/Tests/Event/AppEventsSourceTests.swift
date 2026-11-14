//
//  AppEventsSourceTests.swift
//  osaurusTests
//
//  The "App event" automation: Osaurus starting, the automation created
//  on or turned on, and saved with a change — and a save that changes
//  nothing firing nothing.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AppEventsSourceTests {
    private func appEvent(_ reasons: [AppEventReason], enabled: Bool = true) -> OsaurusEvent {
        var event = OsaurusEvent(
            name: "On app event", source: .app(AppEventsSourceConfig(reasons: reasons)),
            action: EventPipelineFixtures.agentAction())
        event.isEnabled = enabled
        return event
    }

    private func reasons(_ runner: FakeEventRunner) -> [String?] {
        runner.fired.map { $0.payload.value(atPath: "app.reason")?.stringValue }
    }

    @Test func createdOnAndTurnedOnFireEnabled() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let on = manager.create(appEvent([.automationEnabled]))
        await runner.waitForFires(1)
        #expect(reasons(runner) == ["automation_enabled"])
        #expect(runner.fired.first?.eventId == on.id)
        #expect(runner.fired.first?.payload.value(atPath: "app.automation.id")?.stringValue == on.id.uuidString)

        let off = manager.create(appEvent([.automationEnabled], enabled: false))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.count == 1, "created off fires nothing")
        manager.setEnabled(off.id, enabled: true)
        await runner.waitForFires(2)
        #expect(runner.fired.last?.eventId == off.id)
        manager.setEnabled(off.id, enabled: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.count == 2, "turning it off fires nothing")
    }

    @Test func changesFireUpdatedButANoOpSaveDoesNot() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        var event = manager.create(appEvent([.automationUpdated]))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.isEmpty, "automation_enabled is not selected")

        manager.update(event)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.isEmpty, "saving it unchanged fires nothing")

        event.action = .agent(AgentEventAction(target: event.action.agent?.target, instructions: "Something else"))
        manager.update(event)
        await runner.waitForFires(1)
        #expect(reasons(runner) == ["automation_updated"])
    }

    @Test func runBookkeepingIsNotAnEdit() {
        let before = appEvent([.automationUpdated])
        var after = before
        after.updatedAt = Date().addingTimeInterval(60)
        after.lastFiredAt = Date()
        after.lastStatus = .succeeded
        #expect(!AppEventsSource.isEdit(from: before, to: after))
        after.name = "Renamed"
        #expect(AppEventsSource.isEdit(from: before, to: after))
    }

    @Test func launchFiresOnceForEventsThatSelectIt() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let launch = manager.create(appEvent([.appLaunched]))
        _ = manager.create(appEvent([.appLaunched], enabled: false))
        _ = manager.create(appEvent([.automationUpdated]))
        let source = try #require(manager.adapter(for: .app) as? AppEventsSource)
        await source.start()
        await source.start()
        await runner.waitForFires(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.map(\.eventId) == [launch.id])
        #expect(reasons(runner) == ["app_launched"])
        #expect(runner.fired.first?.payload.value(atPath: "app.app_version")?.stringValue?.isEmpty == false)
    }

    @Test func runNowUsesTheFirstSelectedReason() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let event = manager.create(appEvent([.automationUpdated, .appLaunched]))
        let result = await manager.fireNow(event.id)
        #expect(result.accepted)
        await runner.waitForFires(1)
        #expect(reasons(runner) == ["app_launched"], "reasons are kept in a fixed order")
        #expect(runner.fired.first?.trigger == .manual)
    }
}
