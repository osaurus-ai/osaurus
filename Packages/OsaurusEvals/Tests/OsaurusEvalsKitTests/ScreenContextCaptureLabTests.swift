//
//  ScreenContextCaptureLabTests.swift
//  OsaurusEvalsKitTests
//
//  Security-focused coverage for the screen-context capture lab helpers.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

struct ScreenContextCaptureLabTests {

    @Test func captureSummaryFlagsLocalOnlyScreenText() {
        let fixture = Self.privateFixture()

        let summary = fixture.captureSummary()

        #expect(summary.workingApp == "Safari")
        #expect(summary.workingWindowTitle == "Checkout - ada@example.com")
        #expect(summary.appCount == 1)
        #expect(summary.windowCount == 1)
        #expect(summary.elementCount == 3)
        #expect(summary.textElementCount == 3)
        #expect(summary.secureFieldCount == 1)
        #expect(summary.pathFieldCount == 2)
        #expect(summary.focusedRole == "AXSecureTextField")
        #expect(summary.localOnlyReasons.contains("contains text read from the user's accessibility tree"))
        #expect(summary.localOnlyReasons.contains("contains secure-field metadata that must be reviewed"))
        #expect(summary.localOnlyReasons.contains("contains accessibility paths that can include private labels"))
        #expect(summary.localOnlyReasons.contains("contains window title metadata from the user's desktop"))
        #expect(summary.localOnlyReasons.contains("contains app metadata from the user's desktop"))
        #expect(summary.localOnlyReasons.contains("keep under Fixtures/ScreenContext/local/ until sanitized"))
    }

    @Test func captureSummaryFlagsTitleOnlyWindowMetadataAsLocalOnly() {
        let fixture = ScreenContextFixture(
            apps: [
                CUAppListing(
                    pid: 22,
                    bundleId: "com.apple.Terminal",
                    name: "Terminal",
                    active: true,
                    hidden: false
                )
            ],
            activeWindow: CUActiveWindow(
                pid: 22,
                app: "Terminal",
                title: "prod-token-reset.txt",
                x: 0,
                y: 0,
                w: 800,
                h: 500
            ),
            windowsByPid: [:],
            snapshot: ScreenContextFixture.Snapshot(
                app: "Terminal",
                focusedWindow: "prod-token-reset.txt",
                windows: [],
                elements: []
            )
        )

        let summary = fixture.captureSummary()

        #expect(summary.textElementCount == 0)
        #expect(summary.secureFieldCount == 0)
        #expect(summary.pathFieldCount == 0)
        #expect(summary.localOnlyReasons.contains("contains window title metadata from the user's desktop"))
        #expect(summary.localOnlyReasons.contains("contains app metadata from the user's desktop"))
        #expect(summary.localOnlyReasons.contains("keep under Fixtures/ScreenContext/local/ until sanitized"))
    }

    @Test func sanitizedPromotionDropsPrivateScreenContentAndKeepsReplayShape() throws {
        let fixture = Self.privateFixture()

        let candidate = fixture.sanitizedForPromotion()
        let sanitized = candidate.fixture
        let data = try JSONEncoder().encode(sanitized)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("ada@example.com"))
        #expect(!json.contains("card 4242"))
        #expect(!json.contains("hunter2"))
        #expect(!json.contains("/Users/ada"))
        #expect(!json.contains("Safari"))
        #expect(!json.contains("com.apple.Safari"))
        #expect(json.contains("Synthetic"))
        #expect(candidate.report.stringFieldsRedacted > 0)
        #expect(candidate.report.secureValuesDropped == 5)
        #expect(candidate.report.elementIDsRewritten == 3)
        #expect(candidate.report.pathFieldsDropped == 2)
        #expect(candidate.report.windowTitlesRedacted >= 3)
        #expect(candidate.report.appMetadataRedacted >= 4)

