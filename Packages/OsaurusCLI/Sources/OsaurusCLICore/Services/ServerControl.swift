//
//  ServerControl.swift
//  osaurus
//
//  One decision about the local server that every command and the
//  supervisor share: answering, app running but not answering, or app not
//  running. Only the last one may launch the app; launching on anything
//  else starts a second copy (issue #3479).
//

import AppKit
import Foundation

public enum ServerState: String, Equatable, Sendable {
    case healthy
    case appRunningNotAnswering
    case appNotRunning
}

public struct ServerControl {
    public static func checkHealth(port: Int, timeout: TimeInterval = 2.0) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    public static func isAppRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
            .contains { !$0.isTerminated }
    }

    /// Health is tried more than once so a busy app (a model loading, a
    /// long main-thread stall) is not mistaken for a stopped one.
    public static func probe(
        port: Int,
        attempts: Int = 2,
        timeout: TimeInterval = 2.0,
        healthCheck: (Int, TimeInterval) async -> Bool = { await checkHealth(port: $0, timeout: $1) },
        appRunning: () -> Bool = { isAppRunning() },
        pause: () async -> Void = { try? await Task.sleep(nanoseconds: 300_000_000) }
    ) async -> ServerState {
        for attempt in 0 ..< max(1, attempts) {
            if await healthCheck(port, timeout) { return .healthy }
            if attempt < attempts - 1 { await pause() }
        }
        return appRunning() ? .appRunningNotAnswering : .appNotRunning
    }

    /// Polls `/health` until it answers or `seconds` pass.
    public static func waitForHealth(port: Int, seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if await checkHealth(port: port, timeout: 1.0) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        return false
    }

    /// Ensures the server is answering and returns the port. Launches the
    /// app only when it is not running; a running app gets time to answer.
    /// Exits the process with failure when the server does not come up.
    @MainActor
    public static func ensureServerReadyOrExit() async -> Int {
        let port = Configuration.resolveConfiguredPort() ?? 1337
        let state = await AppControl.launchAppIfNeeded(port: port)
        switch state {
        case .healthy:
            return port
        case .appNotRunning:
            if await waitForHealth(port: port, seconds: 20) { return port }
            fputs("Osaurus did not start its server on port \(port). Run `osaurus doctor` for details.\n", stderr)
        case .appRunningNotAnswering:
            if await waitForHealth(port: port, seconds: 8) { return port }
            fputs(
                "Osaurus is running but its server is not answering on port \(port). "
                    + "Start it with `osaurus serve`, or run `osaurus doctor` if it is stuck.\n",
                stderr
            )
        }
        exit(EXIT_FAILURE)
    }
}
