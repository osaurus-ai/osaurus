//
//  BackgroundDriverLiveInputTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Opt-in, end-to-end proof that the real `BackgroundDriver.shared.type` path
//  delivers each character exactly once after the SkyLight double-delivery fix.
//  Drives a live TextEdit window (an AppKit text field — the same input stack
//  as Chrome's omnibox) and reads the result back via accessibility.
//
//  Requires a real GUI session and Accessibility permission for the test
//  runner, so it is gated behind `OSAURUS_CU_LIVE_INPUT=1` and skipped in CI
//  and the default `make test` lane.
//

import AppKit
import ApplicationServices
import XCTest

@testable import OsaurusCore

final class BackgroundDriverLiveInputTests: XCTestCase {

    func testRealTypePathInsertsTextOnce() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OSAURUS_CU_LIVE_INPUT"] == "1",
            "Live input test — set OSAURUS_CU_LIVE_INPUT=1 (needs Accessibility permission) to run."
        )
        try XCTSkipUnless(AXIsProcessTrusted(), "Test runner lacks Accessibility permission.")

        let pid = try launchTextEdit()
        defer { NSRunningApplication(processIdentifier: pid)?.terminate() }

        NSRunningApplication(processIdentifier: pid)?.activate()
        Thread.sleep(forTimeInterval: 0.7)

        let phrase = "hello world"
        let result = BackgroundDriver.shared.type(pid: pid, text: phrase)
        XCTAssertTrue(result.success)
        Thread.sleep(forTimeInterval: 0.6)

        let value = focusedValue(pid: pid)
        // The pre-fix bug produced "hheelllloo  wwoorrlldd". Assert each character
        // landed exactly once: the length must match (doubling would make it 22),
        // and the text must match case-insensitively (TextEdit auto-capitalizes
        // the first letter of a sentence — that is not doubling).
        XCTAssertEqual(
            value?.count,
            phrase.count,
            "doubling would change the length; got \(value ?? "nil")"
        )
        XCTAssertEqual(
            value?.lowercased(),
            phrase.lowercased(),
            "expected single insertion of each character; got \(value ?? "nil")"
        )
        XCTAssertEqual(BackgroundDriver.shared.lastRoute, .skyLight)
    }

    // MARK: Helpers

    private func launchTextEdit() throws -> pid_t {
        let tmp = "/tmp/cu_live_\(getpid()).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data(), attributes: nil)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }

        // `/usr/bin/open` routes through LaunchServices, which launches the app
        // reliably even from the command-line xctest host (NSWorkspace.open's
        // completion returns no app in that context).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "TextEdit", tmp]
        try proc.run()
        proc.waitUntilExit()

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.TextEdit"
            ).first {
                Thread.sleep(forTimeInterval: 1.5)
                return app.processIdentifier
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw XCTSkip("Could not launch TextEdit.")
    }

    private func focusedValue(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
                == .success,
            let focusedRef = focused,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        let element = focusedRef as! AXUIElement
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
