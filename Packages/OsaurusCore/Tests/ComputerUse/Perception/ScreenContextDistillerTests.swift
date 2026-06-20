//
//  ScreenContextDistillerTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Pure-data coverage for the screen-context smart sampler. Drives the
//  distiller through `MockMacDriver` so working-app selection, the
//  Osaurus-exclusion fallback, focused-field extraction, the window list, and
//  the rendered block are all asserted without touching real Accessibility.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ScreenContextDistillerTests: XCTestCase {
    private let selfPid: Int32 = 999
    private let selfBundleId = "ai.osaurus.osaurus"

    // MARK: Fixtures

    private func safariSnapshot() -> CUSnapshot {
        CUSnapshot(
            snapshotId: 1,
            pid: 100,
            app: "Safari",
            focusedWindow: "Weather — Safari",
            tier: .ax,
            truncated: false,
            windows: [
                CUWindowSummary(id: 1, title: "Weather — Safari", focused: true, x: 0, y: 0, w: 1200, h: 800)
            ],
            elements: [
                CUElement(
                    id: "e1",
                    role: "textfield",
                    label: "Search",
                    value: "weather tomorrow",
                    placeholder: "Search or enter address",
                    windowId: 1,
                    focused: true
                ),
                CUElement(id: "e2", role: "button", label: "Go", windowId: 1),
                CUElement(id: "e3", role: "statictext", value: "Results for weather", windowId: 1),
            ],
            image: nil
        )
    }

    private func makeDriver(
        accessibility: Bool = true,
        apps: [CUAppListing],
        active: CUActiveWindow?,
        windowsByPid: [Int32: [CUWindowInfo]] = [:],
        snapshots: [Int32: [CUSnapshot]] = [:]
    ) -> MockMacDriver {
        MockMacDriver(
            availability: MacDriverAvailability(
                accessibility: accessibility,
                screenRecording: false,
                skyLight: false
            ),
            apps: apps,
            windowsByPid: windowsByPid,
            activeWindow: active,
            snapshots: snapshots
        )
    }

    // MARK: Tests

    func testUsesFrontmostNonSelfApp() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: "Weather — Safari", x: 0, y: 0, w: 1200, h: 800),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Weather — Safari",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ]
            ],
            snapshots: [100: [safariSnapshot()]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertTrue(snap.accessibilityGranted)
        XCTAssertEqual(snap.workingApp, "Safari")
        XCTAssertEqual(snap.workingWindowTitle, "Weather — Safari")
        XCTAssertEqual(snap.focusedElement?.role, "text field")
        XCTAssertEqual(snap.focusedElement?.value, "weather tomorrow")
        XCTAssertEqual(snap.activityGist, "In Safari — \"Weather — Safari\"; editing text field (draft present)")
        XCTAssertEqual(snap.windows.first?.app, "Safari")
        XCTAssertTrue(snap.windows.first?.frontmost ?? false)
        // The focused draft is not repeated in the on-screen sample; other text is.
        XCTAssertTrue(snap.sampledContents.contains("Go"))
        XCTAssertTrue(snap.sampledContents.contains("Results for weather"))
        XCTAssertFalse(snap.sampledContents.contains("weather tomorrow"))
    }

    func testFallsBackToPreferredAppWhenOsaurusIsFrontmost() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: false, hidden: false)
            ],
            // Osaurus itself is frontmost (its pid == selfPid).
            active: CUActiveWindow(pid: selfPid, app: "Osaurus", title: "Chat", x: 0, y: 0, w: 600, h: 800),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Weather — Safari",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ]
            ],
            snapshots: [100: [safariSnapshot()]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: 100
        )

        XCTAssertEqual(snap.workingApp, "Safari")
        // No window is frontmost because the genuine frontmost app (Osaurus) is excluded.
        XCTAssertFalse(snap.windows.contains { $0.frontmost })
    }

    func testFallsBackToFirstVisibleAppWhenNoHint() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 200, bundleId: "com.apple.mail", name: "Mail", active: false, hidden: false),
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: false, hidden: false),
            ],
            active: CUActiveWindow(pid: selfPid, app: "Osaurus", title: "Chat", x: 0, y: 0, w: 600, h: 800),
            windowsByPid: [
                200: [
                    CUWindowInfo(
                        windowId: 9,
                        title: "Inbox",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1000,
                        h: 700
                    )
                ]
            ]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.workingApp, "Mail")
    }

    func testExcludesOsaurusOwnWindowsFromList() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false),
                // Osaurus shows up in the app list (dock-icon / .regular mode).
                CUAppListing(pid: selfPid, bundleId: selfBundleId, name: "Osaurus", active: false, hidden: false),
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: "Weather — Safari", x: 0, y: 0, w: 1200, h: 800),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Weather — Safari",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ],
                selfPid: [
                    CUWindowInfo(
                        windowId: 2,
                        title: "Osaurus Chat",
                        focused: false,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 600,
                        h: 800
                    )
                ],
            ],
            snapshots: [100: [safariSnapshot()]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertTrue(snap.windows.allSatisfy { $0.app != "Osaurus" })
    }

    func testWindowListIsCapped() async {
        let windows = (1 ... 5).map {
            CUWindowInfo(
                windowId: $0,
                title: "Tab \($0)",
                focused: $0 == 1,
                minimized: false,
                x: 0,
                y: 0,
                w: 100,
                h: 100
            )
        }
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: "Tab 1", x: 0, y: 0, w: 1200, h: 800),
            windowsByPid: [100: windows],
            snapshots: [100: [safariSnapshot()]]
        )

        let distiller = ScreenContextDistiller(maxWindows: 2)
        let snap = await distiller.capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.windows.count, 2)
    }

    func testRenderedBlockShape() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: "Weather — Safari", x: 0, y: 0, w: 1200, h: 800),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Weather — Safari",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ]
            ],
            snapshots: [100: [safariSnapshot()]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )
        let text = snap.render()

        XCTAssertTrue(text.hasPrefix(ScreenContextSnapshot.openTag))
        XCTAssertTrue(text.hasSuffix(ScreenContextSnapshot.closeTag))
        XCTAssertTrue(text.contains("Doing: In Safari"))
        XCTAssertTrue(text.contains("Focused field: text field"))
        XCTAssertTrue(text.contains("Open windows:"))
        XCTAssertTrue(text.contains("- Safari — \"Weather — Safari\" (frontmost)"))
        XCTAssertTrue(text.contains("On screen:"))
    }

    func testNoAccessibilityYieldsEmptySnapshot() async {
        let driver = makeDriver(
            accessibility: false,
            apps: [],
            active: nil
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertFalse(snap.accessibilityGranted)
        XCTAssertTrue(snap.isEmpty)
        XCTAssertEqual(snap.render(), "")
    }
}
