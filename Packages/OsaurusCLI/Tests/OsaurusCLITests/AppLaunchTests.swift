import Foundation
import XCTest

@testable import OsaurusCLICore

final class AppLaunchTests: XCTestCase {
    /// Scripts the `/health` answers a launch path sees and counts the probes.
    private actor HealthScript {
        private var answers: [Bool]
        private var index = 0
        private(set) var probeCount = 0

        init(_ answers: [Bool]) {
            self.answers = answers
        }

        func next() -> Bool {
            defer { index += 1 }
            probeCount += 1
            if index < answers.count { return answers[index] }
            return answers.last ?? false
        }
    }

    /// Counts polls so a test can prove the loop stops as soon as health appears.
    private func waitForHealth(_ script: HealthScript, timeout: TimeInterval = 10.0) async -> Bool {
        await AppControl.waitForHealth(
            port: 1337,
            timeout: timeout,
            pollInterval: 0,
            healthCheck: { _ in await script.next() },
            sleep: { _ in }
        )
    }

    func testWaitForHealthReturnsImmediatelyWhenTheRunningAppAnswers() async {
        let script = HealthScript([true])

        let healthy = await waitForHealth(script)

        XCTAssertTrue(healthy)
        let probes = await script.probeCount
        XCTAssertEqual(probes, 1, "a healthy running app must not be probed again")
    }

    func testWaitForHealthKeepsPollingWhileTheRunningAppIsSlow() async {
        // Mimics the reported case: the app is up but /health misses the first
        // 0.5 s probe on wake. The wait must keep polling and never relaunch.
        let script = HealthScript([false, false, false, true])

        let healthy = await waitForHealth(script)

        XCTAssertTrue(healthy)
        let probes = await script.probeCount
        XCTAssertEqual(probes, 4)
    }

    func testWaitForHealthReportsAFailingServerInsteadOfAssumingSuccess() async {
        let script = HealthScript([false])

        let healthy = await waitForHealth(script, timeout: 0)

        XCTAssertFalse(healthy)
    }

    func testWaitForHealthStopsPollingAfterTheLastAnswerIsHealthy() async {
        let script = HealthScript([true, true, true])

        _ = await waitForHealth(script)

        let probes = await script.probeCount
        XCTAssertEqual(probes, 1)
    }

    /// The reported bug: the app is up, /health misses the 0.5 s probe on wake,
    /// and the CLI starts another instance. A running process must mean "wait",
    /// never "launch".
    func testRunningAppIsWaitedOnEvenWhenHealthFails() {
        XCTAssertEqual(
            AppControl.launchDecision(serverHealthy: false, appRunning: true),
            .waitForRunningApp
        )
    }

    func testNoAppProcessMeansLaunch() {
        XCTAssertEqual(
            AppControl.launchDecision(serverHealthy: false, appRunning: false),
            .launch
        )
    }

    func testHealthyServerIsNeverDisturbed() {
        XCTAssertEqual(
            AppControl.launchDecision(serverHealthy: true, appRunning: true),
            .serverHealthy
        )
        // A healthy server with no reported process still needs no launch.
        XCTAssertEqual(
            AppControl.launchDecision(serverHealthy: true, appRunning: false),
            .serverHealthy
        )
    }

    func testLaunchIsOnlyChosenWhenBothChecksSayTheAppIsGone() {
        let all = [
            (true, true), (true, false), (false, true), (false, false),
        ]
        let launches = all.filter {
            AppControl.launchDecision(serverHealthy: $0.0, appRunning: $0.1) == .launch
        }
        XCTAssertEqual(launches.count, 1, "exactly one app state should start a process")
        XCTAssertEqual(launches.first?.0, false)
        XCTAssertEqual(launches.first?.1, false)
    }

}
