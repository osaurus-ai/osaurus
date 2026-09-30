//
//  MacDriverContractTests.swift
//  OsaurusCoreTests — Computer Use
//
//  PR0 coverage for the ported macOS driver's pure, app-independent logic
//  (snapshot id format, key-name + modifier vocabulary, capture-mode parsing)
//  and the `MockMacDriver` conformer's scripting/recording contract. The
//  live AX/SkyLight/screenshot paths need a real app + permissions and are
//  exercised by the opt-in eval suite, not here.
//

import CoreGraphics
import Foundation
import XCTest

@testable import OsaurusCore

final class MacDriverSnapshotIdTests: XCTestCase {
    func testFormatRoundTrips() throws {
        let id = SnapshotIdFormat.format(snapshot: 7, element: 12)
        XCTAssertEqual(id, "s7-12")
        let parsed = SnapshotIdFormat.parse(id)
        XCTAssertEqual(parsed?.snapshot, 7)
        XCTAssertEqual(parsed?.element, 12)
    }

    func testRejectsMalformedIds() throws {
        XCTAssertNil(SnapshotIdFormat.parse("foo"))
        XCTAssertNil(SnapshotIdFormat.parse("7-12"))
        XCTAssertNil(SnapshotIdFormat.parse("s7"))
        XCTAssertNil(SnapshotIdFormat.parse("sx-12"))
    }

    func testPublicMarksUseParsedIdsWithCollisionFreeFallbacks() throws {
        XCTAssertEqual(
            SnapshotIdFormat.publicMarks(for: ["s9-2", "weird", "s9-2", "s9-0", "s9-1"]),
            [2, 3, 4, 5, 1]
        )
    }
}

final class MacDriverKeyVocabularyTests: XCTestCase {
    func testResolvesSpecialAndLetterKeys() throws {
        XCTAssertEqual(keyCode(for: "return"), 0x24)
        XCTAssertEqual(keyCode(for: "Escape"), 0x35)
        XCTAssertEqual(keyCode(for: "a"), 0x00)
        XCTAssertEqual(keyCode(for: "L"), 0x25)
        XCTAssertNil(keyCode(for: "definitely-not-a-key"))
    }

    func testParsesModifierAliases() throws {
        let flags = parseModifierFlags(["cmd", "shift"])
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertFalse(flags.contains(.maskControl))
        XCTAssertTrue(parseModifierFlags(nil).isEmpty)
    }
}

final class MacDriverCaptureModeTests: XCTestCase {
    func testParseDefaultsToSom() throws {
        XCTAssertEqual(CaptureMode.parse(nil), .som)
        XCTAssertEqual(CaptureMode.parse("garbage"), .som)
        XCTAssertEqual(CaptureMode.parse("AX"), .ax)
        XCTAssertEqual(CaptureMode.parse("vision"), .vision)
    }

    func testCaptureTierMapsAllCases() throws {
        XCTAssertEqual(Set(CaptureTier.allCases), [.ax, .som, .vision])
    }
}

final class SOMOverlayRendererTests: XCTestCase {
    func testPublicMarksAreDerivedFromSnapshotIdsInMarkOrder() throws {
        let firstFrame = CGRect(x: 10, y: 20, width: 30, height: 40)
        let secondFrame = CGRect(x: 50, y: 60, width: 70, height: 80)
        let fallbackFrame = CGRect(x: 1, y: 1, width: 1, height: 1)
        let marks = SOMOverlayRenderer.publicMarks(from: [
            (id: "s9-2", frame: secondFrame),
            (id: "not-a-snapshot-id", frame: fallbackFrame),
            (id: "s9-1", frame: firstFrame),
        ])

        XCTAssertEqual(marks.map(\.mark), [1, 2, 3])
        XCTAssertEqual(marks.map(\.frame), [firstFrame, secondFrame, fallbackFrame])
    }

