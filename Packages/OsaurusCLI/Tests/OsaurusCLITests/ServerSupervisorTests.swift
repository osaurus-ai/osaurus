import Foundation
import XCTest

@testable import OsaurusCLICore

final class ServerSupervisorTests: XCTestCase {
    /// Scripts the probe sequence and records launches and serve requests.
    private actor Recorder {
        private var states: [ServerState]
        private var index = 0
        private(set) var launchCount = 0
        private(set) var serveCount = 0
        private(set) var probeCount = 0

        init(_ states: [ServerState]) {
            self.states = states
        }

        func next() -> ServerState {
            defer { index += 1 }
            probeCount += 1
            if index < states.count { return states[index] }
            return states.last ?? .healthy
        }

        func recordLaunch() { launchCount += 1 }
        func recordServe() { serveCount += 1 }
    }

    private func supervisor(_ rec: Recorder, iterations: Int) -> ServerSupervisor {
        ServerSupervisor(
            port: 1337,
            probeInterval: 0,
            maxIterations: iterations,
            probe: { _ in await rec.next() },
            launchAndServe: { await rec.recordLaunch() },
            requestServe: { await rec.recordServe() },
            sleep: { _ in },
            log: { _ in }
        )
    }

    func testLaunchesOnEveryTickTheAppIsNotRunning() async {
        let rec = Recorder([.appNotRunning, .appNotRunning, .appNotRunning])
        await supervisor(rec, iterations: 3).run()

        let launches = await rec.launchCount
        let probes = await rec.probeCount
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(launches, 3)
    }

    func testNeverActsWhileHealthy() async {
        let rec = Recorder([.healthy, .healthy, .healthy, .healthy])
        await supervisor(rec, iterations: 4).run()

        let launches = await rec.launchCount
        let serves = await rec.serveCount
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(serves, 0)
    }

    /// Issue #3479: a slow app must never be launched a second time.
    func testRunningButNotAnsweringOnlyRequestsServe() async {
        let rec = Recorder([.appRunningNotAnswering, .appRunningNotAnswering, .healthy])
        await supervisor(rec, iterations: 3).run()

        let launches = await rec.launchCount
        let serves = await rec.serveCount
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(serves, 2)
    }

    func testLaunchesOnlyWhileDownAcrossRecovery() async {
        let rec = Recorder([.appNotRunning, .appNotRunning, .healthy, .healthy])
        await supervisor(rec, iterations: 4).run()

        let launches = await rec.launchCount
        XCTAssertEqual(launches, 2)
    }
}
