//
//  NativeMacDriverLiveTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Opt-in, end-to-end proof that the REAL `NativeMacDriver` (not the mock)
//  behaves against live apps the way the loop assumes: real AX serialization
//  (TextEdit/Safari), element-addressed typing with no character doubling,
//  the coordinate path the loop falls back to when an AX ref goes stale, and
//  Electron's empty-AX → vision escalation (Slack).
//
//  These need a real GUI session, Accessibility permission (and, for the
//  Electron escalation, Screen Recording), so the whole suite is gated behind
//  `OSAURUS_CU_LIVE_INPUT=1` and skipped in CI and the default `make test`
//  lane. Run locally with:
//
//    OSAURUS_CU_LIVE_INPUT=1 \
//      swift test --package-path Packages/OsaurusCore \
//      --filter NativeMacDriverLiveTests
//
//  Each test self-skips when its app can't be launched, so a machine without
//  Slack still runs the TextEdit/Safari coverage.
//

import AppKit
import ApplicationServices
import XCTest

@testable import OsaurusCore

final class NativeMacDriverLiveTests: XCTestCase {

    private let driver = NativeMacDriver()

    // MARK: - Gating

    /// Skips unless the live lane is explicitly enabled AND the runner has the
    /// Accessibility permission the driver needs to read/drive other apps.
    private func requireLiveInput() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OSAURUS_CU_LIVE_INPUT"] == "1",
            "Live macOS lane — set OSAURUS_CU_LIVE_INPUT=1 (needs Accessibility permission) to run."
        )
        try XCTSkipUnless(AXIsProcessTrusted(), "Test runner lacks Accessibility permission.")
    }

    // MARK: - TextEdit: AX serialization

    /// The driver's `.ax` capture must serialize a real, non-empty tree: the
    /// focused window plus at least one editable text element. This is the
    /// perception the whole loop is built on.
    func testCaptureSerializesTextEditAX() async throws {
        try requireLiveInput()
        let pid = try await launchApp(bundleId: "com.apple.TextEdit", appName: "TextEdit")
        defer { terminate(pid) }

        let snapshot = await driver.capture(pid: pid, tier: .ax)
        XCTAssertEqual(snapshot.pid, pid, "capture should report the requested pid")
        XCTAssertFalse(snapshot.app.isEmpty, "capture should name the app")
        XCTAssertFalse(snapshot.windows.isEmpty, "expected at least one window in the AX tree")
        XCTAssertNotNil(
            firstEditableText(in: snapshot),
            "expected an editable text element; got roles \(roles(in: snapshot))"
        )
    }

    // MARK: - TextEdit: element-addressed type (no doubling)

    /// Element-addressed `typeText` through the real driver must insert each
    /// character exactly once (the SkyLight double-delivery regression) and the
    /// change must be observable on the NEXT capture — i.e. perception reflects
    /// actuation.
    func testElementTypeInsertsTextExactlyOnce() async throws {
        try requireLiveInput()
        let pid = try await launchApp(bundleId: "com.apple.TextEdit", appName: "TextEdit")
        defer { terminate(pid) }

        let snapshot = await driver.capture(pid: pid, tier: .ax)
        let field = try XCTUnwrap(
            firstEditableText(in: snapshot),
            "no editable text element to type into"
        )

        let phrase = "hello world"
        let result = await driver.perform(
            .typeText(id: field.id, pid: pid, text: phrase, replace: true)
        )
        XCTAssertTrue(result.success, "type failed: \(result.error ?? "nil")")
        XCTAssertEqual(
            result.routeUsed,
            .skyLight,
            "pid-addressed type should take the SkyLight route, not the HID fallback"
        )

        let value = try await pollText(pid: pid, timeout: 2.0)
        // The pre-fix bug produced "hheelllloo  wwoorrlldd"; a length mismatch is
        // the doubling signature. TextEdit auto-capitalizes the first letter, so
        // compare case-insensitively rather than exactly.
        XCTAssertEqual(value.count, phrase.count, "doubling would change the length; got '\(value)'")
        XCTAssertEqual(
            value.lowercased(),
            phrase.lowercased(),
            "expected single insertion of each character; got '\(value)'"
        )
    }

    // MARK: - TextEdit: coordinate fallback (the stale-ref path)

    /// The coordinate path the loop falls back to when an element ref goes
    /// stale: click the field's center by coordinate (pid-addressed), then type
    /// with NO element id. The text must still land in the focused field.
    func testCoordinateClickFocusesThenTypes() async throws {
        try requireLiveInput()
        let pid = try await launchApp(bundleId: "com.apple.TextEdit", appName: "TextEdit")
        defer { terminate(pid) }

        let snapshot = await driver.capture(pid: pid, tier: .ax)
        let field = try XCTUnwrap(
            firstEditableText(in: snapshot),
            "no editable text element to target"
        )

        // Click the element's center exactly as the loop's coordinate fallback
        // does (center derived from the AX rect), pid-addressed for no warp.
        let cx = Double(field.x) + Double(field.w) / 2.0
        let cy = Double(field.y) + Double(field.h) / 2.0
        let click = await driver.coordinate(.click(x: cx, y: cy, pid: pid))
        XCTAssertTrue(click.success, "coordinate click failed: \(click.error ?? "nil")")

        let phrase = "coordinate path"
        let typed = await driver.perform(.typeText(id: nil, pid: pid, text: phrase, replace: false))
        XCTAssertTrue(typed.success, "type-after-coordinate-focus failed: \(typed.error ?? "nil")")

        let value = try await pollText(pid: pid, timeout: 2.0, contains: "coordinate")
        XCTAssertTrue(
            value.lowercased().contains("coordinate"),
            "expected typed text in the field after coordinate focus; got '\(value)'"
        )
    }

    // MARK: - Safari: AX serialization on a browser

    /// Browsers serialize a different (web) AX tree than AppKit apps. Proves the
    /// driver captures a non-trivial Safari tree (window + interactive elements
    /// such as the toolbar / address field). Best-effort: self-skips if Safari
    /// doesn't come up.
    func testCaptureSerializesSafariAX() async throws {
        try requireLiveInput()
        let pid = try await launchApp(
            bundleId: "com.apple.Safari",
            appName: "Safari",
            openArgs: ["about:blank"]
        )
        defer { terminate(pid) }
        // Safari builds its AX tree lazily after the window paints.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let snapshot = await driver.capture(pid: pid, tier: .ax)
        XCTAssertFalse(snapshot.windows.isEmpty, "expected a Safari window in the AX tree")
        XCTAssertFalse(
            snapshot.elements.isEmpty,
            "expected interactive Safari chrome (toolbar/address field) in the AX tree"
        )
    }

    // MARK: - Slack/Electron: empty-AX → vision escalation

    /// Electron apps expose a near-empty AX tree, which is exactly what the
    /// loop's empty-AX → vision escalation exists for. Proves the `.ax` capture
    /// is sparse while the `.vision` capture yields image bytes to escalate to.
    /// Needs Screen Recording AND Slack installed — self-skips otherwise.
    func testSlackEmptyAXEscalatesToVision() async throws {
        try requireLiveInput()
        try XCTSkipUnless(
            CGPreflightScreenCaptureAccess(),
            "Electron escalation needs Screen Recording permission."
        )
        try XCTSkipUnless(
            isInstalled(bundleId: "com.tinyspeck.slackmacgap"),
            "Slack not installed — skipping the Electron escalation lane."
        )
        let pid = try await launchApp(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack")
        defer { terminate(pid) }
        try await Task.sleep(nanoseconds: 3_000_000_000)  // Electron startup is slow.

        let ax = await driver.capture(pid: pid, tier: .ax)
        let actionable = ax.elements.filter { !$0.actions.isEmpty }
        // The Electron signature: few/no actionable AX nodes. Threshold is
        // generous — the point is "sparse vs. a real native tree", not zero.
        XCTAssertLessThan(
            actionable.count,
            8,
            "expected a sparse Electron AX tree; got \(actionable.count) actionable nodes "
                + "(roles \(roles(in: ax)))"
        )

        let vision = await driver.capture(pid: pid, tier: .vision)
        XCTAssertEqual(vision.tier, .vision)
        let image = try XCTUnwrap(vision.image, "vision tier must carry image bytes to escalate to")
        XCTAssertFalse(image.base64.isEmpty, "vision image must contain real bytes")
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    // MARK: - Helpers

    /// Launches an app via LaunchServices (`/usr/bin/open`, which works from the
    /// command-line xctest host where `NSWorkspace.open` does not) and returns
    /// its pid once it's running and settled. Self-skips if it can't start.
    private func launchApp(
        bundleId: String,
        appName: String,
        openArgs: [String] = []
    ) async throws -> pid_t {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", appName] + openArgs
        do {
            try proc.run()
        } catch {
            throw XCTSkip("Could not launch \(appName): \(error.localizedDescription)")
        }
        proc.waitUntilExit()

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .first
            {
                app.activate()
                // Let the app finish building its window + AX tree.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                return app.processIdentifier
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw XCTSkip("\(appName) did not come up within the deadline.")
    }

    private func isInstalled(bundleId: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    private func terminate(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    /// First editable text element in a snapshot (the document/text-entry node).
    private func firstEditableText(in snapshot: CUSnapshot) -> CUElement? {
        snapshot.elements.first { el in
            let role = el.role.lowercased()
            return role.contains("textarea") || role.contains("textfield")
                || role == "text" || role.contains("text ")
        }
    }

    private func roles(in snapshot: CUSnapshot) -> [String] {
        Array(Set(snapshot.elements.map { $0.role })).sorted()
    }

    /// Re-captures `.ax` until the editable field has a non-empty value (or the
    /// `contains` substring, when given), so the assertions don't race the
    /// asynchronous AX value update after an input.
    private func pollText(
        pid: pid_t,
        timeout: TimeInterval,
        contains needle: String? = nil
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            let snapshot = await driver.capture(pid: pid, tier: .ax)
            if let field = firstEditableText(in: snapshot), let value = field.value, !value.isEmpty {
                last = value
                if let needle {
                    if value.lowercased().contains(needle.lowercased()) { return value }
                } else {
                    return value
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return last
    }
}
