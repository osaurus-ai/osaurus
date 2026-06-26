//
//  AccessibilitySelfGuardTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The native driver must never resolve Osaurus's OWN accessibility tree on the
//  off-main driver queue: querying our own elements re-enters AppKit/SwiftUI
//  accessibility in-process, evaluating SwiftUI `body` and tripping its
//  main-thread assertion when it runs off the main thread (the production
//  AppHang/crash this guard fixes). Every AX entry point therefore treats self
//  as "nothing to perceive". These tests pin the self-identity check and the
//  empty/nil contract each entry point returns for our own pid; the live AX
//  behavior is exercised by the opt-in eval suite, not here.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class AccessibilitySelfGuardTests: XCTestCase {
    func testIsSelfMatchesOwnPidOnly() throws {
        XCTAssertTrue(AccessibilityManager.isSelf(AccessibilityManager.selfPid))
        XCTAssertEqual(
            AccessibilityManager.selfPid,
            ProcessInfo.processInfo.processIdentifier
        )
        // A pid that can't be ours (no process owns Int32.max).
        XCTAssertFalse(AccessibilityManager.isSelf(Int32.max))
        // launchd is pid 1 and is never us.
        XCTAssertFalse(AccessibilityManager.isSelf(1))
    }

    func testTraverseReturnsEmptyForSelf() throws {
        let result = AccessibilityManager.shared.traverse(
            filter: ElementFilter(pid: AccessibilityManager.selfPid)
        )
        XCTAssertEqual(result.pid, AccessibilityManager.selfPid)
        XCTAssertTrue(result.elements.isEmpty)
        XCTAssertEqual(result.elementCount, 0)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.app.isEmpty, "self result should still name the app")
    }

    func testListWindowsReturnsEmptyForSelf() throws {
        XCTAssertTrue(listWindowsForPid(AccessibilityManager.selfPid).windows.isEmpty)
    }

    func testFocusedContentAndDeltaReturnNilForSelf() throws {
        XCTAssertNil(computeFocusedContent(pid: AccessibilityManager.selfPid))
        XCTAssertNil(computeFocusDelta(pid: AccessibilityManager.selfPid))
    }

    func testPrepareForAccessibilityIsNoOpForSelf() throws {
        XCTAssertFalse(
            AccessibilityManager.shared.prepareForAccessibility(pid: AccessibilityManager.selfPid),
            "preparing our own pid must be a no-op (never set AX flags on ourselves)"
        )
    }
}
