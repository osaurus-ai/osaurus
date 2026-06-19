//
//  BackgroundDriverRouteTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Regression guard for the SkyLight + CGEvent.postToPid double-delivery:
//  SLEventPostToPid returns a non-zero status (0xB0000000) on success, so the
//  old `postEvent` `== 0` check always reported failure and `route` ALSO posted
//  via postToPid — delivering every keystroke and click twice. These tests pin
//  each synthesized event to exactly one transport via injected spies (no live
//  app or Accessibility permission required).
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
    }

    private func makeDriver(
        spy: TransportSpy,
        skyLightAvailable: Bool,
        chromium: Bool = false
    ) -> BackgroundDriver {
        var t = BackgroundDriver.Transports.live
        t.isWindowServerVisible = { _ in true }
        t.skyLightAvailable = { skyLightAvailable }
        t.skyLightPost = { _, _ in
            spy.skyLight += 1; return true
        }
        t.postToPid = { _, _ in spy.postToPid += 1 }
        t.hidPost = { _ in spy.hid += 1 }
        t.isChromium = { _ in chromium }
        t.focusWithoutRaise = { _ in }
        return BackgroundDriver(transports: t)
    }

    func testKeyPressPostsViaSkyLightExactlyOncePerEvent() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        XCTAssertTrue(result.success)
        // keyDown + keyUp, each delivered through SkyLight only.
        XCTAssertEqual(spy.skyLight, 2)
        XCTAssertEqual(spy.postToPid, 0, "SkyLight is terminal — postToPid must not double-deliver")
        XCTAssertEqual(spy.hid, 0)
        XCTAssertEqual(driver.lastRoute, .skyLight)
    }

    func testTypePostsEachCharacterExactlyOnceViaSkyLight() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.type(pid: 4242, text: "hello world")

        XCTAssertTrue(result.success)
        // 11 characters × (keyDown + keyUp) = 22 posts, with no duplication.
        XCTAssertEqual(spy.skyLight, 22)
        XCTAssertEqual(spy.postToPid, 0, "the doubling bug would make this 44")
        XCTAssertEqual(spy.hid, 0)
    }

    func testClickPostsDownUpViaSkyLightWithoutDuplication() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: true)

        let result = driver.click(pid: 4242, point: CGPoint(x: 10, y: 10))

        XCTAssertTrue(result.success)
        // mouseDown + mouseUp via SkyLight only.
        XCTAssertEqual(spy.skyLight, 2)
        XCTAssertEqual(spy.postToPid, 0)
        XCTAssertEqual(spy.hid, 0)
        XCTAssertEqual(driver.lastRoute, .skyLight)
    }

    func testFallsBackToPostToPidOnlyWhenSkyLightUnavailable() {
        let spy = TransportSpy()
        let driver = makeDriver(spy: spy, skyLightAvailable: false)

        let result = driver.pressKey(pid: 4242, keyCode: 0)

        XCTAssertTrue(result.success)
        XCTAssertEqual(spy.skyLight, 0)
        XCTAssertEqual(spy.postToPid, 2, "keyDown + keyUp via the CoreGraphics fallback")
        XCTAssertEqual(spy.hid, 0)
        XCTAssertEqual(driver.lastRoute, .perPid)
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
}
