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
