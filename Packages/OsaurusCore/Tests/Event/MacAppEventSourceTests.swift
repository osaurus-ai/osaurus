//
//  MacAppEventSourceTests.swift
//  osaurusTests
//
//  The "Mac App" automation: its config and words, the descriptor and
//  payload, firing only the enabled automations watching that app for
//  that event, observing only while one needs it, and Run Now.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct MacAppEventSourceTests {
    private static let xcode = "com.apple.dt.Xcode"

    private func watch(
        _ bundleID: String = xcode,
        name: String = "Xcode",
        _ events: [MacAppEvent] = [.launched],
        enabled: Bool = true
    ) -> OsaurusEvent {
        var event = OsaurusEvent(
            name: "Watch \(name)",
            source: .macApp(MacAppSourceConfig(bundleID: bundleID, name: name, events: events)),
            action: EventPipelineFixtures.agentAction()
        )
        event.isEnabled = enabled
        return event
    }

    /// The adapter with a private notification center, so real app
    /// switching on this Mac cannot fire anything.
    private func source(_ manager: EventManager, installed: Set<String> = [xcode]) throws -> MacAppEventSource {
        let source = try #require(manager.adapter(for: .macApp) as? MacAppEventSource)
        source.center = NotificationCenter()
        source.appInstalled = { installed.contains($0) }
        return source
    }

    // MARK: Config

    @Test func configKeepsEventsInOrderAndDecodesOldShapes() throws {
        let config = MacAppSourceConfig(
            bundleID: " com.apple.dt.Xcode ",
            name: " Xcode ",
            events: [.quit, .launched, .quit]
        )
        #expect(config.bundleID == Self.xcode)
        #expect(config.name == "Xcode")
        #expect(config.events == [.launched, .quit])
        #expect(config.phrase == "Xcode opens or quits")
        #expect(
            MacAppSourceConfig(bundleID: Self.xcode, name: "Xcode", events: [.launched, .quit, .activated]).phrase
                == "Xcode opens, quits, or comes to the front"
        )
        #expect(config.pastPhrase == "Xcode opened or quit")
        #expect(MacAppSourceConfig(bundleID: Self.xcode, name: "Xcode").pastPhrase == "Xcode opened")
        #expect(MacAppSourceConfig(bundleID: Self.xcode, events: [.activated]).phrase.hasPrefix(Self.xcode))
        #expect(MacAppSourceConfig().phrase.contains("an app"))

        let source = EventSource.macApp(config)
        let decoded = try JSONDecoder().decode(EventSource.self, from: JSONEncoder().encode(source))
        #expect(decoded == source)
        #expect(decoded.kind == .macApp)

        let bare = try JSONDecoder().decode(MacAppSourceConfig.self, from: Data(#"{"bundleID":"a.b"}"#.utf8))
        #expect(bare.events == [.launched], "events default to opening")
    }

    @Test func firesMatchesBundleIDsCaseInsensitively() {
        let config = MacAppSourceConfig(bundleID: Self.xcode, events: [.activated])
        #expect(config.fires(on: .activated, bundleID: "COM.APPLE.DT.XCODE"))
        #expect(!config.fires(on: .launched, bundleID: Self.xcode))
        #expect(!config.fires(on: .activated, bundleID: "com.apple.Safari"))
        #expect(!config.fires(on: .activated, bundleID: nil))
        #expect(!MacAppSourceConfig().fires(on: .launched, bundleID: ""))
    }

    @Test func descriptorAndPayloadShareTheMacAppRoot() {
        let descriptor = EventSourceRegistry.descriptor(for: .macApp)
        #expect(descriptor.payloadRoot == "mac_app")
        #expect(EventSourceRegistry.payloadRoots.contains("mac_app"))
        #expect(EventSourceRegistry.pickerKinds.contains(.macApp))
        #expect(descriptor.defaultDelivery.maxQueued == 0)
        #expect(descriptor.knownBinding(field: "app") == "{{mac_app.name}}")

        let event = watch()
        let payload = EventPayload.macApp(
            event: event,
            firedAt: Date(),
            what: .quit,
            name: "Xcode",
            bundleID: Self.xcode,
            pid: 7
        )
        #expect(payload.value(atPath: "text")?.stringValue == "Xcode quits")
        #expect(payload.value(atPath: "mac_app.event")?.stringValue == "quit")
        #expect(payload.value(atPath: "mac_app.bundle_id")?.stringValue == Self.xcode)
        #expect(payload.value(atPath: "mac_app.pid")?.numberValue == 7)
        #expect(EventTriggerValues.samplePayload(for: event, now: Date()).value(atPath: "mac_app.bundle_id") != nil)
        #expect(AutomationSentence.short(event).contains("Xcode opens"))
    }

    // MARK: Adapter

    @Test func appDidFiresOnlyEnabledAutomationsWatchingThatAppAndEvent() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let source = try source(manager)
        let opens = manager.create(watch(Self.xcode, [.launched]))
        _ = manager.create(watch(Self.xcode, [.launched], enabled: false))
        _ = manager.create(watch(Self.xcode, [.quit]))
        _ = manager.create(watch("com.apple.Safari", name: "Safari", [.launched]))

        source.appDid(.launched, bundleID: "com.apple.dt.xcode", name: nil, pid: 42)
        await runner.waitForFires(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.map(\.eventId) == [opens.id])
        let fired = try #require(runner.fired.first)
        #expect(fired.payload.value(atPath: "mac_app.event")?.stringValue == "launched")
        #expect(fired.payload.value(atPath: "mac_app.name")?.stringValue == "Xcode", "falls back to the chosen name")
        #expect(fired.payload.value(atPath: "mac_app.pid")?.numberValue == 42)
        #expect(fired.trigger != .manual)

        source.appDid(.launched, bundleID: nil, name: "Ghost", pid: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.count == 1, "an app with no bundle id fires nothing")
    }

    @Test func comingToTheFrontWhileLaunchingWaitsForTheLaunchOnlyWhenOpensIsWatched() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let source = try source(manager)
        let both = manager.create(watch(Self.xcode, [.launched, .activated]))
        let frontOnly = manager.create(watch(Self.xcode, [.activated]))

        source.appDid(.activated, bundleID: Self.xcode, name: "Xcode", pid: 7, launching: true)
        await runner.waitForFires(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.map(\.eventId) == [frontOnly.id], "only the automation not watching Opens takes it")

        source.appDid(.launched, bundleID: Self.xcode, name: "Xcode", pid: 7)
        await runner.waitForFires(2)
        let opened = try #require(runner.fired.last)
        #expect(opened.eventId == both.id)
        #expect(opened.payload.value(atPath: "mac_app.event")?.stringValue == "launched")

        source.appDid(.activated, bundleID: Self.xcode, name: "Xcode", pid: 7)
        await runner.waitForFires(4)
        #expect(Set(runner.fired.suffix(2).map(\.eventId)) == [both.id, frontOnly.id], "a later switch fires both")
    }

    @Test func observesOnlyWhileAnEnabledAutomationNeedsIt() async throws {
        let (manager, _) = try EventPipelineFixtures.manager()
        let source = try source(manager)
        await source.reconcile([])
        #expect(!source.isObserving)

        let off = watch(enabled: false)
        let unchosen = watch("", name: "")
        await source.reconcile([off, unchosen])
        #expect(!source.isObserving, "nothing armed: an automation off, and one with no app")

        let on = watch()
        await source.reconcile([off, on])
        #expect(source.isObserving)
        await source.reconcile([on])
        #expect(source.isObserving, "reconciling again keeps one set of observers")

        await source.reconcile([off])
        #expect(!source.isObserving)
        await source.reconcile([on])
        source.stop()
        #expect(!source.isObserving)
    }

    @Test func aMissingAppGetsANoteThatClearsWhenItIsInstalled() async throws {
        let (manager, _) = try EventPipelineFixtures.manager()
        var installed: Set<String> = []
        let source = try source(manager)
        source.appInstalled = { installed.contains($0) }
        let event = manager.create(watch())

        await source.reconcile([event])
        #expect(source.status(event.id).note?.contains("not installed") == true)

        installed = [Self.xcode]
        await source.reconcile([event])
        #expect(source.status(event.id).note == nil)

        installed = []
        await source.reconcile([event])
        source.forget(event.id)
        #expect(source.status(event.id).note == nil)
    }

    @Test func workspaceNotificationsReachTheAdapter() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let source = try source(manager)
        let current = NSRunningApplication.current
        // A test host with no bundle id cannot stand in for an app.
        guard let bundleID = current.bundleIdentifier else { return }
        let event = manager.create(watch(bundleID, name: "Runner", [.activated]))
        await source.reconcile([event])
        #expect(source.isObserving)

        source.center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: current]
        )
        await runner.waitForFires(1)
        #expect(runner.fired.first?.eventId == event.id)
        #expect(runner.fired.first?.payload.value(atPath: "mac_app.event")?.stringValue == "activated")
    }

    @Test func runNowUsesASampleThatLooksLikeTheApp() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        _ = try source(manager)
        let event = manager.create(watch(Self.xcode, [.quit, .activated]))
        let result = await manager.fireNow(event.id)
        #expect(result.accepted)
        await runner.waitForFires(1)
        let fired = try #require(runner.fired.first)
        #expect(fired.trigger == .manual)
        #expect(fired.payload.value(atPath: "mac_app.bundle_id")?.stringValue == Self.xcode)
    }
}
