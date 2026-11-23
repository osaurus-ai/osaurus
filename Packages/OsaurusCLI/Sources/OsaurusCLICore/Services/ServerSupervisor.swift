//
//  ServerSupervisor.swift
//  osaurus
//
//  Keeps the Osaurus server alive across app quit/crash. Periodically probes
//  the server and launches the app only when it is not running. Intended to
//  run as a long-lived process under a launchd KeepAlive LaunchAgent, so the
//  server (and the in-app scheduler that only ticks while the app is
//  running) survives quit, crash, logout, and reboot.
//

import Foundation

/// A long-running keep-alive loop for the Osaurus server.
///
/// On each iteration it probes the server. A stopped app is launched; a
/// running app that does not answer is only asked to serve again, because
/// launching then would start a second copy. All collaborators are injected
/// so the loop logic is unit-testable without a real server, app, or sleep.
public struct ServerSupervisor: Sendable {
    /// Port to probe.
    public let port: Int
    /// Seconds between probes.
    public let probeInterval: TimeInterval
    /// Number of iterations to run before returning. `nil` runs forever
    /// (production); a finite value bounds the loop for tests.
    public let maxIterations: Int?

    let probe: @Sendable (Int) async -> ServerState
    /// Launch the app and request serve.
    let launchAndServe: @Sendable () async -> Void
    /// Ask an already running app to start its server.
    let requestServe: @Sendable () async -> Void
    let sleep: @Sendable (TimeInterval) async -> Void
    let log: @Sendable (String) -> Void

    public init(
        port: Int,
        probeInterval: TimeInterval = 15.0,
        maxIterations: Int? = nil,
        probe: @escaping @Sendable (Int) async -> ServerState = {
            await ServerControl.probe(port: $0)
        },
        launchAndServe: @escaping @Sendable () async -> Void,
        requestServe: @escaping @Sendable () async -> Void,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        },
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.port = port
        self.probeInterval = probeInterval
        self.maxIterations = maxIterations
        self.probe = probe
        self.launchAndServe = launchAndServe
        self.requestServe = requestServe
        self.sleep = sleep
        self.log = log
    }

    /// Run the supervise loop. Returns only after `maxIterations` iterations;
    /// in production (`maxIterations == nil`) it never returns.
    public func run() async {
        log("supervising osaurus server on port \(port) (probe every \(Int(probeInterval))s)")
        var wasHealthy = true
        var iteration = 0
        while maxIterations.map({ iteration < $0 }) ?? true {
            let state = await probe(port)
            switch state {
            case .healthy:
                if !wasHealthy { log("server on port \(port) is back up") }
            case .appNotRunning:
                log("osaurus is not running — launching it")
                await launchAndServe()
            case .appRunningNotAnswering:
                log("osaurus is running but not answering on port \(port) — asking it to serve")
                await requestServe()
            }
            wasHealthy = state == .healthy
            iteration += 1
            await sleep(probeInterval)
        }
    }
}
