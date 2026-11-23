import Foundation
import XCTest

@testable import OsaurusCLICore

/// Issue #3479: a slow app must be reported as running, never relaunched.
final class LaunchDecisionTests: XCTestCase {
    func testHealthyOnFirstAnswer() async {
        let state = await ServerControl.probe(
            port: 1337,
            healthCheck: { _, _ in true },
            appRunning: { XCTFail("not consulted when healthy"); return false },
            pause: {}
        )
        XCTAssertEqual(state, .healthy)
    }

    func testRetriesHealthBeforeGivingUp() async {
        var calls = 0
        let state = await ServerControl.probe(
            port: 1337,
            attempts: 2,
            healthCheck: { _, _ in
                calls += 1
                return calls == 2
            },
            appRunning: { false },
            pause: {}
        )
        XCTAssertEqual(state, .healthy)
        XCTAssertEqual(calls, 2)
    }

    func testRunningAppThatDoesNotAnswerIsNotReportedAsStopped() async {
        let state = await ServerControl.probe(
            port: 1337,
            healthCheck: { _, _ in false },
            appRunning: { true },
            pause: {}
        )
        XCTAssertEqual(state, .appRunningNotAnswering)
    }

    func testAppNotRunning() async {
        let state = await ServerControl.probe(
            port: 1337,
            healthCheck: { _, _ in false },
            appRunning: { false },
            pause: {}
        )
        XCTAssertEqual(state, .appNotRunning)
    }

    func testHealthUsesTheLongerTimeout() async {
        var timeouts: [TimeInterval] = []
        _ = await ServerControl.probe(
            port: 1337,
            healthCheck: { _, timeout in
                timeouts.append(timeout)
                return false
            },
            appRunning: { false },
            pause: {}
        )
        XCTAssertEqual(timeouts, [2.0, 2.0])
    }

    func testStatusDescribesEachState() {
        XCTAssertEqual(StatusCommand.describe(.healthy, port: 1337), "running (port 1337)")
        XCTAssertEqual(
            StatusCommand.describe(.appRunningNotAnswering, port: 1337),
            "app running, server not answering (port 1337)"
        )
        XCTAssertEqual(StatusCommand.describe(.appNotRunning, port: 1337), "stopped")
    }

    func testDuplicateInstancesOutrankEverything() {
        let diagnosis = InstallationDiagnostics.classify(
            apps: [],
            cliVersion: nil,
            healthy: true,
            portOwner: nil,
            runningInstances: 2
        )
        XCTAssertEqual(diagnosis, .duplicateInstances)
    }
}

final class AppIdentityTests: XCTestCase {
    private func makeApp(bundleId: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-identity-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Osaurus Beta.app", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleId],
            format: .xml,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let cli = helpers.appendingPathComponent("osaurus")
        FileManager.default.createFile(atPath: cli.path, contents: Data())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return cli
    }

    func testReadsTheCompanionAppBundleId() throws {
        let cli = try makeApp(bundleId: "com.dinoki.osaurus.beta")
        XCTAssertEqual(
            AppIdentity.resolveBundleIdentifier(environment: [:], executablePath: cli.path),
            "com.dinoki.osaurus.beta"
        )
    }

    func testEnvironmentOverrideWins() throws {
        let cli = try makeApp(bundleId: "com.dinoki.osaurus.beta")
        XCTAssertEqual(
            AppIdentity.resolveBundleIdentifier(
                environment: ["OSAURUS_APP_BUNDLE_ID": "ai.osaurus.proof"],
                executablePath: cli.path
            ),
            "ai.osaurus.proof"
        )
    }

    func testStandaloneCLIFallsBackToStable() {
        XCTAssertEqual(
            AppIdentity.resolveBundleIdentifier(environment: [:], executablePath: "/usr/local/bin/osaurus-dev"),
            "com.dinoki.osaurus"
        )
    }
}

final class ServeOptionsTests: XCTestCase {
    func testPlainServeLeavesExposureAlone() throws {
        let options = try ServeCommand.parseOptions([])
        XCTAssertNil(options.expose)
        XCTAssertNil(ServeCommand.serveUserInfo(options)["expose"])
    }

    func testExposeAndNoExpose() throws {
        XCTAssertEqual(try ServeCommand.parseOptions(["--expose"]).expose, true)
        XCTAssertEqual(try ServeCommand.parseOptions(["--no-expose"]).expose, false)
        XCTAssertEqual(
            ServeCommand.serveUserInfo(try ServeCommand.parseOptions(["--no-expose"]))["expose"] as? Bool,
            false
        )
        XCTAssertThrowsError(try ServeCommand.parseOptions(["--expose", "--no-expose"]))
        XCTAssertEqual(
            ServeCommand.listeningLine(port: 1337, expose: true),
            "listening on http://127.0.0.1:1337 and on your local network"
        )
        XCTAssertEqual(ServeCommand.listeningLine(port: 1337, expose: false), "listening on http://127.0.0.1:1337")
    }

    func testHelpDoesNotStartAnything() throws {
        XCTAssertTrue(try ServeCommand.parseOptions(["--help"]).help)
    }

    func testRejectsUnknownFlagsAndBadPorts() {
        XCTAssertThrowsError(try ServeCommand.parseOptions(["--prot", "8080"]))
        XCTAssertThrowsError(try ServeCommand.parseOptions(["--port", "0"]))
        XCTAssertThrowsError(try ServeCommand.parseOptions(["--port", "abc"]))
        XCTAssertThrowsError(try ServeCommand.parseOptions(["--port"]))
        XCTAssertThrowsError(try ServeCommand.parseOptions(["--interval", "-1"]))
    }

    func testPortAndSupervise() throws {
        let options = try ServeCommand.parseOptions(["--port", "8080", "--supervise", "--interval", "5"])
        XCTAssertEqual(options.port, 8080)
        XCTAssertTrue(options.supervise)
        XCTAssertEqual(options.probeInterval, 5)
        XCTAssertEqual(ServeCommand.serveUserInfo(options)["port"] as? Int, 8080)
    }
}
