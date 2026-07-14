//
//  AccessibilityBoundedElementSourceTests.swift
//  OsaurusCoreTests — Computer Use
//
//  EVERY AX application element must carry a messaging timeout.
//
//  `AXUIElementSetMessagingTimeout` on the system-wide element does NOT
//  propagate to per-application elements, so an element built with a raw
//  `AXUIElementCreateApplication(pid)` has NO timeout at all: a single read or
//  write against a slow, launching, or wedged target app can block the calling
//  thread forever. `AccessibilityManager.axApp(pid)` exists precisely to stamp
//  the timeout on, and its doc comment says every app-element site must go
//  through it.
//
//  That contract was stated and then broken. The "Fix Computer Use main-thread
//  hangs" change applied the timeout "at every app-element site" — and missed
//  two, BOTH of them on the open-app path:
//
//    - `prepareForAccessibility(pid:)`, which flips `AXManualAccessibility` /
//      `AXEnhancedUserInterface`. Those are the most dangerous AX calls we make:
//      they force the target to build its entire accessibility tree, and an app
//      that is still launching can sit on the reply indefinitely.
//    - `waitUntilReady(app:)`, whose poll runs — by construction — against an
//      app that is still coming up.
//
//  So the one driver path that opens an application was also the only one whose
//  AX calls were unbounded, while every other path was capped at 1.5s. A prose
//  comment did not stop that from being reintroduced once, so this is a source
//  guard instead: the ONLY place allowed to call `AXUIElementCreateApplication`
//  is `axApp` itself.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class AccessibilityBoundedElementSourceTests: XCTestCase {

    /// `Accessibility.swift`, read from the source tree next to this test.
    private func accessibilitySource() throws -> String {
        // Tests/ComputerUse/Driver/<this file> → Packages/OsaurusCore/…
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Driver
            .deletingLastPathComponent()  // ComputerUse
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusCore (source lives outside Tests/)
        let source = packageRoot
            .appendingPathComponent("ComputerUse/Driver/Mac/Accessibility.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// Every `AXUIElementCreateApplication` must live inside `axApp`, which is
    /// the only function that follows it with `AXUIElementSetMessagingTimeout`.
    func testOnlyAxAppConstructsAnApplicationElement() throws {
        let source = try accessibilitySource()

        let creations = source.components(separatedBy: "AXUIElementCreateApplication").count - 1
        XCTAssertGreaterThan(creations, 0, "sanity: the symbol should appear at all")
        XCTAssertEqual(
            creations,
            1,
            """
            Found \(creations) uses of AXUIElementCreateApplication in Accessibility.swift. \
            Exactly ONE is allowed — the one inside `axApp(_:)`, which stamps the \
            per-app messaging timeout on. Any other site produces an AX element with NO \
            timeout, and a single call against a launching or wedged app can then block \
            the driver forever. Route it through `AccessibilityManager.axApp(pid)`.
            """)
    }

    /// …and that single use must be the one immediately bounded by a timeout.
    func testTheSoleApplicationElementIsGivenAMessagingTimeout() throws {
        let source = try accessibilitySource()

        guard let axAppRange = source.range(of: "static func axApp(") else {
            return XCTFail("axApp(_:) is gone — the bounded-element contract has no home")
        }
        guard let creationRange = source.range(of: "AXUIElementCreateApplication") else {
            return XCTFail("no AX application element is constructed at all")
        }
        XCTAssertTrue(
            creationRange.lowerBound > axAppRange.lowerBound,
            "the only AXUIElementCreateApplication must be the one inside axApp(_:)")

        // The timeout must be applied to that element, not merely to the
        // system-wide one (which does not propagate).
        let tail = source[creationRange.upperBound...]
        let boundedSoon = tail.prefix(200).contains("AXUIElementSetMessagingTimeout")
        XCTAssertTrue(
            boundedSoon,
            """
            axApp(_:) built an application element without immediately calling \
            AXUIElementSetMessagingTimeout on it. Without that, the element is unbounded: \
            the system-wide timeout does not propagate to per-application elements.
            """)
    }
}