        #expect(sanitized.apps.first?.bundleId == nil)
        #expect(sanitized.apps.first?.name == "Synthetic App 1")
        #expect(sanitized.activeWindow?.app == "Synthetic App 1")
        #expect(sanitized.activeWindow?.title == "Synthetic App 1 Window")
        #expect(sanitized.snapshot.app == "Synthetic App 1")
        #expect(sanitized.snapshot.elements.map(\.id) == ["e1", "e2", "e3"])
        #expect(sanitized.snapshot.elements[0].role == "textfield")
        #expect(sanitized.snapshot.elements[0].x == 40)
        #expect(sanitized.snapshot.elements[0].actions == ["AXSetValue"])
        #expect(sanitized.snapshot.elements[1].role == "AXSecureTextField")
        #expect(sanitized.snapshot.elements[1].value == nil)
        #expect(sanitized.snapshot.elements.allSatisfy { $0.path == nil })
        #expect(sanitized.focusedContent?.role == "AXSecureTextField")
        #expect(sanitized.focusedContent?.value == nil)
        #expect(sanitized.focusedContent?.viewport == nil)
    }

    @Test func cuSnapshotAppliesElementBudgetWithoutLosingFixtureTruncation() {
        let fixture = Self.privateFixture()

        let clipped = fixture.cuSnapshot(pid: 701, snapshotId: 42, maxElements: 2)
        let full = fixture.cuSnapshot(pid: 701, snapshotId: 43, maxElements: nil)

        #expect(clipped.snapshotId == 42)
        #expect(clipped.pid == 701)
        #expect(clipped.elements.map(\.id) == ["email-field", "password-field"])
        #expect(clipped.truncated)
        #expect(full.elements.count == 3)
        #expect(full.truncated)
    }

    private static func privateFixture() -> ScreenContextFixture {
        ScreenContextFixture(
            apps: [
                CUAppListing(
                    pid: 701,
                    bundleId: "com.apple.Safari",
                    name: "Safari",
                    active: true,
                    hidden: false
                )
            ],
            activeWindow: CUActiveWindow(
                pid: 701,
                app: "Safari",
                title: "Checkout - ada@example.com",
                x: 0,
                y: 0,
                w: 1200,
                h: 800
            ),
            windowsByPid: [
                "701": [
                    CUWindowInfo(
                        windowId: 11,
                        title: "Checkout - ada@example.com",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ]
            ],
            snapshot: ScreenContextFixture.Snapshot(
                app: "Safari",
                focusedWindow: "Checkout - ada@example.com",
                truncated: true,
                windows: [
                    CUWindowSummary(
                        id: 11,
                        title: "Checkout - ada@example.com",
                        focused: true,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ],
                elements: [
                    CUElement(
                        id: "email-field",
                        role: "textfield",
                        label: "Email",
                        value: "ada@example.com",
                        path: "/Users/ada/private/form/email",
                        windowId: 11,
                        focused: false,
                        x: 40,
                        y: 90,
                        w: 320,
                        h: 28,
                        actions: ["AXSetValue"]
                    ),
                    CUElement(
                        id: "password-field",
                        role: "AXSecureTextField",
                        label: "Password",
                        value: "hunter2",
                        selectedText: "hunter2",
                        path: "/Users/ada/private/form/password",
                        windowId: 11,
                        focused: true,
                        x: 40,
                        y: 128,
                        w: 320,
                        h: 28,
                        actions: ["AXSetValue"]
                    ),
                    CUElement(
                        id: "card-label",
                        role: "staticText",
                        label: "Payment note",
                        value: "card 4242",
                        windowId: 11,
                        focused: false,
                        x: 40,
                        y: 170,
                        w: 260,
                        h: 20
                    ),
                ]
            ),
            focusedContent: CUFocusedContent(
                role: "AXSecureTextField",
                label: "Password",
                value: "hunter2",
                selectedText: "hunter2",
                viewport: "hunter2"
            )
        )
    }
}
