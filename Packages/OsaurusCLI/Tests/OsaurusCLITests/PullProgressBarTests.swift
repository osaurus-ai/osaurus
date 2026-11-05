//
//  PullProgressBarTests.swift
//  osaurus
//
//  Tests for the `osaurus pull` progress-bar renderer. The reported
//  fraction is `completedBytes / totalBytes`, where `totalBytes` is a
//  precomputed estimate; if the actual download exceeds that estimate the
//  fraction goes above 1.0, which must not crash the renderer.
//

import XCTest

@testable import OsaurusCLICore

final class PullProgressBarTests: XCTestCase {

    func testProgressBarClampsOverflowFractionToFull() {
        // fraction > 1.0 (download exceeded the size estimate) previously
        // made `width - filled` negative and trapped `String(repeating:
        // count:)`, aborting the whole `pull`. It must clamp to a full bar.
        let bar = PullCommand.renderProgressBar(fraction: 1.5, width: 20)
        XCTAssertEqual(bar, String(repeating: "=", count: 20))
    }

    func testProgressBarClampsNegativeFractionToEmpty() {
        let bar = PullCommand.renderProgressBar(fraction: -0.5, width: 20)
        XCTAssertEqual(bar, String(repeating: " ", count: 20))
    }

    func testProgressBarHalfwayIsHalfFilled() {
        let bar = PullCommand.renderProgressBar(fraction: 0.5, width: 20)
        XCTAssertEqual(
            bar,
            String(repeating: "=", count: 10) + String(repeating: " ", count: 10)
        )
    }

    func testProgressBarExactlyFull() {
        let bar = PullCommand.renderProgressBar(fraction: 1.0, width: 20)
        XCTAssertEqual(bar, String(repeating: "=", count: 20))
    }
}
