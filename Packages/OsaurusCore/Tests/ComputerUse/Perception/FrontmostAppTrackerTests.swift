//
//  FrontmostAppTrackerTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The tracker remembers the most-recently-active non-Osaurus app so the
//  screen-context chip and budget preview can name "what you were just in".
//  It must ignore Osaurus itself and publish the resolved app name alongside
//  the pid.
//

import AppKit
import Foundation
import XCTest

@testable import OsaurusCore

@MainActor
final class FrontmostAppTrackerTests: XCTestCase {
    func testStartsEmpty() {
        let tracker = FrontmostAppTracker()
        XCTAssertNil(tracker.lastNonSelfPid)
        XCTAssertNil(tracker.lastNonSelfAppName)
    }

    func testIgnoresSelf() throws {
        let tracker = FrontmostAppTracker()
        // Resolve a real `NSRunningApplication` for this process so its pid
        // genuinely matches `selfPid` (note: `NSRunningApplication.current`
        // reports pid -1 under `swift test`, which would defeat the guard).
        // If the host can't register the process as a running app, skip.
        let selfPid = ProcessInfo.processInfo.processIdentifier
        guard let selfApp = NSRunningApplication(processIdentifier: selfPid) else {
            throw XCTSkip("Current process is not registered as a running application.")
        }
        tracker.record(selfApp)
        XCTAssertNil(tracker.lastNonSelfPid)
        XCTAssertNil(tracker.lastNonSelfAppName)
    }

    func testRecordsNonSelfAppNameAndPid() throws {
        let tracker = FrontmostAppTracker()

        let selfPid = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier
        // Pick any genuinely other running app with a display name. On a
        // headless runner there may be none — skip rather than fail.
        guard
            let other = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier != selfPid
                    && $0.bundleIdentifier != selfBundle
                    && ($0.localizedName?.isEmpty == false)
            })
        else {
            throw XCTSkip("No non-Osaurus running app with a name is available in this environment.")
        }

        tracker.record(other)
        XCTAssertEqual(tracker.lastNonSelfPid, other.processIdentifier)
        XCTAssertEqual(tracker.lastNonSelfAppName, other.localizedName ?? other.bundleIdentifier)
    }
}
