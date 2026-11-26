//
//  BackgroundDriverRouteTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Regression guard for the SkyLight + CGEvent.postToPid double-delivery:
//  SkyLight's status is not a delivery acknowledgement: a completed call can
//  deliver even when it returns zero. These tests pin each synthesized event to
//  exactly one app-class-selected transport via injected spies (no live app or
//  Accessibility permission required).
//

import CoreGraphics
import XCTest

@testable import OsaurusCore

final class BackgroundDriverRouteTests: XCTestCase {

    /// Counts posts per transport. `@unchecked Sendable`: only ever mutated on
    /// the calling thread inside a single synchronous driver call.
    private final class TransportSpy: @unchecked Sendable {
        var skyLight = 0
        var postToPid = 0
        var hid = 0
        var events: [CGEvent] = []
        var focusedWindows: [CGWindowID?] = []
    }

    private func makeDriver(
        spy: TransportSpy,
        skyLightAvailable: Bool,
        chromium: Bool = false,
        skyLightAccepted: Bool = true,
        windowUnderPoint: CGWindowID? = nil,
        visible: Bool = true
    ) -> BackgroundDriver {
        var t = BackgroundDriver.Transports.live
        t.isWindowServerVisible = { _ in visible }
        t.skyLightAvailable = { skyLightAvailable }
        t.skyLightPost = { event, _ in
            spy.skyLight += 1; spy.events.append(event); return skyLightAccepted
        }
        t.postToPid = { event, _ in spy.postToPid += 1; spy.events.append(event) }
        t.hidPost = { event in spy.hid += 1; spy.events.append(event) }
        t.isChromium = { _ in chromium }
        t.focusWithoutRaise = { _, window in spy.focusedWindows.append(window) }
        t.windowAt = { _, _ in windowUnderPoint }
        t.pause = { _ in }
        return BackgroundDriver(transports: t)
    }