    func testOverlayMarksUseCanonicalFallbacksForMixedSnapshotIds() throws {
        let firstFrame = CGRect(x: 10, y: 20, width: 30, height: 40)
        let fallbackFrame = CGRect(x: 50, y: 60, width: 70, height: 80)
        let duplicateFrame = CGRect(x: 90, y: 100, width: 30, height: 40)
        let zeroFrame = CGRect(x: 130, y: 140, width: 30, height: 40)
        let marks = SOMOverlayRenderer.publicMarks(from: [
            (id: "s9-2", frame: firstFrame),
            (id: "weird", frame: fallbackFrame),
            (id: "s9-2", frame: duplicateFrame),
            (id: "s9-0", frame: zeroFrame),
        ])

        XCTAssertEqual(marks.map(\.mark), [1, 2, 3, 4])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: marks.map { (Int($0.frame.origin.x), $0.mark) }),
            [
                10: 2,
                50: 1,
                90: 3,
                130: 4,
            ]
        )
    }

    func testOverlayMarksMatchRenderedAgentViewMarksForSameSnapshot() throws {
        let snapshot = CUSnapshot(
            snapshotId: 9,
            pid: 4242,
            app: "Mail",
            focusedWindow: "Compose",
            tier: .som,
            truncated: false,
            windows: [],
            elements: [
                CUElement(
                    id: "s9-5",
                    role: "textfield",
                    label: "Subject",
                    x: 50,
                    y: 54,
                    w: 240,
                    h: 24
                ),
                CUElement(
                    id: "s9-2",
                    role: "button",
                    label: "Send",
                    x: 10,
                    y: 20,
                    w: 80,
                    h: 24
                ),
            ],
            image: nil
        )
        let view = AgentView.build(from: snapshot, previous: nil)
        let overlayMarks = SOMOverlayRenderer.publicMarks(
            from: snapshot.elements.map {
                (
                    id: $0.id,
                    frame: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)
                )
            }
        )

        XCTAssertEqual(Set(overlayMarks.map(\.mark)), Set(view.items.map(\.mark)))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: overlayMarks.map { (Int($0.frame.origin.x), $0.mark) }),
            [
                10: 2,
                50: 5,
            ]
        )
        XCTAssertEqual(overlayMarks.map { SOMOverlayRenderer.label(for: $0.mark) }, ["2", "5"])
        let renderedElements = view.renderForModel().split(separator: "\n")
            .filter { $0.hasPrefix("  [") }
            .map(String.init)
        XCTAssertTrue(renderedElements.contains("  [2] button \"Send\""))
        XCTAssertTrue(renderedElements.contains("  [5] textfield \"Subject\""))
    }

    func testOverlayLabelIsOnlyThePublicMark() throws {
        let label = SOMOverlayRenderer.label(for: 42)
        XCTAssertEqual(label, "42")
        XCTAssertFalse(label.contains("s42"))
        XCTAssertFalse(label.contains("-"))
        XCTAssertFalse(label.localizedCaseInsensitiveContains("button"))
    }

    func testOverlayKeepsImageDimensions() throws {
        let image = try makeSolidImage(width: 160, height: 120)
        let overlaid = try XCTUnwrap(
            SOMOverlayRenderer.overlay(
                on: image,
                marks: [
                    SOMOverlayMark(
                        mark: 1,
                        frame: CGRect(x: 10, y: 10, width: 40, height: 30)
                    )
                ],
                captureOrigin: .zero
            )
        )

        XCTAssertEqual(overlaid.width, image.width)
        XCTAssertEqual(overlaid.height, image.height)
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

final class MockMacDriverContractTests: XCTestCase {
    func testDemoDriverPerceivesSeededSnapshot() async throws {
        let driver = MockMacDriver.demo()
        let apps = await driver.listApps()
        XCTAssertEqual(apps.first?.name, "Demo")

        let pid = apps.first!.pid
        let snapshot = await driver.capture(pid: pid, tier: .ax)
        XCTAssertEqual(snapshot.elements.count, 2)
        XCTAssertEqual(snapshot.elements.first?.role, "textfield")
        XCTAssertEqual(snapshot.focusedWindowId, 1)
    }

    func testCaptureAdvancesThroughQueueThenHolds() async throws {
        let pid: Int32 = 99
        let first = makeSnapshot(id: 1, pid: pid, labels: ["A"])
        let second = makeSnapshot(id: 2, pid: pid, labels: ["A", "B"])
        let driver = MockMacDriver()
        await driver.enqueueSnapshots([first, second], pid: pid)

        let s1 = await driver.capture(pid: pid, tier: .ax)
        let s2 = await driver.capture(pid: pid, tier: .ax)
        let s3 = await driver.capture(pid: pid, tier: .ax)

        XCTAssertEqual(s1.elements.count, 1)
        XCTAssertEqual(s2.elements.count, 2)
        // Steady state: last snapshot repeats once the queue is exhausted.
        XCTAssertEqual(s3.elements.count, 2)
    }

    func testRecordsElementActionsAndScriptsResults() async throws {
        let driver = MockMacDriver()
        await driver.enqueueActionResults([.failure("boom"), .ok()])

        let r1 = await driver.perform(.click(id: "s1-2"))
        let r2 = await driver.perform(.setValue(id: "s1-1", value: "hi"))

        XCTAssertFalse(r1.success)
        XCTAssertEqual(r1.error, "boom")
        XCTAssertTrue(r2.success)

        let recorded = await driver.elementActions
        XCTAssertEqual(recorded.count, 2)
    }

    func testFindFiltersByRoleAndText() async throws {
        let pid: Int32 = 7
        let snap = makeSnapshot(id: 3, pid: pid, labels: ["Sign in", "Cancel"], roles: ["button", "button"])
        let driver = MockMacDriver()
        await driver.enqueueSnapshots([snap], pid: pid)

        let found = await driver.find(
            pid: pid,
            text: "sign",
            roles: ["button"],
            windowId: nil,
            enabledOnly: false,
            limit: 10
        )
        XCTAssertEqual(found.elements.count, 1)
        XCTAssertEqual(found.elements.first?.label, "Sign in")
    }

    // MARK: Helpers

    private func makeSnapshot(
        id: Int,
        pid: Int32,
        labels: [String],
        roles: [String]? = nil
    ) -> CUSnapshot {
        let elements = labels.enumerated().map { idx, label in
            CUElement(
                id: "s\(id)-\(idx + 1)",
                role: roles?[idx] ?? "button",
                label: label,
                windowId: 1,
                enabled: true,
                x: 0,
                y: idx * 30,
                w: 80,
                h: 24,
                actions: ["press"]
            )
        }
        let window = CUWindowSummary(id: 1, title: "W", focused: true, x: 0, y: 0, w: 800, h: 600)
        return CUSnapshot(
            snapshotId: id,
            pid: pid,
            app: "MockApp",
            focusedWindow: "W",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: elements,
            image: nil
        )
    }
}
