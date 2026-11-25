//
//  ComputerUseSurfaceLiveTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Opt-in proof of the `select`, `hover`, and `zoom` driver paths against a
//  real rich-text TextEdit document kept in the background (Finder in front):
//  the format bar's font-size combo box and popups, a per-pid pointer move,
//  and a full-resolution close-up of the window.
//
//    OSAURUS_CU_LIVE_INPUT=1 \
//      swift test --package-path Packages/OsaurusCore \
//      --filter ComputerUseSurfaceLiveTests
//

import AppKit
import ApplicationServices
import XCTest

@testable import OsaurusCore

final class ComputerUseSurfaceLiveTests: XCTestCase {

    private let driver = NativeMacDriver()

    private func requireLiveInput() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OSAURUS_CU_LIVE_INPUT"] == "1",
            "Live macOS lane — set OSAURUS_CU_LIVE_INPUT=1 (needs Accessibility permission) to run."
        )
        try XCTSkipUnless(AXIsProcessTrusted(), "Test runner lacks Accessibility permission.")
    }

    // MARK: - select

    func testSelectSetsTheFontSizeComboBoxInTheBackground() async throws {
        try requireLiveInput()
        let pid = try launchRichTextEdit()
        defer { terminateAndWait(pid) }
        let finder = try bringFinderToFront()

        let snapshot = await driver.capture(pid: pid, tier: .ax)
        let combo = try XCTUnwrap(
            snapshot.elements.first { $0.role.lowercased().contains("combobox") },
            "no combo box in the format bar; roles: \(roles(snapshot))"
        )
        let result = await driver.perform(.selectOption(id: combo.id, option: "36"))
        XCTAssertTrue(result.success, result.error ?? "")
        let after = await driver.capture(pid: pid, tier: .ax)
        XCTAssertEqual(after.elements.first { $0.role == combo.role && $0.label == combo.label }?.value, "36")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, finder)
    }

    func testSelectPicksAMenuOptionFromAPopupInTheBackground() async throws {
        try requireLiveInput()
        let pid = try launchRichTextEdit()
        defer { terminateAndWait(pid) }
        let finder = try bringFinderToFront()

        let snapshot = await driver.capture(pid: pid, tier: .ax)
        let popups = snapshot.elements.filter { $0.role.lowercased().contains("popup") }
        let popup = try XCTUnwrap(
            popups.first { ($0.value ?? "").localizedCaseInsensitiveContains("Helvetica") } ?? popups.first,
            "no popup button in the format bar; roles: \(roles(snapshot))"
        )
        // Asking for a title that isn't listed must fail and name real options.
        let miss = await driver.perform(.selectOption(id: popup.id, option: "No Such Option 7c1"))
        XCTAssertFalse(miss.success)
        let message = miss.error ?? ""
        XCTAssertTrue(
            message.contains("Options:") || message.contains("no readable list"),
            "popup \(popup.label ?? "?") value=\(popup.value ?? "?"): \(message)"
        )
        try XCTSkipUnless(
            message.contains("Options:"),
            "The popup opened no readable menu in the background: \(message)"
        )
        let listed = message.components(separatedBy: "Options: ").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .components(separatedBy: ", ") ?? []
        let pick = try XCTUnwrap(
            listed.first { !$0.isEmpty && $0 != popup.value },
            "no other option to pick among \(listed)"
        )
        let hit = await driver.perform(.selectOption(id: popup.id, option: pick))
        XCTAssertTrue(hit.success, hit.error ?? "")
        let after = await driver.capture(pid: pid, tier: .ax)
        let updated = after.elements.first { $0.role == popup.role && $0.x == popup.x && $0.y == popup.y }
        XCTAssertEqual(updated?.value, pick, "popup \(popup.label ?? "?") should now show \(pick)")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, finder)
    }

    // MARK: - hover

    func testHoverDoesNotMoveTheUsersPointer() async throws {
        try requireLiveInput()
        let pid = try launchRichTextEdit()
        defer { terminateAndWait(pid) }
        _ = try bringFinderToFront()

        let snapshot = await driver.capture(pid: pid, tier: .ax)
        let window = try XCTUnwrap(snapshot.windows.first, "TextEdit has no window")
        let before = NSEvent.mouseLocation
        let result = await driver.coordinate(
            .move(x: Double(window.x + window.w / 2), y: Double(window.y + window.h / 2), pid: pid)
        )
        XCTAssertTrue(result.success, result.error ?? "")
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = NSEvent.mouseLocation
        XCTAssertEqual(before.x, after.x, accuracy: 0.5, "a per-pid hover must leave the real pointer alone")
        XCTAssertEqual(before.y, after.y, accuracy: 0.5)
    }

    // MARK: - zoom

    func testZoomReturnsAFullResolutionCloseUpOfTheRegion() async throws {
        try requireLiveInput()
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Test runner lacks Screen Recording permission.")
        let pid = try launchRichTextEdit()
        defer { terminateAndWait(pid) }

        let snapshot = await driver.capture(pid: pid, tier: .ax)
        let window = try XCTUnwrap(snapshot.windows.first, "TextEdit has no window")
        let region = CUScreenRegion(x: Double(window.x), y: Double(window.y), w: 240, h: 120)
        let zoomed = await driver.zoom(pid: pid, region: region)
        let image = try XCTUnwrap(zoomed, "zoom returned no image")
        XCTAssertEqual(image.region, region, "the close-up reports the screen region it shows")
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        XCTAssertEqual(Double(image.width), 240 * Double(scale), accuracy: 2, "one point = backing-scale pixels")
        XCTAssertEqual(Double(image.height), 120 * Double(scale), accuracy: 2)
        XCTAssertFalse(image.base64.isEmpty)
    }

    /// A vision capture reports the screen region its pixels show (the
    /// captured window), which is what `target.point` maps through.
    func testVisionCaptureCarriesTheWindowRegion() async throws {
        try requireLiveInput()
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Test runner lacks Screen Recording permission.")
        let pid = try launchRichTextEdit()
        defer { terminateAndWait(pid) }

        let snapshot = await driver.capture(pid: pid, tier: .vision)
        let image = try XCTUnwrap(snapshot.image, "vision capture returned no image")
        let region = try XCTUnwrap(image.region, "the frame must say where it is on screen")
        let window = try XCTUnwrap(snapshot.windows.first, "TextEdit has no window")
        XCTAssertEqual(region.x, Double(window.x), accuracy: 2)
        XCTAssertEqual(region.y, Double(window.y), accuracy: 2)
        XCTAssertEqual(region.w, Double(window.w), accuracy: 2)
        XCTAssertEqual(region.h, Double(window.h), accuracy: 2)
        XCTAssertEqual(
            Double(image.width) / region.w,
            Double(image.height) / region.h,
            accuracy: 0.05,
            "pixels per point must match on both axes"
        )
    }

    // MARK: - Helpers

    private func roles(_ snapshot: CUSnapshot) -> String {
        Set(snapshot.elements.map(\.role)).sorted().joined(separator: ",")
    }

    private func bringFinderToFront() throws -> pid_t {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { throw XCTSkip("Finder is not running.") }
        finder.activate()
        Thread.sleep(forTimeInterval: 0.8)
        return finder.processIdentifier
    }

    private func launchRichTextEdit() throws -> pid_t {
        let path = "/tmp/cu_surface_\(getpid()).rtf"
        let rtf = #"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0\fs24 Surface proof}"#
        FileManager.default.createFile(atPath: path, contents: Data(rtf.utf8), attributes: nil)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "TextEdit", path]
        try proc.run()
        proc.waitUntilExit()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first {
                Thread.sleep(forTimeInterval: 1.5)
                return app.processIdentifier
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw XCTSkip("Could not launch TextEdit.")
    }

    private func terminateAndWait(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.terminate()
        let deadline = Date().addingTimeInterval(5)
        while !app.isTerminated, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if !app.isTerminated { app.forceTerminate() }
    }
}