    /// A pid that quit has no WindowServer connection: nothing is posted, and
    /// no input kind claims it was delivered.
    func testInputForAnExitedPidFailsWithoutPosting() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true, visible: false)
        let point = CGPoint(x: 10, y: 10)

        let results = [
            driver.click(pid: 4242, point: point),
            driver.doubleClick(pid: 4242, point: point),
            driver.move(pid: 4242, to: point),
            driver.type(pid: 4242, text: "hi"),
            driver.pressKey(pid: 4242, keyCode: 0),
            driver.scroll(pid: 4242, direction: .down, at: point),
            driver.drag(pid: 4242, from: point, to: CGPoint(x: 80, y: 80)),
        ]

        XCTAssertTrue(results.allSatisfy { !$0.success }, "\(results.map(\.error))")
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertTrue(spy.focusedWindows.isEmpty, "focus must not be routed to a dead pid")
    }

    func testCocoaKeyPressUsesOnlyPublicPerPidEvenWhenSkyLightExists() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        XCTAssertTrue(result.success)
        XCTAssertEqual(spy.skyLight, 0, "Cocoa must not receive a private transport attempt")
        XCTAssertEqual(spy.postToPid, 2, "keyDown + keyUp use public CoreGraphics once each")
        XCTAssertEqual(spy.hid, 0)
        XCTAssertEqual(driver.lastRoute, .perPid)
    }

    func testCocoaTypePostsEachCharacterExactlyOnceViaPublicPerPid() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.type(pid: 4242, text: "hello world")

        XCTAssertTrue(result.success)
        // 11 characters × (keyDown + keyUp) = 22 posts on one transport.
        XCTAssertEqual(spy.skyLight, 0)
        XCTAssertEqual(spy.postToPid, 22, "the double-delivery bug would also call SkyLight")
        XCTAssertEqual(spy.hid, 0)
    }

    func testCocoaClickPostsDownUpViaPublicPerPidWithoutPrivateAttempt() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.click(pid: 4242, point: CGPoint(x: 10, y: 10))

        XCTAssertTrue(result.success)
        XCTAssertEqual(spy.skyLight, 0)
        XCTAssertEqual(spy.postToPid, 2)
        XCTAssertEqual(spy.hid, 0)
        XCTAssertEqual(driver.lastRoute, .perPid)
    }

    func testCocoaPerPidRouteDoesNotDependOnSkyLightAvailability() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: false)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        XCTAssertTrue(result.success)
        XCTAssertEqual(spy.skyLight, 0)
        XCTAssertEqual(spy.postToPid, 2, "keyDown + keyUp via the CoreGraphics fallback")
        XCTAssertEqual(spy.hid, 0)
        XCTAssertEqual(driver.lastRoute, .perPid)
    }

    func testCocoaNeverCallsSkyLightEvenWhenItsStubWouldReturnFalse() {
        let spy = TransportSpy()
        let driver = makeDriver(
            spy: spy,
            skyLightAvailable: true,
            skyLightAccepted: false
        )

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        XCTAssertTrue(result.success)
        XCTAssertEqual(spy.skyLight, 0)
        XCTAssertEqual(spy.postToPid, 2)
        XCTAssertEqual(spy.hid, 0)
        XCTAssertEqual(driver.lastRoute, .perPid)
    }

    func testChromiumSkyLightCallIsTerminalEvenWhenStatusIsFalse() {
        let spy = TransportSpy()
        let driver = makeDriver(
            spy: spy,
            skyLightAvailable: true,
            chromium: true,
            skyLightAccepted: false
        )

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        XCTAssertTrue(result.success)
        // Primer down/up plus key down/up each use SkyLight exactly once. The
        // returned Bool is deliberately not used for a same-event fallback.
        XCTAssertEqual(spy.skyLight, 4)
        XCTAssertEqual(spy.postToPid, 0)
        XCTAssertEqual(spy.hid, 0)
        XCTAssertEqual(driver.lastRoute, .skyLight)
    }

    // MARK: - Chromium / Electron HID escalation

    func testChromiumKeyPressEscalatesToHidWhenSkyLightUnavailable() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: false, chromium: true)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        XCTAssertTrue(result.success)
        // Chromium web content silently drops per-pid events, so the fallback
        // path escalates to the HID tap rather than posting a per-pid event
        // that never lands. `pressKey` first runs the Chromium user-activation
        // primer (a -1,-1 decoy down/up pair), so: 2 decoy + keyDown + keyUp.
        XCTAssertEqual(spy.postToPid, 0, "per-pid is unreliable for Chromium; must escalate to HID")
        XCTAssertEqual(spy.hid, 4, "decoy click pair + keyDown + keyUp, all via the HID tap")
        XCTAssertEqual(spy.skyLight, 0)
        XCTAssertEqual(driver.lastRoute, .hidFallback)
    }

    func testChromiumPrefersSkyLightWhenAvailable() {
        // SkyLight is trusted by Chromium renderers, so when it's available
        // there is no cursor-warping HID needed.
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true, chromium: true)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        XCTAssertTrue(result.success)
        // Decoy click pair (2) + keyDown + keyUp (2), all via SkyLight.
        XCTAssertEqual(spy.skyLight, 4)
        XCTAssertEqual(spy.hid, 0, "no HID warp needed when SkyLight is available")
        XCTAssertEqual(spy.postToPid, 0)
        XCTAssertEqual(driver.lastRoute, .skyLight)
    }

    func testChromiumClickEscalatesDecoyAndRealClickToHid() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: false, chromium: true)

        let result = driver.click(pid: 4242, point: CGPoint(x: 10, y: 10))

        XCTAssertTrue(result.success)
        // Decoy (-1,-1) down/up + real down/up = 4 events, all via HID since
        // SkyLight is unavailable and per-pid won't deliver to the renderer.
        XCTAssertEqual(spy.hid, 4)
        XCTAssertEqual(spy.postToPid, 0)
        XCTAssertEqual(driver.lastRoute, .hidFallback)
    }

    // MARK: - Window binding

    private func boundWindow(_ event: CGEvent) -> Int64 {
        event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
    }

    func testClickBindsEventsToTheElementWindowAndFocusesIt() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true, windowUnderPoint: 99)

        let result = driver.click(pid: 4242, point: CGPoint(x: 10, y: 10), windowId: 7)

        XCTAssertTrue(result.success)
        XCTAssertEqual(spy.events.count, 2)
        XCTAssertEqual(spy.events.map(boundWindow), [7, 7], "an explicit window wins over the point lookup")
        XCTAssertEqual(
            spy.events.map { $0.getIntegerValueField(.mouseEventWindowUnderMousePointer) },
            [7, 7]
        )
        XCTAssertEqual(spy.focusedWindows, [7])
        XCTAssertTrue(spy.events.allSatisfy(ComputerUseEventTag.isSynthesized))
    }

    func testClickWithoutWindowFallsBackToTheWindowUnderThePoint() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true, windowUnderPoint: 99)

        _ = driver.click(pid: 4242, point: CGPoint(x: 10, y: 10))

        XCTAssertEqual(spy.events.map(boundWindow), [99, 99])
        XCTAssertEqual(spy.postToPid, 2, "binding does not add a transport")
    }

    func testChromiumDecoyClickIsNotBoundToTheWindow() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true, chromium: true)

        _ = driver.click(pid: 4242, point: CGPoint(x: 10, y: 10), windowId: 7)

        XCTAssertEqual(spy.skyLight, 4)
        XCTAssertEqual(spy.events.map(boundWindow), [0, 0, 7, 7], "the off-screen decoy must stay unbound")
    }

    func testScrollAtPointIsPlacedThere() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.scroll(pid: 4242, direction: .down, amount: 3, at: CGPoint(x: 300, y: 200))

        XCTAssertTrue(result.success)
        XCTAssertEqual(spy.postToPid, 1)
        XCTAssertEqual(spy.events.first?.location, CGPoint(x: 300, y: 200))
    }

    // MARK: - Drag

    func testCocoaDragUsesPerPidPathWithoutHid() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true, windowUnderPoint: 5)
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 200, y: 0)

        let result = driver.drag(pid: 4242, from: start, to: end)

        XCTAssertTrue(result.success)
        let path = BackgroundDriver.dragPath(from: start, to: end)
        XCTAssertEqual(spy.hid, 0, "drag no longer warps the user's cursor")
        XCTAssertEqual(spy.skyLight, 0)
        XCTAssertEqual(spy.postToPid, path.count + 2, "down + one event per path point + up")
        XCTAssertEqual(spy.events.first?.type, .leftMouseDown)
        XCTAssertEqual(spy.events.last?.type, .leftMouseUp)
        XCTAssertEqual(spy.events.last?.location, end)
        XCTAssertTrue(spy.events.dropFirst().dropLast().allSatisfy { $0.type == .leftMouseDragged })
        XCTAssertTrue(spy.events.allSatisfy { boundWindow($0) == 5 })
        XCTAssertEqual(driver.lastRoute, .perPid)
    }

    func testDragPathIsMonotonicAndEndsAtTheDestination() {
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 410, y: 310)
        let path = BackgroundDriver.dragPath(from: start, to: end)
        XCTAssertGreaterThanOrEqual(path.count, 4)
        XCTAssertLessThanOrEqual(path.count, 30)
        XCTAssertEqual(path.last, end)
        XCTAssertEqual(path, path.sorted { $0.x < $1.x }, "points advance toward the destination")
        XCTAssertEqual(BackgroundDriver.dragPath(from: start, to: start).count, 4, "a zero-length drag still moves")
    }
}
